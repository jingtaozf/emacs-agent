#!/usr/bin/env bash
# E2E tests for Terminal Workspace Bridge
# Requires: running Emacs MCP server, jq, curl
#
# Usage: bash tests/test-workspace-bridge-e2e.sh [port]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

EMACS_MCP_PORT="${1:-9999}"
export EMACS_MCP_URL="http://localhost:${EMACS_MCP_PORT}/mcp"

# These tests run inside a cmux pane during development (so the
# parent shell inherits CMUX_WORKSPACE_ID).  The bridge's new
# stale-resume detection would fire for every invocation without
# WORKSPACE_BRIDGE_TEST_BYPASS=1 — even though these tests are not
# exercising the resume scenario.  See
# test-cross-workspace-routing-e2e.sh TC3 for the assertion that
# the strict check still aborts when bypass is *not* set.
export WORKSPACE_BRIDGE_TEST_BYPASS=1

source tests/helpers/mcp-call.sh

PASS=0
FAIL=0
TESTS_RUN=0

# Assertions
assert_contains() {
  echo "$1" | grep -qF "$2" || { echo "  Expected to contain: '$2'" >&2; return 1; }
}
assert_not_contains() {
  ! echo "$1" | grep -qF "$2" || { echo "  Expected NOT to contain: '$2'" >&2; return 1; }
}
assert_equals() {
  [ "$1" = "$2" ] || { echo "  Expected '$2', got '$1'" >&2; return 1; }
}
assert_not_equals() {
  [ "$1" != "$2" ] || { echo "  Expected not '$2'" >&2; return 1; }
}
assert_not_empty() {
  [ -n "$1" ] || { echo "  Expected non-empty" >&2; return 1; }
}
assert_order() {
  local content="$1"; shift
  local prev_pos=0
  for pattern in "$@"; do
    local pos
    pos=$(echo "$content" | grep -n "$pattern" | head -1 | cut -d: -f1)
    if [ -z "$pos" ]; then
      echo "  Pattern not found: '$pattern'" >&2
      return 1
    fi
    if [ "$pos" -le "$prev_pos" ]; then
      echo "  '$pattern' (line $pos) not after previous (line $prev_pos)" >&2
      return 1
    fi
    prev_pos=$pos
  done
}

run_test() {
  local name="$1"
  ((TESTS_RUN++)) || true
  echo -n "  $name... "
  if "$name" 2>/tmp/test-workspace-bridge-stderr.log; then
    echo "PASS"
    ((PASS++)) || true
  else
    echo "FAIL"
    cat /tmp/test-workspace-bridge-stderr.log >&2
    ((FAIL++)) || true
  fi
}

# ---------------------------------------------------------------------------
# TC1: Single prompt insertion
# ---------------------------------------------------------------------------
test_single_prompt() {
  local org_file="/tmp/test-workspace-tc1.org"
  local session_id="workspace-test-tc1"

  create_test_workspace "$org_file" "$session_id" >/dev/null

  echo '{"prompt":"explain this function","session_id":"cli-001","transcript_path":"/dev/null"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge prompt >/dev/null

  local content
  content=$(read_org_buffer "$org_file")
  assert_contains "$content" "Instruction 1"
  assert_contains "$content" "#+begin_src ai"
  assert_contains "$content" "explain this function"
  assert_contains "$content" "#+end_src"

  cleanup_test_file "$org_file" >/dev/null
}

# ---------------------------------------------------------------------------
# TC2: Single response insertion
# ---------------------------------------------------------------------------
test_single_response() {
  local org_file="/tmp/test-workspace-tc2.org"
  local session_id="workspace-test-tc2"

  create_test_workspace "$org_file" "$session_id" >/dev/null

  # Insert a prompt first
  echo '{"prompt":"explain this function","session_id":"cli-001","transcript_path":"/dev/null"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge prompt >/dev/null

  # Simulate Stop hook with last_assistant_message (as real Claude CLI does)
  echo '{"session_id":"cli-001","transcript_path":"/dev/null","last_assistant_message":"This function takes a list and returns the first element."}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge response >/dev/null

  local content
  content=$(read_org_buffer "$org_file")
  assert_contains "$content" "Response 1"
  assert_contains "$content" ":ai_output:"
  assert_contains "$content" "This function takes a list and returns the first element."

  cleanup_test_file "$org_file" >/dev/null
}

# ---------------------------------------------------------------------------
# TC3: Multi-turn conversation
# ---------------------------------------------------------------------------
test_multi_turn() {
  local org_file="/tmp/test-workspace-tc3.org"
  local session_id="workspace-test-tc3"

  create_test_workspace "$org_file" "$session_id" >/dev/null

  # Turn 1
  echo '{"prompt":"what does this module do?","session_id":"cli-001","transcript_path":"/dev/null"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge prompt >/dev/null

  echo '{"session_id":"cli-001","transcript_path":"/dev/null","last_assistant_message":"This module handles HTTP routing."}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge response >/dev/null

  # Turn 2
  echo '{"prompt":"show me the main entry point","session_id":"cli-001","transcript_path":"/dev/null"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge prompt >/dev/null

  echo '{"session_id":"cli-001","transcript_path":"/dev/null","last_assistant_message":"The main entry point is the start-server function on line 42."}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge response >/dev/null

  # Assert counts
  local instr_count resp_count
  instr_count=$(count_headings "$org_file" "Instruction [0-9]")
  resp_count=$(count_headings "$org_file" "Response [0-9]")
  assert_equals "$instr_count" "2"
  assert_equals "$resp_count" "2"

  # Assert ordering
  local content
  content=$(read_org_buffer "$org_file")
  assert_order "$content" "Instruction 1" "Response 1" "Instruction 2" "Response 2"

  cleanup_test_file "$org_file" >/dev/null
}

# ---------------------------------------------------------------------------
# TC4: Tool-heavy response extracts text only
# ---------------------------------------------------------------------------
test_tool_response_text_only() {
  local org_file="/tmp/test-workspace-tc4.org"
  local session_id="workspace-test-tc4"

  create_test_workspace "$org_file" "$session_id" >/dev/null

  echo '{"prompt":"read the config file","session_id":"cli-001","transcript_path":"/dev/null"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge prompt >/dev/null

  # last_assistant_message is always text-only (Claude CLI strips tool calls)
  echo '{"session_id":"cli-001","transcript_path":"/dev/null","last_assistant_message":"The config file contains database settings with host=localhost and port=5432."}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge response >/dev/null

  local content
  content=$(read_org_buffer "$org_file")
  assert_contains "$content" "database settings"
  assert_not_contains "$content" "tool_use"

  cleanup_test_file "$org_file" >/dev/null
}

# ---------------------------------------------------------------------------
# TC5: MCP unreachable — hook exits gracefully
# ---------------------------------------------------------------------------
test_mcp_unreachable() {
  echo '{"prompt":"test prompt","session_id":"cli-001","transcript_path":"/dev/null"}' \
    | WORKSPACE_ORG_FILE="/tmp/test-workspace-tc5.org" WORKSPACE_SESSION_ID="workspace-test-tc5" \
      EMACS_MCP_URL="http://localhost:19999/mcp" \
      uv run --project python workspace-bridge prompt 2>/dev/null
  local exit_code=$?
  assert_equals "$exit_code" "0"
}

# ---------------------------------------------------------------------------
# TC6: Empty prompt is ignored
# ---------------------------------------------------------------------------
test_empty_prompt_ignored() {
  local org_file="/tmp/test-workspace-tc6.org"
  local session_id="workspace-test-tc6"

  create_test_workspace "$org_file" "$session_id" >/dev/null

  echo '{"prompt":"","session_id":"cli-001","transcript_path":"/dev/null"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge prompt >/dev/null

  local instr_count
  instr_count=$(count_headings "$org_file" "Instruction [0-9]")
  assert_equals "$instr_count" "0"

  cleanup_test_file "$org_file" >/dev/null
}

# ---------------------------------------------------------------------------
# TC7: System prompt fetch
# ---------------------------------------------------------------------------
test_system_prompt_fetch() {
  local org_file="/tmp/test-workspace-tc7.org"
  local session_id="workspace-test-tc7"

  create_test_workspace "$org_file" "$session_id" >/dev/null

  local prompt
  prompt=$(mcp_call "(let ((debug-on-error nil) (debug-on-quit nil) (edebug-all-defs nil) (edebug-all-forms nil)) (code-agent-org-workspace-bridge-system-prompt \"$org_file\" \"$session_id\"))")

  assert_not_empty "$prompt"
  assert_contains "$prompt" "test feature"

  cleanup_test_file "$org_file" >/dev/null
}

# ---------------------------------------------------------------------------
# TC9: Response with org headings doesn't corrupt structure
# ---------------------------------------------------------------------------
test_response_with_org_headings() {
  local org_file="/tmp/test-workspace-tc9.org"
  local session_id="workspace-test-tc9"

  cleanup_test_file "$org_file" >/dev/null 2>&1 || true
  create_test_workspace "$org_file" "$session_id" >/dev/null

  # Turn 1: prompt + response containing ** and *** org headings
  echo '{"prompt":"1+1","session_id":"cli-001","transcript_path":"/dev/null"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge prompt >/dev/null

  printf '{"session_id":"cli-001","transcript_path":"/dev/null","last_assistant_message":"Here is the answer:\\n\\n** Heading Level 2\\n\\nSome content\\n\\n*** Heading Level 3\\n\\nMore content"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge response >/dev/null

  # Turn 2: prompt + response
  echo '{"prompt":"2+2","session_id":"cli-001","transcript_path":"/dev/null"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge prompt >/dev/null

  echo '{"session_id":"cli-001","transcript_path":"/dev/null","last_assistant_message":"4"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge response >/dev/null

  # Verify structure using raw text between known headings (not org-end-of-subtree,
  # which is the function that's broken by embedded org headings).

  # Check: text between "Response 1" heading and "Instruction 2" heading
  # should contain "Heading Level 2" (response 1 body is intact, not truncated)
  local resp1_body_intact
  resp1_body_intact=$(mcp_call "(let ((debug-on-error nil) (debug-on-quit nil))
    (with-current-buffer (find-buffer-visiting \"$org_file\")
      (save-excursion
        (goto-char (point-min))
        (let* ((r1 (re-search-forward \"^\\\\*+ Response 1\" nil t))
               (i2 (re-search-forward \"^\\\\*+ Instruction 2\" nil t)))
          (if (and r1 i2
                   (string-match-p \"Heading Level 2\"
                     (buffer-substring-no-properties r1 i2)))
              \"yes\" \"no\")))))")
  assert_equals "$resp1_body_intact" "yes"

  # Check: "Instruction 2" should NOT appear inside Response 1 heading's
  # property drawer area (i.e. there should be content between Response 1
  # :END: and Instruction 2)
  local resp1_has_body
  resp1_has_body=$(mcp_call "(let ((debug-on-error nil) (debug-on-quit nil))
    (with-current-buffer (find-buffer-visiting \"$org_file\")
      (save-excursion
        (goto-char (point-min))
        (re-search-forward \"^\\\\*+ Response 1\" nil t)
        (re-search-forward \":END:\" nil t)
        (forward-line 1)
        (let ((body-start (point)))
          (if (re-search-forward \"^\\\\*+ Instruction 2\" nil t)
              (let ((text (string-trim (buffer-substring-no-properties body-start (match-beginning 0)))))
                (if (> (length text) 10) \"yes\" \"no\"))
            \"no\")))))")
  assert_equals "$resp1_has_body" "yes"

  # Check: Response 2 exists after Instruction 2 (not before it)
  local resp2_after_instr2
  resp2_after_instr2=$(mcp_call "(let ((debug-on-error nil) (debug-on-quit nil))
    (with-current-buffer (find-buffer-visiting \"$org_file\")
      (save-excursion
        (goto-char (point-min))
        (let* ((i2 (and (re-search-forward \"^\\\\*+ Instruction 2\" nil t) (point)))
               (r2 (and (re-search-forward \"^\\\\*+ Response 2\" nil t) (point))))
          (if (and i2 r2 (> r2 i2)) \"yes\" \"no\")))))")
  assert_equals "$resp2_after_instr2" "yes"

  cleanup_test_file "$org_file" >/dev/null
}

# ---------------------------------------------------------------------------
# TC10: Response arrives after a second prompt is already inserted
# Reproduces: user sends prompt A, prompt B arrives before response A,
# then response A finally comes. It should still be inserted (not lost).
# ---------------------------------------------------------------------------
test_response_after_new_prompt_inserted() {
  local org_file="/tmp/test-workspace-tc10.org"
  local session_id="workspace-test-tc10"

  create_test_workspace "$org_file" "$session_id" >/dev/null

  # Prompt A
  echo '{"prompt":"research terminals","session_id":"cli-001","transcript_path":"/dev/null"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge prompt >/dev/null

  # Prompt B inserted BEFORE response A arrives
  echo '{"prompt":"fix the bug","session_id":"cli-001","transcript_path":"/dev/null"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge prompt >/dev/null

  # Response A arrives late
  echo '{"session_id":"cli-001","transcript_path":"/dev/null","last_assistant_message":"Terminal research results: iTerm2 is the best."}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge response >/dev/null

  local content
  content=$(read_org_buffer "$org_file")

  # The response MUST exist somewhere in the file (not lost)
  assert_contains "$content" "Terminal research results"
  assert_contains "$content" "Response"
  assert_contains "$content" ":ai_output:"

  # Both instructions must still exist
  local instr_count
  instr_count=$(count_headings "$org_file" ":claude_chat:")
  assert_equals "$instr_count" "2"

  cleanup_test_file "$org_file" >/dev/null
}

# ---------------------------------------------------------------------------
# TC11: Large response with many org headings, tables, code blocks
# Reproduces the terminal research response scenario
# ---------------------------------------------------------------------------
test_large_response_with_many_org_headings() {
  local org_file="/tmp/test-workspace-tc11.org"
  local session_id="workspace-test-tc11"

  create_test_workspace "$org_file" "$session_id" >/dev/null

  echo '{"prompt":"research terminals","session_id":"cli-001","transcript_path":"/dev/null"}' \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge prompt >/dev/null

  # Build a large response similar to the terminal research one
  local big_response
  big_response="$(cat <<'RESP'
** Research: Lisp-Style & Programmable Terminal Interfaces

*** The Short Answer

*No modern, stable terminal emulator has a native Lisp scripting interface.*

*** Tier 1: Full External IPC

| Terminal | API Type | Language |
|----------+----------+----------|
| *iTerm2* | Python API | Python 3 |
| *Kitty* | CLI + Socket | Python |

**** iTerm2 - Best for Emacs Integration

#+begin_example
iterm2-ctl.py launch --title "my story" --cwd /project
iterm2-ctl.py send --session UUID < prompt.txt
iterm2-ctl.py status --session UUID
#+end_example

**** Kitty - Strongest Protocol

JSON-based IPC over Unix socket:

#+begin_example
kitty @ set-tab-title "my title"
kitty @ send-text --match title:myterm "ls\n"
#+end_example

*** Tier 2: Internal Scripting Only

| Terminal | Scripting | External Control |
|----------+-----------+------------------|
| *Ghostty* | None yet | Escape codes |
| *Alacritty* | YAML | None |

*** Recommendation

1. *iTerm2* - Best for macOS + Emacs integration
2. *Kitty* - Cross-platform alternative

*** Sources

- [[https://iterm2.com/python-api/][iTerm2 Python API]]
- [[https://sw.kovidgoyal.net/kitty/remote-control/][Kitty Remote Control]]
RESP
)"

  # Escape the response for JSON and send
  printf '{"session_id":"cli-001","transcript_path":"/dev/null","last_assistant_message":%s}' \
    "$(printf '%s' "$big_response" | jq -Rs .)" \
    | WORKSPACE_ORG_FILE="$org_file" WORKSPACE_SESSION_ID="$session_id" EMACS_MCP_URL="$EMACS_MCP_URL" \
      uv run --project python workspace-bridge response >/dev/null

  local content
  content=$(read_org_buffer "$org_file")

  # Response must exist
  assert_contains "$content" "Response 1"
  assert_contains "$content" ":ai_output:"
  assert_contains "$content" "iTerm2"
  assert_contains "$content" "Kitty"
  assert_contains "$content" "Recommendation"

  # Org headings in response should be shifted (not raw ** or ***)
  # At instruction level 3 (***), response content headings get 3 extra stars
  # so "** Research" becomes "***** Research" (3+2=5 stars)
  assert_not_contains "$content" $'\n** Research'
  assert_contains "$content" "Research"

  cleanup_test_file "$org_file" >/dev/null
}

# ---------------------------------------------------------------------------
# TC8: Launcher fails fast when MCP is down
# ---------------------------------------------------------------------------
test_launcher_fails_fast() {
  EMACS_MCP_URL="http://localhost:19999/mcp" \
    timeout 10 uv run --project python claude-workspace /tmp/test-workspace-tc8.org workspace-test-tc8 2>/dev/null
  local exit_code=$?
  assert_not_equals "$exit_code" "0"
  # 124 = timeout, which means it didn't fail fast
  assert_not_equals "$exit_code" "124"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Verify prerequisites
for cmd in jq curl; do
  command -v "$cmd" >/dev/null || { echo "FATAL: $cmd not found"; exit 1; }
done

echo "Checking MCP server on port $EMACS_MCP_PORT..."
PING=$(mcp_call "(+ 1 1)" 2>/dev/null) || true
if [ "$PING" != "2" ]; then
  echo "FATAL: MCP server unreachable at $EMACS_MCP_URL"
  exit 1
fi

# Load bridge functions into Emacs
echo "Loading bridge functions..."
LOAD_RESULT=$(mcp_call "(let ((debug-on-error nil) (debug-on-quit nil) (edebug-all-defs nil) (edebug-all-forms nil)) (literate-elisp-load \"$PROJECT_DIR/code-agent-org.org\") \"loaded\")" 2>/dev/null) || true
if [ "$LOAD_RESULT" != "loaded" ] && [ "$LOAD_RESULT" != '"loaded"' ]; then
  echo "WARNING: Could not reload code-agent-org.org (result: $LOAD_RESULT)"
  echo "Bridge functions may not be available. Continuing anyway..."
fi

echo ""
echo "Running Workspace Bridge E2E tests..."
echo ""

run_test test_single_prompt
run_test test_single_response
run_test test_multi_turn
run_test test_tool_response_text_only
run_test test_mcp_unreachable
run_test test_empty_prompt_ignored
run_test test_system_prompt_fetch
run_test test_response_with_org_headings
run_test test_response_after_new_prompt_inserted
run_test test_large_response_with_many_org_headings
run_test test_launcher_fails_fast

echo ""
echo "Results: $PASS passed, $FAIL failed (of $TESTS_RUN)"
[ "$FAIL" -eq 0 ]
