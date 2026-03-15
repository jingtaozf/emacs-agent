#!/usr/bin/env python3
"""
Test: Launch Claude Code in iTerm2, send a prompt, and read back output.

Prerequisites:
  1. pip3 install iterm2
  2. iTerm2 → Settings → General → Magic → Enable Python API
  3. Claude Code CLI installed (claude command available)

Usage:
  python3 scripts/iterm2-claude-test.py
"""

import asyncio
import sys
import iterm2


PROMPT = "what is 2+2? answer in one word only"
WAIT_FOR_READY = 15   # seconds to wait for Claude Code to start
WAIT_FOR_RESPONSE = 60  # seconds to wait for response
POLL_INTERVAL = 1       # seconds between screen polls


async def get_screen_text(session, max_lines=50):
    """Read visible screen content as a single string."""
    info = await session.async_get_line_info()
    first = info.overflow
    total = info.scrollback_buffer_height + info.mutable_area_height
    contents = await session.async_get_contents(first, min(total, max_lines))
    return "\n".join(line.string.rstrip() for line in contents)


async def wait_for_pattern(session, pattern, timeout, label=""):
    """Poll screen until pattern appears or timeout."""
    elapsed = 0
    while elapsed < timeout:
        text = await get_screen_text(session)
        if pattern in text:
            return text
        await asyncio.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL
        if elapsed % 5 == 0:
            print(f"   ... waiting for {label} ({elapsed}s)")
    return None


async def test_claude_in_iterm(connection):
    app = await iterm2.async_get_app(connection)
    window = app.current_terminal_window

    if not window:
        print("ERROR: No iTerm2 window. Open iTerm2 first.")
        return False

    # ── 1. Create a dedicated tab ────────────────────────────────────
    print("1. Creating tab for Claude Code...")
    tab = await window.async_create_tab()
    session = tab.current_session
    await tab.async_set_title("🤖 Claude Test")
    print(f"   Session: {session.session_id}")

    # ── 2. Launch Claude Code in interactive mode ────────────────────
    print("2. Launching Claude Code...")
    await session.async_send_text("claude\n")

    # ── 3. Wait for Claude Code to be ready ──────────────────────────
    # Claude Code shows a text input area. We detect readiness by
    # looking for typical startup text like "Claude" or the input hint.
    print(f"3. Waiting for Claude Code to start (up to {WAIT_FOR_READY}s)...")
    # Claude Code TUI shows various patterns when ready:
    # - "Type your prompt" or ">" or the model name
    ready_text = None
    elapsed = 0
    while elapsed < WAIT_FOR_READY:
        text = await get_screen_text(session, 40)
        # Claude Code shows tips, model info, or input prompt when ready
        if any(p in text.lower() for p in [
            "type a message", "type your", "tips:",
            "claude code", "sonnet", "opus", "haiku",
        ]):
            ready_text = text
            break
        await asyncio.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL
        if elapsed % 5 == 0:
            print(f"   ... waiting ({elapsed}s)")

    if ready_text:
        print("   ✓ Claude Code is ready")
    else:
        print("   ⚠ Could not detect ready state, trying to send anyway...")

    # ── 4. Send the prompt ───────────────────────────────────────────
    print(f"4. Sending prompt: '{PROMPT}'")
    # Use send_text — Claude Code accepts typed input
    await session.async_send_text(PROMPT)
    await asyncio.sleep(0.3)
    # Press Enter to submit
    await session.async_send_text("\r")

    # ── 5. Wait for response ─────────────────────────────────────────
    print(f"5. Waiting for response (up to {WAIT_FOR_RESPONSE}s)...")
    # Wait for screen to stabilize — Claude Code is done when the
    # screen content stops changing for a few polls.
    await asyncio.sleep(3)  # give it time to start processing

    response_text = None
    elapsed = 0
    prev_text = ""
    stable_count = 0

    while elapsed < WAIT_FOR_RESPONSE:
        text = await get_screen_text(session, 80)

        # Screen stabilized = Claude finished responding
        if text == prev_text and len(text.strip()) > 0:
            stable_count += 1
            if stable_count >= 3:
                response_text = text
                break
        else:
            stable_count = 0

        prev_text = text
        await asyncio.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL
        if elapsed % 10 == 0:
            print(f"   ... waiting ({elapsed}s)")

    # ── 6. Display results ───────────────────────────────────────────
    print("\n" + "=" * 60)
    print("SCREEN CONTENT:")
    print("=" * 60)
    final_text = response_text or await get_screen_text(session, 80)
    # Show only the interesting part (after our prompt)
    lines = final_text.split("\n")
    for line in lines:
        if line.strip():
            print(f"  {line}")

    print("=" * 60)

    # ── 7. Check for expected answer ─────────────────────────────────
    lower = final_text.lower() if final_text else ""
    # Look for "four" or standalone "4" (not in timestamps like 09:34:18)
    import re
    has_four = "four" in lower
    has_4 = bool(re.search(r'(?<!\d)4(?!\d|:)', final_text or ""))
    if has_four or has_4:
        print("\n✅ SUCCESS: Claude responded correctly!")
        success = True
    else:
        print("\n⚠ Could not verify '4' or 'four' in response.")
        print("   Check the iTerm2 tab manually.")
        success = False

    # ── 8. Clean exit — send /exit to Claude Code ────────────────────
    print("\n8. Sending /exit to Claude Code...")
    await session.async_send_text("/exit\r")
    await asyncio.sleep(2)

    print("   Done. Demo tab left open for inspection.")
    return success


async def main():
    print("=" * 60)
    print("iTerm2 + Claude Code Integration Test")
    print("=" * 60)
    print()

    try:
        conn = await iterm2.Connection.async_create()
        success = await test_claude_in_iterm(conn)
        sys.exit(0 if success else 1)
    except Exception as e:
        print(f"\nERROR: {type(e).__name__}: {e}")
        if "refused" in str(e).lower() or "connect" in str(e).lower():
            print("\nEnable iTerm2 Python API:")
            print("  Settings → General → Magic → Enable Python API")
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
