"""Claude Code workspace launcher.

Thin subclass of ``WorkspaceLauncher`` that fills in the Claude-Code
specifics: interactive session picker when ``session_id`` is not
supplied, ``--plugin-dir`` + ``--mcp-config`` flags
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
from code_agent.workspace_launcher import (
    WorkspaceLauncher,
    _escape_elisp_string,
    is_valid_session,
    split_positional_args,
)


# ======================================================================
# Small helpers specific to Claude
# ======================================================================


def _normalize_name_slug(name: str) -> str:
    """Convert a heading name to a valid ``--name`` slug.

    Lowercases, collapses runs of non-alphanumeric to single hyphens,
    and trims stray leading/trailing hyphens.
    """
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower())
    return slug.strip("-")


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
        # The workspace-bridge session listing functions are dead code —
        # this subclass no longer supports the interactive session picker.
        if self.mcp_ok and not self.session_id:
            print(
                "WARNING: Interactive session listing is unavailable — "
                "the required workspace-bridge Elisp functions have been removed. "
                "Pass a session-id explicitly.",
                file=sys.stderr,
            )
            sys.exit(1)
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
