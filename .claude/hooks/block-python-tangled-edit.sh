#!/usr/bin/env bash
# PreToolUse hook: reject Edit/Write/MultiEdit on ANY .py file.
#
# All Python source in this project is tangle output from
# claude-agent-python.org.  Direct .py edits would be silently
# overwritten by the next `make tangle-python` run.
#
# Bypass: use the Bash tool to write the file directly (the matcher is
# Edit|Write|MultiEdit only).

set -euo pipefail

payload=$(cat)

read -r tool_name file_path <<<"$(python3 - "$payload" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
tool = data.get("tool_name", "")
inp  = data.get("tool_input", {})
path = inp.get("file_path", "") or ""
print(tool, path)
PY
)"

case "$tool_name" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

case "$file_path" in
  *.py) ;;
  *) exit 0 ;;
esac

# --- section-precision lookup via .cache/tangle-map.tsv -----------------
# Resolve file_path → owning .org section heading so the error message
# tells the contributor EXACTLY which section to edit (instead of just
# "edit claude-agent-python.org" — that file is 6770 lines).
#
# Self-heal: rebuild the cache if missing or older than the .org file.

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cache="$repo_root/.cache/tangle-map.tsv"
org_file="$repo_root/claude-agent-python.org"

if [[ ! -f "$cache" || "$org_file" -nt "$cache" ]]; then
  "$repo_root/scripts/build-tangle-map.sh" >/dev/null 2>&1 || true
fi

rel_path="${file_path#$repo_root/}"
rel_path="${rel_path#./}"

section_hint=""
if [[ -f "$cache" ]]; then
  section_hint=$(awk -F'\t' -v p="$rel_path" '$1 == p {print "  " $2 ":" $3 "  " $4}' "$cache")
fi

cat >&2 <<EOF
Refusing to edit $file_path: all .py files in this project are tangle
output from claude-agent-python.org.

Edit the corresponding section in claude-agent-python.org instead,
then re-tangle:

  make tangle-python
EOF

if [[ -n "$section_hint" ]]; then
  cat >&2 <<EOF

Owning section(s):
$section_hint
EOF
fi

cat >&2 <<EOF

To bypass for a one-off: use the Bash tool to write the file directly.
The matcher is Edit|Write|MultiEdit only.
EOF
exit 2
