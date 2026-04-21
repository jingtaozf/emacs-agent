"""OpenCode workspace launcher.

Subclass of ``WorkspaceLauncher`` for the OpenCode TUI. Differences
from Claude and Copilot: MCP wiring lives in ``opencode.jsonc`` (JSONC
with comments; parsed by stripping them), system prompt goes into
``AGENTS.md`` at the project root, and workspace-bridge event plumbing
is a TypeScript plugin copied into ``.opencode/plugins/``. Session
resume uses ``--session <id>`` rather than ``--resume``.

Two OpenCode-only env vars are set: ``OPENCODE_PERMISSION=allow`` for
autonomous operation and ``OTUI_USE_ALTERNATE_SCREEN=main-screen`` so
scrollback survives the TUI exit.
"""

from __future__ import annotations

import atexit
import json
import os
import re
import sys
from pathlib import Path

from claude_agent.workspace_launcher import (
    WorkspaceLauncher,
    filter_claude_args,
    restore_file,
    split_positional_args,
    is_valid_session,
)


# ======================================================================
# File-based injection helpers (OpenCode's MCP + AGENTS.md + plugins)
# ======================================================================

def _parse_jsonc(text: str) -> dict:
    """Minimal JSONC parser — strips ``//`` and ``/* */`` comments."""
    stripped = re.sub(r"//.*?$", "", text, flags=re.MULTILINE)
    stripped = re.sub(r"/\*.*?\*/", "", stripped, flags=re.DOTALL)
    return json.loads(stripped) if stripped.strip() else {}


def _inject_emacs_mcp(project_root: str, mcp_url: str) -> None:
    """Merge the Emacs MCP server entry into ``opencode.jsonc``.

    Accepts either ``opencode.jsonc`` or ``opencode.json`` as input;
    always writes back as ``.jsonc``. Register atexit to restore.
    """
    config_path = Path(project_root) / "opencode.jsonc"
    if not config_path.exists():
        alt = Path(project_root) / "opencode.json"
        if alt.exists():
            config_path = alt

    original: str | None = None
    if config_path.exists():
        original = config_path.read_text()
    try:
        config = _parse_jsonc(original) if original else {}
    except (json.JSONDecodeError, ValueError):
        config = {}

    config.setdefault("mcp", {})["emacs"] = {
        "type": "remote",
        "url": mcp_url,
        "enabled": True,
    }

    out_path = Path(project_root) / "opencode.jsonc"
    out_path.write_text(json.dumps(config, indent=2))
    atexit.register(
        restore_file,
        out_path,
        original if out_path == config_path else None,
    )
    if config_path != out_path and original is not None:
        # Opened a .json, now writing .jsonc — restore both.
        atexit.register(restore_file, config_path, original)
    print(f"  MCP config: injected Emacs server into {out_path}")


def _write_agents_md(project_root: str, system_prompt: str) -> None:
    """Prepend the session system prompt to ``AGENTS.md`` at project root."""
    agents_md_path = Path(project_root) / "AGENTS.md"

    original: str | None = None
    if agents_md_path.exists():
        original = agents_md_path.read_text()

    header = (
        "<!-- BEGIN emacs-agent session instructions (auto-removed on exit) -->\n"
        f"{system_prompt.strip()}\n"
        "<!-- END emacs-agent session instructions -->\n\n"
    )
    agents_md_path.write_text(header + (original or ""))
    atexit.register(restore_file, agents_md_path, original)
    print(f"  System prompt: written to {agents_md_path}")


def _inject_bridge_plugin(plugin_dir: str, project_root: str) -> None:
    """Copy the emacs-bridge TS plugin into ``.opencode/plugins/``.

    OpenCode loads plugins from ``.opencode/plugins/`` and the plugin
    bridges OpenCode events to our workspace-bridge endpoint. Restores
    original state on exit.
    """
    source = Path(plugin_dir) / "hooks" / "opencode-plugin" / "emacs-bridge.ts"
    if not source.exists():
        print(
            f"  WARNING: OpenCode bridge plugin not found: {source}",
            file=sys.stderr,
        )
        print(
            "  workspace bridge hooks will not fire — "
            "responses won't return to Emacs",
            file=sys.stderr,
        )
        return

    dest_dir = Path(project_root) / ".opencode" / "plugins"
    dest = dest_dir / "emacs-bridge.ts"

    created_dir = not dest_dir.exists()
    original: str | None = None
    if dest.exists():
        original = dest.read_text()

    dest_dir.mkdir(parents=True, exist_ok=True)
    dest.write_text(source.read_text())
    atexit.register(restore_file, dest, original)
    if created_dir:
        def _cleanup_plugin_dir():
            try:
                dest.unlink(missing_ok=True)
                if dest_dir.exists() and not any(dest_dir.iterdir()):
                    dest_dir.rmdir()
            except Exception:
                pass

        atexit.register(_cleanup_plugin_dir)
    print(f"  Plugin: installed {source.name} -> {dest}")


# ======================================================================
# OpencodeWorkspaceLauncher
# ======================================================================

class OpencodeWorkspaceLauncher(WorkspaceLauncher):
    """WorkspaceLauncher subclass for the OpenCode TUI."""

    agent_name = "opencode"
    agent_binary = "opencode"
    agent_type_env_value = "opencode"

    def __init__(
        self,
        org_file: str,
        session_id: str,
        extra_args: list[str],
        resume_id: str | None = None,
    ):
        super().__init__(org_file, session_id, extra_args)
        self.resume_id = resume_id

    @classmethod
    def from_argv(cls, argv: list[str]) -> "OpencodeWorkspaceLauncher":
        """Parse ``[--resume <id>]`` and an optional ``--`` separator."""
        org_file, session_id, rest = split_positional_args(argv)
        resume_id: str | None = None
        if len(rest) >= 2 and rest[0] == "--resume":
            resume_id = rest[1]
            rest = rest[2:]
        # `split_positional_args` already stripped a leading `--`, but if
        # `--resume <id>` sat between the session-id and the separator
        # we still have to strip one here.
        if rest and rest[0] == "--":
            rest = rest[1:]
        return cls(org_file, session_id, rest, resume_id=resume_id)

    # ------------------------------------------------------------------
    # Env — two OpenCode-only vars go on top of the base's
    # ------------------------------------------------------------------

    def export_env_vars(self) -> None:
        super().export_env_vars()
        os.environ["OPENCODE_PERMISSION"] = json.dumps("allow")
        os.environ["OTUI_USE_ALTERNATE_SCREEN"] = "main-screen"

    # ------------------------------------------------------------------
    # inject_config — opencode.jsonc + AGENTS.md + TS plugin
    # ------------------------------------------------------------------

    def inject_config(self) -> None:
        _inject_emacs_mcp(self.project_root, self.mcp_url)
        if self.mcp_ok and is_valid_session(self.system_prompt):
            _write_agents_md(self.project_root, self.system_prompt)
        _inject_bridge_plugin(self.plugin_dir, self.project_root)

    # ------------------------------------------------------------------
    # build_args — opencode argv (uses --session, not --resume)
    # ------------------------------------------------------------------

    def build_args(self) -> list[str]:
        args = ["opencode"]
        if self.resume_id:
            args.extend(["--session", self.resume_id])
        if self.model:
            args.extend(["--model", self.model])
        args.extend(filter_claude_args(self.extra_args))
        return args

    # ------------------------------------------------------------------
    # Banner — show the resume id too (OpenCode-specific UX)
    # ------------------------------------------------------------------

    def print_banner(self, args: list[str]) -> None:
        print(f"Starting {self.agent_binary}...")
        print(f"  Org file:   {self.org_file}")
        print(f"  Session ID: {self.session_id or 'none'}")
        print(f"  Resume ID:  {self.resume_id or 'none (fresh session)'}")
        print(f"  Story:      {self.story_name or 'unknown'}")
        print(f"  MCP bridge: {self.mcp_ok}")
        print(f"  Extra args: {self.extra_args}")
        if self.model:
            print(f"  Model:      {self.model}")
        print(f"  Final cmd:  {' '.join(args)}")
        print()


# ======================================================================
# Entry point
# ======================================================================

def main() -> None:
    argv = sys.argv[1:]
    if not argv:
        print(
            "Usage: opencode-workspace <org-file> [session-id] "
            "[--resume <id>] [-- extra-args...]",
            file=sys.stderr,
        )
        sys.exit(1)
    OpencodeWorkspaceLauncher.from_argv(argv).run()


if __name__ == "__main__":
    main()
