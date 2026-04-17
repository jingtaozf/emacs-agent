"""Tests for the OpenCode workspace launcher."""

import json
import os

import pytest

from claude_agent.opencode_workspace import (
    _filter_claude_args,
    _is_valid_session,
    _parse_jsonc,
    build_opencode_args,
    inject_emacs_mcp,
    parse_args,
    write_agents_md,
)


class TestParseArgs:
    def test_org_file_only(self):
        org_file, session_id, resume_id, extra = parse_args(["test.org"])
        assert org_file == "test.org"
        assert session_id == ""
        assert resume_id is None
        assert extra == []

    def test_org_file_and_session(self):
        org_file, session_id, resume_id, extra = parse_args(["test.org", "session-1"])
        assert org_file == "test.org"
        assert session_id == "session-1"
        assert resume_id is None
        assert extra == []

    def test_org_file_session_and_resume(self):
        org_file, session_id, resume_id, extra = parse_args(
            ["test.org", "session-1", "--resume", "oc-abc123"]
        )
        assert session_id == "session-1"
        assert resume_id == "oc-abc123"
        assert extra == []

    def test_org_file_session_resume_and_extras(self):
        org_file, session_id, resume_id, extra = parse_args(
            ["test.org", "session-1", "--resume", "oc-abc", "--", "--verbose"]
        )
        assert session_id == "session-1"
        assert resume_id == "oc-abc"
        assert extra == ["--verbose"]

    def test_org_file_with_dash_separator(self):
        org_file, session_id, resume_id, extra = parse_args(
            ["test.org", "--", "--verbose"]
        )
        assert session_id == ""
        assert resume_id is None
        assert extra == ["--verbose"]

    def test_no_args_exits(self):
        with pytest.raises(SystemExit):
            parse_args([])

    def test_flag_as_second_arg_is_not_session(self):
        org_file, session_id, resume_id, extra = parse_args(["test.org", "--verbose"])
        assert session_id == ""
        assert resume_id is None
        assert extra == ["--verbose"]


class TestIsValidSession:
    def test_valid(self):
        assert _is_valid_session("oc-uuid-123") is True

    def test_empty(self):
        assert _is_valid_session("") is False

    def test_null(self):
        assert _is_valid_session("null") is False

    def test_nil(self):
        assert _is_valid_session("nil") is False


class TestParseJsonc:
    def test_plain_json(self):
        result = _parse_jsonc('{"key": "value"}')
        assert result == {"key": "value"}

    def test_line_comments(self):
        text = '{\n  // comment\n  "key": "value"\n}'
        result = _parse_jsonc(text)
        assert result == {"key": "value"}

    def test_block_comments(self):
        text = '{\n  /* block\n     comment */\n  "key": "value"\n}'
        result = _parse_jsonc(text)
        assert result == {"key": "value"}

    def test_empty_string(self):
        assert _parse_jsonc("") == {}

    def test_whitespace_only(self):
        assert _parse_jsonc("   \n  ") == {}


class TestFilterClaudeArgs:
    def test_empty_args(self):
        assert _filter_claude_args([]) == []

    def test_no_claude_flags(self):
        args = ["--verbose", "--model", "opus"]
        assert _filter_claude_args(args) == ["--verbose", "--model", "opus"]

    def test_strips_boolean_flags(self):
        args = ["--dangerously-skip-permissions", "--verbose"]
        assert _filter_claude_args(args) == ["--verbose"]

    def test_strips_flag_with_value(self):
        args = ["--permission-mode", "plan", "--verbose"]
        assert _filter_claude_args(args) == ["--verbose"]

    def test_strips_ide_flag(self):
        args = ["--ide", "--verbose"]
        assert _filter_claude_args(args) == ["--verbose"]

    def test_strips_mcp_config(self):
        args = ["--mcp-config", '{"servers":{}}', "--verbose"]
        assert _filter_claude_args(args) == ["--verbose"]

    def test_strips_system_prompt(self):
        args = ["--system-prompt", "You are helpful", "--verbose"]
        assert _filter_claude_args(args) == ["--verbose"]

    def test_strips_multiple_claude_flags(self):
        args = [
            "--dangerously-skip-permissions",
            "--ide",
            "--mcp-config",
            "{}",
            "--name",
            "my-session",
            "--verbose",
        ]
        assert _filter_claude_args(args) == ["--verbose"]

    def test_preserves_unknown_flags(self):
        args = ["--custom-flag", "value"]
        assert _filter_claude_args(args) == ["--custom-flag", "value"]


class TestBuildOpencodeArgs:
    def test_minimal(self):
        args = build_opencode_args(None, [])
        assert args == ["opencode"]

    def test_with_resume_session(self):
        args = build_opencode_args("oc-uuid-123", [])
        assert args == ["opencode", "--session", "oc-uuid-123"]

    def test_with_model(self):
        args = build_opencode_args(None, [], model="anthropic/claude-sonnet-4-5")
        assert "--model" in args
        idx = args.index("--model")
        assert args[idx + 1] == "anthropic/claude-sonnet-4-5"

    def test_with_extra_args(self):
        args = build_opencode_args(None, ["--verbose", "--debug"])
        assert "--verbose" in args
        assert "--debug" in args

    def test_filters_claude_flags_from_extras(self):
        args = build_opencode_args(None, ["--ide", "--verbose"])
        assert "--ide" not in args
        assert "--verbose" in args

    def test_resume_plus_model_plus_extras(self):
        args = build_opencode_args("oc-abc", ["--verbose"], model="openai/gpt-4o")
        assert args[0] == "opencode"
        assert "--session" in args
        assert "--model" in args
        assert "--verbose" in args


class TestInjectEmacsMcp:
    def test_creates_config_when_none_exists(self, tmp_path):
        inject_emacs_mcp(str(tmp_path), "http://localhost:9999/mcp")
        config_path = tmp_path / "opencode.jsonc"
        assert config_path.exists()
        config = json.loads(config_path.read_text())
        assert config["mcp"]["emacs"]["type"] == "remote"
        assert config["mcp"]["emacs"]["url"] == "http://localhost:9999/mcp"
        assert config["mcp"]["emacs"]["enabled"] is True

    def test_merges_into_existing_config(self, tmp_path):
        existing = tmp_path / "opencode.jsonc"
        existing.write_text('{"model": "gpt-4o", "mcp": {"other": {"type": "local"}}}')
        inject_emacs_mcp(str(tmp_path), "http://localhost:8080/mcp")
        config = json.loads(existing.read_text())
        # Original MCP server preserved
        assert config["mcp"]["other"]["type"] == "local"
        # Emacs MCP server added
        assert config["mcp"]["emacs"]["url"] == "http://localhost:8080/mcp"
        # Original model preserved
        assert config["model"] == "gpt-4o"

    def test_reads_json_variant(self, tmp_path):
        existing = tmp_path / "opencode.json"
        existing.write_text('{"model": "claude"}')
        inject_emacs_mcp(str(tmp_path), "http://localhost:9999/mcp")
        # Should write to .jsonc
        jsonc = tmp_path / "opencode.jsonc"
        assert jsonc.exists()
        config = json.loads(jsonc.read_text())
        assert config["model"] == "claude"
        assert config["mcp"]["emacs"]["url"] == "http://localhost:9999/mcp"

    def test_handles_jsonc_with_comments(self, tmp_path):
        existing = tmp_path / "opencode.jsonc"
        existing.write_text('{\n  // My config\n  "model": "gpt-4o"\n}')
        inject_emacs_mcp(str(tmp_path), "http://localhost:9999/mcp")
        config = json.loads(existing.read_text())
        assert config["model"] == "gpt-4o"
        assert "emacs" in config["mcp"]


class TestWriteAgentsMd:
    def test_creates_agents_md_when_none_exists(self, tmp_path):
        write_agents_md(str(tmp_path), "You are a helpful agent.")
        agents_md = tmp_path / "AGENTS.md"
        assert agents_md.exists()
        content = agents_md.read_text()
        assert "You are a helpful agent." in content
        assert "BEGIN emacs-agent session instructions" in content

    def test_prepends_to_existing_agents_md(self, tmp_path):
        existing = tmp_path / "AGENTS.md"
        existing.write_text("# Existing project instructions\n\nDo good work.")
        write_agents_md(str(tmp_path), "Session-specific instructions.")
        content = (tmp_path / "AGENTS.md").read_text()
        # Session instructions come first
        session_pos = content.find("Session-specific instructions.")
        existing_pos = content.find("Existing project instructions")
        assert session_pos < existing_pos
        # Original content preserved
        assert "Do good work." in content

    def test_header_and_footer_markers(self, tmp_path):
        write_agents_md(str(tmp_path), "Instructions here.")
        content = (tmp_path / "AGENTS.md").read_text()
        assert "<!-- BEGIN emacs-agent session instructions" in content
        assert "<!-- END emacs-agent session instructions -->" in content
