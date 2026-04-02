"""GitHub Copilot workspace launcher for cmux backend.

Launches GitHub Copilot CLI with workspace bridge hooks and MCP integration.
Usage: copilot-workspace <org-file> [session-id] [-- extra-args...]

Key differences from claude_workspace.py:
  - No --ide: Copilot has no WebSocket IDE integration
  - MCP via .github/mcp.json (file-based, not --mcp-config flag)
  - System prompt via .github/AGENTS.md (file-based, not --system-prompt)
  - Requires --allow-all-tools for autonomous operation
  - Restores .github/mcp.json and .github/AGENTS.md on exit

State principle: Python is stateless. Emacs is the state owner.
This script receives org-file and session-id as CLI args and env vars.
It does NOT independently read org properties or make session decisions.
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
            "Usage: copilot-workspace <org-file> [session-id] [-- extra-args...]",
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


def _restore_file(path: Path, original_content: str | None) -> None:
    """Restore a file to its original content, or delete it if it didn't exist."""
    try:
        if original_content is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(original_content)
    except Exception:
        pass  # Best-effort — process may be torn down


def inject_emacs_mcp_into_dotgithub(project_root: str, mcp_url: str) -> None:
    """Merge Emacs MCP server entry into .github/mcp.json.

    Saves the original content and registers restore via atexit so the
    user's repo is not permanently modified by this launcher process.
    If .github/mcp.json does not exist, it is created and deleted on exit.
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
    atexit.register(_restore_file, mcp_json_path, original)
    print(f"  MCP config: injected Emacs server into {mcp_json_path}")


def write_agents_md(project_root: str, system_prompt: str) -> None:
    """Prepend session system prompt to .github/AGENTS.md.

    Restores original on exit. If AGENTS.md already exists, the session
    instructions are prepended above the existing content with a clear header/footer
    so they are visually distinct from the permanent project instructions.
    If AGENTS.md does not exist it is created and deleted on exit.
    """
    agents_md_path = Path(project_root) / ".github" / "AGENTS.md"
    agents_md_path.parent.mkdir(parents=True, exist_ok=True)

    original: str | None = None
    if agents_md_path.exists():
        original = agents_md_path.read_text()

    header = (
        "<!-- BEGIN emacs-agent session instructions (auto-removed on exit) -->\n"
        f"{system_prompt.strip()}\n"
        "<!-- END emacs-agent session instructions -->\n\n"
    )
    agents_md_path.write_text(header + (original or ""))
    atexit.register(_restore_file, agents_md_path, original)
    print(f"  System prompt: written to {agents_md_path}")


# Claude Code-specific flags that must not be forwarded to Copilot CLI
# Note: --resume is NOT listed here because Copilot CLI supports it
_CLAUDE_ONLY_FLAGS = frozenset({
    "--dangerously-skip-permissions",
    "--permission-mode",
    "--ide",
    "--chrome",
    "--plugin-dir",
    "--mcp-config",
    "--system-prompt",
    "--name",
})

# Flags that take a following value argument (so we skip value too)
_CLAUDE_FLAGS_WITH_VALUE = frozenset({
    "--permission-mode",
    "--plugin-dir",
    "--mcp-config",
    "--system-prompt",
    "--name",
})


def _filter_claude_args(args: list[str]) -> list[str]:
    """Remove Claude Code-specific flags from args for Copilot compatibility."""
    result = []
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


def build_copilot_args(
    extra_args: list[str],
    plugin_dir: str,
    model: str = "",
) -> list[str]:
    """Build the copilot CLI argument list.

    State principle: --resume is passed when Emacs provides a CLI session ID
    via CLAUDE_CLI_SESSION org property (Emacs is the state owner).
    MCP and system-prompt are injected via files before this is called.
    Claude Code-specific flags are filtered from extra_args.
    Workspace bridge hooks are loaded via --plugin-dir.
    """
    args = ["copilot"]

    # Required for autonomous / agentic operation in cmux
    args.append("--allow-all-tools")

    # Load workspace bridge hooks plugin
    copilot_plugin_dir = os.path.join(plugin_dir, "hooks", "copilot-plugin")
    if os.path.isdir(copilot_plugin_dir):
        args.extend(["--plugin-dir", copilot_plugin_dir])
    else:
        print(
            f"  WARNING: Copilot plugin dir not found: {copilot_plugin_dir}",
            file=sys.stderr,
        )
        print(
            "  workspace bridge hooks will not fire — responses won't return to Emacs",
            file=sys.stderr,
        )

    # Optional model override (from AGENT_MODEL org property via env var)
    if model:
        args.extend(["--model", model])

    # Filter out Claude-only flags before forwarding to Copilot
    filtered = _filter_claude_args(extra_args)
    args.extend(filtered)
    return args


def fetch_session_metadata(
    mcp: McpClient, org_file: str, session_id: str
) -> tuple[str, str]:
    """Fetch session metadata (story_name, system_prompt) from Emacs via MCP.

    State principle: Python is stateless. System prompt is fetched from
    Emacs (the state owner), not determined independently here.
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


def _is_valid_session(value: str) -> bool:
    """Check if a value is a non-null, non-empty string."""
    return bool(value) and value not in ("null", "nil")


def main() -> None:
    org_file, session_id, extra_args = parse_args(sys.argv[1:])
    org_file = os.path.abspath(org_file)
    project_root = os.getcwd()

    plugin_dir = os.environ.get(
        "CLAUDE_PLUGIN_ROOT",
        str(Path(__file__).resolve().parent.parent.parent),
    )
    mcp_url = os.environ.get("EMACS_MCP_URL", "http://localhost:9999/mcp")
    model = os.environ.get("AGENT_MODEL", "")

    mcp = McpClient(url=mcp_url, read_timeout=30.0)

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

    system_prompt = ""
    story_name = ""

    if mcp_ok and session_id:
        print(f"Building session metadata for {session_id}...")
        story_name, system_prompt = fetch_session_metadata(mcp, org_file, session_id)
        if not _is_valid_session(system_prompt):
            print(
                "  WARNING: Could not build system prompt — launching without it",
                file=sys.stderr,
            )

    # Export env vars for hook scripts (workspace_bridge.py reads these)
    os.environ["WORKSPACE_ORG_FILE"] = org_file
    os.environ["WORKSPACE_SESSION_ID"] = session_id or ""
    os.environ["EMACS_MCP_URL"] = mcp_url
    os.environ["CLAUDE_PLUGIN_ROOT"] = plugin_dir

    # Set terminal tab title
    file_base = os.path.splitext(os.path.basename(org_file))[0]
    tab_title = f"{file_base}:{story_name or session_id or 'copilot'}"
    os.environ["WARP_DISABLE_AUTO_TITLE"] = "true"
    sys.stdout.write(f"\033]0;{tab_title}\007")
    sys.stdout.flush()

    # Inject MCP config and system prompt via files (Copilot's mechanism)
    inject_emacs_mcp_into_dotgithub(project_root, mcp_url)
    if mcp_ok and _is_valid_session(system_prompt):
        write_agents_md(project_root, system_prompt)

    # Build copilot command — no --resume (not supported by Copilot CLI)
    args = build_copilot_args(extra_args, plugin_dir=plugin_dir, model=model)

    print("Starting GitHub Copilot...")
    print(f"  Org file:   {org_file}")
    print(f"  Session ID: {session_id or 'none'}")
    print(f"  Story:      {story_name or 'unknown'}")
    print(f"  MCP bridge: {mcp_ok}")
    print(f"  Extra args: {extra_args}")
    print(f"  Model:      {model or 'default'}")
    print(f"  Final cmd:  {' '.join(args)}")
    print()

    # Register SIGTERM handler so cleanup (atexit) runs even on kill
    def _sigterm_handler(signum, frame):
        sys.exit(128 + signum)

    signal.signal(signal.SIGTERM, _sigterm_handler)

    result = subprocess.run(args)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
