#!/usr/bin/env bash
# MCP call helper for E2E tests
# Usage: source this file, then call mcp_call "<elisp>"

mcp_call() {
  local elisp="$1"
  local url="${EMACS_MCP_URL:-http://localhost:9999/mcp}"
  # MCP response is double-wrapped:
  #   {"jsonrpc":"2.0","result":{"content":[{"text":"{\"success\":true,\"result\":\"VALUE\\n\"}"}]}}
  # Extract .result.content[0].text (JSON string), then parse .result from it,
  # and trim trailing newlines that Emacs adds.
  # The result chain: MCP JSON -> .result.content[0].text -> {"success":true,"result":"VALUE\n"}
  # For elisp strings, .result is "\"value\"\n" — jq -r unescapes to "value"\n.
  # We strip trailing whitespace and surrounding double quotes from string results.
  curl -sf --connect-timeout 3 --max-time 10 "$url" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",
         \"params\":{\"name\":\"evalElisp\",
                     \"arguments\":{\"code\":$(printf '%s' "$elisp" | jq -Rs .)}}}" \
    | jq -r '.result.content[0].text' \
    | jq -r '.result // empty' \
    | sed 's/[[:space:]]*$//' \
    | sed 's/^"//;s/"$//'
}

create_test_sdd() {
  local org_file="$1"
  local session_id="$2"
  mcp_call "(let ((debug-on-error nil)
      (debug-on-quit nil)
      (edebug-all-defs nil)
      (edebug-all-forms nil))
  (with-current-buffer (find-file-noselect \"$org_file\")
    (erase-buffer)
    (org-mode)
    (insert \"* Test Feature :sdd:\\n\")
    (insert \":PROPERTIES:\\n\")
    (insert \":CLAUDE_SESSION_ID: $session_id\\n\")
    (insert \":CUSTOM_ID: $session_id\\n\")
    (insert \":END:\\n\")
    (insert \"** System Prompt :system_prompt:\\n\")
    (insert \"You are helping with a test feature.\\n\")
    (insert \"** Workflow :sdd:\\n\")
    (save-buffer)
    \"ok\"))"
}

read_org_buffer() {
  local org_file="$1"
  mcp_call "(let ((debug-on-error nil)
      (debug-on-quit nil))
  (with-current-buffer (or (find-buffer-visiting \"$org_file\")
                           (find-file-noselect \"$org_file\"))
    (buffer-substring-no-properties (point-min) (point-max))))"
}

count_headings() {
  local org_file="$1"
  local pattern="$2"
  mcp_call "(let ((debug-on-error nil)
      (debug-on-quit nil))
  (with-current-buffer (or (find-buffer-visiting \"$org_file\")
                           (find-file-noselect \"$org_file\"))
    (save-excursion
      (goto-char (point-min))
      (let ((count 0))
        (while (re-search-forward \"$pattern\" nil t)
          (setq count (1+ count)))
        (number-to-string count)))))"
}

cleanup_test_file() {
  local org_file="$1"
  mcp_call "(let ((debug-on-error nil)
      (debug-on-quit nil))
  (let ((buf (find-buffer-visiting \"$org_file\")))
    (when buf (kill-buffer buf)))
  (when (file-exists-p \"$org_file\") (delete-file \"$org_file\"))
  \"ok\")"
}
