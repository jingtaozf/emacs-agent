#!/usr/bin/env python3
"""mock-claude-cli-v2.py — Drop-in replacement for `claude` CLI for testing.

Speaks the identical JSON-over-pipe protocol:
  stdin:  newline-delimited JSON (control_request init, user messages)
  stdout: newline-delimited JSON (system/init, assistant, result)

Behaviour is controlled by the MOCK_SCENARIO environment variable,
which selects a fixture file from mock-scenarios/<name>.jsonl.

The fixture format is plain JSONL with extensions:
  Lines starting with "DELAY:<seconds>" insert a sleep.
  Lines starting with "#CRASH" exit with signal immediately.
  Lines starting with "#DELAY <ms>" wait before next line (ms precision).
  Lines starting with "#WAIT_FOR_INPUT" read stdin before continuing.
  Lines starting with "#EXIT <code>" exit with specific code.
  Lines starting with "#MALFORMED" output invalid JSON on next line.

Exit codes match real CLI:
  0 = normal exit after outputting result
  Signal deaths propagate naturally (SIGINT=130, SIGKILL=137)
"""

import json
import os
import signal
import sys
import time


def parse_args(argv):
    """Parse CLI arguments, mimicking real claude arg parsing."""
    resume_id = ""
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--resume":
            if i + 1 < len(argv):
                resume_id = argv[i + 1]
                i += 2
            else:
                i += 1
        elif arg in ("--verbose", "--continue", "--print"):
            i += 1
        elif arg in (
            "--output-format", "--input-format", "--permission-mode",
            "--system-prompt", "--max-turns", "--max-budget-usd",
            "--setting-sources", "--allowedTools", "--disallowedTools",
            "--mcp-config", "--permission-prompt-tool",
        ):
            i += 2  # flag + value
        else:
            i += 1  # skip unknown
    return resume_id


def read_stdin():
    """Read stdin (control_request init + user message).

    The SDK sends exactly 2 JSON lines: init request then user message.
    We must consume them to avoid EPIPE / broken-pipe errors.
    Uses readline() instead of iterator to avoid buffering issues.
    """
    user_prompt = ""
    # Line 1: control_request init (consume and discard)
    sys.stdin.readline()
    # Line 2: user message (extract prompt)
    line = sys.stdin.readline().rstrip("\n")
    if line:
        try:
            data = json.loads(line)
            msg = data.get("message", {})
            user_prompt = msg.get("content", "")
        except (json.JSONDecodeError, AttributeError):
            pass
    return user_prompt


def auto_detect_scenario(prompt):
    """Auto-detect scenario from prompt content (case-insensitive)."""
    p = prompt.lower()
    if "2+2" in p or "2 + 2" in p:
        return "simple-query"
    if "count" in p and "slowly" in p or "long story" in p or "write a very long" in p:
        return "slow-response"
    if "remember" in p:
        return "session-start"
    if "what number" in p or "what did i" in p:
        return "session-resume"
    if "block b" in p:
        return "block-b-response"
    if "block c" in p:
        return "block-c-response"
    if "scheduled-past-due" in p:
        return "scheduled-past-due"
    if "daily-repeater" in p:
        return "scheduled-repeater"
    if "translate" in p or "chinese" in p:
        return "translate"
    if "read" in p and "tool" in p or "read the file" in p:
        return "tool-use-read"
    if "askuserquestion" in p or "ask me" in p:
        return "ask-user-question"
    return "generic-response"


def replay_fixture(fixture_path):
    """Replay fixture file, handling directives."""
    emit_malformed = False

    with open(fixture_path, "r") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue

            # Legacy DELAY:<seconds> format (backward compat with shell mock)
            if line.startswith("DELAY:"):
                delay = float(line[6:])
                time.sleep(delay)
                continue

            # New directive: #CRASH — exit with signal immediately
            if line == "#CRASH":
                os.kill(os.getpid(), signal.SIGKILL)
                # Fallback if SIGKILL doesn't work (shouldn't happen)
                sys.exit(137)

            # New directive: #DELAY <ms> — wait before next line (ms precision)
            if line.startswith("#DELAY "):
                delay_ms = int(line[7:])
                time.sleep(delay_ms / 1000.0)
                continue

            # New directive: #WAIT_FOR_INPUT — read stdin before continuing
            if line == "#WAIT_FOR_INPUT":
                try:
                    sys.stdin.readline()
                except EOFError:
                    pass
                continue

            # New directive: #EXIT <code> — exit with specific code
            if line.startswith("#EXIT "):
                code = int(line[6:])
                sys.stdout.flush()
                sys.exit(code)

            # New directive: #MALFORMED — output invalid JSON on next line
            if line == "#MALFORMED":
                emit_malformed = True
                continue

            # If malformed flag is set, output truncated/invalid JSON
            if emit_malformed:
                emit_malformed = False
                sys.stdout.write('{"type":"assistant","message":{"content":[{"text":"trunc\n')
                sys.stdout.flush()
                continue

            # Normal line — output as-is
            sys.stdout.write(line + "\n")
            sys.stdout.flush()


def main():
    resume_id = parse_args(sys.argv)
    user_prompt = read_stdin()

    # Select scenario
    scenario = os.environ.get("MOCK_SCENARIO", "")

    if not scenario:
        scenario = auto_detect_scenario(user_prompt)

    # Override for --resume (session continuity tests)
    if resume_id and scenario != "slow-response":
        scenario = "session-resume"

    # Resolve fixture file
    script_dir = os.path.dirname(os.path.abspath(__file__))
    scenarios_dir = os.path.join(script_dir, "fixtures", "mock-scenarios")
    fixture_file = os.path.join(scenarios_dir, f"{scenario}.jsonl")

    if not os.path.isfile(fixture_file):
        print(f"mock-claude-cli-v2: fixture not found: {fixture_file}", file=sys.stderr)
        sys.exit(1)

    replay_fixture(fixture_file)
    sys.exit(0)


if __name__ == "__main__":
    main()
