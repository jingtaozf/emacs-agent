"""GitHub Copilot workspace launcher.

Subclass of ``WorkspaceLauncher`` for the Copilot CLI. Differences from
Claude: no WebSocket IDE integration, MCP wiring lives in
``.github/mcp.json``, the system prompt is prepended to
``.github/AGENTS.md``, and Copilot requires ``--allow-all-tools`` to
run autonomously. Both injected files are restored on exit via
``atexit`` so the user's repo is not left modified.

Claude Code-specific flags in ``extra_args`` are filtered out before
forwarding to Copilot, which does not know about them.
"""

from __future__ import annotations

import atexit
import json
import os
import sys
from pathlib import Path

from claude_agent.workspace_launcher import (
    McpConfigInjector,
    WorkspaceLauncher,
    cleanup_emacs_agent_inject,
    filter_claude_args,
    is_valid_session,
    restore_file,
    split_positional_args,
    strip_emacs_agent_inject_blocks,
)


class DotGithubMcpInjector(McpConfigInjector):
    """Injects the Emacs MCP entry into ``.github/mcp.json`` (Copilot)."""

    def _resolve_paths(self) -> tuple[Path, Path]:
        path = self.project_root / ".github" / "mcp.json"
        return path, path

    def _parse_or_empty(self, content: str | None) -> dict:
        if not content:
            return {}
        try:
            return json.loads(content)
        except json.JSONDecodeError:
            return {}

    def _merge_emacs_entry(self, config: dict) -> None:
        config.setdefault("mcpServers", {})["emacs"] = {
            "type": "http",
            "url": self.mcp_url,
        }


# --- Back-compat free function -------------------------------------------------
# `_inject_emacs_mcp_into_dotgithub` was the public surface before the
# class extraction; tests + CopilotWorkspaceLauncher both called it by
# name.  Keep it as a 1-line wrapper around DotGithubMcpInjector so test
# imports continue to resolve.


def _inject_emacs_mcp_into_dotgithub(project_root: str, mcp_url: str) -> None:
    """Back-compat wrapper — delegates to `DotGithubMcpInjector`."""
    DotGithubMcpInjector(project_root, mcp_url).inject()


# ======================================================================
# CopilotWorkspaceLauncher
# ======================================================================


class CopilotWorkspaceLauncher(WorkspaceLauncher):
    """WorkspaceLauncher subclass for the GitHub Copilot CLI."""

    agent_name = "copilot"
    agent_binary = "copilot"
    agent_type_env_value = "copilot"

    # ------------------------------------------------------------------
    # inject_config — Copilot uses files, not CLI flags
    # ------------------------------------------------------------------

    def inject_config(self) -> None:
        _inject_emacs_mcp_into_dotgithub(self.project_root, self.mcp_url)
        if self.mcp_ok and is_valid_session(self.system_prompt):
            AgentsMdInjector(Path(self.project_root) / ".github" / "AGENTS.md").inject(
                self.system_prompt
            )

    # ------------------------------------------------------------------
    # build_args — copilot argv + plugin-dir + model override
    # ------------------------------------------------------------------

    def build_args(self) -> list[str]:
        args = ["copilot", "--allow-all-tools"]

        copilot_plugin_dir = os.path.join(self.plugin_dir, "hooks", "copilot-plugin")
        if os.path.isdir(copilot_plugin_dir):
            args.extend(["--plugin-dir", copilot_plugin_dir])
        else:
            print(
                f"  WARNING: Copilot plugin dir not found: {copilot_plugin_dir}",
                file=sys.stderr,
            )
            print(
                "  workspace bridge hooks will not fire — "
                "responses won't return to Emacs",
                file=sys.stderr,
            )

        if self.model:
            args.extend(["--model", self.model])

        args.extend(filter_claude_args(self.extra_args))
        return args


# ======================================================================
# Entry point
# ======================================================================


def main() -> None:
    argv = sys.argv[1:]
    if not argv:
        print(
            "Usage: copilot-workspace <org-file> [session-id] [-- extra-args...]",
            file=sys.stderr,
        )
        sys.exit(1)
    org_file, session_id, extras = split_positional_args(argv)
    CopilotWorkspaceLauncher(org_file, session_id, extras).run()


if __name__ == "__main__":
    main()
