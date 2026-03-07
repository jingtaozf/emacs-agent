#!/usr/bin/env python3
"""Layer 2: iTerm2 integration tests (real iTerm2, no Claude Code).

Tests tab lifecycle, screen reading, title matching, and tab reuse.

Prerequisites:
  pip3 install iterm2
  iTerm2 running with Python API enabled

Usage:
  python3 tests/test-iterm2-integration.py
"""

import asyncio
import json
import os
import subprocess
import sys

# Add project root to path
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(PROJECT_DIR, "tests", "helpers"))

from iterm2_fixtures import (
    TAB_PREFIX, check_prerequisites, cleanup_test_tabs,
    find_tab_by_title, get_screen_text,
)

import iterm2

CTL = os.path.join(PROJECT_DIR, "scripts", "iterm2-ctl.py")

PASS = 0
FAIL = 0
TESTS_RUN = 0


def run_ctl(*args, stdin_text=None, expect_rc=0):
    """Run iterm2-ctl.py with args, return stdout."""
    proc = subprocess.run(
        ["python3", CTL] + list(args),
        input=stdin_text,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if proc.returncode != expect_rc:
        raise AssertionError(
            f"iterm2-ctl {args[0]} returned {proc.returncode}, "
            f"expected {expect_rc}\nstderr: {proc.stderr}\nstdout: {proc.stdout}"
        )
    return proc.stdout.strip()


def run_test(name, func):
    global PASS, FAIL, TESTS_RUN
    TESTS_RUN += 1
    sys.stdout.write(f"  {name}... ")
    sys.stdout.flush()
    try:
        func()
        print("PASS")
        PASS += 1
    except Exception as e:
        print(f"FAIL: {e}")
        FAIL += 1


# -- Tests -------------------------------------------------------------------

# Store session ID across tests
_session_id = None
_title = f"{TAB_PREFIX}integration-test"


def test_launch_creates_tab():
    global _session_id
    out = run_ctl("launch", "--title", _title, "--cwd", "/tmp")
    assert out, "launch returned empty session ID"
    _session_id = out


def test_list_contains_session():
    out = run_ctl("list")
    sessions = json.loads(out)
    ids = [s["session_id"] for s in sessions]
    assert _session_id in ids, f"{_session_id} not in {ids}"


def test_status_not_dead():
    out = run_ctl("status", "--session", _session_id)
    data = json.loads(out)
    assert data["state"] != "dead", f"Expected not dead, got {data}"
    assert data["tab_title"] == _title, f"Title mismatch: {data['tab_title']}"


def test_send_and_read():
    """Test send/read by creating a plain shell tab (no Claude)."""
    global _shell_session_id
    _shell_title = f"{TAB_PREFIX}shell-test"

    # Create a plain shell tab via iTerm2 API directly
    import time

    async def create_shell(conn):
        app = await iterm2.async_get_app(conn)
        window = app.current_terminal_window
        if not window:
            window = await iterm2.Window.async_create(connection=conn)
        tab = await window.async_create_tab()
        await tab.async_set_title(_shell_title)
        session = tab.current_session
        return session.session_id

    result = [None]
    async def _run(conn):
        result[0] = await create_shell(conn)
    iterm2.run_until_complete(_run)
    _shell_session_id = result[0]

    time.sleep(1)  # wait for shell to start

    # Send echo via iterm2-ctl
    run_ctl("send", "--session", _shell_session_id,
            stdin_text="echo INTEGRATION_TEST_OK")
    time.sleep(1)
    out = run_ctl("read", "--session", _shell_session_id, "--lines", "10")
    assert "INTEGRATION_TEST_OK" in out, f"Echo not found in: {out[:200]}"

    # Clean up shell tab
    run_ctl("close", "--session", _shell_session_id)


def test_tab_reuse_by_title():
    out = run_ctl("launch", "--title", _title, "--cwd", "/tmp")
    assert out == _session_id, f"Expected reuse {_session_id}, got {out}"


def test_focus():
    out = run_ctl("focus", "--session", _session_id)
    assert out == "ok"


def test_dead_session_status():
    out = run_ctl("status", "--session", "NONEXISTENT-SESSION-ID-12345")
    data = json.loads(out)
    assert data["state"] == "dead", f"Expected dead, got {data}"


def test_close():
    out = run_ctl("close", "--session", _session_id)
    assert out == "ok"
    import time; time.sleep(1)
    out = run_ctl("status", "--session", _session_id)
    data = json.loads(out)
    assert data["state"] == "dead", f"Expected dead after close, got {data}"


# -- Main --------------------------------------------------------------------

def main():
    check_prerequisites(need_claude=False)
    print("=" * 60)
    print("Layer 2: iTerm2 Integration Tests")
    print("=" * 60)

    # Cleanup any leftover test tabs
    async def pre_cleanup(conn):
        app = await iterm2.async_get_app(conn)
        closed = await cleanup_test_tabs(app)
        if closed:
            print(f"  (cleaned up {closed} leftover test tabs)")

    try:
        iterm2.run_until_complete(pre_cleanup)
    except Exception:
        pass

    run_test("test_launch_creates_tab", test_launch_creates_tab)
    run_test("test_list_contains_session", test_list_contains_session)
    run_test("test_status_not_dead", test_status_not_dead)
    run_test("test_send_and_read", test_send_and_read)
    run_test("test_tab_reuse_by_title", test_tab_reuse_by_title)
    run_test("test_focus", test_focus)
    run_test("test_dead_session_status", test_dead_session_status)
    run_test("test_close", test_close)

    print()
    print(f"Results: {PASS} passed, {FAIL} failed, {TESTS_RUN} total")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
