"""Claude Code workspace launcher.

Thin subclass of ``WorkspaceLauncher`` that fills in the Claude-Code
specifics: interactive session picker when ``session_id`` is not
supplied, ``--plugin-dir`` + ``--mcp-config`` + ``--settings`` flags
built from the plugin tree, ``--ide`` / ``--chrome`` for the built-in
IDE bridge, and a ``pre_launch`` hook that starts the Emacs-side
WebSocket IDE server before the CLI takes over.

State principle: ``--resume`` is decided by Emacs and passed through in
``extra_args`` — Python never reads org properties to decide whether to
resume.
"""

from __future__ import annotations

import atexit
import json
import os
import re
import sys
from pathlib import Path

from code_agent.mcp_client import McpClient
from code_agent.workspace_bridge import _escape_elisp_string
from code_agent.workspace_launcher import (
    WorkspaceLauncher,
    is_valid_session,
    split_positional_args,
)


# ======================================================================
# Small helpers specific to Claude
# ======================================================================


def _normalize_story_slug(name: str) -> str:
    """Convert a story heading to a valid ``--name`` slug.

    Lowercases, collapses runs of non-alphanumeric to single hyphens,
    and trims stray leading/trailing hyphens.
    """
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower())
    return slug.strip("-")


# ======================================================================
# ClaudeHooksFile — owns the workspace-hooks.json contract
# ======================================================================
#
# Claude Code reads a ``--settings`` file at startup that wires three
# hook events back into the workspace-bridge subprocess:
#
#   - Stop              → workspace-bridge response   (30s timeout)
#   - UserPromptSubmit  → workspace-bridge prompt     (10s timeout)
#   - SessionStart      → workspace-bridge session-start (10s timeout)
#
# Co-locate the bridge-path discovery + JSON template + write step in
# one class so the contract is auditable in one read. Class constants
# expose the timeouts so a deployment with slow MCP can override
# without forking the hook generation.


class ClaudeHooksFile:
    """Writer for the per-plugin ``workspace-hooks.json`` settings file."""

    HOOKS_FILENAME = "workspace-hooks.json"
    STOP_TIMEOUT_SECS = 30
    PROMPT_TIMEOUT_SECS = 10
    SESSION_START_TIMEOUT_SECS = 10

    def __init__(self, plugin_dir: str):
        self.plugin_dir = plugin_dir

    @staticmethod
    def find_bridge_path() -> str:
        """Return the absolute path to the ``workspace-bridge`` console script.

        Prefers the script installed in the same venv as this launcher so
        the hook and the launcher stay in lockstep; falls back to PATH.
        """
        venv_bin = Path(sys.executable).parent
        bridge = venv_bin / "workspace-bridge"
        if bridge.exists():
            return str(bridge)
        return "workspace-bridge"

    def _hook_block(self, command: str, timeout: int) -> dict:
        return {
            "matcher": "",
            "hooks": [{"type": "command", "command": command, "timeout": timeout}],
        }

    def write(self) -> str:
        """Render and write the hooks JSON. Returns the settings file path."""
        bridge = self.find_bridge_path()
        hooks = {
            "hooks": {
                "Stop": [
                    self._hook_block(f"{bridge} response", self.STOP_TIMEOUT_SECS),
                ],
                "UserPromptSubmit": [
                    self._hook_block(f"{bridge} prompt", self.PROMPT_TIMEOUT_SECS),
                ],
                "SessionStart": [
                    self._hook_block(
                        f"{bridge} session-start", self.SESSION_START_TIMEOUT_SECS
                    ),
                ],
            }
        }
        settings_file = os.path.join(self.plugin_dir, self.HOOKS_FILENAME)
        with open(settings_file, "w") as f:
            json.dump(hooks, f)
        return settings_file


def _list_sessions(mcp: McpClient, org_file: str) -> str | None:
    """Return a tab-separated session listing from Emacs (None on failure)."""
    elisp = (
        "(let ((debug-on-error nil) (debug-on-quit nil)) "
        f'(code-agent-org-workspace-bridge-list-sessions "{_escape_elisp_string(org_file)}"))'
    )
    return mcp.eval_elisp(elisp)


def _select_session_interactive(sessions_text: str, org_file: str) -> str:
    """Print the session list and prompt the user to pick one."""
    print(f"\nAvailable workspace sessions in {os.path.basename(org_file)}:")

    session_ids: list[str] = []
    current_parent = "__unset__"
    for line in sessions_text.split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        sid, heading = parts[0], parts[1]
        parent = parts[2] if len(parts) > 2 else ""
        if parent != current_parent:
            print()
            print(f"  [{parent}]" if parent else "  [top-level]")
            current_parent = parent
        session_ids.append(sid)
        print(f"    {len(session_ids)}) {heading}  ({sid})")

    if not session_ids:
        print(f"No workspace sessions found in {org_file}", file=sys.stderr)
        sys.exit(1)

    print()
    try:
        choice = int(input(f"Select session [1-{len(session_ids)}]: "))
    except (EOFError, KeyboardInterrupt):
        sys.exit(1)
    except ValueError:
        choice = 0

    if not 1 <= choice <= len(session_ids):
        print("Invalid selection", file=sys.stderr)
        sys.exit(1)

    selected = session_ids[choice - 1]
    print(f"Selected: {selected}\n")
    return selected


def _cleanup_ide_server(mcp: McpClient, session_id: str) -> None:
    """Tell Emacs to stop the IDE WebSocket server for SESSION_ID."""
    if not session_id:
        return
    try:
        mcp.eval_elisp(
            "(condition-case nil"
            f'  (claude-ide-stop-server "{_escape_elisp_string(session_id)}")'
            "  (error nil))"
        )
    except Exception:
        pass  # Best-effort — Emacs may be gone too


# ======================================================================
# ClaudeWorkspaceLauncher
# ======================================================================


class ClaudeWorkspaceLauncher(WorkspaceLauncher):
    """WorkspaceLauncher subclass for the Claude Code CLI."""

    agent_name = "claude"
    agent_binary = "claude"
    agent_type_env_value = ""  # Claude is the default — no AGENT_TYPE set

    # ------------------------------------------------------------------
    # Extra flow: prompt for a session if one wasn't supplied
    # ------------------------------------------------------------------

    def fetch_session_metadata(self) -> None:
        # Offer the interactive picker before running the base flow.
        if self.mcp_ok and not self.session_id:
            sessions = _list_sessions(self.mcp, self.org_file)
            if not sessions:
                print(
                    f"No workspace sessions found in {self.org_file}",
                    file=sys.stderr,
                )
                sys.exit(1)
            self.session_id = _select_session_interactive(sessions, self.org_file)
        super().fetch_session_metadata()

    # ------------------------------------------------------------------
    # inject_config — Claude uses CLI flags, nothing to write to disk
    # ------------------------------------------------------------------

    def inject_config(self) -> None:
        # Claude takes its MCP config via the CLI, not a file.
        pass

    # ------------------------------------------------------------------
    # build_args — the Claude-specific argv
    # ------------------------------------------------------------------

    def build_args(self) -> list[str]:
        args = ["claude", "--plugin-dir", self.plugin_dir]

        mcp_config = (
            f'{{"mcpServers":{{"emacs":{{"type":"http","url":"{self.mcp_url}"}}}}}}'
        )
        args.extend(["--mcp-config", mcp_config])

        hooks_file = ClaudeHooksFile(self.plugin_dir).write()
        args.extend(["--settings", hooks_file])

        if self.story_name:
            slug = _normalize_story_slug(self.story_name)
            if slug:
                args.extend(["--name", slug])

        if is_valid_session(self.system_prompt):
            args.extend(["--system-prompt", self.system_prompt])

        # --resume from Emacs arrives here; Python never invents one.
        args.extend(self.extra_args)
        args.append("--ide")
        args.append("--chrome")
        return args

    # ------------------------------------------------------------------
    # pre_launch — start the Emacs IDE WebSocket server
    # ------------------------------------------------------------------

    def pre_launch(self) -> None:
        # Unset CLAUDECODE so the spawned CLI doesn't refuse to start
        # "inside another Claude Code session".
        os.environ.pop("CLAUDECODE", None)

        if not (self.mcp_ok and self.session_id):
            return
        try:
            self.mcp.eval_elisp(
                "(let ((debug-on-error nil) (debug-on-quit nil))"
                "  (code-agent-org-cmux--ensure-ide-server "
                f'"{_escape_elisp_string(self.project_root)}" '
                f'"{_escape_elisp_string(self.session_id)}"))'
            )
            print(f"  IDE server: started for {os.path.basename(self.project_root)}")
        except Exception as e:
            print(f"  IDE server: failed to start ({e})", file=sys.stderr)
        # Register atexit cleanup; `post_launch` also runs it for the
        # happy-path, but atexit is our belt-and-suspenders for edge
        # cases where the subprocess.run raises.
        atexit.register(_cleanup_ide_server, self.mcp, self.session_id)

    # ------------------------------------------------------------------
    # post_launch — stop the IDE WebSocket server
    # ------------------------------------------------------------------

    def post_launch(self, returncode: int) -> None:
        if not (self.mcp_ok and self.session_id):
            return
        atexit.unregister(_cleanup_ide_server)
        _cleanup_ide_server(self.mcp, self.session_id)


# ======================================================================
# Entry point
# ======================================================================


def main() -> None:
    argv = sys.argv[1:]
    if not argv:
        print(
            "Usage: claude-workspace <org-file> [session-id] [-- extra-args...]",
            file=sys.stderr,
        )
        sys.exit(1)
    org_file, session_id, extras = split_positional_args(argv)
    ClaudeWorkspaceLauncher(org_file, session_id, extras).run()


if __name__ == "__main__":
    main()
