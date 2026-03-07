"""Shared test fixtures for iTerm2 backend tests.

Provides common primitives for screen reading, ready detection,
tab management, and test isolation.
"""

import asyncio
import re
import sys

TAB_PREFIX = "test-harness:"
SIMPLE_PROMPT = "what is 2+2? answer in one word only"
EXPECTED_ANSWER_RE = re.compile(r"(?i)\b(four|4)\b")

CLAUDE_READY_PATTERNS = [
    "type a message", "type your", "tips:",
    "claude code", "sonnet", "opus", "haiku",
]

WAIT_FOR_READY = 20
WAIT_FOR_RESPONSE = 90
POLL_INTERVAL = 1


async def get_screen_text(session, max_lines=50):
    """Read visible screen content as a single string."""
    info = await session.async_get_line_info()
    first = info.overflow
    total = info.scrollback_buffer_height + info.mutable_area_height
    contents = await session.async_get_contents(first, min(total, max_lines))
    return "\n".join(line.string.rstrip() for line in contents)


async def is_claude_ready(session):
    """Check if Claude Code is at the input prompt."""
    text = await get_screen_text(session, max_lines=10)
    lower = text.lower()
    return any(p in lower for p in CLAUDE_READY_PATTERNS)


async def detect_state(session):
    """Detect Claude Code state from screen content.

    Returns: "ready", "busy", or "dead".
    """
    try:
        text = await get_screen_text(session, max_lines=10)
    except Exception:
        return "dead"
    if not text.strip():
        return "dead"
    lower = text.lower()
    if any(p in lower for p in CLAUDE_READY_PATTERNS):
        return "ready"
    return "busy"


async def wait_for_ready(session, timeout=WAIT_FOR_READY):
    """Wait for Claude Code to reach the input prompt."""
    elapsed = 0
    while elapsed < timeout:
        if await is_claude_ready(session):
            return True
        await asyncio.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL
    return False


async def wait_for_screen_stable(session, timeout=WAIT_FOR_RESPONSE,
                                  min_stable=3):
    """Wait for screen content to stabilize (response finished)."""
    elapsed = 0
    prev_text = ""
    stable_count = 0
    while elapsed < timeout:
        text = await get_screen_text(session, max_lines=80)
        if text == prev_text and text.strip():
            stable_count += 1
            if stable_count >= min_stable:
                return text
        else:
            stable_count = 0
        prev_text = text
        await asyncio.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL
    return prev_text


async def find_tab_by_title(app, title):
    """Search all windows/tabs for matching titleOverride."""
    for window in app.terminal_windows:
        for tab in window.tabs:
            t_title = await tab.async_get_variable("titleOverride")
            if t_title == title:
                return tab
    return None


async def find_session_and_tab(app, session_id):
    """Find session and its parent tab by session ID."""
    for window in app.terminal_windows:
        for tab in window.tabs:
            for session in tab.sessions:
                if session.session_id == session_id:
                    return session, tab
    return None, None


async def cleanup_test_tabs(app):
    """Close all tabs with test-harness: prefix."""
    closed = 0
    for window in app.terminal_windows:
        for tab in window.tabs:
            title = await tab.async_get_variable("titleOverride")
            if title and title.startswith(TAB_PREFIX):
                try:
                    await tab.current_session.async_send_text("exit\n")
                    closed += 1
                    await asyncio.sleep(0.3)
                except Exception:
                    pass
    return closed


def check_prerequisites(need_claude=False):
    """Verify test environment. Exits 77 (skip) if missing."""
    missing = []
    try:
        import iterm2  # noqa: F401
    except ImportError:
        missing.append("iterm2 python package")

    if need_claude:
        import shutil
        if not shutil.which("claude"):
            missing.append("claude CLI")

    if missing:
        print(f"SKIP: Missing prerequisites: {', '.join(missing)}")
        sys.exit(77)
