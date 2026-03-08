"""SDD bridge hook handler — replaces scripts/sdd-bridge.sh.

Called by Claude CLI hooks with event type as argv[1], JSON on stdin.
Required env vars: SDD_ORG_FILE, SDD_SESSION_ID, EMACS_MCP_URL
"""

import json
import os
import sys

from claude_agent.mcp_client import McpClient

STATUS_DIR = "/tmp/claude-agent-status"


def write_status(session_id: str, status: str) -> None:
    """Write status file for fast detection by iTerm2 backend."""
    os.makedirs(STATUS_DIR, exist_ok=True)
    path = os.path.join(STATUS_DIR, session_id)
    with open(path, "w") as f:
        f.write(status)


def _escape_elisp_string(s: str) -> str:
    """Escape a string for embedding in an elisp double-quoted string."""
    return (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
    )


def _build_save_cli_session_sexp(
    org_file: str, session_id: str, cli_session: str
) -> str:
    """Build elisp sexp to save CLI session ID, or empty string if no cli_session."""
    if not cli_session:
        return ""
    return (
        f'(claude-org-sdd-bridge-save-cli-session '
        f'"{_escape_elisp_string(org_file)}" '
        f'"{_escape_elisp_string(session_id)}" '
        f'"{_escape_elisp_string(cli_session)}")'
    )


def handle_prompt(
    mcp: McpClient,
    input_data: dict,
    org_file: str,
    session_id: str,
) -> None:
    """Handle UserPromptSubmit hook event."""
    write_status(session_id, "busy")

    prompt = input_data.get("prompt", "")
    if not prompt:
        return

    # Skip system-injected messages — these are not human prompts
    if prompt.lstrip().startswith("<"):
        return

    save_sexp = _build_save_cli_session_sexp(
        org_file, session_id, input_data.get("session_id", "")
    )

    # Check from-emacs flag
    from_emacs_flag = os.path.join(STATUS_DIR, f"{session_id}.from-emacs")
    if os.path.exists(from_emacs_flag):
        os.remove(from_emacs_flag)
        if save_sexp:
            mcp.eval_elisp(save_sexp)
    else:
        escaped_prompt = _escape_elisp_string(prompt)
        elisp = (
            f'(progn '
            f'(claude-org-sdd-bridge-insert-prompt '
            f'"{_escape_elisp_string(org_file)}" '
            f'"{_escape_elisp_string(session_id)}" '
            f'"{escaped_prompt}") '
            f'{save_sexp})'
        )
        mcp.eval_elisp(elisp)


def handle_response(
    mcp: McpClient,
    input_data: dict,
    org_file: str,
    session_id: str,
) -> None:
    """Handle Stop hook event."""
    write_status(session_id, "ready")

    # Extract full response from transcript (skips intermediate tool-use turns)
    response = ""
    transcript_path = input_data.get("transcript_path", "")
    if transcript_path and os.path.isfile(transcript_path):
        response = _extract_full_response(transcript_path)

    # Fallback: last_assistant_message when no transcript available
    if not response:
        response = input_data.get("last_assistant_message", "")

    if not response:
        return

    save_sexp = _build_save_cli_session_sexp(
        org_file, session_id, input_data.get("session_id", "")
    )

    elisp = (
        f'(progn '
        f'(claude-org-sdd-bridge-insert-response '
        f'"{_escape_elisp_string(org_file)}" '
        f'"{_escape_elisp_string(session_id)}" '
        f'"{_escape_elisp_string(response)}") '
        f'{save_sexp})'
    )
    mcp.eval_elisp(elisp)


def _extract_full_response(transcript_path: str) -> str:
    """Extract all assistant text since the last user prompt from JSONL transcript.

    Reads the transcript, finds the last user entry, then collects all
    assistant text content blocks after it. Skips tool_use and thinking blocks.
    Returns joined text separated by double newlines.
    """
    entries = []
    with open(transcript_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue

    if not entries:
        return ""

    # Find the last user entry index
    last_user_idx = -1
    for i, entry in enumerate(entries):
        if entry.get("type") == "user":
            last_user_idx = i

    # Collect assistant text after the last user entry.
    # Skip entries that contain tool_use blocks — these are intermediate turns
    # (e.g., "Let me check...", agent result summaries) that produce noisy
    # duplicate sections when inserted into org.
    texts = []
    start = last_user_idx + 1 if last_user_idx >= 0 else 0
    for entry in entries[start:]:
        if entry.get("type") != "assistant":
            continue
        content = entry.get("message", {}).get("content", [])
        has_tool_use = any(p.get("type") == "tool_use" for p in content)
        if has_tool_use:
            continue
        for part in content:
            if part.get("type") == "text":
                text = part.get("text", "").strip()
                if text:
                    texts.append(text)

    return "\n\n".join(texts)


def _format_todos_as_elisp(todos: list[dict]) -> str:
    """Convert a JSON todos array to elisp plist list syntax.

    Each todo is {:content STRING :status STRING :priority NUMBER}.
    Input: [{"content": "Do X", "status": "completed"}, ...]
    Output: '((:content "Do X" :status "completed") ...)'
    """
    items = []
    for todo in todos:
        content = _escape_elisp_string(todo.get("content", ""))
        status = _escape_elisp_string(todo.get("status", "pending"))
        try:
            priority = int(todo.get("priority", 0))
        except (TypeError, ValueError):
            priority = 0
        items.append(f'(:content "{content}" :status "{status}" :priority {priority})')
    return "(" + " ".join(items) + ")"


def handle_tool(
    mcp: McpClient,
    input_data: dict,
    org_file: str,
    session_id: str,
) -> None:
    """Handle PostToolUse hook event — updates todo checkboxes for TodoWrite."""
    tool_name = input_data.get("tool_name", "")
    tool_input = input_data.get("tool_input", {})

    if tool_name == "TodoWrite":
        _handle_todo_tool(mcp, tool_input, org_file, session_id)


def _handle_todo_tool(
    mcp: McpClient,
    tool_input: dict,
    org_file: str,
    session_id: str,
) -> None:
    """Handle TodoWrite tool — update checkbox list in the org buffer."""
    todos = tool_input.get("todos", [])
    if not todos:
        return

    elisp_todos = _format_todos_as_elisp(todos)
    elisp = (
        f'(claude-org-sdd-bridge-update-todos '
        f'"{_escape_elisp_string(org_file)}" '
        f'"{_escape_elisp_string(session_id)}" '
        f"'{elisp_todos})"
    )
    mcp.eval_elisp(elisp)


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: sdd-bridge <event-type>", file=sys.stderr)
        sys.exit(1)

    event = sys.argv[1]
    input_text = sys.stdin.read()

    org_file = os.environ.get("SDD_ORG_FILE")
    session_id = os.environ.get("SDD_SESSION_ID")
    mcp_url = os.environ.get("EMACS_MCP_URL", "http://localhost:9999/mcp")

    if not org_file or not session_id:
        sys.exit(0)  # soft-fail: don't break hooks for non-SDD sessions

    try:
        input_data = json.loads(input_text) if input_text.strip() else {}
    except json.JSONDecodeError:
        input_data = {}

    mcp = McpClient(url=mcp_url)

    if event == "prompt":
        handle_prompt(mcp, input_data, org_file, session_id)
    elif event == "response":
        handle_response(mcp, input_data, org_file, session_id)
    elif event == "tool":
        handle_tool(mcp, input_data, org_file, session_id)
    else:
        print(f"sdd-bridge: unknown event: {event}", file=sys.stderr)


if __name__ == "__main__":
    main()
