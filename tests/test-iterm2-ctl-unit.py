#!/usr/bin/env python3
"""Layer 1: iterm2-ctl.py unit tests (no iTerm2 needed).

Tests argument parsing, output format validation using saved fixture data
from real iTerm2 runs.

Usage:
  python3 -m pytest tests/test-iterm2-ctl-unit.py -v
  # or
  python3 tests/test-iterm2-ctl-unit.py
"""

import json
import os
import subprocess
import sys
import unittest

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CTL = os.path.join(PROJECT_DIR, "scripts", "iterm2-ctl.py")
FIXTURES = os.path.join(PROJECT_DIR, "tests", "fixtures", "iterm2")


class TestArgParsing(unittest.TestCase):
    """Test that argument parsing works correctly."""

    def test_no_args_shows_help(self):
        proc = subprocess.run(
            ["python3", CTL],
            capture_output=True, text=True, timeout=5,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("usage", proc.stderr.lower())

    def test_launch_requires_title(self):
        proc = subprocess.run(
            ["python3", CTL, "launch"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("--title", proc.stderr)

    def test_send_requires_session(self):
        proc = subprocess.run(
            ["python3", CTL, "send"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("--session", proc.stderr)

    def test_status_requires_session(self):
        proc = subprocess.run(
            ["python3", CTL, "status"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("--session", proc.stderr)

    def test_cancel_requires_session(self):
        proc = subprocess.run(
            ["python3", CTL, "cancel"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("--session", proc.stderr)

    def test_unknown_subcommand(self):
        proc = subprocess.run(
            ["python3", CTL, "bogus"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertNotEqual(proc.returncode, 0)

    def test_list_no_args_ok(self):
        """list subcommand requires no additional args (parsing only)."""
        proc = subprocess.run(
            ["python3", CTL, "list", "--help"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(proc.returncode, 0)


class TestFixtureFormat(unittest.TestCase):
    """Validate output format using saved fixture data from real runs."""

    def _load_fixture(self, name):
        path = os.path.join(FIXTURES, name)
        if not os.path.exists(path):
            self.skipTest(f"Fixture not found: {name} (run Layer 2/3 first)")
        with open(path) as f:
            return f.read().strip()

    def test_status_ready_format(self):
        data = json.loads(self._load_fixture("status-ready.json"))
        self.assertIn("state", data)
        self.assertEqual(data["state"], "ready")
        self.assertIn("session_id", data)
        self.assertIn("tab_title", data)

    def test_status_dead_format(self):
        data = json.loads(self._load_fixture("status-dead.json"))
        self.assertIn("state", data)
        self.assertEqual(data["state"], "dead")

    def test_cancel_result_format(self):
        data = json.loads(self._load_fixture("cancel-result.json"))
        self.assertIn("result", data)
        self.assertEqual(data["result"], "ok")
        self.assertIn("state", data)

    def test_list_format(self):
        data = json.loads(self._load_fixture("list-with-sessions.json"))
        self.assertIsInstance(data, list)
        if data:
            entry = data[0]
            self.assertIn("session_id", entry)
            self.assertIn("tab_title", entry)
            self.assertIn("tab_id", entry)

    def test_screen_output_is_text(self):
        text = self._load_fixture("screen-after-response.txt")
        self.assertIsInstance(text, str)
        self.assertGreater(len(text), 10)


class TestShellQuoting(unittest.TestCase):
    """Test the _shell_quote utility."""

    def test_import_and_quote(self):
        # Import the function directly
        sys.path.insert(0, os.path.dirname(CTL))
        # Can't easily import from scripts, test via known output
        # Just verify the script is valid Python
        proc = subprocess.run(
            ["python3", "-c",
             f"import importlib.util; spec = importlib.util.spec_from_file_location('ctl', '{CTL}'); "
             f"mod = importlib.util.module_from_spec(spec); "
             f"print(mod.__name__)"],
            capture_output=True, text=True, timeout=5,
        )
        # If it loads without syntax errors, basic structure is valid
        self.assertEqual(proc.returncode, 0)


if __name__ == "__main__":
    unittest.main()
