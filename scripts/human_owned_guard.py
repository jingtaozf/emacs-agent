#!/usr/bin/env python3
"""Require human confirmation when an agent edit targets an Org section
marked ``:HUMAN_OWNED: yes``.

Reads a Claude Code PreToolUse event from stdin:

    {"tool_name": "Edit"|"Write"|"MultiEdit", "tool_input": {...}}

Prints a PreToolUse permission decision only when the edit overlaps a
protected section or touches the ``:HUMAN_OWNED:`` marker; otherwise prints
nothing so the call proceeds and other rules still apply.
"""

import json
import os
import re
import sys

DECISION = os.environ.get("HUMAN_OWNED_GUARD_DECISION", "ask")
HEADING_RE = re.compile(r"^(\*+)\s")
PROP_RE = re.compile(r"^\s*:HUMAN_OWNED:\s*(\S+)", re.IGNORECASE)
MARKER = ":HUMAN_OWNED:"
TRUTHY = {"yes", "true", "t", "1", "on"}

# Guard-the-guard: the protection's own *source* files always ask, even
# when they are not Org (you cannot mark a JSON file with an Org property).
# Matched by path suffix / basename.  Files that merely *use* the gate —
# e.g. the Pi extension — are NOT listed here: they carry a section-scoped
# :HUMAN_OWNED: property on just the gate section, so the rest of the file
# (tools, bridges) stays freely editable.  Listing a whole multi-purpose
# .org here was the 2026-06-07 over-block bug: every unrelated edit asked.
SELF_PROTECTED = (
    ".claude/settings.json",
    "scripts/human_owned_guard.py",
    "human-owned-guard.org",
)

# Best-effort shell write indicators for the Bash path (file-level — a
# shell command is opaque, so the exact touched section cannot be resolved).
WRITE_RE = re.compile(
    r"(>>?|>\||\btee\b|\bsed\b[^|]*\s-i|\bdd\b[^|]*\bof=|\btruncate\b|\bcp\b|\bmv\b)"
)

def protected_ranges(text):
    """Char ranges [start, end) of every section whose property drawer has
    ``:HUMAN_OWNED:`` set to a truthy value."""
    lines = text.splitlines(keepends=True)
    offsets, pos = [], 0
    for ln in lines:
        offsets.append(pos)
        pos += len(ln)
    total = pos

    heads = []  # (line_index, level)
    for i, ln in enumerate(lines):
        m = HEADING_RE.match(ln)
        if m:
            heads.append((i, len(m.group(1))))

    ranges = []
    for hi, (line_i, level) in enumerate(heads):
        owned, in_drawer, j = False, False, line_i + 1
        while j < len(lines):
            s = lines[j].strip()
            if not in_drawer:
                if s == ":PROPERTIES:":
                    in_drawer = True
                elif s == "":
                    pass
                else:
                    break
                j += 1
                continue
            if s == ":END:":
                break
            pm = PROP_RE.match(lines[j])
            if pm and pm.group(1).lower() in TRUTHY:
                owned = True
            j += 1
        if owned:
            start = offsets[line_i]
            end = total
            for (nl, nlevel) in heads[hi + 1:]:
                if nlevel <= level:
                    end = offsets[nl]
                    break
            ranges.append((start, end))
    return ranges


def _overlaps(a0, a1, b0, b1):
    return a0 < b1 and b0 < a1


def _occurrences(hay, needle):
    if not needle:
        return []
    out, i = [], hay.find(needle)
    while i != -1:
        out.append((i, i + len(needle)))
        i = hay.find(needle, i + 1)
    return out


def _bash_org_targets(cmd):
    """Org-looking path tokens in a shell command (best-effort)."""
    return re.findall(r"[^\s'\"<>|]+\.org", cmd or "")

def _extract(tool, ti):
    """Return (file_path, location_strings, marker_check_strings, whole_file)."""
    fp = ti.get("file_path")
    if tool == "Write":
        return fp, [], [ti.get("content", "")], True
    if tool == "Edit":
        old, new = ti.get("old_string", ""), ti.get("new_string", "")
        return fp, [old], [old, new], False
    if tool == "MultiEdit":
        loc, mark = [], []
        for e in ti.get("edits", []) or []:
            loc.append(e.get("old_string", ""))
            mark.extend((e.get("old_string", ""), e.get("new_string", "")))
        return fp, loc, mark, False
    return fp, [], [], False

def _decide(tool, target):
    reason = ("This %s touches a protected location (%s). The human owner must "
              "review and confirm this change before it lands." % (tool, target))
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny" if DECISION == "deny" else "ask",
            "permissionDecisionReason": reason,
        }
    }))


def _self_protected(path):
    return bool(path) and any(path.endswith(sp) for sp in SELF_PROTECTED)


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        return
    tool = event.get("tool_name", "")
    ti = event.get("tool_input", {}) or {}

    if tool == "Bash":
        cmd = str(ti.get("command", ""))
        if not WRITE_RE.search(cmd):
            return
        for sp in SELF_PROTECTED:
            if sp.rsplit("/", 1)[-1] in cmd:
                return _decide("Bash", sp)
        for tok in _bash_org_targets(cmd):
            if os.path.isfile(tok):
                try:
                    with open(tok, "r", encoding="utf-8") as f:
                        if protected_ranges(f.read()):
                            return _decide("Bash", tok)
                except OSError:
                    pass
        return

    if tool not in ("Edit", "Write", "MultiEdit"):
        return

    fp, loc_targets, marker_targets, whole = _extract(tool, ti)
    if not fp:
        return
    if _self_protected(fp):  # guard the guard (any file type)
        return _decide(tool, fp)
    if not fp.endswith(".org") or not os.path.isfile(fp):
        return
    try:
        with open(fp, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return

    ranges = protected_ranges(text)
    if not ranges:
        return

    hit = whole
    if not hit and any(MARKER in s for s in marker_targets):
        hit = True
    if not hit:
        for t in loc_targets:
            if any(_overlaps(s, e, r0, r1)
                   for (s, e) in _occurrences(text, t)
                   for (r0, r1) in ranges):
                hit = True
                break
    if hit:
        _decide(tool, fp)


if __name__ == "__main__":
    main()
