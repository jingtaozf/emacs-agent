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
    WorkspaceLauncher,
    cleanup_emacs_agent_inject,
    filter_claude_args,
    is_valid_session,
    restore_file,
    split_positional_args,
    strip_emacs_agent_inject_blocks,
)


# ======================================================================
# File-based injection helpers (Copilot's MCP + system-prompt model)
# ======================================================================


def _inject_emacs_mcp_into_dotgithub(project_root: str, mcp_url: str) -> None:
    """Merge the Emacs MCP server entry into ``.github/mcp.json``.

    Saves the original (or marks "did not exist") and registers an
    atexit to restore it so the launcher is non-destructive.
    """
    mcp_json_path = Path(project_root) / ".github" / "mcp.json"
    mcp_json_path.parent.mkdir(parents=True, exist_ok=True)

    original: str | None = None
    if mcp_json_path.exists():
        original = mcp_json_path.read_text()
    try:
        config = json.loads(original) if original else {}
    except json.JSONDecodeError:
        config = {}

    config.setdefault("mcpServers", {})["emacs"] = {"type": "http", "url": mcp_url}
    mcp_json_path.write_text(json.dumps(config, indent=2))
    atexit.register(restore_file, mcp_json_path, original)
    print(f"  MCP config: injected Emacs server into {mcp_json_path}")


def _write_agents_md(project_root: str, system_prompt: str) -> None:
    """Prepend the session system prompt to ``.github/AGENTS.md``.

    Existing content is preserved with a clear header/footer so session
    instructions are visually separate from permanent project guidance.
    On exit the inject block is stripped (idempotent) so multiple failed
    cleanups don't accumulate — see tasks/lessons.md (2026-04-30) for the
    self-perpetuating bloat bug this avoids.
    """
    agents_md_path = Path(project_root) / ".github" / "AGENTS.md"
    agents_md_path.parent.mkdir(parents=True, exist_ok=True)

    file_existed_before = agents_md_path.exists()
    raw = agents_md_path.read_text() if file_existed_before else ""
    base = strip_emacs_agent_inject_blocks(raw)

    header = (
        "<!-- BEGIN emacs-agent session instructions (auto-removed on exit) -->\n"
        f"{system_prompt.strip()}\n"
        "<!-- END emacs-agent session instructions -->\n\n"
    )
    agents_md_path.write_text(header + base)
    atexit.register(cleanup_emacs_agent_inject, agents_md_path, file_existed_before)
    print(f"  System prompt: written to {agents_md_path}")


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
            _write_agents_md(self.project_root, self.system_prompt)

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
