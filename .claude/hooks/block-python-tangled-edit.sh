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

cat >&2 <<EOF
Refusing to edit $file_path: all .py files in this project are tangle
output from claude-agent-python.org.

Edit the corresponding section in claude-agent-python.org instead,
then re-tangle:

  make tangle-python

To bypass for a one-off: use the Bash tool to write the file directly.
The matcher is Edit|Write|MultiEdit only.
EOF
exit 2
