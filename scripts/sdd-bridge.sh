#!/usr/bin/env bash
# sdd-bridge.sh - Bridge between Claude CLI hooks and Emacs org SDD
#
# Called by hooks with event type as $1, JSON on stdin.
# Required env vars: SDD_ORG_FILE, SDD_SESSION_ID, EMACS_MCP_URL

EVENT="$1"
INPUT=$(cat)

EMACS_MCP_URL="${EMACS_MCP_URL:?SDD bridge: EMACS_MCP_URL must be set}"
SDD_SESSION_ID="${SDD_SESSION_ID:?SDD bridge: SDD_SESSION_ID must be set}"
SDD_ORG_FILE="${SDD_ORG_FILE:?SDD bridge: SDD_ORG_FILE must be set}"

call_emacs() {
  local elisp="$1"
  local result
  result=$(curl -sf --connect-timeout 3 --max-time 8 "$EMACS_MCP_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",
         \"params\":{\"name\":\"evalElisp\",
                     \"arguments\":{\"code\":$(printf '%s' "$elisp" | jq -Rs .)}}}" 2>/dev/null)
  if [ $? -ne 0 ]; then
    echo "sdd-bridge: warning: Emacs MCP unreachable at $EMACS_MCP_URL" >&2
    return 0
  fi
  echo "$result" | jq -r '.result.content[0].text' 2>/dev/null | jq -r '.result // empty' 2>/dev/null
}

# Build a save-cli-session sexp if session_id is present in the input.
# Returns empty string if no session_id, otherwise a progn-ready sexp.
CLI_SESSION=$(echo "$INPUT" | jq -r '.session_id // empty')
SAVE_SESSION_SEXP=""
if [ -n "$CLI_SESSION" ]; then
  SAVE_SESSION_SEXP="(claude-org-sdd-bridge-save-cli-session \"$SDD_ORG_FILE\" \"$SDD_SESSION_ID\" \"$CLI_SESSION\")"
fi

  # Hook status file — fast status detection for iTerm2 backend
STATUS_DIR="/tmp/claude-agent-status"
mkdir -p "$STATUS_DIR"
write_status() {
  printf '%s' "$1" > "$STATUS_DIR/$SDD_SESSION_ID"
}

case "$EVENT" in
  prompt)
    write_status "busy"

    PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
    [ -z "$PROMPT" ] && exit 0

    # Check if prompt was sent from Emacs (flag file written by execute-ai-block).
    # If so, skip insert-prompt — the AI block already exists in the org file.
    # If not (user typed directly in Claude TUI), insert the prompt.
    FROM_EMACS_FLAG="$STATUS_DIR/$SDD_SESSION_ID.from-emacs"
    if [ -f "$FROM_EMACS_FLAG" ]; then
      rm -f "$FROM_EMACS_FLAG"
      # Still save CLI session but skip prompt insertion
      call_emacs "(progn $SAVE_SESSION_SEXP)" 2>/dev/null || true
    else
      ESCAPED_PROMPT=$(printf '%s' "$PROMPT" | jq -Rs .)
      call_emacs "(progn (claude-org-sdd-bridge-insert-prompt \"$SDD_ORG_FILE\" \"$SDD_SESSION_ID\" $ESCAPED_PROMPT) $SAVE_SESSION_SEXP)"
    fi
    ;;

  response)
    write_status "ready"

    # The Stop hook input includes last_assistant_message directly.
    RESPONSE=$(echo "$INPUT" | jq -r '.last_assistant_message // empty')

    # Fallback: try transcript if last_assistant_message is empty
    if [ -z "$RESPONSE" ]; then
      TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
      if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
        RESPONSE=$(tac "$TRANSCRIPT_PATH" \
          | jq -r 'select(.type == "assistant") | .message.content[] | select(.type == "text") | .text' 2>/dev/null \
          | head -1)
      fi
    fi

    [ -z "$RESPONSE" ] && exit 0

    ESCAPED_RESPONSE=$(printf '%s' "$RESPONSE" | jq -Rs .)
    call_emacs "(progn (claude-org-sdd-bridge-insert-response \"$SDD_ORG_FILE\" \"$SDD_SESSION_ID\" $ESCAPED_RESPONSE) $SAVE_SESSION_SEXP)"
    ;;

  *)
    echo "sdd-bridge: unknown event: $EVENT" >&2
    exit 0
    ;;
esac
