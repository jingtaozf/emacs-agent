"""Claude SDD launcher — replaces scripts/claude-sdd.

Launches Claude Code CLI with SDD bridge hooks and MCP integration.

Usage: claude-sdd <org-file> [session-id] [-- extra-args...]
"""

import os
import sys
from pathlib import Path

from claude_agent.mcp_client import McpClient
from claude_agent.sdd_bridge import _escape_elisp_string


def parse_args(argv: list[str]) -> tuple[str, str, list[str]]:
    """Parse CLI arguments.

    Returns (org_file, session_id, extra_args).
    """
    if not argv:
        print(
            "Usage: claude-sdd <org-file> [session-id] [-- extra-args...]",
            file=sys.stderr,
        )
        sys.exit(1)

    org_file = argv[0]
    rest = argv[1:]

    session_id = ""
    if rest and not rest[0].startswith("-"):
        session_id = rest[0]
        rest = rest[1:]

    # Skip optional -- separator
    if rest and rest[0] == "--":
        rest = rest[1:]

    return org_file, session_id, rest


def _is_valid_session(value: str) -> bool:
    """Check if a value is a valid (non-null) session string."""
    return bool(value) and value not in ("null", "nil")


def list_sessions(mcp: McpClient, org_file: str) -> str | None:
    """List available SDD sessions via MCP."""
    elisp = (
        '(let ((debug-on-error nil) (debug-on-quit nil)) '
        f'(claude-org-sdd-bridge-list-sessions "{_escape_elisp_string(org_file)}"))'
    )
    return mcp.eval_elisp(elisp)


def select_session_interactive(sessions_text: str, org_file: str) -> str:
    """Display session list and prompt user to select one."""
    print(f"\nAvailable SDD sessions in {os.path.basename(org_file)}:")

    session_ids = []
    current_parent = "__unset__"

    for line in sessions_text.split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        sid = parts[0]
        heading = parts[1]
        parent = parts[2] if len(parts) > 2 else ""

        if parent != current_parent:
            print()
            if parent:
                print(f"  [{parent}]")
            else:
                print("  [top-level]")
            current_parent = parent

        i = len(session_ids) + 1
        print(f"    {i}) {heading}  ({sid})")
        session_ids.append(sid)

    if not session_ids:
        print(f"No SDD sessions found in {org_file}", file=sys.stderr)
        sys.exit(1)

    print()
    try:
        choice = int(input(f"Select session [1-{len(session_ids)}]: "))
    except (EOFError, KeyboardInterrupt):
        sys.exit(1)
    except ValueError:
        choice = 0  # will fail range check below

    if not 1 <= choice <= len(session_ids):
        print("Invalid selection", file=sys.stderr)
        sys.exit(1)

    selected = session_ids[choice - 1]
    print(f"Selected: {selected}\n")
    return selected


def fetch_session_metadata(
    mcp: McpClient, org_file: str, session_id: str
) -> tuple[str, str, str]:
    """Fetch session metadata (cli_session, story_name, system_prompt)."""
    esc_org = _escape_elisp_string(org_file)
    esc_sid = _escape_elisp_string(session_id)
    elisp = (
        '(let ((debug-on-error nil) (debug-on-quit nil))'
        '  (let* ((prompt (claude-org-sdd-bridge-system-prompt '
        f'    "{esc_org}" "{esc_sid}"))'
        '         (cli-sid (or (claude-org-sdd-bridge-get-cli-session '
        f'    "{esc_org}" "{esc_sid}") ""))'
        f'         (story (with-current-buffer (claude-org-sdd-bridge--ensure-buffer "{esc_org}")'
        '            (save-excursion (save-restriction (widen)'
        f'              (claude-org-sdd-bridge--goto-session "{esc_sid}")'
        '              (substring-no-properties (org-get-heading t t t t)))))))'
        r'    (format "%s\t%s\n%s" cli-sid story prompt)))'
    )
    result = mcp.eval_elisp(elisp)
    if not result:
        return "", "", ""

    lines = result.split("\n", 1)
    first_line = lines[0]
    system_prompt = lines[1] if len(lines) > 1 else ""

    parts = first_line.split("\t", 1)
    cli_session = parts[0] if parts else ""
    story_name = parts[1] if len(parts) > 1 else ""

    return cli_session, story_name, system_prompt


def build_claude_args(
    plugin_dir: str,
    mcp_url: str,
    system_prompt: str,
    cli_session: str,
    extra_args: list[str],
) -> list[str]:
    """Build the claude CLI argument list."""
    args = ["claude"]

    # Always include plugin-dir and mcp-config
    args.extend(["--plugin-dir", plugin_dir])

    mcp_config = (
        f'{{"mcpServers":{{"emacs":{{"type":"http","url":"{mcp_url}"}}}}}}'
    )
    args.extend(["--mcp-config", mcp_config])

    if _is_valid_session(system_prompt):
        args.extend(["--system-prompt", system_prompt])

    if _is_valid_session(cli_session):
        args.extend(["--resume", cli_session])

    args.extend(extra_args)
    return args


def main() -> None:
    org_file, session_id, extra_args = parse_args(sys.argv[1:])
    org_file = os.path.abspath(org_file)

    # Determine plugin directory (parent of python/)
    plugin_dir = os.environ.get(
        "CLAUDE_PLUGIN_ROOT",
        str(Path(__file__).resolve().parent.parent.parent),
    )

    mcp_url = os.environ.get("EMACS_MCP_URL", "http://localhost:9999/mcp")
    mcp = McpClient(url=mcp_url)

    # Check MCP connection
    print(f"Checking Emacs MCP server at {mcp_url}...")
    mcp_ok = mcp.ping()

    if mcp_ok:
        print("  MCP server OK")
    else:
        print(f"  WARNING: MCP server not reachable at {mcp_url}", file=sys.stderr)
        print(
            "  SDD bridge hooks disabled. Launching without SDD integration...",
            file=sys.stderr,
        )

    # MCP-dependent setup
    system_prompt = ""
    cli_session = ""
    story_name = ""

    if mcp_ok:
        if not session_id:
            sessions = list_sessions(mcp, org_file)
            if not sessions:
                print(f"No SDD sessions found in {org_file}", file=sys.stderr)
                sys.exit(1)
            session_id = select_session_interactive(sessions, org_file)

        print(f"Building session metadata for {session_id}...")
        cli_session, story_name, system_prompt = fetch_session_metadata(
            mcp, org_file, session_id
        )

        if not _is_valid_session(system_prompt):
            print(
                "  WARNING: Could not build system prompt — launching without it",
                file=sys.stderr,
            )

    # Export env vars for hook scripts
    os.environ["SDD_ORG_FILE"] = org_file
    os.environ["SDD_SESSION_ID"] = session_id or ""
    os.environ["EMACS_MCP_URL"] = mcp_url

    # Set terminal tab title
    file_base = os.path.splitext(os.path.basename(org_file))[0]
    tab_title = f"{file_base}:{story_name or session_id or 'standalone'}"
    os.environ["WARP_DISABLE_AUTO_TITLE"] = "true"
    sys.stdout.write(f"\033]0;{tab_title}\007")
    sys.stdout.flush()

    # Build and exec claude
    args = build_claude_args(plugin_dir, mcp_url, system_prompt, cli_session, extra_args)

    if _is_valid_session(cli_session):
        print(f"Resuming Claude CLI session: {cli_session}")

    print("Starting Claude Code...")
    print(f"  Org file:   {org_file}")
    print(f"  Session ID: {session_id or 'none'}")
    print(f"  Story:      {story_name or 'unknown'}")
    print(f"  MCP bridge: {mcp_ok}")
    print()

    os.execvp(args[0], args)


if __name__ == "__main__":
    main()
