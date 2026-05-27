#!/usr/bin/env python3
"""Quarterly LP-health audit — composite report.

Runs every measurement the LP-alignment workstream cares about, and
writes a Markdown report under tasks/audit-YYYY-Qq.md.  Designed to
be called from `make audit-quarterly` once a quarter (per the
=lp-agent-long-horizon-audit-cadence= rule).

Measurements:
1. Prose-less src-after-heading sections (target: 0)
2. CLT element-interactivity violations (≥8 depth-2 children)
3. Big-defun bodies >80 lines
4. Cross-module --internal-call leakage
5. :CUSTOM_ID: coverage on concept-level headings
6. Bare =module.org= prose mentions outside src blocks
7. cl-defgeneric specialisation ratio
8. cl-defstruct → -create factory wrapper ratio
9. Public defuns without docstring
10. Verified-by pointer coverage

CLI: python3 scripts/audit_lp_health.py [--output PATH] [--quiet]
"""
from __future__ import annotations
import argparse
import datetime as _dt
import re
import sys
from collections import Counter
from pathlib import Path

LP_ROOT = Path("lp")
DRAFTS = "_drafts"


def _walk_lp():
    return sorted(f for f in LP_ROOT.rglob("*.org") if DRAFTS not in f.parts)


def measure_prose_less(files):
    total = 0
    for f in files:
        if f.name in ("README.org", "INDEX.org", "PROTOCOL-MAP.org"):
            continue
        text = f.read_text().splitlines()
        for i, line in enumerate(text):
            m = re.match(r"^(\*+) (.+)$", line)
            if not m:
                continue
            j = i + 1
            if j < len(text) and text[j].strip() == ":PROPERTIES:":
                while j < len(text) and text[j].strip() != ":END:":
                    j += 1
                j += 1
            while j < len(text) and text[j].strip() == "":
                j += 1
            if j < len(text) and text[j].strip().lower().startswith("#+begin_src"):
                total += 1
    return total


def measure_clt_violations(files):
    out = []
    for f in files:
        text = f.read_text().splitlines()
        top = None
        depth2 = 0
        for line in text:
            m = re.match(r"^(\*+) (.+)$", line)
            if not m:
                continue
            d = len(m.group(1))
            if d == 1:
                if top and depth2 >= 8:
                    out.append((depth2, top, str(f)))
                top = m.group(2)
                depth2 = 0
            elif d == 2:
                depth2 += 1
        if top and depth2 >= 8:
            out.append((depth2, top, str(f)))
    return out


def measure_big_defuns(files):
    out = []
    for f in files:
        lines = f.read_text().splitlines()
        in_src = False
        in_defun = False
        depth = 0
        defun_name = ""
        defun_start = 0
        in_doc = False
        doc_lines = 0
        for i, line in enumerate(lines):
            ls = line.lstrip().lower()
            if ls.startswith("#+begin_src elisp"):
                in_src = True
                continue
            if ls.startswith("#+end_src"):
                in_src = False
                in_defun = False
                continue
            if not in_src:
                continue
            if not in_defun:
                m = re.match(r"\((?:cl-)?(?:defun|defmethod)\s+(\S+)", line)
                if m:
                    in_defun = True
                    defun_start = i
                    defun_name = m.group(1)
                    depth = line.count("(") - line.count(")")
                    in_doc = False
                    doc_lines = 0
            else:
                stripped = line.strip()
                if not in_doc and stripped.startswith('"'):
                    in_doc = True
                    doc_lines += 1
                    if stripped.endswith('"') and len(stripped) > 1 and not stripped.endswith('\\"'):
                        in_doc = False
                elif in_doc:
                    doc_lines += 1
                    if line.rstrip().endswith('"') and not line.rstrip().endswith('\\"'):
                        in_doc = False
                depth += line.count("(") - line.count(")")
                if depth <= 0:
                    body = (i - defun_start + 1) - doc_lines
                    if body > 80:
                        out.append((body, defun_name, str(f), defun_start + 1))
                    in_defun = False
    return sorted(out, reverse=True)


def measure_cross_module_internal(files):
    defines = {}
    calls = []
    for f in files:
        text = f.read_text().splitlines()
        in_src = False
        for line in text:
            ls = line.lstrip().lower()
            if ls.startswith("#+begin_src elisp") or ls.startswith("#+begin_src emacs-lisp"):
                in_src = True
                continue
            if ls.startswith("#+end_src"):
                in_src = False
                continue
            if not in_src:
                continue
            for m in re.finditer(r"\((?:cl-)?(?:defun|defmethod)\s+([a-z0-9-]+)", line):
                defines[m.group(1)] = str(f)
            for m in re.finditer(r"\(([a-z][a-z0-9-]*--[a-z0-9-]+)", line):
                calls.append((str(f), m.group(1)))
    n = 0
    for cf, sym in calls:
        df = defines.get(sym)
        if df and df != cf:
            n += 1
    return n


def measure_anchor_coverage(files):
    total_h = 0
    total_a = 0
    for f in files:
        text = f.read_text().splitlines()
        for line in text:
            if re.match(r"^\*+ ", line):
                total_h += 1
            if re.match(r"^:CUSTOM_ID:", line.lstrip()):
                total_a += 1
    return total_a, total_h


def measure_bare_module_refs(files):
    n = 0
    pat = re.compile(r"=[a-z][a-z0-9-]*\.org=")
    for f in files:
        text = f.read_text().splitlines()
        in_src = False
        for line in text:
            ls = line.lstrip().lower()
            if ls.startswith("#+begin_src"):
                in_src = True
                continue
            if ls.startswith("#+end_src"):
                in_src = False
                continue
            if in_src:
                continue
            for m in pat.finditer(line):
                if "[[file:" not in line[: m.start()]:
                    n += 1
    return n


def measure_protocol_health(files):
    generics = set()
    method_count = Counter()
    structs = 0
    factories = 0
    for f in files:
        text = f.read_text()
        for m in re.finditer(r"\(cl-defgeneric\s+([a-z0-9-]+)", text):
            generics.add(m.group(1))
        for m in re.finditer(r"\(cl-defmethod\s+([a-z0-9-]+)", text):
            method_count[m.group(1)] += 1
        structs += len(re.findall(r"\(cl-defstruct", text))
        factories += len(re.findall(r"\(defun\s+[a-z0-9-]+-create\b", text))
    return len(generics), sum(method_count.values()), structs, factories


def measure_docstring_gaps(files):
    no_doc = 0
    for f in files:
        lines = f.read_text().splitlines()
        in_src = False
        in_defun = False
        depth = 0
        defun_start = 0
        for i, line in enumerate(lines):
            ls = line.lstrip().lower()
            if ls.startswith("#+begin_src elisp"):
                in_src = True
                continue
            if ls.startswith("#+end_src"):
                in_src = False
                in_defun = False
                continue
            if not in_src:
                continue
            if not in_defun:
                m = re.match(r"\((?:cl-)?(?:defun|defmethod)\s+([a-z0-9-]+)", line)
                if m and "--" not in m.group(1):
                    in_defun = True
                    defun_start = i
                    depth = line.count("(") - line.count(")")
            else:
                depth += line.count("(") - line.count(")")
                if depth <= 0:
                    doc_found = any(
                        re.search(r'^\s*"', lines[k])
                        for k in range(defun_start, min(defun_start + 10, i + 1))
                    )
                    if not doc_found:
                        no_doc += 1
                    in_defun = False
    return no_doc


def measure_verified_by_coverage(files):
    n_total = 0
    n_with = 0
    for f in files:
        if f.name in ("README.org", "INDEX.org", "PROTOCOL-MAP.org"):
            continue
        n_total += 1
        if "Verified by:" in f.read_text():
            n_with += 1
    return n_with, n_total


def quarter_label(date):
    q = (date.month - 1) // 3 + 1
    return f"{date.year}-Q{q}"


def render_report(date):
    files = _walk_lp()
    prose_less = measure_prose_less(files)
    clt = measure_clt_violations(files)
    big_defuns = measure_big_defuns(files)
    xmod = measure_cross_module_internal(files)
    anchors, headings = measure_anchor_coverage(files)
    bare_refs = measure_bare_module_refs(files)
    gen, methods, structs, factories = measure_protocol_health(files)
    no_doc = measure_docstring_gaps(files)
    vb_with, vb_total = measure_verified_by_coverage(files)

    label = quarter_label(date)
    pct = lambda a, b: f"{a*100//b}%" if b else "n/a"

    lines = []
    lines.append(f"# LP-health audit — {label}")
    lines.append("")
    lines.append(f"_Generated by `make audit-quarterly` on {date.isoformat()}._")
    lines.append("")
    lines.append(f"Files scanned: {len(files)}.  Headings: {headings}.")
    lines.append("")
    lines.append("## Top-line measurements")
    lines.append("")
    lines.append("| Metric | Value | Target | Status |")
    lines.append("|--------|-------|--------|--------|")
    lines.append(
        f"| Prose-less src sections | {prose_less} | 0 | "
        f"{'✓' if prose_less == 0 else '⚠️ ' + str(prose_less)} |"
    )
    lines.append(
        f"| CLT violations (≥8 depth-2 children) | {len(clt)} | 0 | "
        f"{'✓' if not clt else '⚠️ ' + str(len(clt))} |"
    )
    lines.append(
        f"| Big defuns (body >80 lines) | {len(big_defuns)} | 0 | "
        f"{'✓' if not big_defuns else '⚠️ ' + str(len(big_defuns))} |"
    )
    lines.append(f"| Cross-module `--` calls | {xmod} | trending ↓ | n/a |")
    lines.append(
        f"| :CUSTOM_ID: coverage | {anchors}/{headings} "
        f"({pct(anchors, headings)}) | ≥30% | "
        f"{'✓' if anchors * 100 >= 30 * headings else '⚠️'} |"
    )
    lines.append(
        f"| Bare `=module.org=` prose refs | {bare_refs} | 0 | "
        f"{'✓' if bare_refs == 0 else '⚠️ ' + str(bare_refs)} |"
    )
    lines.append(
        f"| cl-defgeneric / cl-defmethod | {gen} / {methods} | "
        f"impl/generic ≥2 | "
        f"{'✓' if gen and methods >= 2*gen else '⚠️'} |"
    )
    lines.append(
        f"| cl-defstruct / public factory | {structs} / {factories} | "
        f"factory:struct ≥50% | "
        f"{'✓' if structs and factories*2 >= structs else '⚠️'} |"
    )
    lines.append(
        f"| Public defuns w/o docstring | {no_doc} | 0 | "
        f"{'✓' if no_doc == 0 else '⚠️ ' + str(no_doc)} |"
    )
    lines.append(
        f"| Verified-by coverage | {vb_with}/{vb_total} "
        f"({pct(vb_with, vb_total)}) | ≥70% | "
        f"{'✓' if vb_with * 100 >= 70 * vb_total else '⚠️'} |"
    )
    lines.append("")

    if clt:
        lines.append("## CLT violations")
        lines.append("")
        for cnt, sec, f in clt:
            lines.append(f"- **{cnt} children** in `{sec}` ({f})")
        lines.append("")

    if big_defuns:
        lines.append("## Big defuns (body >80 lines)")
        lines.append("")
        for body, name, f, ln in big_defuns:
            lines.append(f"- **{body} lines** `{name}` ({f}:{ln})")
        lines.append("")

    lines.extend([
        "## Trend (compare across quarters)",
        "",
        "Find prior audits at `tasks/audit-*.md`.  When a metric jumps",
        "or a target flips ✓→⚠️, dig in and either fix or document.",
        "",
        "## Process notes",
        "",
        "Per `lp-agent-long-horizon-audit-cadence` rule (in literate-agent),",
        "this audit should run every quarter.  Triggering this run from",
        "`make audit-quarterly` re-renders the report at the same path",
        "(overwriting); commit + diff against the prior version to see",
        "drift.",
        "",
    ])

    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    today = _dt.date.today()
    report = render_report(today)

    out = args.output
    if out is None:
        Path("tasks").mkdir(parents=True, exist_ok=True)
        out = Path("tasks") / f"audit-{quarter_label(today)}.md"
    out.write_text(report)

    if not args.quiet:
        print(report, end="")
        print(f"\n  → written to {out}")
    else:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
