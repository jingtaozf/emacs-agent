"""Tests for the Claude SDD launcher."""

import json

import pytest

from claude_agent.claude_sdd import (
    _is_valid_session,
    build_claude_args,
    parse_args,
)


class TestParseArgs:
    def test_org_file_only(self):
        org_file, session_id, extra = parse_args(["test.org"])
        assert org_file == "test.org"
        assert session_id == ""
        assert extra == []

    def test_org_file_and_session(self):
        org_file, session_id, extra = parse_args(["test.org", "session-1"])
        assert org_file == "test.org"
        assert session_id == "session-1"
        assert extra == []

    def test_org_file_session_and_extras(self):
        org_file, session_id, extra = parse_args(
            ["test.org", "session-1", "--", "--verbose", "--model", "opus"]
        )
        assert extra == ["--verbose", "--model", "opus"]

    def test_org_file_with_dash_separator(self):
        org_file, session_id, extra = parse_args(["test.org", "--", "--verbose"])
        assert session_id == ""
        assert extra == ["--verbose"]

    def test_no_args_exits(self):
        with pytest.raises(SystemExit):
            parse_args([])

    def test_flag_as_second_arg_is_not_session(self):
        org_file, session_id, extra = parse_args(["test.org", "--verbose"])
        assert session_id == ""
        assert extra == ["--verbose"]


class TestIsValidSession:
    def test_valid(self):
        assert _is_valid_session("cli-123") is True

    def test_empty(self):
        assert _is_valid_session("") is False

    def test_null(self):
        assert _is_valid_session("null") is False

    def test_nil(self):
        assert _is_valid_session("nil") is False


class TestBuildClaudeArgs:
    def test_minimal(self):
        args = build_claude_args("/plugin", "http://localhost:9999/mcp", "", "", [])
        assert args[0] == "claude"
        assert "--plugin-dir" in args
        assert "--mcp-config" in args
        assert "--system-prompt" not in args
        assert "--resume" not in args

    def test_with_system_prompt(self):
        args = build_claude_args("/plugin", "http://localhost:9999/mcp", "You are helpful", "", [])
        idx = args.index("--system-prompt")
        assert args[idx + 1] == "You are helpful"

    def test_with_resume(self):
        args = build_claude_args("/plugin", "http://localhost:9999/mcp", "", "cli-123", [])
        idx = args.index("--resume")
        assert args[idx + 1] == "cli-123"

    def test_null_resume_ignored(self):
        assert "--resume" not in build_claude_args("/p", "http://x", "", "null", [])

    def test_nil_resume_ignored(self):
        assert "--resume" not in build_claude_args("/p", "http://x", "", "nil", [])

    def test_extra_args(self):
        args = build_claude_args("/p", "http://x", "", "", ["--verbose", "--model", "opus"])
        assert "--verbose" in args and "opus" in args

    def test_mcp_config_contains_url(self):
        args = build_claude_args("/p", "http://custom:8080/mcp", "", "", [])
        config = json.loads(args[args.index("--mcp-config") + 1])
        assert config["mcpServers"]["emacs"]["url"] == "http://custom:8080/mcp"
