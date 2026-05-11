"""Structural lint for claude-agent Python LP .org files.

Adapted from skill-scout-server's ``scripts/check_org_structure.py`` for
the single-master-`.org` layout (one ``claude-agent-python.org`` for the
entire ``python/claude_agent/`` package).

Enforces rules from ``.claude/rules/python-literate-programming.md``
that can be checked mechanically:

  1. Section nesting depth <= MAX_DEPTH (currently 5).
  2. No grab-bag headings (Functions / Helpers / Utilities / Misc / Things / Stuff).
  3. Sections that tangle to a Python file open with prose, not a src block.

Exits non-zero on any violation.  Designed to be invoked from
``make check-python-structure``.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

MAX_DEPTH = 5
GRAB_BAG_RE = re.compile(
    r"^(Functions|Helpers|Utilities|Misc|Things|Stuff)\s*(?::[\w:]+:)?\s*$",
    re.IGNORECASE,
)
HEADING_RE = re.compile(r"^(\*+)\s+(.*?)\s*$")
TANGLE_PY_RE = re.compile(r":tangle\s+\S*python/claude_agent/[^\s]+\.py")
SRC_BEGIN_RE = re.compile(r"^\s*#\+(?:BEGIN_SRC|begin_src)\b", re.IGNORECASE)


@dataclass
class Violation:
    line: int
    rule: str
    message: str

    def format(self, path: Path) -> str:
        return f"{path}:{self.line}: [{self.rule}] {self.message}"


def lint(path: Path) -> list[Violation]:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    violations: list[Violation] = []

    for idx, line in enumerate(lines, start=1):
        m = HEADING_RE.match(line)
        if m:
            depth = len(m.group(1))
            heading = m.group(2)
            if depth > MAX_DEPTH:
                violations.append(
                    Violation(
                        idx,
                        f"depth>{MAX_DEPTH}",
                        f"section nesting depth is {depth}, max is {MAX_DEPTH}: {heading!r}",
                    )
                )
            stripped = re.sub(r"\s*:[\w:]+:\s*$", "", heading).strip()
            if GRAB_BAG_RE.match(stripped):
                violations.append(
                    Violation(
                        idx,
                        "grab-bag-heading",
                        f"forbidden grab-bag heading {stripped!r} -- name the concept",
                    )
                )

    violations.extend(_check_prose_before_src(lines))
    return violations


def _check_prose_before_src(lines: list[str]) -> list[Violation]:
    """For every section that tangles to python/claude_agent/*.py,
    the lines between its heading and the next heading must contain at
    least one non-empty prose line *before* the first src block."""
    out: list[Violation] = []
    section_starts: list[tuple[int, int]] = []
    for i, line in enumerate(lines):
        m = HEADING_RE.match(line)
        if m:
            section_starts.append((i, len(m.group(1))))
    section_starts.append((len(lines), 0))

    for s_idx in range(len(section_starts) - 1):
        start, _depth = section_starts[s_idx]
        end, _next_depth = section_starts[s_idx + 1]
        body = lines[start + 1 : end]
        body_text = "\n".join(body)
        if not TANGLE_PY_RE.search(body_text):
            continue

        first_src_offset = None
        for j, bline in enumerate(body):
            if SRC_BEGIN_RE.match(bline):
                first_src_offset = j
                break
        if first_src_offset is None:
            continue

        before_src = body[:first_src_offset]
        has_prose = any(
            stripped
            and not stripped.startswith("#")
            and not stripped.startswith(":")
            and not stripped.startswith("*")
            for stripped in (bline.strip() for bline in before_src)
        )
        if not has_prose:
            heading_lineno = start + 1
            out.append(
                Violation(
                    heading_lineno,
                    "no-prose-before-src",
                    "section tangles to python/claude_agent/*.py but has no prose before the first src block",
                )
            )
    return out


def main(argv: list[str]) -> int:
    targets = [Path(p) for p in argv[1:]]
    if not targets:
        print(
            "check-org-structure: no .org files passed",
            file=sys.stderr,
        )
        return 0

    total_violations = 0
    for target in targets:
        if not target.exists():
            print(f"check-org-structure: {target} not found", file=sys.stderr)
            return 1
        violations = lint(target)
        for v in violations:
            print(v.format(target))
        total_violations += len(violations)

    if total_violations:
        print(
            f"\n{total_violations} structural violation(s) across "
            f"{len(targets)} file(s)",
            file=sys.stderr,
        )
        return 1
    print(f"check-org-structure: {len(targets)} file(s) OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
