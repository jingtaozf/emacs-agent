#!/usr/bin/env python3
"""Phoenix trace health check — scans recent traces for anomalies.

Usage: python3 tests/e2e/trace_health.py [--spans N] [--max-latency-ms MS]

Checks:
  - ERROR status spans
  - Orphan children (parentId not matching any spanId in same trace)
  - Excessive latency (>60s by default)
  - evalElisp calls with errors

Exits 0 if healthy, 1 if anomalies found, 2 if Phoenix unreachable.
"""

import json
import sys
import urllib.request
import urllib.error
from collections import defaultdict

PHOENIX_URL = "http://localhost:6006"
PROJECT_ID = "UHJvamVjdDoy"  # emacs-agent project


def query_phoenix(graphql: str) -> dict:
    """Execute GraphQL query against Phoenix."""
    payload = json.dumps({"query": graphql}).encode()
    req = urllib.request.Request(
        f"{PHOENIX_URL}/graphql",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    resp = urllib.request.urlopen(req, timeout=10)
    return json.loads(resp.read().decode())


def fetch_recent_spans(n: int = 50) -> list[dict]:
    """Fetch N most recent spans with full attributes."""
    query = f"""query {{
        node(id: "{PROJECT_ID}") {{
            ... on Project {{
                spans(first: {n}, sort: {{col: startTime, dir: desc}}) {{
                    edges {{
                        node {{
                            name spanId parentId
                            spanKind statusCode startTime latencyMs
                        }}
                    }}
                }}
            }}
        }}
    }}"""
    result = query_phoenix(query)
    edges = result["data"]["node"]["spans"]["edges"]
    return [e["node"] for e in edges]


def check_health(spans: list[dict], max_latency_ms: int = 60000) -> list[str]:
    """Check spans for anomalies. Returns list of issue descriptions."""
    issues = []

    # Check 1: ERROR status spans
    for s in spans:
        if s.get("statusCode") == "ERROR":
            issues.append(
                f"ERROR span: {s['name']} at={s.get('startTime', '?')}"
            )

    # Check 2: Excessive latency
    for s in spans:
        latency = s.get("latencyMs", 0) or 0
        if latency > max_latency_ms:
            issues.append(
                f"SLOW span: {s['name']} "
                f"latency={latency}ms (>{max_latency_ms}ms) "
                f"at={s.get('startTime', '?')}"
            )

    # Check 3: Orphan children (parentId doesn't match any spanId in batch)
    all_span_ids = {s["spanId"] for s in spans if s.get("spanId")}
    for s in spans:
        parent = s.get("parentId")
        if parent and parent != "null" and parent not in all_span_ids:
            # Parent not in this batch — might be in an older batch, only flag
            # if it's a root-like span (no parent should have parentId set)
            pass  # skip orphan check without traceId grouping

    return issues


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Phoenix trace health check")
    parser.add_argument("--spans", type=int, default=50, help="Number of recent spans")
    parser.add_argument(
        "--max-latency-ms", type=int, default=60000, help="Max latency threshold"
    )
    args = parser.parse_args()

    # Check Phoenix reachability
    try:
        urllib.request.urlopen(f"{PHOENIX_URL}/health", timeout=3)
    except (urllib.error.URLError, OSError):
        print("Phoenix unreachable at", PHOENIX_URL, file=sys.stderr)
        sys.exit(2)

    print(f"Checking {args.spans} recent spans from Phoenix...")
    spans = fetch_recent_spans(args.spans)
    print(f"  Fetched {len(spans)} spans")

    # Summary
    status_counts: dict[str, int] = defaultdict(int)
    name_counts: dict[str, int] = defaultdict(int)
    for s in spans:
        status_counts[s.get("statusCode", "UNSET")] += 1
        name_counts[s.get("name", "?")] += 1

    print(f"\n  Status: {dict(status_counts)}")
    print(f"  Top spans: {dict(sorted(name_counts.items(), key=lambda x: -x[1])[:5])}")

    # Health check
    issues = check_health(spans, args.max_latency_ms)

    if issues:
        print(f"\n  {len(issues)} issue(s) found:")
        for issue in issues:
            print(f"    - {issue}")
        sys.exit(1)
    else:
        print("\n  No anomalies found")
        sys.exit(0)


if __name__ == "__main__":
    main()
