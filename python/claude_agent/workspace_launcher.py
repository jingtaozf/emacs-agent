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

import atexit
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
# in code-agent grew to 736 lines / 30K from this loop.
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


# ======================================================================
# McpConfigInjector — base for per-project MCP config injection
#
# Both Copilot (.github/mcp.json) and OpenCode (opencode.jsonc) need
# the same shape of operation: resolve target → read original (or
# None) → parse → mutate to add the Emacs MCP entry → write → register
# atexit cleanup.  Only the path policy, parser, JSON shape of the
# mutation, and (for OpenCode's .jsonc/.json alt) the restore
# registration differ.  Pull the scaffolding into a template-method
# base class and override only the four hooks that actually vary.
# ======================================================================


class McpConfigInjector:
    """Template-method base for injecting Emacs MCP into a config file.

    Subclasses override four hooks; the rest of the inject lifecycle
    (mkdir parent, capture original, parse, write, restore on exit,
    log to stdout) is shared.
    """

    def __init__(self, project_root: str, mcp_url: str):
        self.project_root = Path(project_root)
        self.mcp_url = mcp_url

    def inject(self) -> None:
        """Run the inject lifecycle: resolve → read → parse → mutate → write → restore."""
        input_path, output_path = self._resolve_paths()
        input_path.parent.mkdir(parents=True, exist_ok=True)
        original: str | None = input_path.read_text() if input_path.exists() else None
        config = self._parse_or_empty(original)
        self._merge_emacs_entry(config)
        output_path.write_text(json.dumps(config, indent=2))
        self._register_restore(input_path, output_path, original)
        print(f"  MCP config: injected Emacs server into {output_path}")

    # ------------------------------------------------------------------
    # Subclass hooks
    # ------------------------------------------------------------------

    def _resolve_paths(self) -> tuple[Path, Path]:
        """Return ``(INPUT_PATH, OUTPUT_PATH)``.

        INPUT_PATH is read for the prior content (may not exist).
        OUTPUT_PATH is where the merged config is written.  They may
        be the same; OpenCode reads ``.json`` as fallback but always
        writes back as ``.jsonc``."""
        raise NotImplementedError

    def _parse_or_empty(self, content: str | None) -> dict:
        """Parse CONTENT into a dict, returning {} when missing or malformed."""
        raise NotImplementedError

    def _merge_emacs_entry(self, config: dict) -> None:
        """Mutate CONFIG in place to add the Emacs MCP entry."""
        raise NotImplementedError

    def _register_restore(
        self, input_path: Path, output_path: Path, original: str | None
    ) -> None:
        """Register atexit restore — default: restore the output path only."""
        atexit.register(restore_file, output_path, original)


# ======================================================================
# AgentsMdInjector — shared system-prompt injector for AGENTS.md files
# ======================================================================
#
# Copilot writes to ``.github/AGENTS.md``; OpenCode writes to
# ``AGENTS.md`` at the project root. The body of the operation is
# otherwise identical: read existing content → strip prior inject
# blocks (idempotent) → prepend a BEGIN/END-marked session block →
# register an atexit cleanup that re-strips the block.
#
# Co-locating the path policy + content template + atexit wiring in
# one class makes the two launchers' inject_config() methods
# one-liners.

_AGENTS_MD_HEADER_TEMPLATE = (
    "<!-- BEGIN emacs-agent session instructions (auto-removed on exit) -->\n"
    "{prompt}\n"
    "<!-- END emacs-agent session instructions -->\n\n"
)


class AgentsMdInjector:
    """Inject a session system prompt into an AGENTS.md-style file.

    Construct with the full target path (e.g.
    ``Path(project_root) / "AGENTS.md"`` for OpenCode or
    ``Path(project_root) / ".github" / "AGENTS.md"`` for Copilot).
    Calling ``inject(prompt)`` prepends the BEGIN/END block and
    registers an atexit cleanup; safe to call again across sessions
    because the prior block is stripped first.
    """

    def __init__(self, path: Path):
        self.path = path

    def inject(self, system_prompt: str) -> None:
        """Prepend the system-prompt block; register atexit cleanup."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        file_existed_before = self.path.exists()
        raw = self.path.read_text() if file_existed_before else ""
        base = strip_emacs_agent_inject_blocks(raw)
        header = _AGENTS_MD_HEADER_TEMPLATE.format(prompt=system_prompt.strip())
        self.path.write_text(header + base)
        atexit.register(cleanup_emacs_agent_inject, self.path, file_existed_before)
        print(f"  System prompt: written to {self.path}")


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
        # ``__file__`` always points at the actually-running launcher,
        # so its ancestor directory is authoritative even if the agent's
        # process tree inherited a stale ``CLAUDE_PLUGIN_ROOT`` from a
        # previous launch (e.g. the directory was renamed between
        # sessions — the 2026-05-26 ``claude-agent`` → ``emacs-agent``
        # rename left every shell under cmux exporting the old path,
        # and the launcher used to write its hooks file there, failing
        # with FileNotFoundError).  Prefer the env var only when it
        # resolves to a real directory.
        env_plugin_dir = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
        file_plugin_dir = str(Path(__file__).resolve().parent.parent.parent)
        if env_plugin_dir and os.path.isdir(env_plugin_dir):
            self.plugin_dir = env_plugin_dir
        else:
            self.plugin_dir = file_plugin_dir
        self.mcp_url = os.environ.get("EMACS_MCP_URL", "http://localhost:9999/mcp")
        self.model = os.environ.get("AGENT_MODEL", "")
        self.mcp = McpClient(url=self.mcp_url, read_timeout=30.0)
        # Populated during run().
        self.mcp_ok: bool = False
        self.story_name: str = ""
        self.system_prompt: str = ""
        # ``workspace_custom_id`` is the org heading's ``:CUSTOM_ID:`` for
        # the workspace section.  Populated by ``fetch_session_metadata``
        # and exported as ``WORKSPACE_CUSTOM_ID`` so the bridge can route
        # by stable id rather than the rename-prone session_id.
        self.workspace_custom_id: str = ""

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
        Populates ``self.story_name``, ``self.system_prompt``, and
        ``self.workspace_custom_id`` (the workspace heading's
        ``:CUSTOM_ID:`` — used as the routing key by the bridge so
        renaming the heading or cmux workspace cannot misroute prompts).
        """
        if not (self.mcp_ok and self.session_id):
            return
        print(f"Building session metadata for {self.session_id}...")
        esc_org = _escape_elisp_string(self.org_file)
        esc_sid = _escape_elisp_string(self.session_id)
        # One round-trip pulls three values separated by NULs: heading
        # text, CUSTOM_ID, and the system prompt body.  NUL is safe
        # because none of the three can legitimately contain it.
        elisp = (
            "(let ((debug-on-error nil) (debug-on-quit nil))"
            f'  (with-current-buffer (code-agent-org-workspace-bridge--ensure-buffer "{esc_org}")'
            "    (save-excursion (save-restriction (widen)"
            f'      (code-agent-org-workspace-bridge--goto-session "{esc_sid}")'
            "      (let ((story (substring-no-properties (org-get-heading t t t t)))"
            '            (cid (or (org-entry-get nil "CUSTOM_ID") ""))'
            "            (prompt (code-agent-org-workspace-bridge-system-prompt "
            f'              "{esc_org}" "{esc_sid}")))'
            r'        (format "%s\0%s\0%s" story cid prompt))))))'
        )
        result = self.mcp.eval_elisp(elisp)
        if not result:
            return
        parts = result.split("\0", 2)
        self.story_name = parts[0] if len(parts) > 0 else ""
        self.workspace_custom_id = parts[1] if len(parts) > 1 else ""
        self.system_prompt = parts[2] if len(parts) > 2 else ""
        if not is_valid_session(self.system_prompt):
            print(
                "  WARNING: Could not build system prompt — launching without it",
                file=sys.stderr,
            )
        if not self.workspace_custom_id:
            print(
                "  WARNING: Workspace heading has no :CUSTOM_ID: — bridge "
                "will fall back to :CLAUDE_SESSION_ID: routing. Add "
                ":CUSTOM_ID: to the heading for name-based routing.",
                file=sys.stderr,
            )

    # ------------------------------------------------------------------
    # Env + terminal setup
    # ------------------------------------------------------------------

    def export_env_vars(self) -> None:
        """Export env vars read by hook scripts / bridge plugins.

        Four routing-relevant vars are pinned at launch time so the
        in-process bridge never needs to re-query cmux:

        * ``WORKSPACE_ORG_FILE``    — which .org file holds the workspace
        * ``WORKSPACE_SESSION_ID``  — legacy routing key (back-compat)
        * ``WORKSPACE_CUSTOM_ID``   — preferred routing key (org heading
          ``:CUSTOM_ID:`` — globally unique, survives heading rename)
        * ``CMUX_WORKSPACE``        — cmux workspace title at launch
          time (display + sanity check only, not a routing key)

        ``CMUX_WORKSPACE`` falls back to ``self.story_name`` when cmux
        cannot be reached (CI / direct invocation), which matches the
        existing tab-title convention.
        """
        os.environ["WORKSPACE_ORG_FILE"] = self.org_file
        os.environ["WORKSPACE_SESSION_ID"] = self.session_id or ""
        os.environ["WORKSPACE_CUSTOM_ID"] = self.workspace_custom_id or ""
        cmux_ws = self._detect_cmux_workspace_title() or self.story_name or ""
        if cmux_ws:
            os.environ["CMUX_WORKSPACE"] = cmux_ws
        os.environ["EMACS_MCP_URL"] = self.mcp_url
        os.environ["CLAUDE_PLUGIN_ROOT"] = self.plugin_dir
        if self.agent_type_env_value:
            os.environ["AGENT_TYPE"] = self.agent_type_env_value

    def _detect_cmux_workspace_title(self) -> str:
        """Best-effort: ask cmux for the current workspace title.

        Returns an empty string if cmux is not reachable (CI sandbox,
        non-cmux terminal).  The caller falls back to ``story_name``;
        the bridge's fail-loud check then refuses to route only when
        BOTH are empty — which is itself a useful invariant.
        """
        try:
            ident = subprocess.run(
                ["cmux", "identify", "--json"],
                capture_output=True,
                text=True,
                timeout=2,
                check=False,
            )
            if ident.returncode != 0 or not ident.stdout.strip():
                return ""
            ident_data = json.loads(ident.stdout)
            ws_ref = ident_data.get("caller", {}).get("workspace_ref")
            if not ws_ref:
                return ""
            tree = subprocess.run(
                ["cmux", "tree", "--json"],
                capture_output=True,
                text=True,
                timeout=2,
                check=False,
            )
            if tree.returncode != 0 or not tree.stdout.strip():
                return ""
            tree_data = json.loads(tree.stdout)
            for win in tree_data.get("windows", []):
                for ws in win.get("workspaces", []):
                    if ws.get("ref") == ws_ref:
                        return ws.get("title", "") or ""
        except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
            return ""
        return ""

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
            self.post_launch(result.returncode if "result" in dir() else 1)
        sys.exit(result.returncode)
