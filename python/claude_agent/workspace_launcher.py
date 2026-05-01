"""Base class for workspace CLI launchers.

Three launchers — Claude Code, GitHub Copilot, OpenCode — share the
same shape: parse a command line, contact the Emacs MCP server for
session metadata, inject agent-specific config (MCP wiring + system
prompt), build an argv for the target CLI, and run it with env vars
pointed at the hook bridge.

Instead of three ~300-line procedural scripts that drift apart, we
express the flow as a template method on ``WorkspaceLauncher``: the
base ``run()`` drives the sequence, and subclasses fill in only the
agent-specific steps (``inject_config``, ``build_args``, optional
``pre_launch`` / ``post_launch`` hooks).

State ownership is unchanged: Emacs is the source of truth for every
session decision, and each launcher is a stateless one-shot that
receives its instructions via CLI args + env vars. The class exists to
share *code*, not state — each invocation constructs a fresh
launcher, runs once, and exits.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path
from typing import ClassVar

from claude_agent.mcp_client import McpClient
from claude_agent.workspace_bridge import _escape_elisp_string


# ======================================================================
# Common helpers (shared by every subclass)
# ======================================================================

# Flags that belong to Claude Code only and must not be forwarded to a
# different agent's CLI. The set plus "takes a value" map drives the
# filter below.
_CLAUDE_ONLY_FLAGS: frozenset[str] = frozenset(
    {
        "--dangerously-skip-permissions",
        "--permission-mode",
        "--ide",
        "--chrome",
        "--plugin-dir",
        "--mcp-config",
        "--system-prompt",
        "--name",
    }
)

_CLAUDE_FLAGS_WITH_VALUE: frozenset[str] = frozenset(
    {
        "--permission-mode",
        "--plugin-dir",
        "--mcp-config",
        "--system-prompt",
        "--name",
    }
)


def filter_claude_args(args: list[str]) -> list[str]:
    """Drop Claude-Code-only flags so other agents don't see them.

    Used by the Copilot and OpenCode launchers — Emacs sometimes passes
    Claude-shaped extra args and we need to strip them before forwarding
    to a CLI that doesn't know those flags. The filter skips the value
    argument that follows value-carrying flags."""
    result: list[str] = []
    skip_next = False
    for arg in args:
        if skip_next:
            skip_next = False
            continue
        if arg in _CLAUDE_ONLY_FLAGS:
            if arg in _CLAUDE_FLAGS_WITH_VALUE:
                skip_next = True
            continue
        result.append(arg)
    return result


def is_valid_session(value: str) -> bool:
    """Return True for a real session string (not blank, not a null sentinel)."""
    return bool(value) and value not in ("null", "nil")


def restore_file(path: Path, original_content: str | None) -> None:
    """Restore PATH to its original content, deleting if it didn't exist."""
    try:
        if original_content is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(original_content)
    except Exception:
        pass  # Best-effort — process may be torn down


# AGENTS.md ephemeral inject block markers + helpers.
#
# OpenCode and Copilot launchers prepend a session-specific "system prompt"
# block to AGENTS.md (or .github/AGENTS.md), then register an atexit hook to
# strip it on exit. The original design captured the file's prior content as
# ``original`` and restored it. That had a self-perpetuating bug: if a prior
# session's atexit hook didn't fire (process killed, or the parent exec'd
# OpenCode and exited before child cleanup), the next session would read
# the polluted file as ``original`` and restore-back the pollution — each
# new session adding another stacked inject block. Real instance: AGENTS.md
# in claude-agent grew to 736 lines / 30K from this loop.
#
# The helpers below replace that with a content-driven, idempotent design:
# we strip blocks delimited by the BEGIN/END markers from the current file
# at exit (or before injecting), so cleanup works regardless of whether
# any prior cleanup fired. See tasks/lessons.md (2026-04-30) for full RCA.

_EMACS_AGENT_INJECT_RE = re.compile(
    r"<!-- BEGIN emacs-agent session instructions[^>]*-->\n.*?"
    r"<!-- END emacs-agent session instructions -->\n*",
    re.DOTALL,
)


def strip_emacs_agent_inject_blocks(text: str) -> str:
    """Remove every ``<!-- BEGIN/END emacs-agent ... -->`` block from TEXT.

    Idempotent: returns TEXT unchanged if no markers are present.
    """
    return _EMACS_AGENT_INJECT_RE.sub("", text)


def cleanup_emacs_agent_inject(path: Path, file_existed_before: bool) -> None:
    """Strip emacs-agent inject blocks from PATH; unlink if no base remains.

    Idempotent and content-driven (does not rely on a captured original).
    Safe to call multiple times. If FILE_EXISTED_BEFORE is False and the
    base content (after stripping inject blocks) is empty, the file is
    removed — matching the behaviour of ``restore_file(path, None)``.
    """
    try:
        if not path.exists():
            return
        cleaned = strip_emacs_agent_inject_blocks(path.read_text())
        if not cleaned.strip() and not file_existed_before:
            path.unlink()
        else:
            path.write_text(cleaned)
    except Exception:
        pass  # Best-effort — process may be torn down


def split_positional_args(argv: list[str]) -> tuple[str, str, list[str]]:
    """Parse ``<org_file> [session_id] [-- extra_args...]`` from ARGV.

    Returns ``(org_file, session_id, extra_args)``. ``session_id`` is
    empty when absent; leading ``--`` separator (if present) is stripped
    from ``extra_args``. Raises SystemExit(1) with usage on empty argv.
    """
    if not argv:
        print(
            "Usage: <launcher> <org-file> [session-id] [-- extra-args...]",
            file=sys.stderr,
        )
        sys.exit(1)
    org_file = argv[0]
    rest = argv[1:]
    session_id = ""
    if rest and not rest[0].startswith("-"):
        session_id = rest[0]
        rest = rest[1:]
    if rest and rest[0] == "--":
        rest = rest[1:]
    return org_file, session_id, rest


# ======================================================================
# WorkspaceLauncher — the template-method base class
# ======================================================================

class WorkspaceLauncher:
    """Launch an agent CLI with workspace bridge integration.

    Subclasses customise only the parts that differ between agents:

    * ``agent_name`` / ``agent_binary`` class attributes.
    * ``agent_type_env_value`` — value written to ``AGENT_TYPE`` so the
      hook bridge picks the right transcript extractor.
    * ``inject_config()`` — agent-specific MCP wiring and system-prompt
      delivery (Claude uses a ``--mcp-config`` flag; Copilot edits
      ``.github/mcp.json``; OpenCode edits ``opencode.jsonc``).
    * ``build_args()`` — the final argv to ``subprocess.run``.
    * ``pre_launch()`` / ``post_launch()`` — optional hooks for
      Claude's IDE server and other agent-only lifecycle events.

    The base ``run()`` method composes these into the full flow.
    """

    # Class-level identity — subclasses set these.
    agent_name: ClassVar[str] = ""
    agent_binary: ClassVar[str] = ""
    agent_type_env_value: ClassVar[str] = ""  # empty = don't set AGENT_TYPE

    # ------------------------------------------------------------------
    # Construction
    # ------------------------------------------------------------------

    def __init__(
        self,
        org_file: str,
        session_id: str,
        extra_args: list[str],
    ):
        self.org_file = os.path.abspath(org_file)
        self.session_id = session_id
        self.extra_args = extra_args
        self.project_root = os.getcwd()
        self.plugin_dir = os.environ.get(
            "CLAUDE_PLUGIN_ROOT",
            str(Path(__file__).resolve().parent.parent.parent),
        )
        self.mcp_url = os.environ.get(
            "EMACS_MCP_URL", "http://localhost:9999/mcp"
        )
        self.model = os.environ.get("AGENT_MODEL", "")
        self.mcp = McpClient(url=self.mcp_url, read_timeout=30.0)
        # Populated during run().
        self.mcp_ok: bool = False
        self.story_name: str = ""
        self.system_prompt: str = ""

    @classmethod
    def from_argv(cls, argv: list[str]) -> WorkspaceLauncher:
        """Default factory — ``<org_file> [session_id] [-- extras...]``.

        Subclasses with extra CLI grammar (opencode's ``--resume <id>``)
        override this to capture their additional args before
        delegating to the base constructor.
        """
        org_file, session_id, extras = split_positional_args(argv)
        return cls(org_file, session_id, extras)

    # ------------------------------------------------------------------
    # MCP + metadata
    # ------------------------------------------------------------------

    def check_mcp(self) -> None:
        """Ping Emacs's MCP server and note whether it answers."""
        print(f"Checking Emacs MCP server at {self.mcp_url}...")
        self.mcp_ok = self.mcp.ping()
        if self.mcp_ok:
            print("  MCP server OK")
        else:
            print(
                f"  WARNING: MCP server not reachable at {self.mcp_url}",
                file=sys.stderr,
            )
            print(
                "  workspace bridge hooks disabled. "
                "Launching without workspace integration...",
                file=sys.stderr,
            )

    def fetch_session_metadata(self) -> None:
        """Ask Emacs for the story name + system prompt for this session.

        Identical in all three agents — the Emacs side owns the shape.
        Populates ``self.story_name`` and ``self.system_prompt``.
        """
        if not (self.mcp_ok and self.session_id):
            return
        print(f"Building session metadata for {self.session_id}...")
        esc_org = _escape_elisp_string(self.org_file)
        esc_sid = _escape_elisp_string(self.session_id)
        elisp = (
            "(let ((debug-on-error nil) (debug-on-quit nil))"
            "  (let* ((prompt (code-agent-org-workspace-bridge-system-prompt "
            f'    "{esc_org}" "{esc_sid}"))'
            f'         (story (with-current-buffer (code-agent-org-workspace-bridge--ensure-buffer "{esc_org}")'
            "            (save-excursion (save-restriction (widen)"
            f'              (code-agent-org-workspace-bridge--goto-session "{esc_sid}")'
            "              (substring-no-properties (org-get-heading t t t t)))))))"
            r'    (substring-no-properties (format "%s\n%s" story prompt))))'
        )
        result = self.mcp.eval_elisp(elisp)
        if not result:
            return
        lines = result.split("\n", 1)
        self.story_name = lines[0]
        self.system_prompt = lines[1] if len(lines) > 1 else ""
        if not is_valid_session(self.system_prompt):
            print(
                "  WARNING: Could not build system prompt — launching without it",
                file=sys.stderr,
            )

    # ------------------------------------------------------------------
    # Env + terminal setup
    # ------------------------------------------------------------------

    def export_env_vars(self) -> None:
        """Export env vars read by hook scripts / bridge plugins."""
        os.environ["WORKSPACE_ORG_FILE"] = self.org_file
        os.environ["WORKSPACE_SESSION_ID"] = self.session_id or ""
        os.environ["EMACS_MCP_URL"] = self.mcp_url
        os.environ["CLAUDE_PLUGIN_ROOT"] = self.plugin_dir
        if self.agent_type_env_value:
            os.environ["AGENT_TYPE"] = self.agent_type_env_value

    def set_tab_title(self) -> None:
        """Set the terminal-tab title so cmux pane name shows the story."""
        file_base = os.path.splitext(os.path.basename(self.org_file))[0]
        suffix = self.story_name or self.session_id or self.agent_name
        tab_title = f"{file_base}:{suffix}"
        os.environ["WARP_DISABLE_AUTO_TITLE"] = "true"
        sys.stdout.write(f"\033]0;{tab_title}\007")
        sys.stdout.flush()

    # ------------------------------------------------------------------
    # Banner
    # ------------------------------------------------------------------

    def print_banner(self, args: list[str]) -> None:
        """Print the launch summary the user sees before the CLI takes over."""
        print(f"Starting {self.agent_binary}...")
        print(f"  Org file:   {self.org_file}")
        print(f"  Session ID: {self.session_id or 'none'}")
        print(f"  Story:      {self.story_name or 'unknown'}")
        print(f"  MCP bridge: {self.mcp_ok}")
        print(f"  Extra args: {self.extra_args}")
        if self.model:
            print(f"  Model:      {self.model}")
        print(f"  Final cmd:  {' '.join(args)}")
        print()

    # ------------------------------------------------------------------
    # Subclass hooks
    # ------------------------------------------------------------------

    def inject_config(self) -> None:
        """Inject agent-specific MCP config / system prompt / plugins.

        Default: no-op. Subclasses override to write .github/mcp.json,
        opencode.jsonc, etc.
        """

    def build_args(self) -> list[str]:
        """Return the argv list to pass to ``subprocess.run``."""
        raise NotImplementedError

    def pre_launch(self) -> None:
        """Called after ``build_args`` and before ``subprocess.run``.

        Claude Code overrides to start the IDE WebSocket server; other
        agents typically leave this alone.
        """

    def post_launch(self, returncode: int) -> None:
        """Called after the child CLI exits (before ``sys.exit``)."""

    # ------------------------------------------------------------------
    # Template method
    # ------------------------------------------------------------------

    def run(self) -> None:
        """Drive the full launch sequence; exits the process when done."""
        self.check_mcp()
        self.fetch_session_metadata()
        self.export_env_vars()
        self.set_tab_title()
        self.inject_config()
        args = self.build_args()
        self.print_banner(args)

        def _sigterm_handler(signum, _frame):
            self.post_launch(128 + signum)
            sys.exit(128 + signum)

        signal.signal(signal.SIGTERM, _sigterm_handler)

        self.pre_launch()
        try:
            result = subprocess.run(args)
        finally:
            self.post_launch(
                result.returncode if "result" in dir() else 1
            )
        sys.exit(result.returncode)
