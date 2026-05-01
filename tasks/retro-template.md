# Quarterly retro template

Run on the **first Monday of each quarter**. Copy this file to
`tasks/retro-YYYY-Q.md`, fill in the metrics, write the "what's working /
what isn't" prose, then promote 0-3 lessons to `CLAUDE.md` rules and
0-3 tasks to a new milestone.

Source: lens #18 in `tasks/ai-codebase-mastery-action-plan.org`. The whole
point is *measure real ROI*, not perceived ROI — METR 2025 RCT showed
developers self-report +20% productivity while actually being −19%.

## How to gather the metrics

```bash
# DORA 4 (last 90 days)
gh pr list --state merged --limit 200 --json mergedAt,createdAt | \
  jq '[.[] | (((.mergedAt | fromdate) - (.createdAt | fromdate)) / 3600)] | (add/length, max, min)'
# → mean / max / min hours from PR open to merge

# AI-specific 6:
# - PR size (lockfiles excluded already; see ci.yml)
gh pr list --state merged --limit 100 --json additions,deletions | \
  jq '[.[] | (.additions + .deletions)] | (add/length, max)'

# - Unreviewed merge rate (PRs merged with 0 review comments)
gh pr list --state merged --limit 100 --json reviews | \
  jq '[.[] | select(.reviews | length == 0)] | length'

# - AI rejection rate / reasons (read tasks/lessons.md last quarter's entries)

# Token spend (Phoenix dashboard, by session_id):
curl -s -X POST http://localhost:6006/graphql -H "Content-Type: application/json" \
  -d '{"query": "query { node(id: \"UHJvamVjdDoy\") { ... on Project { spans(first: 1000, sort: {col: startTime, dir: desc}) { edges { node { attributes } } } } } }"}' \
  | jq '[.data.node.spans.edges[].node.attributes | fromjson? // empty | .["gen_ai.usage.input_tokens"] // 0 | tonumber] | add'
```

## Template

```
# Retro YYYY-Q

## DORA 4

| Metric | This quarter | Last quarter | Δ |
|--------|--------------|--------------|----|
| Deploy frequency | _/week |  | |
| Lead time (PR → merge) | _h | _h | |
| Change failure rate | _% | _% | |
| MTTR | _h | _h | |

## AI-specific 6

| Metric | This quarter | Last quarter | Δ |
|--------|--------------|--------------|----|
| Mean PR size (LOC, lockfile-excluded) | _ | _ | |
| % PRs > 400 LOC | _% | _% | |
| % PRs merged with 0 review comments | _% | _% | |
| AI PR rejection rate | _% | _% | |
| Mean token spend / task | _k | _k | |
| AI-attributed defect rate | _% | _% | |

## What's working

- (free-form prose, 3-5 bullets)

## What isn't

- (free-form prose, 3-5 bullets)

## AI rejection-reason taxonomy (top 5)

| Reason | Count | Promote to CLAUDE.md? |
|--------|-------|-----------------------|
| 1. … | _ | yes / no |
| 2. … | _ | |

(Pull from tasks/lessons.md entries since last retro.)

## Lessons → CLAUDE.md promotions (0-3)

- [ ] (specific rule + structural test if applicable)

## New milestones for next quarter (0-3)

- [ ] (specific, measurable, time-boxed)

## Reviewer

Author: _, reviewed by: _, date: YYYY-MM-DD
```

## When to promote a metric to a hard CI gate

If a metric has been red for **2 consecutive quarters** AND has a clear
mechanical fix → wire it as a CI failing job (mirror of the PR size cap
in `.github/workflows/ci.yml::pr-size`). Soft warnings that nobody acts on
become noise.
