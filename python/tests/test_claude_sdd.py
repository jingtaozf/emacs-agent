"""Tests for the Claude SDD launcher."""

import json

import pytest

from unittest.mock import MagicMock, patch

from claude_agent.claude_sdd import (
    _is_valid_session,
    _normalize_name,
    build_claude_args,
    cleanup_ide_server,
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
        args = build_claude_args("/plugin", "http://localhost:9999/mcp", "", [])
        assert args[0] == "claude"
        assert "--plugin-dir" in args
        assert "--mcp-config" in args
        assert "--system-prompt" not in args
        assert "--resume" not in args

    def test_with_system_prompt(self):
        args = build_claude_args("/plugin", "http://localhost:9999/mcp", "You are helpful", [])
        idx = args.index("--system-prompt")
        assert args[idx + 1] == "You are helpful"

    def test_resume_via_extra_args(self):
        """--resume comes from Emacs via extra_args (state owner principle)."""
        args = build_claude_args("/plugin", "http://localhost:9999/mcp", "", ["--resume", "cli-123"])
        idx = args.index("--resume")
        assert args[idx + 1] == "cli-123"

    def test_no_resume_without_extra_args(self):
        """No --resume when extra_args is empty (new story)."""
        args = build_claude_args("/p", "http://x", "", [])
        assert "--resume" not in args

    def test_extra_args(self):
        args = build_claude_args("/p", "http://x", "", ["--verbose", "--model", "opus"])
        assert "--verbose" in args and "opus" in args

    def test_mcp_config_contains_url(self):
        args = build_claude_args("/p", "http://custom:8080/mcp", "", [])
        config = json.loads(args[args.index("--mcp-config") + 1])
        assert config["mcpServers"]["emacs"]["url"] == "http://custom:8080/mcp"


class TestBuildClaudeArgsIde:
    """Tests for --ide flag in build_claude_args."""

    def test_ide_flag_always_present(self):
        """build_claude_args always includes --ide."""
        args = build_claude_args("/plugin", "http://mcp", "", [])
        assert "--ide" in args

    def test_ide_flag_with_extra_args(self):
        """--ide coexists with extra args."""
        args = build_claude_args("/plugin", "http://mcp", "", ["--verbose"])
        assert "--ide" in args
        assert "--verbose" in args


class TestCleanupIdeServer:
    """Tests for cleanup_ide_server."""

    def test_cleanup_calls_mcp(self):
        """cleanup_ide_server calls MCP to stop the IDE server."""
        mcp = MagicMock()
        cleanup_ide_server(mcp, "test-123")
        assert mcp.eval_elisp.called
        call_arg = mcp.eval_elisp.call_args[0][0]
        assert "claude-ide-stop-server" in call_arg
        assert "test-123" in call_arg

    def test_cleanup_swallows_errors(self):
        """cleanup_ide_server does not raise even if MCP is unreachable."""
        mcp = MagicMock()
        mcp.eval_elisp.side_effect = ConnectionError("unreachable")
        cleanup_ide_server(mcp, "test")  # should not raise

    def test_cleanup_skips_empty_session(self):
        """cleanup_ide_server skips MCP call for empty session_id."""
        mcp = MagicMock()
        cleanup_ide_server(mcp, "")
        assert not mcp.eval_elisp.called


class TestNormalizeName:
    """Tests for _normalize_name."""

    def test_simple_ascii(self):
        assert _normalize_name("my story") == "my-story"

    def test_mixed_case(self):
        assert _normalize_name("My Story Name") == "my-story-name"

    def test_special_chars(self):
        assert _normalize_name("fix: bug #123!") == "fix-bug-123"

    def test_all_unicode_returns_empty(self):
        """BUG PY-1: All-unicode name normalizes to empty string."""
        assert _normalize_name("混合中文") == ""

    def test_empty_name_not_passed_to_cli(self):
        """BUG PY-1: Empty normalized name must NOT produce --name ''."""
        args = build_claude_args("/p", "http://x", "", [], story_name="混合中文")
        assert "--name" not in args

    def test_valid_name_passed_to_cli(self):
        """Normal story name produces --name with normalized slug."""
        args = build_claude_args("/p", "http://x", "", [], story_name="My Story")
        idx = args.index("--name")
        assert args[idx + 1] == "my-story"
