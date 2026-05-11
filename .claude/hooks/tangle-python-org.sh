#!/usr/bin/env bash
# PostToolUse hook: tangle claude-agent-python.org after Claude edits it.
#
# Strategy: prefer the host Emacs, fall back to `make tangle-python`.
#
# Escape hatch: set LITERATE_ORG_NO_AUTO_TANGLE=1 to skip entirely.

set -euo pipefail

payload=$(cat)
read -r tool_name file_path <<<"$(python3 - "$payload" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
print(d.get("tool_name", ""), d.get("tool_input", {}).get("file_path", "") or "")
PY
)"

[ "${LITERATE_ORG_NO_AUTO_TANGLE:-0}" = "1" ] && exit 0

case "$tool_name" in Edit|Write|MultiEdit) ;; *) exit 0 ;; esac
case "$file_path" in *claude-agent-python.org) ;; *) exit 0 ;; esac

cd "$CLAUDE_PROJECT_DIR"

# Try host Emacs first.
if emacsclient -e "(org-babel-tangle-file \"$file_path\")" >/dev/null 2>&1; then
  echo "OK tangled $file_path (via host Emacs)"
  exit 0
fi

# Fall back to batch tangle.
if make tangle-python >/dev/null 2>&1; then
  echo "OK tangled $file_path (batch fallback)"
  exit 0
fi

echo >&2 "tangle failed for $file_path"
echo >&2 "  set LITERATE_ORG_NO_AUTO_TANGLE=1 to bypass"
exit 2
