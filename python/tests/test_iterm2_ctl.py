"""Tests for iterm2_ctl — argument parsing and utility functions.

Note: Async iTerm2 commands require a running iTerm2 instance and are
tested via E2E tests, not here.
"""

import pytest

from claude_agent.iterm2_ctl import _shell_quote, build_parser, _looks_like_shell_prompt


class TestShellQuote:
    def test_simple_string(self):
        assert _shell_quote("hello") == "'hello'"

    def test_string_with_single_quote(self):
        assert _shell_quote("it's") == "'it'\\''s'"

    def test_string_with_spaces(self):
        assert _shell_quote("hello world") == "'hello world'"

    def test_empty_string(self):
        assert _shell_quote("") == "''"


class TestBuildParser:
    def test_launch_requires_title(self):
        parser = build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args(["launch"])

    def test_launch_with_title(self):
        parser = build_parser()
        args = parser.parse_args(["launch", "--title", "my-tab"])
        assert args.command == "launch"
        assert args.title == "my-tab"

    def test_launch_with_all_options(self):
        parser = build_parser()
        args = parser.parse_args([
            "launch", "--title", "tab", "--cwd", "/project",
            "--launch-cmd", "claude-workspace test.org",
            "--system-prompt-file", "/tmp/sp.txt",
            "--resume", "abc-123",
        ])
        assert args.title == "tab"
        assert args.cwd == "/project"
        assert args.launch_cmd == "claude-workspace test.org"
        assert args.system_prompt_file == "/tmp/sp.txt"
        assert args.resume == "abc-123"

    def test_send_requires_session(self):
        parser = build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args(["send"])

    def test_status_command(self):
        parser = build_parser()
        args = parser.parse_args(["status", "--session", "sess-1"])
        assert args.command == "status"
        assert args.session == "sess-1"

    def test_read_default_lines(self):
        parser = build_parser()
        args = parser.parse_args(["read", "--session", "sess-1"])
        assert args.lines == 50

    def test_read_custom_lines(self):
        parser = build_parser()
        args = parser.parse_args(["read", "--session", "sess-1", "--lines", "100"])
        assert args.lines == 100

    def test_list_command(self):
        parser = build_parser()
        args = parser.parse_args(["list"])
        assert args.command == "list"

    def test_requires_command(self):
        parser = build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args([])


class TestLooksLikeShellPrompt:
    def test_dollar_prompt(self):
        assert _looks_like_shell_prompt("user@host:~$") is True

    def test_percent_prompt(self):
        assert _looks_like_shell_prompt("% ") is True

    def test_arrow_prompt(self):
        assert _looks_like_shell_prompt("❯") is True

    def test_hash_prompt(self):
        assert _looks_like_shell_prompt("root@host:~#") is True

    def test_not_a_prompt(self):
        assert _looks_like_shell_prompt("Hello world") is False

    def test_empty_string(self):
        assert _looks_like_shell_prompt("") is False

    def test_claude_output(self):
        assert _looks_like_shell_prompt("I can help you with that.") is False
