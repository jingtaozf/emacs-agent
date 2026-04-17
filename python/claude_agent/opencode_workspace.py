"""OpenCode workspace launcher for cmux backend.

Launches OpenCode TUI with workspace bridge hooks and MCP integration.
Usage: opencode-workspace <org-file> [session-id] [--resume <id>] [-- extra-args...]

Key differences from claude_workspace.py / copilot_workspace.py:
  - MCP via opencode.jsonc mcp section (file-based, not --mcp-config flag)
  - System prompt via AGENTS.md (file-based, not --system-prompt flag)
  - Session resume via --session <id> (not --resume)
  - Permissions configurable via opencode.jsonc or OPENCODE_PERMISSION env var
  - Plugin hooks in .opencode/plugins/ (JS/TS, not shell scripts)
  - Env var: OTUI_USE_ALTERNATE_SCREEN=main-screen (scrollback preservation)

State principle: Python is stateless. Emacs is the state owner.
This script receives org-file and session-id as CLI args and env vars.
It does NOT independently read org properties or make session decisions.
"""

import atexit
import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path

from claude_agent.mcp_client import McpClient
from claude_agent.workspace_bridge import _escape_elisp_string


def parse_args(argv: list[str]) -> tuple[str, str, str | None, list[str]]:
    """Parse CLI arguments.

    Returns (org_file, session_id, resume_id, extra_args).
    """
    if not argv:
        print(
            "Usage: opencode-workspace <org-file> [session-id] [--resume <id>] [-- extra-args...]",
            file=sys.stderr,
        )
        sys.exit(1)

    org_file = argv[0]
    rest = argv[1:]

    session_id = ""
    if rest and not rest[0].startswith("-"):
        session_id = rest[0]
        rest = rest[1:]

    # Parse --resume <id> (passed by Emacs launch command builder)
    resume_id = None
    if len(rest) >= 2 and rest[0] == "--resume":
        resume_id = rest[1]
        rest = rest[2:]

    # Skip optional -- separator
    if rest and rest[0] == "--":
        rest = rest[1:]

    return org_file, session_id, resume_id, rest


def _restore_file(path: Path, original_content: str | None) -> None:
    """Restore a file to its original content, or delete it if it didn't exist."""
    try:
        if original_content is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(original_content)
    except Exception:
        pass  # Best-effort — process may be torn down


def _parse_jsonc(text: str) -> dict:
    """Minimal JSONC parser — strip // and /* */ comments."""
    stripped = re.sub(r"//.*?$", "", text, flags=re.MULTILINE)
    stripped = re.sub(r"/\*.*?\*/", "", stripped, flags=re.DOTALL)
    return json.loads(stripped) if stripped.strip() else {}


def inject_emacs_mcp(project_root: str, mcp_url: str) -> None:
    """Merge Emacs MCP server entry into opencode.jsonc.

    Saves the original content and registers restore via atexit so the
    user's repo is not permanently modified by this launcher process.
    If opencode.jsonc does not exist, it is created and deleted on exit.

    OpenCode uses the 'mcp' section in opencode.jsonc (not a CLI flag).
    The Emacs MCP server is added as a 'remote' type (HTTP transport).
    """
    # Check both .jsonc and .json variants
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

    # Always write as .jsonc
    out_path = Path(project_root) / "opencode.jsonc"
    out_path.write_text(json.dumps(config, indent=2))
    atexit.register(
        _restore_file, out_path, original if out_path == config_path else None
    )
    if config_path != out_path and original is not None:
        # We read from opencode.json but wrote to opencode.jsonc — restore the original too
        atexit.register(_restore_file, config_path, original)
    print(f"  MCP config: injected Emacs server into {out_path}")


def write_agents_md(project_root: str, system_prompt: str) -> None:
    """Prepend session system prompt to AGENTS.md.

    Restores original on exit. If AGENTS.md already exists, the session
    instructions are prepended above the existing content with a clear header/footer
    so they are visually distinct from the permanent project instructions.
    If AGENTS.md does not exist it is created and deleted on exit.
    """
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
    atexit.register(_restore_file, agents_md_path, original)
    print(f"  System prompt: written to {agents_md_path}")


def inject_bridge_plugin(plugin_dir: str, project_root: str) -> None:
    """Copy the emacs-bridge plugin into .opencode/plugins/.

    OpenCode loads plugins from .opencode/plugins/ in the project root.
    The plugin bridges OpenCode events to the workspace bridge HTTP endpoint.
    Restores original state on exit.
    """
    source = Path(plugin_dir) / "hooks" / "opencode-plugin" / "emacs-bridge.ts"
    if not source.exists():
        print(f"  WARNING: OpenCode bridge plugin not found: {source}", file=sys.stderr)
        print(
            "  workspace bridge hooks will not fire — responses won't return to Emacs",
            file=sys.stderr,
        )
        return

    dest_dir = Path(project_root) / ".opencode" / "plugins"
    dest = dest_dir / "emacs-bridge.ts"

    # Track whether we created the directory or the file
    created_dir = not dest_dir.exists()
    original: str | None = None
    if dest.exists():
        original = dest.read_text()

    dest_dir.mkdir(parents=True, exist_ok=True)
    dest.write_text(source.read_text())
    atexit.register(_restore_file, dest, original)
    if created_dir:
        # Clean up the directory we created (only if it was empty minus our file)
        def _cleanup_plugin_dir():
            try:
                dest.unlink(missing_ok=True)
                # Only rmdir if empty
                if dest_dir.exists() and not any(dest_dir.iterdir()):
                    dest_dir.rmdir()
            except Exception:
                pass

        atexit.register(_cleanup_plugin_dir)
    print(f"  Plugin: installed {source.name} -> {dest}")


# Claude Code-specific flags that must not be forwarded to OpenCode
_CLAUDE_ONLY_FLAGS = frozenset(
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

_CLAUDE_FLAGS_WITH_VALUE = frozenset(
    {
        "--permission-mode",
        "--plugin-dir",
        "--mcp-config",
        "--system-prompt",
        "--name",
    }
)


def _filter_claude_args(args: list[str]) -> list[str]:
    """Remove Claude Code-specific flags from args for OpenCode compatibility."""
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


def build_opencode_args(
    resume_session_id: str | None,
    extra_args: list[str],
    model: str = "",
) -> list[str]:
    """Build the opencode CLI argument list.

    State principle: --session is passed when Emacs provides a session ID
    via OPENCODE_SESSION_ID org property (Emacs is the state owner).
    MCP and system-prompt are injected via files before this is called.
    Claude Code-specific flags are filtered from extra_args.
    """
    args = ["opencode"]

    # Session resume (OpenCode uses --session <id>, not --resume)
    if resume_session_id:
        args.extend(["--session", resume_session_id])

    # Optional model override (from AGENT_MODEL org property via env var)
    if model:
        args.extend(["--model", model])

    # Filter out Claude-only flags before forwarding
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
        "(let ((debug-on-error nil) (debug-on-quit nil))"
        "  (let* ((prompt (claude-org-workspace-bridge-system-prompt "
        f'    "{esc_org}" "{esc_sid}"))'
        f'         (story (with-current-buffer (claude-org-workspace-bridge--ensure-buffer "{esc_org}")'
        "            (save-excursion (save-restriction (widen)"
        f'              (claude-org-workspace-bridge--goto-session "{esc_sid}")'
        "              (substring-no-properties (org-get-heading t t t t)))))))"
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
    org_file, session_id, resume_id, extra_args = parse_args(sys.argv[1:])
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

    # Export env vars for hook scripts / bridge plugin
    os.environ["WORKSPACE_ORG_FILE"] = org_file
    os.environ["WORKSPACE_SESSION_ID"] = session_id or ""
    os.environ["EMACS_MCP_URL"] = mcp_url
    os.environ["CLAUDE_PLUGIN_ROOT"] = plugin_dir
    os.environ["AGENT_TYPE"] = "opencode"

    # OpenCode-specific env vars
    os.environ["OPENCODE_PERMISSION"] = json.dumps("allow")
    os.environ["OTUI_USE_ALTERNATE_SCREEN"] = "main-screen"

    # Set terminal tab title
    file_base = os.path.splitext(os.path.basename(org_file))[0]
    tab_title = f"{file_base}:{story_name or session_id or 'opencode'}"
    os.environ["WARP_DISABLE_AUTO_TITLE"] = "true"
    sys.stdout.write(f"\033]0;{tab_title}\007")
    sys.stdout.flush()

    # Inject MCP config into opencode.jsonc (OpenCode's mechanism)
    inject_emacs_mcp(project_root, mcp_url)

    # Inject system prompt via AGENTS.md (OpenCode's mechanism)
    if mcp_ok and _is_valid_session(system_prompt):
        write_agents_md(project_root, system_prompt)

    # Inject bridge plugin into .opencode/plugins/
    inject_bridge_plugin(plugin_dir, project_root)

    # Build opencode command
    args = build_opencode_args(
        resume_session_id=resume_id,
        extra_args=extra_args,
        model=model,
    )

    print("Starting OpenCode...")
    print(f"  Org file:   {org_file}")
    print(f"  Session ID: {session_id or 'none'}")
    print(f"  Resume ID:  {resume_id or 'none (fresh session)'}")
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
