"""Claude workspace launcher — replaces scripts/claude-workspace.

Launches Claude Code CLI with workspace bridge hooks and MCP integration.

Usage: claude-workspace <org-file> [session-id] [-- extra-args...]
"""

import atexit
import json
import os
import signal
import subprocess
import sys
from pathlib import Path

from claude_agent.mcp_client import McpClient
from claude_agent.workspace_bridge import _escape_elisp_string


def parse_args(argv: list[str]) -> tuple[str, str, list[str]]:
    """Parse CLI arguments.

    Returns (org_file, session_id, extra_args).
    """
    if not argv:
        print(
            "Usage: claude-workspace <org-file> [session-id] [-- extra-args...]",
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
    """List available workspace sessions via MCP."""
    elisp = (
        '(let ((debug-on-error nil) (debug-on-quit nil)) '
        f'(claude-org-workspace-bridge-list-sessions "{_escape_elisp_string(org_file)}"))'
    )
    return mcp.eval_elisp(elisp)


def select_session_interactive(sessions_text: str, org_file: str) -> str:
    """Display session list and prompt user to select one."""
    print(f"\nAvailable workspace sessions in {os.path.basename(org_file)}:")

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
        print(f"No workspace sessions found in {org_file}", file=sys.stderr)
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
) -> tuple[str, str]:
    """Fetch session metadata (story_name, system_prompt) from Emacs.

    State principle: Python is stateless. CLI session (--resume) is decided
    by Emacs and passed as a CLI arg — NOT read here via MCP.
    """
    esc_org = _escape_elisp_string(org_file)
    esc_sid = _escape_elisp_string(session_id)
    elisp = (
        '(let ((debug-on-error nil) (debug-on-quit nil))'
        '  (let* ((prompt (claude-org-workspace-bridge-system-prompt '
        f'    "{esc_org}" "{esc_sid}"))'
        f'         (story (with-current-buffer (claude-org-workspace-bridge--ensure-buffer "{esc_org}")'
        '            (save-excursion (save-restriction (widen)'
        f'              (claude-org-workspace-bridge--goto-session "{esc_sid}")'
        '              (substring-no-properties (org-get-heading t t t t)))))))'
        r'    (substring-no-properties (format "%s\n%s" story prompt))))'
    )
    result = mcp.eval_elisp(elisp)
    if not result:
        return "", ""

    lines = result.split("\n", 1)
    story_name = lines[0]
    system_prompt = lines[1] if len(lines) > 1 else ""

    return story_name, system_prompt


def _normalize_name(name: str) -> str:
    """Normalize a story name to a valid symbol name for --name flag.

    Lowercases, replaces non-alphanumeric with hyphens, collapses runs,
    strips leading/trailing hyphens.
    """
    import re

    slug = re.sub(r"[^a-z0-9]+", "-", name.lower())
    return slug.strip("-")


def _find_workspace_bridge_path() -> str:
    """Find the workspace-bridge binary path in the current virtualenv."""
    venv_bin = Path(sys.executable).parent
    bridge = venv_bin / "workspace-bridge"
    if bridge.exists():
        return str(bridge)
    return "workspace-bridge"  # fallback to PATH


def _write_hooks_settings(plugin_dir: str) -> str:
    """Write a temporary settings JSON with workspace-bridge hooks.

    Returns the path to the settings file.  The file is placed in the
    plugin directory so it persists across the session (Claude Code
    reads it at startup).
    """
    bridge = _find_workspace_bridge_path()
    hooks = {
        "hooks": {
            "Stop": [{
                "matcher": "",
                "hooks": [{
                    "type": "command",
                    "command": f"{bridge} response",
                    "timeout": 30,
                }],
            }],
            "UserPromptSubmit": [{
                "matcher": "",
                "hooks": [{
                    "type": "command",
                    "command": f"{bridge} prompt",
                    "timeout": 10,
                }],
            }],
            "SessionStart": [{
                "matcher": "",
                "hooks": [{
                    "type": "command",
                    "command": f"{bridge} session-start",
                    "timeout": 10,
                }],
            }],
        }
    }
    settings_file = os.path.join(plugin_dir, "workspace-hooks.json")
    with open(settings_file, "w") as f:
        json.dump(hooks, f)
    return settings_file


def build_claude_args(
    plugin_dir: str,
    mcp_url: str,
    system_prompt: str,
    extra_args: list[str],
    story_name: str = "",
) -> list[str]:
    """Build the claude CLI argument list.

    State principle: --resume is decided by Emacs and arrives via extra_args.
    Python does NOT independently determine whether to resume.
    """
    args = ["claude"]

    # Always include plugin-dir and mcp-config
    args.extend(["--plugin-dir", plugin_dir])

    mcp_config = (
        f'{{"mcpServers":{{"emacs":{{"type":"http","url":"{mcp_url}"}}}}}}'
    )
    args.extend(["--mcp-config", mcp_config])

    # Inject workspace-bridge hooks so responses are piped back to org buffer
    hooks_file = _write_hooks_settings(plugin_dir)
    args.extend(["--settings", hooks_file])

    # Set session name from workspace story name
    normalized = _normalize_name(story_name) if story_name else ""
    if normalized:
        args.extend(["--name", normalized])

    if _is_valid_session(system_prompt):
        args.extend(["--system-prompt", system_prompt])

    # extra_args may contain --resume <id> from Emacs (state owner)
    args.extend(extra_args)
    args.append("--ide")
    args.append("--chrome")
    return args


def cleanup_ide_server(mcp: McpClient, session_id: str) -> None:
    """Stop the IDE server in Emacs for this workspace session."""
    if not session_id:
        return
    try:
        mcp.eval_elisp(
            '(condition-case nil'
            f'  (claude-ide-stop-server "{_escape_elisp_string(session_id)}")'
            '  (error nil))'
        )
    except Exception:
        pass  # Best-effort — Emacs may be gone too


def main() -> None:
    org_file, session_id, extra_args = parse_args(sys.argv[1:])
    org_file = os.path.abspath(org_file)

    # Determine plugin directory (parent of python/)
    plugin_dir = os.environ.get(
        "CLAUDE_PLUGIN_ROOT",
        str(Path(__file__).resolve().parent.parent.parent),
    )

    mcp_url = os.environ.get("EMACS_MCP_URL", "http://localhost:9999/mcp")
    mcp = McpClient(url=mcp_url, read_timeout=30.0)

    # Check MCP connection
    print(f"Checking Emacs MCP server at {mcp_url}...")
    mcp_ok = mcp.ping()

    if mcp_ok:
        print("  MCP server OK")
    else:
        print(f"  WARNING: MCP server not reachable at {mcp_url}", file=sys.stderr)
        print(
            "  workspace bridge hooks disabled. Launching without workspace integration...",
            file=sys.stderr,
        )

    # MCP-dependent setup
    system_prompt = ""
    story_name = ""

    if mcp_ok:
        if not session_id:
            sessions = list_sessions(mcp, org_file)
            if not sessions:
                print(f"No workspace sessions found in {org_file}", file=sys.stderr)
                sys.exit(1)
            session_id = select_session_interactive(sessions, org_file)

        print(f"Building session metadata for {session_id}...")
        story_name, system_prompt = fetch_session_metadata(
            mcp, org_file, session_id
        )

        if not _is_valid_session(system_prompt):
            print(
                "  WARNING: Could not build system prompt — launching without it",
                file=sys.stderr,
            )

    # Export env vars for hook scripts
    os.environ["WORKSPACE_ORG_FILE"] = org_file
    os.environ["WORKSPACE_SESSION_ID"] = session_id or ""
    os.environ["EMACS_MCP_URL"] = mcp_url
    os.environ["CLAUDE_PLUGIN_ROOT"] = plugin_dir

    # Set terminal tab title
    file_base = os.path.splitext(os.path.basename(org_file))[0]
    tab_title = f"{file_base}:{story_name or session_id or 'standalone'}"
    os.environ["WARP_DISABLE_AUTO_TITLE"] = "true"
    sys.stdout.write(f"\033]0;{tab_title}\007")
    sys.stdout.flush()

    # Build and exec claude
    # --resume comes via extra_args from Emacs (state owner), not from Python
    args = build_claude_args(
        plugin_dir, mcp_url, system_prompt, extra_args,
        story_name=story_name or "",
    )

    print("Starting Claude Code...")
    print(f"  Org file:   {org_file}")
    print(f"  Session ID: {session_id or 'none'}")
    print(f"  Story:      {story_name or 'unknown'}")
    print(f"  MCP bridge: {mcp_ok}")
    print(f"  Extra args: {extra_args}")
    print(f"  Final cmd:  {' '.join(args)}")
    print()

    # Unset CLAUDECODE to avoid "cannot launch inside another Claude Code session" error
    os.environ.pop("CLAUDECODE", None)

    # Start IDE WebSocket server in Emacs before Claude Code launches
    # Claude Code with --ide reads ~/.claude/ide/*.lock to find the server
    if mcp_ok and session_id:
        project_root = os.getcwd()
        try:
            mcp.eval_elisp(
                '(let ((debug-on-error nil) (debug-on-quit nil))'
                f'  (claude-org-cmux--ensure-ide-server '
                f'"{_escape_elisp_string(project_root)}" '
                f'"{_escape_elisp_string(session_id)}"))'
            )
            print(f"  IDE server: started for {os.path.basename(project_root)}")
        except Exception as e:
            print(f"  IDE server: failed to start ({e})", file=sys.stderr)

    # Register atexit as belt-and-suspenders for edge cases
    if mcp_ok and session_id:
        atexit.register(cleanup_ide_server, mcp, session_id)

    # Register SIGTERM handler so cleanup runs even on kill/docker stop
    # (atexit handlers do NOT fire on SIGTERM)
    def _sigterm_handler(signum, frame):
        if mcp_ok and session_id:
            cleanup_ide_server(mcp, session_id)
        sys.exit(128 + signum)

    signal.signal(signal.SIGTERM, _sigterm_handler)

    result = subprocess.run(args)

    # Primary cleanup: stop IDE server when Claude Code exits
    # Unregister first to prevent atexit double-call if cleanup_ide_server raises
    if mcp_ok and session_id:
        atexit.unregister(cleanup_ide_server)
        cleanup_ide_server(mcp, session_id)

    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
