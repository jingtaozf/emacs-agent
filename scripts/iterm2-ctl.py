#!/usr/bin/env python3
"""iTerm2 control tool for Claude Code — stateless CLI.

Each invocation connects to iTerm2, performs one action, exits.
Designed to be called from Emacs via call-process.

Prerequisites:
  pip3 install iterm2
  iTerm2 → Settings → General → Magic → Enable Python API

Usage:
  iterm2-ctl.py launch --title "my story" --cwd /project [--system-prompt-file /tmp/sp.txt] [--resume ID]
  iterm2-ctl.py send --session <ID> < prompt.txt
  iterm2-ctl.py cancel --session <ID>
  iterm2-ctl.py status --session <ID>
  iterm2-ctl.py read --session <ID> [--lines 50]
  iterm2-ctl.py focus --session <ID>
  iterm2-ctl.py close --session <ID>
  iterm2-ctl.py list

Exit codes:
  0 = success (result on stdout)
  1 = iTerm2 not running or API not enabled
  2 = session not found
  3 = Claude Code not ready (for send with --wait)
"""

import argparse
import asyncio
import json
import os
import re
import sys

import iterm2

# -- Constants ---------------------------------------------------------------

CLAUDE_READY_PATTERNS = [
    "type a message", "type your", "tips:",
    "claude code", "sonnet", "opus", "haiku",
]

WAIT_FOR_READY_TIMEOUT = 20  # seconds
POLL_INTERVAL = 1  # seconds


# -- Screen helpers ----------------------------------------------------------

async def get_screen_text(session, max_lines=50):
    """Read visible screen content as a single string."""
    info = await session.async_get_line_info()
    first = info.overflow
    total = info.scrollback_buffer_height + info.mutable_area_height
    contents = await session.async_get_contents(first, min(total, max_lines))
    return "\n".join(line.string.rstrip() for line in contents)


async def detect_state(session):
    """Detect Claude Code state: 'ready', 'busy', or 'dead'.

    Reads the visible mutable area (not scrollback) to detect the
    current state of the Claude Code TUI.

    IMPORTANT: Default is 'dead' (no Claude evidence), NOT 'busy'.
    Only returns 'busy' when positive Claude TUI indicators are found.
    This prevents stale shell tabs from being mistaken for active Claude.
    """
    try:
        info = await session.async_get_line_info()
        # Read the mutable area (visible terminal, not scrollback)
        mutable_start = info.overflow + info.scrollback_buffer_height
        mutable_count = info.mutable_area_height
        if mutable_count <= 0:
            return "dead"
        contents = await session.async_get_contents(
            mutable_start, mutable_count)
        text = "\n".join(line.string.rstrip() for line in contents)
    except Exception:
        return "dead"
    if not text.strip():
        return "dead"
    lower = text.lower()

    # Check bottom lines for specific indicators
    bottom_lines = [l.strip() for l in text.split("\n") if l.strip()]
    if bottom_lines:
        last = bottom_lines[-1]
        # "-- INSERT --" at bottom means Claude Code is at input prompt
        if "-- insert --" in last.lower():
            return "ready"
        # Shell prompt at bottom → Claude exited, shell is waiting
        # Check BEFORE TUI indicators because Claude's farewell message
        # leaves box-drawing chars (╭╰│) in the mutable area above the
        # shell prompt, which would falsely match as "busy".
        if _looks_like_shell_prompt(last):
            return "dead"

    # Check for Claude Code ready patterns (input prompt visible)
    if any(p in lower for p in CLAUDE_READY_PATTERNS):
        return "ready"

    # Trust prompt counts as "busy" (waiting for user action)
    if any(p in lower for p in TRUST_PROMPT_PATTERNS):
        return "busy"

    # Positive evidence of Claude TUI: box-drawing chars, tool activity
    if any(indicator in text for indicator in CLAUDE_TUI_INDICATORS):
        return "busy"

    # No Claude evidence — assume shell or dead process
    return "dead"


def _looks_like_shell_prompt(line):
    """Check if a line looks like a shell prompt.

    After Claude exits, the terminal returns to the shell. The last
    non-empty line will be a shell prompt. We check for common prompt
    endings: $, %, ❯, >, #, and path-like patterns (~/...).
    """
    stripped = line.rstrip()
    if not stripped:
        return False
    # Common prompt endings (after stripping ANSI escape sequences)
    clean = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', stripped).rstrip()
    if not clean:
        return False
    # Check last character for common prompt indicators
    if clean[-1] in ('$', '%', '>', '#', '❯', '➜'):
        return True
    # Starship/powerline prompts often end with these
    if clean.endswith('❯') or clean.endswith('➜'):
        return True
    return False


# Box-drawing and TUI elements that Claude Code renders
CLAUDE_TUI_INDICATORS = [
    "╭", "╰", "│",       # Claude Code box-drawing frame
    "⏺",                  # Claude activity spinner
    "Tool:",              # Tool use header
]


TRUST_PROMPT_PATTERNS = [
    "trust this folder",
    "yes, i trust",
    "no, exit",
]


async def wait_for_ready(session, timeout=WAIT_FOR_READY_TIMEOUT):
    """Wait for Claude Code to reach the input prompt.

    Automatically handles the trust folder prompt if it appears.
    """
    elapsed = 0
    trust_handled = False
    while elapsed < timeout:
        try:
            text = await get_screen_text(session, max_lines=20)
        except Exception:
            await asyncio.sleep(POLL_INTERVAL)
            elapsed += POLL_INTERVAL
            continue

        lower = text.lower()

        # Handle trust prompt
        if not trust_handled and any(p in lower for p in TRUST_PROMPT_PATTERNS):
            # Send "1" to accept trust, then Enter
            await session.async_send_text("1")
            await asyncio.sleep(0.5)
            trust_handled = True
            continue

        # Check for ready state
        if any(p in lower for p in CLAUDE_READY_PATTERNS):
            return True

        await asyncio.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL
    return False


# -- Session lookup ----------------------------------------------------------

async def find_session_and_tab(app, session_id):
    """Find session and its parent tab by session ID."""
    for window in app.terminal_windows:
        for tab in window.tabs:
            for session in tab.sessions:
                if session.session_id == session_id:
                    return session, tab
    return None, None


async def find_tab_by_title(app, title):
    """Search all windows/tabs for matching titleOverride."""
    for window in app.terminal_windows:
        for tab in window.tabs:
            t_title = await tab.async_get_variable("titleOverride")
            if t_title == title:
                return tab
    return None


# -- Subcommands -------------------------------------------------------------

async def cmd_launch(app, args):
    """Find or create tab, launch Claude Code, return session ID."""
    # 1. Search existing tabs by title
    existing_tab = await find_tab_by_title(app, args.title)
    if existing_tab:
        session = existing_tab.current_session
        state = await detect_state(session)
        if state in ("ready", "busy"):
            # Claude alive (at prompt or processing) — reuse directly
            print(session.session_id)
            return 0
        # state == "dead": tab exists but Claude not running
        # Reuse this tab — launch Claude in it below
        tab = existing_tab
    else:
        # 2. No matching tab — create new one
        window = app.current_terminal_window
        if not window:
            window = await iterm2.Window.async_create(
                connection=app._connection)
            if not window:
                print("Failed to create iTerm2 window", file=sys.stderr)
                return 1
        tab = await window.async_create_tab()
        await tab.async_set_title(args.title)

    session = tab.current_session

    # 3. Build launch command
    cmd_parts = []
    if args.cwd:
        cmd_parts.append(f"cd {_shell_quote(args.cwd)} &&")

    if args.launch_cmd:
        # Custom command — use as-is (e.g. claude-sdd with full args)
        cmd_parts.append(args.launch_cmd)
    else:
        # Default: bare claude with optional flags
        cmd_parts.append("claude")
        if args.system_prompt_file:
            cmd_parts.append(
                f"--system-prompt \"$(cat {_shell_quote(args.system_prompt_file)})\""
            )
        if args.resume:
            cmd_parts.append(f"--resume {_shell_quote(args.resume)}")

    cmd = " ".join(cmd_parts)
    await session.async_send_text(cmd + "\n")

    # 4. Wait for ready
    ready = await wait_for_ready(session, timeout=WAIT_FOR_READY_TIMEOUT)
    if not ready:
        # Still return session ID — caller can retry later
        print(f"Warning: Claude Code not ready within {WAIT_FOR_READY_TIMEOUT}s",
              file=sys.stderr)

    print(session.session_id)
    return 0


async def cmd_send(app, args):
    """Send prompt (from stdin) to Claude Code via bracketed paste."""
    session, tab = await find_session_and_tab(app, args.session)
    if not session:
        print(f"Session not found: {args.session}", file=sys.stderr)
        return 2

    # Read prompt from stdin
    prompt = sys.stdin.read()
    if not prompt.strip():
        print("Empty prompt on stdin", file=sys.stderr)
        return 1

    # Bracketed paste mode — safe for multi-line content
    await session.async_send_text(f"\x1b[200~{prompt}\x1b[201~")
    await asyncio.sleep(0.3)
    # Press Enter to submit
    await session.async_send_text("\r")

    print("ok")
    return 0


async def cmd_cancel(app, args):
    """Send Escape to interrupt Claude Code."""
    session, tab = await find_session_and_tab(app, args.session)
    if not session:
        result = {"result": "dead"}
        print(json.dumps(result))
        return 2

    # Send Escape
    await session.async_send_text("\x1b")
    await asyncio.sleep(0.5)

    state = await detect_state(session)
    result = {"result": "ok", "state": state}
    print(json.dumps(result))
    return 0


async def cmd_status(app, args):
    """Check Claude Code state, return JSON."""
    session, tab = await find_session_and_tab(app, args.session)
    if not session:
        print(json.dumps({"state": "dead"}))
        return 0  # not an error — caller checks state field

    state = await detect_state(session)
    tab_title = ""
    if tab:
        tab_title = await tab.async_get_variable("titleOverride") or ""

    result = {
        "state": state,
        "session_id": args.session,
        "tab_title": tab_title,
    }
    print(json.dumps(result))
    return 0


async def cmd_read(app, args):
    """Read last N lines from terminal screen."""
    session, tab = await find_session_and_tab(app, args.session)
    if not session:
        print(f"Session not found: {args.session}", file=sys.stderr)
        return 2

    text = await get_screen_text(session, max_lines=args.lines)
    print(text)
    return 0


async def cmd_focus(app, args):
    """Activate tab and bring iTerm2 to front."""
    session, tab = await find_session_and_tab(app, args.session)
    if not session or not tab:
        print(f"Session not found: {args.session}", file=sys.stderr)
        return 2

    await tab.async_select()
    await app.async_activate()
    print("ok")
    return 0


async def cmd_close(app, args):
    """Send /exit to Claude Code and close the tab."""
    session, tab = await find_session_and_tab(app, args.session)
    if not session:
        print(f"Session not found: {args.session}", file=sys.stderr)
        return 2

    # Send /exit to Claude Code, then exit shell
    await session.async_send_text("\x1b")  # Escape first (cancel if busy)
    await asyncio.sleep(0.3)
    await session.async_send_text("/exit\r")
    await asyncio.sleep(1)
    await session.async_send_text("exit\n")
    await asyncio.sleep(1)

    # If tab is still there, close it via API
    try:
        if tab:
            await tab.async_close(force=True)
    except Exception:
        pass

    print("ok")
    return 0


async def cmd_list(app, args):
    """List all iTerm2 sessions with their tab titles."""
    sessions = []
    for window in app.terminal_windows:
        for tab in window.tabs:
            title = await tab.async_get_variable("titleOverride") or ""
            for session in tab.sessions:
                sessions.append({
                    "session_id": session.session_id,
                    "tab_title": title,
                    "tab_id": tab.tab_id,
                })
    print(json.dumps(sessions))
    return 0


# -- Utilities ---------------------------------------------------------------

def _shell_quote(s):
    """Shell-quote a string for embedding in a command."""
    return "'" + s.replace("'", "'\\''") + "'"


# -- Argument parsing --------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        description="iTerm2 control tool for Claude Code")
    sub = parser.add_subparsers(dest="command", required=True)

    # launch
    p = sub.add_parser("launch", help="Find or create tab, launch Claude Code")
    p.add_argument("--title", required=True, help="Tab title (used for reuse)")
    p.add_argument("--cwd", help="Working directory")
    p.add_argument("--launch-cmd", dest="launch_cmd",
                       help="Full shell command to run (overrides default claude)")
    p.add_argument("--system-prompt-file", help="Path to system prompt file")
    p.add_argument("--resume", help="Claude CLI session ID to resume")

    # send
    p = sub.add_parser("send", help="Send prompt from stdin to Claude Code")
    p.add_argument("--session", required=True, help="iTerm2 session ID")

    # cancel
    p = sub.add_parser("cancel", help="Send Escape to interrupt Claude Code")
    p.add_argument("--session", required=True, help="iTerm2 session ID")

    # status
    p = sub.add_parser("status", help="Check Claude Code state")
    p.add_argument("--session", required=True, help="iTerm2 session ID")

    # read
    p = sub.add_parser("read", help="Read terminal screen content")
    p.add_argument("--session", required=True, help="iTerm2 session ID")
    p.add_argument("--lines", type=int, default=50, help="Max lines to read")

    # focus
    p = sub.add_parser("focus", help="Activate tab and bring iTerm2 to front")
    p.add_argument("--session", required=True, help="iTerm2 session ID")

    # close
    p = sub.add_parser("close", help="Send /exit and close tab")
    p.add_argument("--session", required=True, help="iTerm2 session ID")

    # list
    sub.add_parser("list", help="List all sessions")

    return parser


# -- Main entry point --------------------------------------------------------

COMMANDS = {
    "launch": cmd_launch,
    "send": cmd_send,
    "cancel": cmd_cancel,
    "status": cmd_status,
    "read": cmd_read,
    "focus": cmd_focus,
    "close": cmd_close,
    "list": cmd_list,
}


async def main_async(connection, args):
    app = await iterm2.async_get_app(connection)
    # Store connection on app so subcommands can access it
    app._connection = connection
    handler = COMMANDS[args.command]
    exit_code = await handler(app, args)
    return exit_code


def main():
    parser = build_parser()
    args = parser.parse_args()

    exit_code = [0]

    async def run(connection):
        exit_code[0] = await main_async(connection, args)

    try:
        iterm2.run_until_complete(run)
    except Exception as e:
        msg = str(e).lower()
        if "refused" in msg or "connect" in msg:
            print("Cannot connect to iTerm2. Ensure:", file=sys.stderr)
            print("  1. iTerm2 is running", file=sys.stderr)
            print("  2. Settings > General > Magic > Enable Python API",
                  file=sys.stderr)
            sys.exit(1)
        raise

    sys.exit(exit_code[0])


if __name__ == "__main__":
    main()
