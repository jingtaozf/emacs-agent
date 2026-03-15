#!/usr/bin/env python3
"""
iTerm2 Python API Demo — programmatic terminal control.

Prerequisites:
  1. pip3 install iterm2
  2. iTerm2 → Settings → General → Magic → Enable Python API (checkbox)
  3. iTerm2 must be running

Usage:
  python3 scripts/iterm2-demo.py
"""

import asyncio
import iterm2


async def demo(connection):
    app = await iterm2.async_get_app(connection)
    window = app.current_terminal_window

    if not window:
        print("ERROR: No iTerm2 window found. Open iTerm2 first.")
        return

    # ── 1. Create a new tab ──────────────────────────────────────────
    print("1. Creating new tab...")
    tab = await window.async_create_tab()
    session = tab.current_session
    print(f"   Session ID: {session.session_id}")

    # ── 2. Set tab title ─────────────────────────────────────────────
    print("2. Setting tab title...")
    await tab.async_set_title("🤖 iTerm2 Demo")

    # ── 3. Send commands ─────────────────────────────────────────────
    print("3. Sending commands...")
    await session.async_send_text("echo 'Hello from iTerm2 Python API!'\n")
    await asyncio.sleep(0.5)  # wait for output

    await session.async_send_text("date\n")
    await asyncio.sleep(0.5)

    await session.async_send_text("echo '--- Multi-line paste demo ---'\n")
    await asyncio.sleep(0.3)

    # ── 4. Read screen content ───────────────────────────────────────
    print("4. Reading screen content...")
    line_info = await session.async_get_line_info()
    first = line_info.overflow
    num_lines = line_info.scrollback_buffer_height + line_info.mutable_area_height
    contents = await session.async_get_contents(first, min(num_lines, 50))
    print("   Screen content (last 8 non-empty lines):")
    non_empty = [l.string.rstrip() for l in contents if l.string.strip()]
    for text in non_empty[-8:]:
        print(f"   │ {text}")

    # ── 5. Split pane ────────────────────────────────────────────────
    print("5. Splitting pane horizontally...")
    right_session = await session.async_split_pane(vertical=True)
    await right_session.async_send_text("echo 'Right pane!'\n")
    await asyncio.sleep(0.3)

    # ── 6. Read right pane ───────────────────────────────────────────
    print("6. Reading right pane...")
    rinfo = await right_session.async_get_line_info()
    rfirst = rinfo.overflow
    rcount = rinfo.scrollback_buffer_height + rinfo.mutable_area_height
    right_contents = await right_session.async_get_contents(rfirst, min(rcount, 20))
    non_empty_r = [l.string.rstrip() for l in right_contents if l.string.strip()]
    for text in non_empty_r[-4:]:
        print(f"   │ {text}")

    # ── 7. Get all sessions info ─────────────────────────────────────
    print("7. Listing all sessions...")
    for w in app.terminal_windows:
        for t in w.tabs:
            for s in t.sessions:
                print(f"   Window={w.window_id} Tab={t.tab_id} "
                      f"Session={s.session_id} "
                      f"Name={s.name}")

    # ── 8. Profile inspection ────────────────────────────────────────
    print("8. Reading session profile...")
    profile = await session.async_get_profile()
    print(f"   Font: {profile.normal_font}")
    # Get terminal size from session variables
    cols = await session.async_get_variable("columns")
    rows = await session.async_get_variable("rows")
    print(f"   Rows: {rows}, Cols: {cols}")

    print("\n✅ Demo complete! Check iTerm2 for the new tab with split panes.")
    print("   Close the demo tab manually when done.")


async def main():
    print("Connecting to iTerm2...")
    print("(Make sure Python API is enabled: Settings → General → Magic)\n")
    try:
        connection = await iterm2.Connection.async_create()
        await demo(connection)
    except Exception as e:
        if "ConnectionRefused" in type(e).__name__ or "connection" in str(e).lower():
            print("ERROR: Connection refused. Enable the Python API in iTerm2:")
            print("  Settings → General → Magic → Enable Python API")
        else:
            print(f"ERROR: {type(e).__name__}: {e}")
            print("\nIf iTerm2 is not running or API not enabled:")
            print("  1. Open iTerm2")
            print("  2. Go to Settings → General → Magic")
            print("  3. Check 'Enable Python API'")


if __name__ == "__main__":
    asyncio.run(main())
