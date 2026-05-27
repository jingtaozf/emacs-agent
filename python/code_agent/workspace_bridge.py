"""Workspace bridge — Claude CLI hook events into Emacs org state.

The bridge is the Python half of the agent/editor seam. Claude CLI spawns
this process (via one of the six registered hooks — SessionStart,
UserPromptSubmit, Stop, PostToolUse, PreToolUse, PostToolUse-clear) and
passes the event type on ``argv[1]`` and the event payload as JSON on
stdin. We turn each event into an elisp call issued through the Emacs
MCP server, so the user sees prompts appear, responses stream in, todo
checkboxes update, and permission requests surface in the mode-line.

Architecturally the bridge is a **coordinator class** (``WorkspaceBridge``)
plus a tiny ``typing.Protocol`` that names the published contract. One
instance carries one session's state — the MCP client, the org file
path, the session id, and an optional OpenTelemetry tracer — and each
hook invocation calls ``bridge.handle(event, input_data)``. Dispatch
happens by method lookup (``_handle_<event>``), the Smalltalk-flavoured
style used throughout the project (see
the imported `oop-smalltalk-protocols` rule). Callers never branch on
the event string themselves.

Tracing: every handler opens a span under the process-root span created
in ``main``. Two parent shapes exist — Flow A where Emacs has already
written a ``traceparent`` for this session (bridge-root becomes a
CONSUMER child) and Flow B where this process is the first observer (it
writes its own traceparent for subsequent events to join). See
``code-agent-trace.org`` → "Two Execution Flows" for the current design.

Required env vars: ``WORKSPACE_ORG_FILE``, ``WORKSPACE_SESSION_ID``,
``EMACS_MCP_URL`` (defaults to ``http://localhost:9999/mcp``).
"""

from __future__ import annotations

import enum
import json
import logging
import os
import subprocess
import sys
import time
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

# Process start time — used by the "any recent .from-emacs flag" check
# to distinguish flags written during *this* invocation from stale ones
# left by an earlier run. A fixed time window would either miss slow
# invocations or consume unrelated flags.
_process_start_time = time.time()

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


def _format_todos_as_elisp(todos: list[dict]) -> str:
    """Convert a TodoWrite JSON list to an elisp plist list expression.

    Each todo ``{"content": ..., "status": ..., "priority": ...}`` becomes
    ``(:content "..." :status "..." :priority N)``; the final result is
    a parenthesised sequence suitable for quoting with ``'``.
    """
    items: list[str] = []
    for todo in todos:
        content = _escape_elisp_string(todo.get("content", ""))
        status = _escape_elisp_string(todo.get("status", "pending"))
        try:
            priority = int(todo.get("priority", 0))
        except (TypeError, ValueError):
            priority = 0
        items.append(f'(:content "{content}" :status "{status}" :priority {priority})')
    return "(" + " ".join(items) + ")"


class AgentKind(enum.Enum):
    """Which agent CLI is driving this workspace.

    Values are the string written to the ``AGENT_TYPE`` env var by
    the launcher, so an enum member round-trips through env-var I/O
    without a separate mapping table.

    Method `cli_session_property` collapses the
    "Copilot vs everyone-else" CLI-session-property dispatch that
    previously sat in `_cli_session_property` as a single ``if``
    branch — Smalltalk-style: each agent kind *carries* the
    knowledge of what org property it persists its session id to.
    """

    CLAUDE = "claude"
    COPILOT = "copilot"
    OPENCODE = "opencode"

    @property
    def cli_session_property(self) -> str:
        """Org property name where this agent persists its CLI session id.

        Copilot and Claude Code use distinct property names so a
        workspace can run both without stomping on each other's
        resume token; OpenCode shares CLAUDE_CLI_SESSION historically
        and has its own separate ACP_SESSION_ID for the direct-ACP
        integration path.
        """
        if self is AgentKind.COPILOT:
            return "COPILOT_CLI_SESSION"
        return "CLAUDE_CLI_SESSION"

    @classmethod
    def from_env(cls) -> "AgentKind":
        """Read the current kind from ``AGENT_TYPE``; default to CLAUDE."""
        return cls.from_string(os.environ.get("AGENT_TYPE", ""))

    @classmethod
    def from_string(cls, value: str | None) -> "AgentKind":
        """Parse VALUE into a kind, defaulting to CLAUDE when unrecognised."""
        if value:
            value = value.lower()
            for kind in cls:
                if kind.value == value:
                    return kind
        return cls.CLAUDE


def _cli_session_property() -> str:
    """Return the org property name where we persist the CLI session id.

    Thin shim over `AgentKind.from_env().cli_session_property` kept
    for the existing call site in `WorkspaceBridge._save_cli_session_elisp`.
    """
    return AgentKind.from_env().cli_session_property


def _read_agent_name_from_ppid() -> str | None:
    """Return the value of ``--name`` on the parent process's argv.

    See module-level cross-cmux-restart recovery design in
    ``_resolve_routing_via_agent_name``.
    """
    ppid = os.getppid()
    if ppid <= 1:
        return None
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-ww", "-o", "command="],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (subprocess.SubprocessError, OSError):
        return None
    if result.returncode != 0 or not result.stdout.strip():
        return None
    tokens = result.stdout.strip().split()
    for i, tok in enumerate(tokens):
        if tok == "--name" and i + 1 < len(tokens):
            return tokens[i + 1]
        if tok.startswith("--name="):
            return tok[len("--name=") :]
    return None


def _resolve_routing_via_agent_name(
    env_org_file: str,
    env_session_id: str,
    env_custom_id: str,
    mcp_url: str,
) -> tuple[str, str, str, bool]:
    """Recover routing tuple from claude's ``--name`` slug via Emacs MCP.

    See section docstring above for the full design.  Tuple shape:
    ``(org_file, session_id, custom_id, recovered)``.
    """
    agent_name = _read_agent_name_from_ppid()
    if not agent_name:
        return env_org_file, env_session_id, env_custom_id, False
    cwd = os.environ.get("CMUX_AGENT_LAUNCH_CWD") or os.getcwd()
    try:
        mcp = McpClient(url=mcp_url)
        elisp = (
            "(let ((debug-on-error nil) (debug-on-quit nil))"
            "  (if (fboundp 'code-agent-org-cmux--lookup-session-by-agent-name-as-string)"
            "      (code-agent-org-cmux--lookup-session-by-agent-name-as-string "
            f'        "{_escape_elisp_string(agent_name)}" '
            f'        "{_escape_elisp_string(cwd)}")'
            '    ""))'
        )
        result = mcp.eval_elisp(elisp)
    except (McpConnectionError, McpElispError, OSError):
        return env_org_file, env_session_id, env_custom_id, False
    if not result:
        return env_org_file, env_session_id, env_custom_id, False
    parts = result.split("\0", 2)
    mcp_org_file = parts[0] if len(parts) > 0 else ""
    mcp_session_id = parts[1] if len(parts) > 1 else ""
    mcp_custom_id = parts[2] if len(parts) > 2 else ""
    if not (mcp_org_file and mcp_session_id):
        return env_org_file, env_session_id, env_custom_id, False
    changed = (mcp_org_file != env_org_file) or (mcp_session_id != env_session_id)
    return mcp_org_file, mcp_session_id, mcp_custom_id, changed


def _check_any_recent_from_emacs_flag() -> tuple[bool, str]:
    """Return ``(True, path)`` if a ``.from-emacs`` flag was written during
    this process's lifetime, else ``(False, "")``.

    Emacs writes the flag keyed by its own per-heading session id, which
    may differ from the terminal's ``WORKSPACE_SESSION_ID``. Rather than
    guess the right id, we accept any flag newer than
    ``_process_start_time`` so we don't consume flags from unrelated
    earlier executions.
    """
    try:
        for f in os.listdir(STATUS_DIR):
            if f.endswith(".from-emacs"):
                path = os.path.join(STATUS_DIR, f)
                try:
                    if os.path.getmtime(path) >= _process_start_time:
                        return True, path
                except OSError:
                    continue
    except OSError:
        pass
    return False, ""


def write_status(session_id: str, status: str) -> None:
    """Write ``<STATUS_DIR>/<session_id>`` with STATUS for fast detection.

    Emacs's terminal backends poll this file during the short
    window between "prompt sent" and "first response token" to decide
    whether the CLI is still busy. The hook handlers flip it busy/ready
    at the obvious points.
    """
    os.makedirs(STATUS_DIR, exist_ok=True)
    path = os.path.join(STATUS_DIR, session_id)
    with open(path, "w") as f:
        f.write(status)


# ======================================================================
# Transcript extractors
#
# Two transcript formats exist — Claude Code's JSONL (``type: "assistant"``
# with a content-block list) and Copilot's events.jsonl (``type:
# "assistant.message"`` with a plain string). Both implementations find
# the last user-message boundary and collect assistant text after it,
# skipping turns that contain tool calls to avoid inserting noisy
# intermediate narration.
# ======================================================================


def _extract_full_response(transcript_path: str) -> str:
    """Back-compat wrapper around ``ClaudeTranscriptReader``.

    Kept because tests import it by name; production code calls
    ``TranscriptReader.for_path(p).extract_response()`` instead.
    """
    return ClaudeTranscriptReader(transcript_path).extract_response()


def _extract_turns(transcript_path: str) -> list[tuple[str, str]]:
    """Back-compat wrapper — see ``ClaudeTranscriptReader.extract_turns``.

    The shared algorithm groups every user turn with the non-tool-use
    assistant text that immediately follows it (before the next user
    turn).  Empty assistant text marks a superseded or cancelled turn
    so the orchestration layer can route accordingly.
    """
    return ClaudeTranscriptReader(transcript_path).extract_turns()


def _extract_user_text(entry: dict) -> str:
    """Back-compat wrapper — delegates to ``ClaudeTranscriptReader._user_text``."""
    return ClaudeTranscriptReader("")._user_text(entry)


def _extract_copilot_response(transcript_path: str) -> str:
    """Back-compat wrapper around ``CopilotTranscriptReader.extract_response``."""
    return CopilotTranscriptReader(transcript_path).extract_response()


# ======================================================================
# TranscriptReader — polymorphic abstraction over the two formats
# ======================================================================
#
# The four ``_extract_*`` free functions above grew from two parallel
# implementations: Claude Code JSONL (``type: "user"`` /
# ``type: "assistant"`` with content-block lists) and Copilot
# events.jsonl (``type: "user.message"`` / ``type: "assistant.message"``
# with plain-string content).  Three independent call sites then
# string-sniffed ``first_entry.get("type", "").startswith("session.")``
# to pick which one to call — a recurring discriminator that ought to
# be a class hierarchy.
#
# Below: a tiny ABC + two concrete readers + a ``for_path`` factory.
# Callers say ``TranscriptReader.for_path(p).extract_response()`` and
# the right implementation runs.  The free functions kept above stay
# as thin shims because external tests import them.


class TranscriptReader:
    """Polymorphic reader for one transcript file.

    Subclasses implement ``USER_TYPE`` (the ``type`` value that marks
    a user turn) and ``_assistant_text(entry)`` (how to pull text
    from one assistant entry, returning ``None`` for tool-use turns
    that should be skipped).  The shared ``extract_response`` and
    ``extract_turns`` algorithms are identical across formats.
    """

    USER_TYPE: str = ""  # overridden by subclasses
    ASSISTANT_TYPE: str = ""

    @classmethod
    def for_path(cls, transcript_path: str) -> "TranscriptReader":
        """Sniff the first non-blank line, return the matching subclass."""
        first_entry: dict = {}
        try:
            with open(transcript_path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        first_entry = json.loads(line)
                    except json.JSONDecodeError:
                        first_entry = {}
                    break
        except OSError:
            pass
        if str(first_entry.get("type", "")).startswith("session."):
            return CopilotTranscriptReader(transcript_path)
        return ClaudeTranscriptReader(transcript_path)

    def __init__(self, transcript_path: str):
        self.path = transcript_path

    # --- JSONL parsing: shared, tolerates malformed lines ---
    def _entries(self) -> list[dict]:
        entries: list[dict] = []
        try:
            with open(self.path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entries.append(json.loads(line))
                    except json.JSONDecodeError:
                        logger.warning("Skipping malformed JSONL line in transcript")
                        continue
        except OSError:
            pass
        return entries

    # --- Subclass hooks ---
    def _assistant_text(self, entry: dict) -> str | None:
        """Return the assistant text for ENTRY, or None to skip (e.g. tool use).

        Subclass override — the two formats store the text differently."""
        raise NotImplementedError

    def _user_text(self, entry: dict) -> str:
        """Return the user-message text for ENTRY (default: empty)."""
        return ""

    # --- Shared algorithms ---
    def extract_response(self) -> str:
        """Concatenate assistant text since the last user-turn boundary."""
        entries = self._entries()
        if not entries:
            return ""
        last_user_idx = -1
        for i, entry in enumerate(entries):
            if entry.get("type") == self.USER_TYPE:
                last_user_idx = i
        texts: list[str] = []
        start = last_user_idx + 1 if last_user_idx >= 0 else 0
        for entry in entries[start:]:
            if entry.get("type") != self.ASSISTANT_TYPE:
                continue
            text = self._assistant_text(entry)
            if text:
                texts.append(text)
        return "\n\n".join(texts)

    def extract_turns(self) -> list[tuple[str, str]]:
        """Return per-user-turn ``(user_text, assistant_text)`` pairs.

        Each user turn is grouped with the non-tool-use assistant text
        that immediately follows it (before the next user turn).
        """
        entries = self._entries()
        turns: list[tuple[str, str]] = []
        current_user: str | None = None
        current_assistant_parts: list[str] = []

        def flush():
            if current_user is not None:
                turns.append((current_user, "\n\n".join(current_assistant_parts)))

        for entry in entries:
            etype = entry.get("type")
            if etype == self.USER_TYPE:
                flush()
                current_user = self._user_text(entry)
                current_assistant_parts = []
            elif etype == self.ASSISTANT_TYPE and current_user is not None:
                text = self._assistant_text(entry)
                if text:
                    current_assistant_parts.append(text)
        flush()
        return turns


class ClaudeTranscriptReader(TranscriptReader):
    """Reader for Claude Code's JSONL transcripts.

    User turns are ``type: "user"``; assistant turns are
    ``type: "assistant"`` with a ``message.content`` block list.
    Turns containing any ``tool_use`` block are skipped — those are
    intermediate narration that would clutter the response.
    """

    USER_TYPE = "user"
    ASSISTANT_TYPE = "assistant"

    def _user_text(self, entry: dict) -> str:
        message = entry.get("message")
        if not isinstance(message, dict):
            return ""
        content = message.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    return part.get("text", "")
        return ""

    def _assistant_text(self, entry: dict) -> str | None:
        message = entry.get("message")
        if not isinstance(message, dict):
            return None
        content = message.get("content") or []
        if any(p.get("type") == "tool_use" for p in content):
            return None
        parts: list[str] = []
        for part in content:
            if part.get("type") == "text":
                text = part.get("text", "").strip()
                if text:
                    parts.append(text)
        return "\n\n".join(parts) if parts else None


class CopilotTranscriptReader(TranscriptReader):
    """Reader for Copilot's events.jsonl streams.

    User turns are ``type: "user.message"``; assistant turns are
    ``type: "assistant.message"`` with a plain string at
    ``data.content``.  Messages with a non-empty ``toolRequests`` list
    are tool-use turns and are skipped, same rationale as Claude Code.
    """

    USER_TYPE = "user.message"
    ASSISTANT_TYPE = "assistant.message"

    def _assistant_text(self, entry: dict) -> str | None:
        data = entry.get("data") or {}
        if data.get("toolRequests"):
            return None
        content = (data.get("content") or "").strip()
        return content or None


# ======================================================================
# WorkspaceBridge
# ======================================================================


class WorkspaceBridge:
    """One bridge = one Claude CLI session = one org buffer.

    Holds the MCP client, the target org file, the session id, and (when
    available) an OpenTelemetry tracer. Event handlers are methods so
    they share state without threading it through every call signature;
    dispatch in ``handle`` is by method lookup, which makes adding a new
    event a matter of defining ``_handle_<event>`` and nothing else.
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
        # stable, globally-unique routing key.  Preferred over session_id
        # because it survives heading rename + cmux workspace rename.
        # Empty string means "fall back to session_id-based routing"
        # (legacy path for tests that haven't migrated).
        self.workspace_custom_id = workspace_custom_id
        # cmux_workspace is the cmux workspace title at launch time —
        # used for display/error messages only.  Not a routing key.
        self.cmux_workspace = cmux_workspace

    def _routing_key(self) -> str:
        """Return the preferred routing key for elisp workspace lookups.

        Prefers ``workspace_custom_id`` (the org heading's ``:CUSTOM_ID:``
        — globally unique within the file, survives heading rename and
        cmux workspace rename).  Falls back to ``session_id`` (legacy
        path matched against ``:CLAUDE_SESSION_ID:``).

        The Elisp ``--goto-session`` accepts both — it tries ``:CUSTOM_ID:``
        first, then ``:CLAUDE_SESSION_ID:``.  This lets us thread a single
        argument through without changing every elisp signature.
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
        handler creates child spans under our current Python span. When
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
    # Custom-id queue
    #
    # Each *custom_id* is the id of one instruction heading in the org
    # file.  Previously a single ``<session>.custom-id`` file held the
    # latest id and ``UserPromptSubmit`` blindly overwrote it — which
    # lost the routing target whenever the user typed a new prompt
    # before Claude Code finished replying to the previous one, causing
    # the older instruction to be stuck at ``AI_EXEC_STATUS: executing``
    # forever (the PCR dev1 bug, 2026-04-22).
    #
    # The queue model preserves every pending id.  Each prompt
    # *appends* to ``<session>.custom-ids`` (newline-delimited, oldest
    # first, newest last).  On ``Stop`` the orchestrator pops the whole
    # queue and maps entries to the last-N turns of the transcript so
    # every prompt gets either a response or a ``cancelled`` mark.
    # ------------------------------------------------------------------

    def _custom_ids_path(self) -> str:
        return os.path.join(STATUS_DIR, f"{self.session_id}.custom-ids")

    def _read_custom_ids(self) -> list[str]:
        """Return the queue of pending custom ids, oldest first."""
        try:
            with open(self._custom_ids_path()) as f:
                return [l.strip() for l in f if l.strip()]
        except FileNotFoundError:
            return []

    def _append_custom_id(self, custom_id: str) -> None:
        """Append CUSTOM_ID to the pending-response queue."""
        with open(self._custom_ids_path(), "a") as f:
            f.write(f"{custom_id}\n")

    def _clear_custom_ids(self) -> None:
        """Remove the queue file — called after ``Stop`` finishes processing."""
        try:
            os.remove(self._custom_ids_path())
        except FileNotFoundError:
            pass

    # The "latest pending id" shim — most callers want the newest id
    # (trace-span attributes, legacy tests) rather than the full FIFO.
    # The list→latest-or-None transformation lives here so call sites
    # stay declarative.
    def _read_custom_id(self) -> str | None:
        ids = self._read_custom_ids()
        return ids[-1] if ids else None

    # ------------------------------------------------------------------
    # Small helpers
    # ------------------------------------------------------------------

    def _notify_query_completed(self, custom_id: str | None = None) -> None:
        """Unregister the query from Emacs's active-queries registry.

        Clears the mode-line indicator and the ``*Claude Queries*``
        buffer entry. Errors are warned and swallowed because this runs
        at the end of a hook — there is no user left to show them to.
        """
        with self._span("notify-query-completed", **self._span_attrs(custom_id)):
            try:
                self._mcp_eval(
                    f"(code-agent-org--terminal-query-completed "
                    f'"{_escape_elisp_string(self.session_id)}")'
                )
            except (McpConnectionError, McpElispError):
                logger.warning(
                    "Failed to notify query completed for %s", self.session_id
                )

    def _build_save_cli_session_sexp(self, cli_session: str) -> str:
        """Build the elisp that persists CLI_SESSION into the org property.

        Returns the empty string when ``cli_session`` is falsy so callers
        can unconditionally embed the result into a larger ``progn`` —
        an empty form is valid in elisp's nested context.
        """
        if not cli_session:
            return ""
        prop = _cli_session_property()
        return (
            f"(code-agent-org-workspace-bridge-save-cli-session "
            f'"{_escape_elisp_string(self.org_file)}" '
            f'"{_escape_elisp_string(self._routing_key())}" '
            f'"{_escape_elisp_string(cli_session)}" '
            f'"{prop}")'
        )

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    def _handle_session_start(self, input_data: dict) -> None:
        """Signal readiness so Emacs can stop polling capture-pane.

        We write a cmux wait-for signal keyed on the session id; the
        terminal backend's polling loop drops out as soon as the signal
        fires. Best-effort — Emacs falls back to polling if cmux is
        unavailable.
        """
        with self._span("handle-session-start", **self._span_attrs(None)):
            signal_name = f"claude-ready-{self.session_id}"
            try:
                subprocess.run(
                    ["cmux", "wait-for", "-S", signal_name],
                    timeout=5,
                    capture_output=True,
                )
            except Exception:
                pass  # best-effort

    def _handle_prompt(self, input_data: dict) -> None:
        """Handle ``UserPromptSubmit`` — insert into org if not from Emacs.

        Two origins for a prompt need different handling:

        * **Typed into the terminal** — no ``.from-emacs`` flag exists.
          We insert the prompt into the org buffer (Emacs returns the
          freshly-minted instruction custom_id), save it for response
          correlation, and persist the CLI session id.
        * **Issued by Emacs (``C-c C-c`` on an AI block)** — Emacs wrote
          the flag already and owns the org-side insertion. We consume
          the flag and only persist the CLI session id.

        Internally-generated system messages (first char ``<``) are
        dropped — they are not human prompts and should not appear in
        the transcript.
        """
        write_status(self.session_id, "busy")
        try:
            prompt = input_data.get("prompt", "")
            if not prompt:
                return
            if prompt.lstrip().startswith("<"):
                return

            # Prefer the session-specific flag; fall back to any recent
            # flag to handle the Emacs/terminal session-id mismatch.
            from_emacs_flag = os.path.join(STATUS_DIR, f"{self.session_id}.from-emacs")
            flag_exists = os.path.exists(from_emacs_flag)
            if not flag_exists:
                flag_exists, from_emacs_flag = _check_any_recent_from_emacs_flag()

            custom_id = self._read_custom_id()
            with self._span(
                "handle-prompt",
                **self._span_attrs(
                    custom_id,
                    **{
                        "from.emacs": flag_exists,
                        "prompt.length": len(prompt),
                        "input.value": prompt[:2000],
                        "input.mime_type": "text/plain",
                    },
                ),
            ) as span:
                save_sexp = self._build_save_cli_session_sexp(
                    input_data.get("session_id", "")
                )

                if flag_exists:
                    try:
                        os.remove(from_emacs_flag)
                    except FileNotFoundError:
                        pass
                    if save_sexp:
                        try:
                            self._mcp_eval(save_sexp)
                        except (McpConnectionError, McpElispError):
                            pass
                    return

                # Terminal-typed: insert into org and cache the returned
                # custom_id for the response handler.
                elisp = (
                    f"(code-agent-org-workspace-bridge-insert-prompt "
                    f'"{_escape_elisp_string(self.org_file)}" '
                    f'"{_escape_elisp_string(self._routing_key())}" '
                    f'"{_escape_elisp_string(prompt)}")'
                )
                try:
                    result = self._mcp_eval(elisp)
                except (McpConnectionError, McpElispError):
                    logger.warning("Failed to insert prompt for %s", self.session_id)
                    return
                if result is None:
                    return
                if result:
                    self._append_custom_id(result)
                    if span:
                        span.set_attribute("org.custom_id", result)
                if save_sexp:
                    try:
                        self._mcp_eval(save_sexp)
                    except (McpConnectionError, McpElispError):
                        pass
        finally:
            write_status(self.session_id, "ready")

    def _handle_response(self, input_data: dict) -> None:
        """Handle ``Stop`` / ``sessionEnd`` / ``session.idle`` — render responses.

        Walks the pending custom-id queue and the transcript's turns
        together so every queued prompt either gets a response
        rendered or gets its ``AI_EXEC_STATUS`` flipped to
        ``cancelled``.  This is the fix for the supersede bug where a
        new ``UserPromptSubmit`` used to overwrite the previous custom
        id and the older instruction's response was dropped forever.

        Flow:

        * Gather the queue (pending ids, oldest first) and the
          transcript turns (same ordering).
        * Pair the queue with the *last-N* turns (N = len(queue)).
          Any older transcript turns have already been processed by
          earlier ``Stop`` events.
        * Per pair: empty assistant text → mark that id cancelled;
          non-empty → insert the response.
        * Persist the CLI session id and clear the queue.

        Legacy paths:

        * Empty queue + transcript with a response → mint a custom id
          on the fly (terminal-typed prompt, no preceding prompt hook)
          and insert.  Same behaviour as before the queue refactor.
        * Copilot's ``sessionEnd`` without ``transcript_path`` → fall
          back to the local session-state events file.
        """
        write_status(self.session_id, "ready")

        transcript_path = input_data.get("transcript_path") or input_data.get(
            "transcriptPath", ""
        )
        if not transcript_path:
            copilot_session_id = input_data.get("sessionId", "")
            if copilot_session_id:
                candidate = os.path.expanduser(
                    f"~/.copilot/session-state/{copilot_session_id}/events.jsonl"
                )
                if os.path.isfile(candidate):
                    transcript_path = candidate

        pending_ids = self._read_custom_ids()

        with self._span(
            "handle-response",
            **self._span_attrs(
                pending_ids[-1] if pending_ids else None,
                **{
                    "transcript.path": transcript_path,
                    "pending.queue_length": len(pending_ids),
                },
            ),
        ) as span:
            transcript_exists = bool(
                transcript_path and os.path.isfile(transcript_path)
            )

            if (
                pending_ids
                and transcript_exists
                and self._looks_like_claude_transcript(transcript_path)
            ):
                # Claude Code supersede-capable path: pair queue entries with
                # the last N transcript turns.
                self._render_queue_against_transcript(
                    pending_ids, transcript_path, input_data, span
                )
                self._clear_custom_ids()
                self._notify_query_completed(pending_ids[-1])
                return

            if pending_ids and not transcript_exists:
                # Spurious Stop: queue is non-empty but the transcript is
                # absent (another agent's hook leaked through shared env
                # vars, or a cancelled turn).  Do NOT drain the queue —
                # that would insert the payload's `last_assistant_message'
                # (which belongs to the other agent) under our queued id.
                # The real Stop will fire later with a valid transcript.
                # Regression guard: 2026-04-22 "first" incident.
                self._notify_query_completed(pending_ids[-1])
                return

            # Single-response path (Copilot session.idle, or legacy
            # terminal-typed prompt with no prompt hook): the transcript
            # (when present) carries one response; the queued id (when
            # present) is the routing target.
            response = self._collect_response_text(transcript_path, span)
            if not response:
                response = input_data.get("last_assistant_message", "")
            if span:
                span.set_attribute("response.length", len(response) if response else 0)
                span.set_attribute("output.value", (response or "")[:2000])
                span.set_attribute("output.mime_type", "text/plain")

            if not response:
                self._notify_query_completed(pending_ids[-1] if pending_ids else None)
                return

            custom_id = pending_ids[-1] if pending_ids else None
            if not custom_id:
                custom_id = self._mint_missing_custom_id(input_data, span)
            if not custom_id:
                # Fallback for sentinel prompts (`/loop` autonomous
                # iterations, `<task-notification>`, `<system-reminder>`)
                # whose UserPromptSubmit was filtered at the `<` prefix
                # check — no queue entry + `last_user_message` missing
                # or also a sentinel.  Route the response to the
                # newest real instruction so its Response section grows
                # to capture the continuation.  Observed 2026-04-22:
                # PCR dev1's autonomous-loop "Profiling done" response
                # was silently dropped before this fallback existed.
                custom_id = self._find_latest_instruction_custom_id()
                if not custom_id:
                    self._notify_query_completed(None)
                    return

            self._insert_response(custom_id, response, input_data)
            self._clear_custom_ids()
            self._notify_query_completed(custom_id)

    def _find_latest_instruction_custom_id(self) -> str | None:
        """Ask Emacs for the newest instruction's custom-id under this workspace.

        Used as a fallback when the legacy path can't route via
        queue or by minting a new instruction from
        `last_user_message' (typical for sentinel-prompt turns that
        never registered a UserPromptSubmit).  Returns None if no
        instruction exists yet, which causes the caller to drop the
        response — preferable to spawning a ghost heading.
        """
        elisp = (
            f"(code-agent-org-workspace-bridge-latest-instruction-custom-id "
            f'"{_escape_elisp_string(self.org_file)}" '
            f'"{_escape_elisp_string(self._routing_key())}")'
        )
        try:
            result = self._mcp_eval(elisp)
            return result if result else None
        except (McpConnectionError, McpElispError):
            logger.warning("Failed to find latest instruction for %s", self.session_id)
            return None

    # ------------------------------------------------------------------
    # Response-rendering helpers
    # ------------------------------------------------------------------

    def _looks_like_claude_transcript(self, transcript_path: str) -> bool:
        """Quick sniff: does TRANSCRIPT_PATH look like a Claude Code JSONL?

        Copilot transcripts start with ``session.*`` entries and are
        handled by the single-response legacy path (they don't supersede
        like Claude Code does).
        """
        if not (transcript_path and os.path.isfile(transcript_path)):
            return False
        return isinstance(
            TranscriptReader.for_path(transcript_path), ClaudeTranscriptReader
        )

    def _render_queue_against_transcript(
        self,
        pending_ids: list[str],
        transcript_path: str,
        input_data: dict,
        span,
    ) -> None:
        """Pair every pending id with the last ``len(pending_ids)`` transcript turns.

        Shorter-than-queue transcripts mean the earliest pending ids
        never had any user turn recorded (shouldn't happen under normal
        operation) — we mark them cancelled.  Empty assistant turns
        inside the matched window are the supersede case and get the
        same cancellation treatment.
        """
        with self._span("extract-turns", **{"transcript.path": transcript_path}):
            turns = _extract_turns(transcript_path)

        n = len(pending_ids)
        matched_turns = (
            turns[-n:] if len(turns) >= n else ([("", "")] * (n - len(turns)) + turns)
        )

        if span:
            span.set_attribute("pending.ids_count", n)
            span.set_attribute("transcript.turns_count", len(turns))

        for cid, (_user_text, assistant_text) in zip(pending_ids, matched_turns):
            if assistant_text:
                self._insert_response(cid, assistant_text, input_data)
            else:
                self._mark_cancelled(cid)

    def _insert_response(
        self,
        custom_id: str,
        response: str,
        input_data: dict,
    ) -> None:
        """Insert RESPONSE under the instruction keyed by CUSTOM_ID.

        Also persists the CLI session id on the workspace heading and
        fires the ``code-agent-org-complete-hook`` so downstream listeners
        (queue drain, header-line refresh) run.
        """
        save_sexp = self._build_save_cli_session_sexp(
            input_data.get("session_id") or input_data.get("sessionId", "")
        )
        elisp = (
            f"(progn "
            f"(code-agent-org-workspace-bridge-insert-response "
            f'"{_escape_elisp_string(self.org_file)}" '
            f'"{_escape_elisp_string(self._routing_key())}" '
            f'"{_escape_elisp_string(response)}" '
            f'"{_escape_elisp_string(custom_id)}") '
            f"{save_sexp} "
            f"(with-current-buffer (code-agent-org-workspace-bridge--ensure-buffer "
            f'"{_escape_elisp_string(self.org_file)}") '
            f"(run-hook-with-args "
            f"'code-agent-org-complete-hook "
            f"(code-agent-org-current-session-key) nil "
            f"'completed)))"
        )
        try:
            self._mcp_eval(elisp)
        except (McpConnectionError, McpElispError):
            logger.warning(
                "Failed to insert response for %s (custom-id=%s)",
                self.session_id,
                custom_id,
            )

    def _mark_cancelled(self, custom_id: str) -> None:
        """Flip the instruction's ``AI_EXEC_STATUS`` to ``cancelled``.

        Called when a queued prompt has no assistant turn in the
        transcript (superseded by a later prompt, or aborted before any
        generation ran).  Leaves the AI block text in place so the user
        can re-execute manually if they still want a response.
        """
        elisp = (
            f"(code-agent-org-workspace-bridge-mark-cancelled "
            f'"{_escape_elisp_string(self.org_file)}" '
            f'"{_escape_elisp_string(self._routing_key())}" '
            f'"{_escape_elisp_string(custom_id)}")'
        )
        try:
            self._mcp_eval(elisp)
        except (McpConnectionError, McpElispError):
            logger.warning(
                "Failed to mark cancelled for %s (custom-id=%s)",
                self.session_id,
                custom_id,
            )

    def _collect_response_text(self, transcript_path: str, span) -> str:
        """Read the transcript file and return the response text or ``""``.

        Polymorphic — ``TranscriptReader.for_path`` sniffs the first
        entry and returns the matching ``ClaudeTranscriptReader`` or
        ``CopilotTranscriptReader``; the rest of this method is the
        same regardless of format.
        """
        if not (transcript_path and os.path.isfile(transcript_path)):
            return ""
        reader = TranscriptReader.for_path(transcript_path)
        span_name = (
            "extract-copilot-response"
            if isinstance(reader, CopilotTranscriptReader)
            else "extract-full-response"
        )
        with self._span(span_name, **{"transcript.path": transcript_path}):
            return reader.extract_response()

    def _mint_missing_custom_id(self, input_data: dict, span) -> str | None:
        """Insert a terminal-typed prompt to obtain a fresh custom_id.

        Called when the response handler discovers no custom_id exists —
        typically the OpenCode ``session.idle`` path that has no separate
        prompt hook. Returns the new id, or ``None`` after notifying
        query-completed if we can't recover (in which case the caller
        should abort).

        Staleness guard.  A ``<session>.from-emacs`` flag means Emacs
        recently sent a prompt via the org-mode AI block path and the
        following hook chain should route the response to the queued
        ``.custom-id``.  But the flag has no built-in expiry — if the
        prompt hook *failed* (e.g. corrupted hooks.json, missing python
        deps, network blip), the flag stays on disk and gets consumed by
        the next unrelated terminal-typed Stop hook, routing that
        response to the *previous* failed ai block's instruction.

        We mirror the freshness rule already enforced by
        ``_check_any_recent_from_emacs_flag``: the flag must be newer
        than this Python process started.  Per-hook invocation the
        process is freshly spawned, so this caps the flag's effective
        lifetime to the hook's own latency (sub-second normally).  Any
        leftover flag from a previous failed ai block is treated as
        stale, deleted, and the function falls through to the
        terminal-typed prompt path.

        Observed 2026-05-14 ASM-dev1 incident: corrupted hooks.json made
        the 12:48 ai-block's prompt+Stop hooks silently no-op, leaving
        a stale ``.from-emacs`` flag.  A user terminal prompt 15 min
        later fired its Stop hook in a fresh bridge process; without
        this guard the bridge consumed the stale flag and inserted the
        terminal response under the failed 12:48 instruction.
        """
        last_user_message = input_data.get("last_user_message", "")
        if not last_user_message:
            self._notify_query_completed(None)
            return None

        from_emacs_flag = os.path.join(STATUS_DIR, f"{self.session_id}.from-emacs")
        flag_exists = os.path.exists(from_emacs_flag)
        if flag_exists:
            try:
                # Stale-flag guard: a flag older than this process's start
                # belongs to a previous (probably failed) hook chain.
                if os.path.getmtime(from_emacs_flag) < _process_start_time:
                    os.remove(from_emacs_flag)
                    flag_exists = False
            except OSError:
                flag_exists = False
        if not flag_exists:
            flag_exists, from_emacs_flag = _check_any_recent_from_emacs_flag()

        if flag_exists:
            try:
                os.remove(from_emacs_flag)
            except FileNotFoundError:
                pass
            custom_id = self._read_custom_id()
            if not custom_id:
                self._notify_query_completed(None)
                return None
            return custom_id

        elisp = (
            f"(code-agent-org-workspace-bridge-insert-prompt "
            f'"{_escape_elisp_string(self.org_file)}" '
            f'"{_escape_elisp_string(self._routing_key())}" '
            f'"{_escape_elisp_string(last_user_message)}")'
        )
        try:
            result = self._mcp_eval(elisp)
        except (McpConnectionError, McpElispError):
            logger.warning("Failed to insert prompt for %s", self.session_id)
            self._notify_query_completed(None)
            return None
        if not result:
            self._notify_query_completed(None)
            return None
        self._append_custom_id(result)
        if span:
            span.set_attribute("org.custom_id", result)
        return result

    def _handle_tool(self, input_data: dict) -> None:
        """Handle ``PostToolUse`` — currently wires ``TodoWrite`` into org."""
        tool_name = input_data.get("tool_name", "")
        tool_input = input_data.get("tool_input", {})
        custom_id = self._read_custom_id()
        with self._span(
            "handle-tool",
            **self._span_attrs(
                custom_id,
                **{
                    "tool.name": tool_name,
                    "input.value": json.dumps(tool_input, default=str)[:1000],
                    "input.mime_type": "application/json",
                },
            ),
        ):
            if tool_name == "TodoWrite":
                self._update_todos(tool_input, custom_id)

    def _update_todos(self, tool_input: dict, custom_id: str | None) -> None:
        """Push a TodoWrite update into the org checkbox list.

        Refuses to proceed without a custom_id — there is no instruction
        heading to attach the todo list to, so silently doing nothing
        is strictly better than emitting a detached checkbox block.
        """
        todos = tool_input.get("todos", [])
        if not todos or not custom_id:
            return

        elisp = (
            f"(code-agent-org-workspace-bridge-update-todos "
            f'"{_escape_elisp_string(self.org_file)}" '
            f'"{_escape_elisp_string(self._routing_key())}" '
            f"'{_format_todos_as_elisp(todos)} "
            f'"{_escape_elisp_string(custom_id)}")'
        )
        try:
            self._mcp_eval(elisp)
        except (McpConnectionError, McpElispError):
            logger.warning("Failed to update todos for %s", self.session_id)

    def _handle_permission(self, input_data: dict) -> None:
        """Handle ``PreToolUse`` — surface interactive tools to Emacs only.

        Non-interactive tools ignore the permission channel entirely:
        emitting nothing means the CLI uses its default (allow), which
        is what we want for bulk tool calls. Interactive tools
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
        no-op for every bulk tool call. Blocking Emacs's main thread for
        30–1500 ms on every MCP eval is the observed cost.
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

    Sets up the two-flow trace root described in the module docstring
    before calling ``bridge.handle``: a Flow A run (Emacs traceparent
    present) becomes a ``CONSUMER`` child of Emacs's span; a Flow B run
    (no parent) becomes a ``SERVER`` root and writes its own trace
    context for any subsequent hook in this session to join.
    """
    if len(sys.argv) < 2:
        print("Usage: workspace-bridge <event-type>", file=sys.stderr)
        sys.exit(1)

    event = sys.argv[1]
    input_text = sys.stdin.read()

    env_org_file = os.environ.get("WORKSPACE_ORG_FILE", "")
    env_session_id = os.environ.get("WORKSPACE_SESSION_ID", "")
    env_custom_id = os.environ.get("WORKSPACE_CUSTOM_ID", "")
    cmux_workspace = os.environ.get("CMUX_WORKSPACE", "")
    mcp_url = os.environ.get("EMACS_MCP_URL", "http://localhost:9999/mcp")

    # Cross-cmux-restart routing recovery — see
    # ``_resolve_routing_via_agent_name`` docstring for the full design.
    # Read the live ``--name`` slug from the parent claude argv (cmux
    # preserves this across restart, unlike the WORKSPACE_* env vars)
    # and ask Emacs MCP which (org-file, session-id, custom-id) owns
    # that slug.  When the MCP-recovered tuple differs from env, the
    # env is stale (inherited from this surface's original launch
    # before cmux re-attached it elsewhere) — prefer MCP and log a
    # notice so the user knows recovery worked.
    org_file, session_id, workspace_custom_id, recovered = (
        _resolve_routing_via_agent_name(
            env_org_file, env_session_id, env_custom_id, mcp_url
        )
    )
    if recovered:
        print(
            "workspace-bridge: routing recovered via claude --name slug — "
            f"env said {env_org_file!r}::{env_session_id!r}, MCP says "
            f"{org_file!r}::{session_id!r}. Cmux restart lost the "
            "original launch's WORKSPACE_* env vars; the --name flag "
            "is the anchor we use to find the right routing on every "
            "restart.",
            file=sys.stderr,
        )

    if not org_file or not session_id:
        sys.exit(0)  # soft-fail: don't break hooks for non-workspace sessions

    # Cross-routing guard (2026-05-21 bug): when running inside cmux
    # (it sets CMUX_WORKSPACE_ID for every pane) without launcher
    # metadata (CMUX_WORKSPACE empty), env routing is suspect.  After
    # the 2026-05-26 ``--name``-based recovery, this guard becomes a
    # last-resort safety net: skip routing only if recovery ALSO
    # failed (``recovered`` False AND env still says cmux_workspace
    # empty).  Tests opt out with WORKSPACE_BRIDGE_TEST_BYPASS=1.
    if (
        not recovered
        and os.environ.get("CMUX_WORKSPACE_ID")
        and not cmux_workspace
        and not os.environ.get("WORKSPACE_BRIDGE_TEST_BYPASS")
    ):
        print(
            "workspace-bridge: skipping routing — running inside cmux "
            "(CMUX_WORKSPACE_ID is set) but launcher metadata is "
            "missing (CMUX_WORKSPACE empty) AND --name recovery "
            "found no matching Emacs session.  This usually means "
            "cmux resumed a saved claude session without going "
            "through workspace_launcher.py and the matching org "
            "heading is not currently open in Emacs.  Open the org "
            "notebook so its sessions are loaded, or relaunch "
            "claude via the cmux 'New Claude session' action so the "
            "launcher can set CMUX_WORKSPACE + WORKSPACE_CUSTOM_ID "
            "from the current cmux workspace.  Non-fatal; the hook "
            "chain continues.",
            file=sys.stderr,
        )
        sys.exit(0)

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
    # traceparent for this session (Flow A) or we are creating it now
    # (Flow B). See module docstring.
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
