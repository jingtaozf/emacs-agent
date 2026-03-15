"""SDD bridge hook handler — replaces scripts/sdd-bridge.sh.

Called by Claude CLI hooks with event type as argv[1], JSON on stdin.
Required env vars: SDD_ORG_FILE, SDD_SESSION_ID, EMACS_MCP_URL
"""

import json
import logging
import os
import sys
from contextlib import nullcontext

from opentelemetry import trace as otel_trace
from opentelemetry.trace import SpanKind

from claude_agent.mcp_client import McpClient, McpConnectionError, McpElispError

try:
    from claude_agent.otel_setup import (
        STATUS_DIR, setup_tracer, read_trace_context, write_trace_context,
    )
except ImportError:
    STATUS_DIR = "/tmp/claude-agent-status"
    setup_tracer = None
    read_trace_context = None
    write_trace_context = None

logger = logging.getLogger(__name__)

tracer = None  # initialized in main()


_OI_KIND_ATTR = "openinference.span.kind"


def _span(name, kind=SpanKind.INTERNAL, oi_kind="CHAIN", **attrs):
    """Create a span if tracer is available, otherwise no-op context manager."""
    if tracer:
        attrs[_OI_KIND_ATTR] = oi_kind
        return tracer.start_as_current_span(name, kind=kind, attributes=attrs)
    return nullcontext()


def _span_attrs(session_id: str, custom_id: str | None = None, **extra) -> dict:
    """Build common span attributes with session and custom ID."""
    attrs = {"session.id": session_id, "org.custom_id": custom_id or ""}
    attrs.update(extra)
    return attrs


def write_status(session_id: str, status: str) -> None:
    """Write status file for fast detection by iTerm2 backend."""
    os.makedirs(STATUS_DIR, exist_ok=True)
    path = os.path.join(STATUS_DIR, session_id)
    with open(path, "w") as f:
        f.write(status)


def _write_custom_id(session_id: str, custom_id: str) -> None:
    """Save the active instruction CUSTOM_ID for prompt→response correlation."""
    path = os.path.join(STATUS_DIR, f"{session_id}.custom-id")
    with open(path, "w") as f:
        f.write(custom_id)


def _read_custom_id(session_id: str) -> str | None:
    """Read the active instruction CUSTOM_ID, or None if not set."""
    path = os.path.join(STATUS_DIR, f"{session_id}.custom-id")
    try:
        with open(path) as f:
            value = f.read().strip()
            return value if value else None
    except FileNotFoundError:
        return None


def _notify_query_completed(mcp: McpClient, session_id: str, custom_id: str | None = None) -> None:
    """Unregister query from Emacs active-queries (mode-line + *Claude Queries*)."""
    with _span("notify-query-completed", **_span_attrs(session_id, custom_id)):
        try:
            _mcp_eval_with_trace(
                mcp,
                f'(claude-org--terminal-query-completed '
                f'"{_escape_elisp_string(session_id)}")'
            )
        except (McpConnectionError, McpElispError):
            logger.warning("Failed to notify query completed for %s", session_id)


def _read_request_id(session_id: str) -> str | None:
    """Read the active-query request-id written by Emacs, or None."""
    path = os.path.join(STATUS_DIR, f"{session_id}.request-id")
    try:
        with open(path) as f:
            value = f.read().strip()
            return value if value else None
    except FileNotFoundError:
        return None


def _escape_elisp_string(s: str) -> str:
    """Escape a string for embedding in an elisp double-quoted string."""
    return (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
        .replace("\x00", "")  # strip null bytes - invalid in elisp strings
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


def _mcp_eval_with_trace(mcp: McpClient, elisp: str) -> str | None:
    """Eval elisp via MCP, passing current trace context for child span creation.

    Wraps the elisp in a let-binding that sets claude-agent-trace--current-context
    so Emacs MCP handlers create child spans under the current Python span.
    Falls back to plain eval_elisp when tracing is not active.
    """
    wrapped = elisp
    try:
        span = otel_trace.get_current_span()
        ctx = span.get_span_context()
        if ctx.is_valid:
            wrapped = (
                f'(let ((claude-agent-trace--current-context '
                f'(cons "{ctx.trace_id:032x}" "{ctx.span_id:016x}")))'
                f' {elisp})'
            )
    except Exception:
        pass  # Tracing unavailable, use original elisp
    return mcp.eval_elisp(wrapped)


def _check_any_recent_from_emacs_flag(max_age_sec: float = 10.0):
    """Check if ANY .from-emacs flag was written recently.

    Returns (True, path) if found, (False, "") otherwise.
    Handles the session ID mismatch where Emacs writes the flag keyed by
    a per-heading session ID but the terminal uses a different SDD_SESSION_ID.
    """
    import time

    now = time.time()
    try:
        for f in os.listdir(STATUS_DIR):
            if f.endswith(".from-emacs"):
                path = os.path.join(STATUS_DIR, f)
                try:
                    if now - os.path.getmtime(path) < max_age_sec:
                        return True, path
                except OSError:
                    continue
    except OSError:
        pass
    return False, ""


def handle_prompt(
    mcp: McpClient,
    input_data: dict,
    org_file: str,
    session_id: str,
) -> None:
    """Handle UserPromptSubmit hook event."""
    write_status(session_id, "busy")

    try:
        prompt = input_data.get("prompt", "")
        if not prompt:
            return

        # Skip system-injected messages — these are not human prompts
        if prompt.lstrip().startswith("<"):
            return

        # Check from-emacs flag — try session-specific first, then any recent flag.
        # Emacs writes the flag keyed by per-heading session ID, which may differ
        # from the terminal's SDD_SESSION_ID. Checking any recent flag handles this.
        from_emacs_flag = os.path.join(STATUS_DIR, f"{session_id}.from-emacs")
        flag_exists = os.path.exists(from_emacs_flag)
        if not flag_exists:
            flag_exists, from_emacs_flag = _check_any_recent_from_emacs_flag()

        custom_id = _read_custom_id(session_id)
        with _span(
            "handle-prompt",
            **_span_attrs(session_id, custom_id,
                          **{"from.emacs": flag_exists, "prompt.length": len(prompt)}),
        ) as span:
            save_sexp = _build_save_cli_session_sexp(
                org_file, session_id, input_data.get("session_id", "")
            )

            if flag_exists:
                try:
                    os.remove(from_emacs_flag)
                except FileNotFoundError:
                    pass
                # Flag existed and was removed — prompt came from Emacs
                if save_sexp:
                    try:
                        _mcp_eval_with_trace(mcp, save_sexp)
                    except (McpConnectionError, McpElispError):
                        pass
            else:
                # No flag — prompt was typed in terminal, insert into org
                escaped_prompt = _escape_elisp_string(prompt)
                elisp = (
                    f'(claude-org-sdd-bridge-insert-prompt '
                    f'"{_escape_elisp_string(org_file)}" '
                    f'"{_escape_elisp_string(session_id)}" '
                    f'"{escaped_prompt}")'
                )
                try:
                    result = _mcp_eval_with_trace(mcp, elisp)
                except (McpConnectionError, McpElispError):
                    logger.warning("Failed to insert prompt for %s", session_id)
                    return
                if result is None:
                    return
                # Save instruction CUSTOM_ID for response correlation
                if result:
                    _write_custom_id(session_id, result)
                    if span:
                        span.set_attribute("org.custom_id", result)
                if save_sexp:
                    try:
                        _mcp_eval_with_trace(mcp, save_sexp)
                    except (McpConnectionError, McpElispError):
                        pass
    finally:
        write_status(session_id, "ready")


def handle_response(
    mcp: McpClient,
    input_data: dict,
    org_file: str,
    session_id: str,
) -> None:
    """Handle Stop hook event."""
    write_status(session_id, "ready")

    custom_id = _read_custom_id(session_id)

    with _span("handle-response", **_span_attrs(session_id, custom_id)) as span:
        # Extract full response from transcript (skips intermediate tool-use turns)
        response = ""
        transcript_path = input_data.get("transcript_path", "")
        if transcript_path and os.path.isfile(transcript_path):
            response = _extract_full_response(transcript_path)

        # Fallback: last_assistant_message when no transcript available
        if not response:
            response = input_data.get("last_assistant_message", "")

        if span:
            span.set_attribute("response.length", len(response) if response else 0)

        if not response:
            # No response to insert — still mark query completed
            _notify_query_completed(mcp, session_id, custom_id)
            return

        save_sexp = _build_save_cli_session_sexp(
            org_file, session_id, input_data.get("session_id", "")
        )

        if not custom_id:
            # No instruction to attach response to — still mark query completed
            _notify_query_completed(mcp, session_id)
            return

        elisp = (
            f'(progn '
            f'(claude-org-sdd-bridge-insert-response '
            f'"{_escape_elisp_string(org_file)}" '
            f'"{_escape_elisp_string(session_id)}" '
            f'"{_escape_elisp_string(response)}" '
            f'"{_escape_elisp_string(custom_id)}") '
            f'{save_sexp} '
            f'(with-current-buffer (claude-org-sdd-bridge--ensure-buffer '
            f'"{_escape_elisp_string(org_file)}") '
            f'(run-hook-with-args '
            f"'claude-org-complete-hook "
            f'(claude-org--current-session-key) nil '
            f"'completed)))"
        )
        try:
            _mcp_eval_with_trace(mcp, elisp)
        except (McpConnectionError, McpElispError):
            logger.warning("Failed to insert response for %s", session_id)

        # Mark query completed AFTER response insertion attempt
        _notify_query_completed(mcp, session_id, custom_id)


def _extract_full_response(transcript_path: str) -> str:
    """Extract all assistant text since the last user prompt from JSONL transcript.

    Reads the transcript, finds the last user entry, then collects all
    assistant text content blocks after it. Skips tool_use and thinking blocks.
    Returns joined text separated by double newlines.
    """
    with _span("extract-full-response", **{"transcript.path": transcript_path}) as span:
        entries = []
        with open(transcript_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    logger.warning("Skipping malformed JSONL line in transcript")
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
            message = entry.get("message")
            if not isinstance(message, dict):
                continue
            content = message.get("content", [])
            has_tool_use = any(p.get("type") == "tool_use" for p in content)
            if has_tool_use:
                continue
            for part in content:
                if part.get("type") == "text":
                    text = part.get("text", "").strip()
                    if text:
                        texts.append(text)

        if span:
            span.set_attribute("text_blocks.count", len(texts))

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

    custom_id = _read_custom_id(session_id)
    with _span("handle-tool", **_span_attrs(session_id, custom_id, **{"tool.name": tool_name})):
        if tool_name == "TodoWrite":
            _handle_todo_tool(mcp, tool_input, org_file, session_id, custom_id)


def _handle_todo_tool(
    mcp: McpClient,
    tool_input: dict,
    org_file: str,
    session_id: str,
    custom_id: str | None = None,
) -> None:
    """Handle TodoWrite tool — update checkbox list in the org buffer."""
    todos = tool_input.get("todos", [])
    if not todos:
        return

    if not custom_id:
        return  # No instruction to attach todos to

    elisp_todos = _format_todos_as_elisp(todos)
    elisp = (
        f'(claude-org-sdd-bridge-update-todos '
        f'"{_escape_elisp_string(org_file)}" '
        f'"{_escape_elisp_string(session_id)}" '
        f"'{elisp_todos} "
        f'"{_escape_elisp_string(custom_id)}")'
    )
    try:
        _mcp_eval_with_trace(mcp, elisp)
    except (McpConnectionError, McpElispError):
        logger.warning("Failed to update todos for %s", session_id)


# Tools that require user interaction — notify Emacs and return "ask"
_INTERACTIVE_TOOLS = {"AskUserQuestion", "ExitPlanMode"}


def handle_permission(
    mcp: McpClient,
    input_data: dict,
    org_file: str,
    session_id: str,
) -> None:
    """Handle PreToolUse hook — notify Emacs for interactive tools only.

    For AskUserQuestion/ExitPlanMode: notify Emacs + return "ask" (needs user).
    For all other tools: no notification, no permission override (empty output).
    """
    tool_name = input_data.get("tool_name", "unknown")

    custom_id = _read_custom_id(session_id)
    with _span("handle-permission", **_span_attrs(session_id, custom_id, **{"tool.name": tool_name})):
        if tool_name in _INTERACTIVE_TOOLS:
            # Notify Emacs (best-effort)
            try:
                _mcp_eval_with_trace(
                    mcp,
                    f'(claude-org-iterm2--permission-needed '
                    f'"{_escape_elisp_string(session_id)}" '
                    f'"{_escape_elisp_string(tool_name)}")'
                )
            except (McpConnectionError, McpElispError):
                pass

            # Return "ask" so the terminal prompt appears
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "ask",
                }
            }))


def handle_permission_clear(
    mcp: McpClient,
    input_data: dict,
    org_file: str,
    session_id: str,
) -> None:
    """Handle PostToolUse hook — clear pending permission in Emacs."""
    with _span("handle-permission-clear", **{"session.id": session_id}):
        try:
            _mcp_eval_with_trace(
                mcp,
                f'(claude-org-iterm2--permission-resolved '
                f'"{_escape_elisp_string(session_id)}")'
            )
        except (McpConnectionError, McpElispError):
            pass


def main() -> None:
    global tracer

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

    # Initialize tracing (optional — gracefully degrades if deps missing)
    ctx = None
    if setup_tracer:
        tracer = setup_tracer("claude-agent-sdd-bridge")
        ctx = read_trace_context(session_id)

    try:
        input_data = json.loads(input_text) if input_text.strip() else {}
    except json.JSONDecodeError:
        input_data = {}

    mcp = McpClient(url=mcp_url)

    # Determine root vs child based on trace context existence
    custom_id = _read_custom_id(session_id)
    root_attrs = _span_attrs(session_id, custom_id, event=event, **{"org.file": org_file})

    if ctx is None:
        # No Emacs parent — WE are the root (Flow B: direct mode)
        root_kind = SpanKind.SERVER
        root_oi_kind = "CHAIN"
    else:
        # Emacs parent exists — we're a child (Flow A: Emacs-initiated)
        root_kind = SpanKind.CONSUMER
        root_oi_kind = "TOOL"

    root_attrs[_OI_KIND_ATTR] = root_oi_kind

    if tracer:
        root_span_ctx = tracer.start_as_current_span(
            f"sdd-bridge-{event}", context=ctx,
            kind=root_kind, attributes=root_attrs
        )
    else:
        root_span_ctx = _span(
            f"sdd-bridge-{event}", kind=root_kind, oi_kind=root_oi_kind,
            **root_attrs
        )

    with root_span_ctx as root_span:
        # When we're the root, write traceparent so subsequent events join this trace
        if ctx is None and root_span is not None and write_trace_context:
            span_ctx = root_span.get_span_context()
            write_trace_context(
                session_id,
                format(span_ctx.trace_id, '032x'),
                format(span_ctx.span_id, '016x'),
            )

        if event == "prompt":
            handle_prompt(mcp, input_data, org_file, session_id)
        elif event == "response":
            handle_response(mcp, input_data, org_file, session_id)
        elif event == "tool":
            handle_tool(mcp, input_data, org_file, session_id)
        elif event == "permission":
            handle_permission(mcp, input_data, org_file, session_id)
        elif event == "permission-clear":
            handle_permission_clear(mcp, input_data, org_file, session_id)
        else:
            print(f"sdd-bridge: unknown event: {event}", file=sys.stderr)


if __name__ == "__main__":
    main()
