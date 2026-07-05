"""Minimal workspace bridge — permission handling only.

The bridge handles two Claude CLI hook events:

- ``PreToolUse`` (``AskUserQuestion`` / ``ExitPlanMode``) — surfaces
  permission prompts to Emacs's mode-line and returns ``ask`` so the
  terminal TUI appears for the user.
- ``PostToolUse`` — clears the pending permission state in Emacs.

All other hook events (``SessionStart``, ``UserPromptSubmit``, ``Stop``)
are silently ignored with a warning.  The response-insertion and prompt-
routing logic that previously lived here has been moved into Elisp.

Required env vars: ``WORKSPACE_ORG_FILE``, ``WORKSPACE_SESSION_ID``,
``EMACS_MCP_URL`` (defaults to ``http://localhost:9999/mcp``).
"""

from __future__ import annotations

import json
import logging
import os
import sys
from contextlib import nullcontext
from typing import Protocol

from opentelemetry import trace as otel_trace
from opentelemetry.trace import SpanKind

from code_agent.mcp_client import (
    McpClient,
    McpClientProtocol,
    McpConnectionError,
    McpElispError,
)

try:
    from code_agent.otel_setup import (
        OI_KIND_ATTR,
        STATUS_DIR,
        TraceContextStore,
        setup_tracer,
    )
except ImportError:
    STATUS_DIR = "/tmp/code-agent-status"
    OI_KIND_ATTR = "openinference.span.kind"
    setup_tracer = None
    TraceContextStore = None

logger = logging.getLogger(__name__)

# ======================================================================
# Stateless helpers
#
# These pure functions have no session identity and no side-effects
# beyond their inputs; they stay at module scope rather than becoming
# methods on ``WorkspaceBridge``. Anything that reads or writes
# session-scoped state lives on the class.
# ======================================================================


def _escape_elisp_string(s: str) -> str:
    """Escape STR so it can be embedded in an elisp double-quoted literal.

    Null bytes are stripped outright (elisp strings cannot contain them);
    everything else is backslash-escaped in the way elisp's reader expects.
    """
    return (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
        .replace("\x00", "")  # invalid in elisp strings
    )


# ======================================================================
# WorkspaceBridge
# ======================================================================


class WorkspaceBridge:
    """Minimal bridge — permission handling only.

    Holds the MCP client, the target org file, the session id, and
    (when available) an OpenTelemetry tracer.  Only ``_handle_permission``
    and ``_handle_permission_clear`` carry real logic — every other event
    prints a warning and returns.
    """

    INTERACTIVE_TOOLS: frozenset[str] = frozenset({"AskUserQuestion", "ExitPlanMode"})
    """Tools that require user interaction — we notify Emacs and return
    ``{"permissionDecision": "ask"}`` so the terminal prompt appears."""

    def __init__(
        self,
        mcp: McpClientProtocol,
        org_file: str,
        session_id: str,
        tracer: object | None = None,
        workspace_custom_id: str = "",
        cmux_workspace: str = "",
    ):
        self.mcp = mcp
        self.org_file = org_file
        self.session_id = session_id
        self.tracer = tracer
        # workspace_custom_id is the org heading's :CUSTOM_ID: — the
        # stable, globally-unique routing key.
        self.workspace_custom_id = workspace_custom_id
        # cmux_workspace is the cmux workspace title at launch time —
        # used for display/error messages only.
        self.cmux_workspace = cmux_workspace

    def _routing_key(self) -> str:
        """Return the preferred routing key for elisp workspace lookups.

        Prefers ``workspace_custom_id`` (the org heading's ``:CUSTOM_ID:``)
        — falls back to ``session_id``.
        """
        return self.workspace_custom_id or self.session_id

    # ------------------------------------------------------------------
    # Public dispatch
    # ------------------------------------------------------------------

    def handle(self, event: str, input_data: dict) -> None:
        """Dispatch EVENT to the appropriate ``_handle_<event>`` method.

        Unknown events print a warning instead of raising so a future
        hook name added by Claude CLI doesn't crash the session.
        """
        method_name = f"_handle_{event.replace('-', '_')}"
        method = getattr(self, method_name, None)
        if method is None:
            print(f"workspace-bridge: unknown event: {event}", file=sys.stderr)
            return
        method(input_data)

    # ------------------------------------------------------------------
    # Tracing helpers
    # ------------------------------------------------------------------

    def _span(
        self,
        name: str,
        kind: SpanKind = SpanKind.INTERNAL,
        oi_kind: str = "CHAIN",
        **attrs,
    ):
        """Open a span if the tracer is available; otherwise a no-op CM."""
        if self.tracer:
            attrs[OI_KIND_ATTR] = oi_kind
            return self.tracer.start_as_current_span(name, kind=kind, attributes=attrs)
        return nullcontext()

    def _span_attrs(self, custom_id: str | None = None, **extra) -> dict:
        """Build the common attribute dict carried by every handler span."""
        attrs = {
            "session.id": self.session_id,
            "org.custom_id": custom_id or "",
        }
        attrs.update(extra)
        return attrs

    # ------------------------------------------------------------------
    # MCP wrapper
    # ------------------------------------------------------------------

    def _mcp_eval(self, elisp: str) -> str | None:
        """Eval ELISP in Emacs via MCP, threading the current trace context.

        When a span is active we wrap the form in a ``let`` that binds
        ``code-agent-trace--current-context`` so the Emacs-side MCP
        handler creates child spans under our current Python span.  When
        no span exists (tracing disabled or before setup) we fall through
        to a plain eval.
        """
        wrapped = elisp
        try:
            span = otel_trace.get_current_span()
            ctx = span.get_span_context()
            if ctx.is_valid:
                wrapped = (
                    f"(let ((code-agent-trace--current-context "
                    f'(cons "{ctx.trace_id:032x}" "{ctx.span_id:016x}")))'
                    f" {elisp})"
                )
        except Exception:
            pass  # Tracing unavailable — use original elisp
        return self.mcp.eval_elisp(wrapped)

    # ------------------------------------------------------------------
    # Custom-id file (single value, no queue)
    # ------------------------------------------------------------------

    def _custom_id_path(self) -> str:
        """Return the path to the single custom-id file on disk."""
        return os.path.join(STATUS_DIR, f"{self.session_id}.custom-id")

    def _read_custom_id(self) -> str | None:
        """Read the current custom-id from disk, or None if absent."""
        try:
            with open(self._custom_id_path()) as f:
                val = f.read().strip()
                return val if val else None
        except FileNotFoundError:
            return None

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    def _handle_permission(self, input_data: dict) -> None:
        """Handle ``PreToolUse`` — surface interactive tools to Emacs only.

        Non-interactive tools ignore the permission channel entirely:
        emitting nothing means the CLI uses its default (allow), which
        is what we want for bulk tool calls.  Interactive tools
        (``AskUserQuestion``, ``ExitPlanMode``) notify Emacs's mode-line
        and return ``{"permissionDecision": "ask"}`` so the TUI prompt
        appears for the user to answer.
        """
        tool_name = input_data.get("tool_name", "unknown")
        tool_input = input_data.get("tool_input", {})
        custom_id = self._read_custom_id()
        is_interactive = tool_name in self.INTERACTIVE_TOOLS
        with self._span(
            "handle-permission",
            **self._span_attrs(
                custom_id,
                **{
                    "tool.name": tool_name,
                    "tool.is_interactive": is_interactive,
                    "input.value": json.dumps(tool_input, default=str)[:1000],
                    "input.mime_type": "application/json",
                },
            ),
        ):
            if not is_interactive:
                return

            display_text = tool_name
            if tool_name == "AskUserQuestion":
                question = tool_input.get("question", "")
                if question:
                    display_text = f"asks: {question[:200]}"
            elif tool_name == "ExitPlanMode":
                display_text = "wants to exit plan mode"

            try:
                self._mcp_eval(
                    f"(code-agent-org--terminal-permission-needed "
                    f'"{_escape_elisp_string(self.session_id)}" '
                    f'"{_escape_elisp_string(display_text)}")'
                )
            except (McpConnectionError, McpElispError):
                pass

            print(
                json.dumps(
                    {
                        "hookSpecificOutput": {
                            "hookEventName": "PreToolUse",
                            "permissionDecision": "ask",
                        }
                    }
                )
            )

    def _handle_permission_clear(self, input_data: dict) -> None:
        """Handle ``PostToolUse`` counterpart — clear Emacs's pending state.

        Skipped for non-interactive tools: only ``AskUserQuestion`` /
        ``ExitPlanMode`` ever set pending state in Emacs via
        ``_handle_permission``, so the clear-call would be a costly
        no-op for every bulk tool call.  Blocking Emacs's main thread for
        30-1500 ms on every MCP eval is the observed cost.
        """
        tool_name = input_data.get("tool_name", "unknown")
        is_interactive = tool_name in self.INTERACTIVE_TOOLS
        with self._span(
            "handle-permission-clear",
            **{
                "session.id": self.session_id,
                "tool.name": tool_name,
                "tool.is_interactive": is_interactive,
            },
        ):
            if not is_interactive:
                return
            try:
                self._mcp_eval(
                    f"(code-agent-org--terminal-permission-resolved "
                    f'"{_escape_elisp_string(self.session_id)}")'
                )
            except (McpConnectionError, McpElispError):
                pass


# ======================================================================
# Entry point
# ======================================================================


def main() -> None:
    """CLI entry — parse argv/env, construct the bridge, dispatch once.

    Sets up a trace root (SERVER when we create the context, CONSUMER
    when joined to an existing Emacs traceparent) before calling
    ``bridge.handle``.
    """
    if len(sys.argv) < 2:
        print("Usage: workspace-bridge <event-type>", file=sys.stderr)
        sys.exit(1)

    event = sys.argv[1]
    input_text = sys.stdin.read()

    org_file = os.environ.get("WORKSPACE_ORG_FILE", "")
    session_id = os.environ.get("WORKSPACE_SESSION_ID", "")
    workspace_custom_id = os.environ.get("WORKSPACE_CUSTOM_ID", "")
    cmux_workspace = os.environ.get("CMUX_WORKSPACE", "")
    mcp_url = os.environ.get("EMACS_MCP_URL", "http://localhost:9999/mcp")

    if not org_file or not session_id:
        sys.exit(0)  # soft-fail: don't break hooks for non-workspace sessions

    tracer = setup_tracer("code-agent-workspace-bridge") if setup_tracer else None
    trace_store = (
        TraceContextStore(STATUS_DIR) if (tracer and TraceContextStore) else None
    )
    ctx = trace_store.read(session_id) if trace_store else None

    try:
        input_data = json.loads(input_text) if input_text.strip() else {}
    except json.JSONDecodeError:
        input_data = {}

    mcp = McpClient(url=mcp_url)
    bridge = WorkspaceBridge(
        mcp=mcp,
        org_file=org_file,
        session_id=session_id,
        tracer=tracer,
        workspace_custom_id=workspace_custom_id,
        cmux_workspace=cmux_workspace,
    )

    # Root span shape depends on whether Emacs already wrote a
    # traceparent for this session (Flow A / CONSUMER) or we are
    # creating it now (Flow B / SERVER).
    custom_id = bridge._read_custom_id()
    root_attrs = bridge._span_attrs(
        custom_id,
        event=event,
        **{
            "org.file": org_file,
            "input.has_data": bool(input_text.strip()),
            "mcp.url": mcp_url,
        },
    )
    if ctx is None:
        root_kind, root_oi_kind = SpanKind.SERVER, "CHAIN"
    else:
        root_kind, root_oi_kind = SpanKind.CONSUMER, "TOOL"
    root_attrs[OI_KIND_ATTR] = root_oi_kind

    if tracer:
        root_span_ctx = tracer.start_as_current_span(
            f"workspace-bridge-{event}",
            context=ctx,
            kind=root_kind,
            attributes=root_attrs,
        )
    else:
        root_span_ctx = bridge._span(
            f"workspace-bridge-{event}",
            kind=root_kind,
            oi_kind=root_oi_kind,
            **root_attrs,
        )

    with root_span_ctx as root_span:
        if ctx is None and root_span is not None and trace_store is not None:
            span_ctx = root_span.get_span_context()
            trace_store.write(
                session_id,
                format(span_ctx.trace_id, "032x"),
                format(span_ctx.span_id, "016x"),
            )
        bridge.handle(event, input_data)


if __name__ == "__main__":
    main()
