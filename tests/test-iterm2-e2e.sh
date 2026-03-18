#!/usr/bin/env bash
# Layer 4: Full E2E — iTerm2 + Claude Code + Emacs MCP
#
# Tests the complete flow:
#   1. Emacs functions callable via MCP (iterm2--call, ensure-session, etc.)
#   2. sdd-bridge.sh writes hook status files to /tmp/claude-agent-status/
#   3. Emacs reads hook status correctly
#   4. iTerm2 backend dispatch works (CLAUDE_BACKEND=iterm2)
#
# Prerequisites:
#   - iTerm2 running with Python API enabled
#   - Claude CLI installed
#   - Emacs MCP server running
#
# Usage:
#   bash tests/test-iterm2-e2e.sh [mcp-port]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_PORT="${1:-9999}"
MCP_URL="http://localhost:${MCP_PORT}/mcp"

PASS=0
FAIL=0
TOTAL=0

# -- Helpers -----------------------------------------------------------------

call_emacs() {
  local elisp="$1"
  local result
  result=$(curl -sf --connect-timeout 3 --max-time 15 "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",
         \"params\":{\"name\":\"evalElisp\",
                     \"arguments\":{\"code\":$(printf '%s' "$elisp" | jq -Rs .)}}}" 2>/dev/null)
  # Extract the "result" field from the MCP JSON envelope
  # The text field contains {"success":true,"result":"VALUE\n"}
  local text
  text=$(echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
text = data['result']['content'][0]['text']
inner = json.loads(text)
print(inner.get('result', '').strip())
" 2>/dev/null)
  echo "$text"
}

run_test() {
  local name="$1"
  local func="$2"
  TOTAL=$((TOTAL + 1))
  printf "  %s... " "$name"
  if eval "$func"; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
  fi
}

# -- Tests -------------------------------------------------------------------

test_emacs_mcp_reachable() {
  local result
  result=$(call_emacs "(+ 1 1)")
  echo "$result" | grep -q "2"
}

test_iterm2_functions_defined() {
  local result
  result=$(call_emacs "(and (fboundp 'claude-org-iterm2--call)
                            (fboundp 'claude-org-iterm2--ensure-session)
                            (fboundp 'claude-org-iterm2--execute-ai-block)
                            (fboundp 'claude-org-iterm2-open-tab)
                            (fboundp 'claude-org-iterm2-cancel)
                            (fboundp 'claude-org-iterm2--set-busy)
                            (fboundp 'claude-org-iterm2--set-ready)
                            (fboundp 'claude-org-terminal--read-hook-status)
                            t)")
  echo "$result" | grep -q "t"
}

test_iterm2_script_path_valid() {
  local result
  result=$(call_emacs "(file-exists-p claude-org-iterm2-script)")
  echo "$result" | grep -q "t"
}

test_hook_status_write_and_read() {
  # Simulate what sdd-bridge.sh does: write status file, read via Emacs
  local test_id="test-e2e-$$"
  local status_dir="/tmp/claude-agent-status"
  mkdir -p "$status_dir"

  # Write "busy"
  printf 'busy' > "$status_dir/$test_id"
  local result
  result=$(call_emacs "(claude-org-terminal--read-hook-status \"$test_id\")")
  echo "$result" | grep -q "busy" || return 1

  # Write "ready"
  printf 'ready' > "$status_dir/$test_id"
  result=$(call_emacs "(claude-org-terminal--read-hook-status \"$test_id\")")
  echo "$result" | grep -q "ready" || return 1

  # Cleanup
  rm -f "$status_dir/$test_id"

  # Missing file returns "unknown"
  result=$(call_emacs "(claude-org-terminal--read-hook-status \"nonexistent-id-$$\")")
  echo "$result" | grep -q "unknown"
}

test_sdd_bridge_writes_status() {
  # Run sdd-bridge.sh prompt event and verify it writes "busy"
  local test_id="test-bridge-$$"
  local status_dir="/tmp/claude-agent-status"
  mkdir -p "$status_dir"
  rm -f "$status_dir/$test_id"

  # Run prompt event
  echo '{"prompt":"test","session_id":"s1"}' | \
    SDD_SESSION_ID="$test_id" \
    SDD_ORG_FILE="/tmp/fake.org" \
    EMACS_MCP_URL="$MCP_URL" \
    uv run --project "$PROJECT_DIR/python" sdd-bridge prompt 2>/dev/null || true

  # Check status file was written
  [ -f "$status_dir/$test_id" ] || return 1
  local status
  status=$(cat "$status_dir/$test_id")
  [ "$status" = "busy" ] || return 1

  # Run response event
  echo '{"last_assistant_message":"hello"}' | \
    SDD_SESSION_ID="$test_id" \
    SDD_ORG_FILE="/tmp/fake.org" \
    EMACS_MCP_URL="$MCP_URL" \
    uv run --project "$PROJECT_DIR/python" sdd-bridge response 2>/dev/null || true

  status=$(cat "$status_dir/$test_id")
  [ "$status" = "ready" ] || return 1

  # Cleanup
  rm -f "$status_dir/$test_id"
}

test_activity_mode_line_variable() {
  local result
  result=$(call_emacs "(boundp 'claude-org-iterm2--activity-string)")
  echo "$result" | grep -q "t"
}

test_iterm2_ctl_list() {
  # Verify iterm2-ctl.py list works (returns JSON array)
  local result
  result=$(python3 "$PROJECT_DIR/python/claude_agent/iterm2_ctl.py" list 2>/dev/null) || return 1
  echo "$result" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null
}

test_emacs_calls_iterm2_list() {
  # Verify Emacs can call iterm2-ctl.py via our helper
  local result
  result=$(call_emacs "(condition-case err
    (let ((out (claude-org-iterm2--call \"list\")))
      (if (string-prefix-p \"[\" out) \"ok\" (format \"bad: %s\" out)))
    (error (format \"error: %s\" (error-message-string err))))")
  echo "$result" | grep -q "ok"
}

# -- Main --------------------------------------------------------------------

echo "============================================================"
echo "Layer 4: Full E2E — iTerm2 + Claude Code + Emacs"
echo "============================================================"
echo "  MCP URL: $MCP_URL"
echo

run_test "Emacs MCP reachable" test_emacs_mcp_reachable
run_test "iTerm2 functions defined" test_iterm2_functions_defined
run_test "iterm2-ctl.py script exists" test_iterm2_script_path_valid
run_test "Hook status write/read" test_hook_status_write_and_read
run_test "sdd-bridge.sh writes status" test_sdd_bridge_writes_status
run_test "Activity mode-line variable" test_activity_mode_line_variable
run_test "iterm2-ctl list (Python)" test_iterm2_ctl_list
run_test "Emacs calls iterm2-ctl list" test_emacs_calls_iterm2_list

echo
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "============================================================"

# Save fixture data
FIXTURES_DIR="$PROJECT_DIR/tests/fixtures/iterm2"
mkdir -p "$FIXTURES_DIR"
echo "{\"pass\":$PASS,\"fail\":$FAIL,\"total\":$TOTAL,\"layer\":4}" \
  > "$FIXTURES_DIR/e2e-run-summary.json"

exit $((FAIL > 0 ? 1 : 0))
