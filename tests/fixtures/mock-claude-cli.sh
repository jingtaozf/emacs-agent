#!/usr/bin/env bash
# mock-claude-cli.sh — Drop-in replacement for `claude` CLI for testing.
#
# Speaks the identical JSON-over-pipe protocol:
#   stdin:  newline-delimited JSON (control_request init, user messages)
#   stdout: newline-delimited JSON (system/init, assistant, result)
#
# Behaviour is controlled by the MOCK_SCENARIO environment variable,
# which selects a fixture file from mock-scenarios/<name>.jsonl.
#
# The fixture format is plain JSONL with one extension:
#   Lines starting with "DELAY:<seconds>" insert a sleep.
#
# Exit codes match real CLI:
#   0 = normal exit after outputting result
#   Signal deaths propagate naturally (SIGINT=130, SIGKILL=137)

set -euo pipefail

# ── Resolve fixture directory (next to this script) ──────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_DIR="${SCRIPT_DIR}/mock-scenarios"

# ── Parse CLI arguments (mimic real claude arg parsing) ───────────
RESUME_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resume)       RESUME_ID="$2"; shift 2 ;;
        # Consume all other flags the SDK sends (ignored by mock)
        --output-format|--input-format|--permission-mode|--verbose|\
        --system-prompt|--max-turns|--max-budget-usd|--setting-sources|\
        --allowedTools|--disallowedTools|--mcp-config|--permission-prompt-tool|\
        --continue)
            # Flags that take a value
            case "$1" in
                --verbose|--continue) shift ;;
                *) shift 2 ;;
            esac
            ;;
        --print)        shift ;;
        *)              shift ;;   # skip unknown args
    esac
done

# ── Read stdin (control_request init + user message) ──────────────
# The SDK sends exactly 2 JSON lines: init request then user message.
# We must consume them to avoid EPIPE / broken-pipe errors.
USER_PROMPT=""
LINE_NUM=0
while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))
    # Extract prompt from the user message (line 2)
    if [[ $LINE_NUM -ge 2 ]]; then
        # Extract "content" field value from JSON using lightweight parsing
        # Handles: {"type":"user","message":{"role":"user","content":"..."}}
        if command -v python3 &>/dev/null; then
            USER_PROMPT=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    msg = data.get('message', {})
    print(msg.get('content', ''))
except Exception:
    print('')
" "$line" 2>/dev/null || echo "")
        fi
        break  # Only need the first user message
    fi
done

# ── Select scenario ──────────────────────────────────────────────
# Priority: MOCK_SCENARIO env > prompt-based auto-detection > generic
SCENARIO="${MOCK_SCENARIO:-}"

if [[ -z "$SCENARIO" ]]; then
    # Auto-detect from prompt content (case-insensitive matching)
    prompt_lower=$(echo "$USER_PROMPT" | tr '[:upper:]' '[:lower:]')
    if [[ "$prompt_lower" == *"2+2"* ]] || [[ "$prompt_lower" == *"2 + 2"* ]]; then
        SCENARIO="simple-query"
    elif [[ "$prompt_lower" == *"count"*"slowly"* ]] || \
         [[ "$prompt_lower" == *"long story"* ]] || \
         [[ "$prompt_lower" == *"write a very long"* ]]; then
        SCENARIO="slow-response"
    elif [[ "$prompt_lower" == *"remember"* ]]; then
        SCENARIO="session-start"
    elif [[ "$prompt_lower" == *"what number"* ]] || \
         [[ "$prompt_lower" == *"what did i"* ]]; then
        SCENARIO="session-resume"
    elif [[ "$prompt_lower" == *"block b"* ]]; then
        SCENARIO="block-b-response"
    elif [[ "$prompt_lower" == *"block c"* ]]; then
        SCENARIO="block-c-response"
    elif [[ "$prompt_lower" == *"scheduled-past-due"* ]]; then
        SCENARIO="scheduled-past-due"
    elif [[ "$prompt_lower" == *"daily-repeater"* ]]; then
        SCENARIO="scheduled-repeater"
    elif [[ "$prompt_lower" == *"translate"* ]] || \
         [[ "$prompt_lower" == *"chinese"* ]]; then
        SCENARIO="translate"
    elif [[ "$prompt_lower" == *"read"*"tool"* ]] || \
         [[ "$prompt_lower" == *"read the file"* ]]; then
        SCENARIO="tool-use-read"
    elif [[ "$prompt_lower" == *"askuserquestion"* ]] || \
         [[ "$prompt_lower" == *"ask me"* ]]; then
        SCENARIO="ask-user-question"
    else
        SCENARIO="generic-response"
    fi
fi

# Override for --resume (session continuity tests)
if [[ -n "$RESUME_ID" && "$SCENARIO" != "slow-response" ]]; then
    SCENARIO="session-resume"
fi

FIXTURE_FILE="${SCENARIOS_DIR}/${SCENARIO}.jsonl"
if [[ ! -f "$FIXTURE_FILE" ]]; then
    echo "mock-claude-cli: fixture not found: ${FIXTURE_FILE}" >&2
    exit 1
fi

# ── Replay fixture ───────────────────────────────────────────────
# Output each line from the fixture file.
# DELAY:N lines insert a sleep (for cancellation tests).
while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == DELAY:* ]]; then
        delay="${line#DELAY:}"
        sleep "$delay"
    elif [[ -n "$line" ]]; then
        printf '%s\n' "$line"
    fi
done < "$FIXTURE_FILE"

# ── Normal exit ──────────────────────────────────────────────────
exit 0
