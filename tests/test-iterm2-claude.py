#!/usr/bin/env python3
"""Layer 3: iTerm2 + Claude Code integration tests.

Tests launching Claude Code in iTerm2, sending prompts, status
detection, cancel, and tab reuse.

Prerequisites:
  pip3 install iterm2
  iTerm2 running with Python API enabled
  Claude Code CLI installed (claude command)

Usage:
  python3 tests/test-iterm2-claude.py
"""

import json
import os
import subprocess
import sys
import time

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(PROJECT_DIR, "tests", "helpers"))

from iterm2_fixtures import (
    TAB_PREFIX, SIMPLE_PROMPT, EXPECTED_ANSWER_RE,
    check_prerequisites, cleanup_test_tabs,
    WAIT_FOR_READY, WAIT_FOR_RESPONSE, POLL_INTERVAL,
)

import iterm2

CTL = os.path.join(PROJECT_DIR, "scripts", "iterm2-ctl.py")

PASS = 0
FAIL = 0
TESTS_RUN = 0

# Shared state
_title = f"{TAB_PREFIX}claude-test"
_session_id = None


def run_ctl(*args, stdin_text=None, expect_rc=0, timeout=30):
    """Run iterm2-ctl.py with args, return stdout."""
    proc = subprocess.run(
        ["python3", CTL] + list(args),
        input=stdin_text,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != expect_rc:
        raise AssertionError(
            f"iterm2-ctl {args[0]} returned {proc.returncode}, "
            f"expected {expect_rc}\nstderr: {proc.stderr}\n"
            f"stdout: {proc.stdout}"
        )
    return proc.stdout.strip()


def wait_for_status(session_id, target_state, timeout=60):
    """Poll status until target_state or timeout."""
    elapsed = 0
    while elapsed < timeout:
        out = run_ctl("status", "--session", session_id)
        data = json.loads(out)
        if data["state"] == target_state:
            return data
        time.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL
    raise TimeoutError(
        f"Status did not reach '{target_state}' within {timeout}s. "
        f"Last: {data}"
    )


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

def test_launch_claude():
    """Launch Claude Code in iTerm2 tab."""
    global _session_id
    out = run_ctl("launch", "--title", _title, "--cwd", "/tmp",
                  timeout=60)
    assert out, "launch returned empty session ID"
    _session_id = out
    print(f"(session: {_session_id[:8]}...) ", end="")


def test_ready_detection():
    """Wait for Claude Code to reach input prompt."""
    data = wait_for_status(_session_id, "ready", timeout=WAIT_FOR_READY + 10)
    assert data["state"] == "ready"


def test_send_and_busy():
    """Send prompt, verify busy state (if fast enough to catch)."""
    run_ctl("send", "--session", _session_id, stdin_text=SIMPLE_PROMPT)
    # Try to catch busy state — may be too fast for simple question
    out = run_ctl("status", "--session", _session_id)
    data = json.loads(out)
    # Either busy (caught it) or ready (already done) is ok
    assert data["state"] in ("busy", "ready"), f"Unexpected: {data}"


def test_response_completes():
    """Wait for response to complete, verify answer."""
    data = wait_for_status(_session_id, "ready", timeout=WAIT_FOR_RESPONSE)
    assert data["state"] == "ready"
    # Read screen and check for expected answer
    out = run_ctl("read", "--session", _session_id, "--lines", "30")
    assert EXPECTED_ANSWER_RE.search(out), (
        f"Expected 'four' or '4' in response, got: {out[-200:]}"
    )


def test_cancel_instruction():
    """Send slow prompt, then cancel."""
    run_ctl("send", "--session", _session_id,
            stdin_text="Write a detailed 2000 word essay about the history "
                       "of mathematics from ancient Babylon to modern day")
    time.sleep(3)  # let Claude start responding
    out = run_ctl("cancel", "--session", _session_id)
    data = json.loads(out)
    assert data["result"] == "ok", f"Cancel failed: {data}"
    # Wait for ready state (may take a moment after cancel)
    wait_for_status(_session_id, "ready", timeout=15)


def test_reuse_existing_tab():
    """Second launch with same title returns same session."""
    out = run_ctl("launch", "--title", _title, "--cwd", "/tmp",
                  timeout=30)
    assert out == _session_id, f"Expected reuse {_session_id}, got {out}"


def test_screen_read():
    """Read screen content returns non-empty text."""
    out = run_ctl("read", "--session", _session_id, "--lines", "20")
    assert out.strip(), "Screen read returned empty"
    assert len(out) > 10, f"Screen too short: {out}"


def test_close_claude():
    """Close Claude Code and tab."""
    out = run_ctl("close", "--session", _session_id, timeout=15)
    assert out == "ok"
    time.sleep(1)
    out = run_ctl("status", "--session", _session_id)
    data = json.loads(out)
    assert data["state"] == "dead", f"Expected dead, got {data}"


# -- Main --------------------------------------------------------------------

def main():
    check_prerequisites(need_claude=True)
    print("=" * 60)
    print("Layer 3: iTerm2 + Claude Code Tests")
    print("=" * 60)

    # Cleanup leftover test tabs
    async def pre_cleanup(conn):
        app = await iterm2.async_get_app(conn)
        closed = await cleanup_test_tabs(app)
        if closed:
            print(f"  (cleaned up {closed} leftover test tabs)")
    try:
        iterm2.run_until_complete(pre_cleanup)
    except Exception:
        pass

    run_test("test_launch_claude", test_launch_claude)
    run_test("test_ready_detection", test_ready_detection)
    run_test("test_send_and_busy", test_send_and_busy)
    run_test("test_response_completes", test_response_completes)
    run_test("test_cancel_instruction", test_cancel_instruction)
    run_test("test_reuse_existing_tab", test_reuse_existing_tab)
    run_test("test_screen_read", test_screen_read)
    run_test("test_close_claude", test_close_claude)

    print()
    print(f"Results: {PASS} passed, {FAIL} failed, {TESTS_RUN} total")

    # Save fixture data from this run
    fixtures_dir = os.path.join(PROJECT_DIR, "tests", "fixtures", "iterm2")
    os.makedirs(fixtures_dir, exist_ok=True)
    with open(os.path.join(fixtures_dir, "test-run-summary.json"), "w") as f:
        json.dump({"pass": PASS, "fail": FAIL, "total": TESTS_RUN}, f)

    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
