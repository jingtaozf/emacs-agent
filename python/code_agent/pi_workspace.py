"""Pi workspace launcher.

Subclass of ``WorkspaceLauncher`` that runs the Pi TUI in a cmux pane.
The Emacs MCP bridge + response return are handled by Pi's global
``emacs-mcp`` extension (env-gated on ``WORKSPACE_ORG_FILE``), so this
launcher only needs to set env, optionally resume, and exec ``pi``.
"""

from __future__ import annotations

import sys

from code_agent.workspace_launcher import (
    WorkspaceLauncher,
    filter_claude_args,
    split_positional_args,
)


class PiWorkspaceLauncher(WorkspaceLauncher):
    """WorkspaceLauncher subclass for the Pi TUI."""

    agent_name = "pi"
    agent_binary = "pi"
    agent_type_env_value = "pi"

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
    def from_argv(cls, argv: list[str]) -> "PiWorkspaceLauncher":
        """Parse ``[--resume <id>]`` and an optional ``--`` separator."""
        org_file, session_id, rest = split_positional_args(argv)
        resume_id: str | None = None
        if len(rest) >= 2 and rest[0] == "--resume":
            resume_id = rest[1]
            rest = rest[2:]
        if rest and rest[0] == "--":
            rest = rest[1:]
        return cls(org_file, session_id, rest, resume_id=resume_id)

    def build_args(self) -> list[str]:
        # Interactive Pi TUI (no --mode rpc). System prompt deferred to v1.1.
        args = ["pi"]
        if self.resume_id:
            args.extend(["--resume", self.resume_id])
        args.extend(filter_claude_args(self.extra_args))
        return args

    def print_banner(self, args: list[str]) -> None:
        print(f"Starting {self.agent_binary}...")
        print(f"  Org file:   {self.org_file}")
        print(f"  Session ID: {self.session_id or 'none'}")
        print(f"  Resume ID:  {self.resume_id or 'none (fresh session)'}")
        print(f"  Story:      {self.story_name or 'unknown'}")
        print(f"  MCP bridge: {self.mcp_ok}")
        print(f"  Extra args: {self.extra_args}")
        print(f"  Final cmd:  {' '.join(args)}")
        print()


def main() -> None:
    argv = sys.argv[1:]
    if not argv:
        print(
            "Usage: pi-workspace <org-file> [session-id] "
            "[--resume <id>] [-- extra-args...]",
            file=sys.stderr,
        )
        sys.exit(1)
    PiWorkspaceLauncher.from_argv(argv).run()


if __name__ == "__main__":
    main()
