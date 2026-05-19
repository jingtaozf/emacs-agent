#!/usr/bin/env bash
# build-tangle-map.sh — emit .py-path → owning-.org-section mapping.
#
# Adapted from edo-literate's `scripts/build_tangle_map.py` pattern,
# scoped down to this repo's single literate-Python source
# (`claude-agent-python.org`).  Output is a TSV at
# `.cache/tangle-map.tsv` used by `block-python-tangled-edit.sh`
# to print section-precise navigation hints instead of the generic
# "edit claude-agent-python.org" message.
#
# Run on demand:
#   scripts/build-tangle-map.sh
#
# The hook self-heals on miss — runs this builder automatically if
# the cache is absent or older than the .org file.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORG_FILE="$REPO_ROOT/claude-agent-python.org"
CACHE_DIR="$REPO_ROOT/.cache"
CACHE_FILE="$CACHE_DIR/tangle-map.tsv"

if [[ ! -f "$ORG_FILE" ]]; then
  echo "build-tangle-map: $ORG_FILE not found" >&2
  exit 1
fi

mkdir -p "$CACHE_DIR"

# Walk the .org file once.  For each section heading + tangle target,
# emit a row:
#
#   <tangled-path>\t<org-file>\t<line>\t<heading>
#
# The tangle target may sit on:
#   - a file-level `#+PROPERTY: header-args:python :tangle <path>` line,
#   - a section :PROPERTIES: drawer's `:header-args: :tangle <path>`,
#   - or a per-block `#+BEGIN_SRC python :tangle <path>`.
#
# In claude-agent-python.org the dominant pattern is section-level
# `:PROPERTIES: :header-args: :tangle <path>`, with the heading
# immediately above.  Track the current section heading and its
# pending tangle target; emit a row whenever a new tangle target is
# seen under a heading.

awk -v org_file="claude-agent-python.org" '
  function extract_tangle(line,    pos, rest, tangle, end) {
    pos = index(line, ":tangle ")
    if (pos == 0) return ""
    rest = substr(line, pos + 8)
    # tangle target is the first whitespace-delimited token
    end = match(rest, /[[:space:]]/)
    if (end == 0) tangle = rest
    else          tangle = substr(rest, 1, end - 1)
    sub(/^\.\//, "", tangle)
    return tangle
  }
  /^\*+ / {
    current_heading = $0
    current_line = NR
    next
  }
  /:header-args:.*:tangle / {
    t = extract_tangle($0)
    if (t != "") printf "%s\t%s\t%d\t%s\n", t, org_file, current_line, current_heading
  }
  /^#\+BEGIN_SRC python.*:tangle/ {
    t = extract_tangle($0)
    if (t != "") printf "%s\t%s\t%d\t%s\n", t, org_file, current_line, current_heading
  }
' "$ORG_FILE" \
  | sort -u \
  > "$CACHE_FILE.tmp"

mv "$CACHE_FILE.tmp" "$CACHE_FILE"

n=$(wc -l < "$CACHE_FILE" | tr -d ' ')
echo "build-tangle-map: wrote $n rows to $CACHE_FILE"
