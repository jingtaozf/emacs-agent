"""Tests for the OpenCode workspace launcher.

Uses ``OpencodeWorkspaceLauncher`` directly. Injection helpers and the
JSONC parser remain as module-level functions (stateless) and are
tested by name.
"""

import json

import pytest

from claude_agent.opencode_workspace import (
    OpencodeWorkspaceLauncher,
    _inject_emacs_mcp,
    _parse_jsonc,
    _write_agents_md,
)
from claude_agent.workspace_launcher import (
    filter_claude_args,
    is_valid_session,
    split_positional_args,
)


def _make_launcher(
    project_root,
    org_file="/tmp/test.org",
    session_id="",
    extra_args=None,
    resume_id=None,
    model="",
):
    """Build an OpencodeWorkspaceLauncher pointed at PROJECT_ROOT."""
    launcher = OpencodeWorkspaceLauncher(
        org_file, session_id, extra_args or [], resume_id=resume_id
    )
    launcher.project_root = str(project_root)
    launcher.model = model
    return launcher


class TestFromArgv:
    def test_org_file_only(self):
        launcher = OpencodeWorkspaceLauncher.from_argv(["test.org"])
        assert launcher.session_id == ""
        assert launcher.resume_id is None
        assert launcher.extra_args == []

    def test_org_file_and_session(self):
        launcher = OpencodeWorkspaceLauncher.from_argv(["test.org", "session-1"])
        assert launcher.session_id == "session-1"
        assert launcher.resume_id is None
        assert launcher.extra_args == []

    def test_org_file_session_and_resume(self):
        launcher = OpencodeWorkspaceLauncher.from_argv(
            ["test.org", "session-1", "--resume", "oc-abc123"]
        )
        assert launcher.session_id == "session-1"
        assert launcher.resume_id == "oc-abc123"
        assert launcher.extra_args == []

    def test_org_file_session_resume_and_extras(self):
        launcher = OpencodeWorkspaceLauncher.from_argv(
            ["test.org", "session-1", "--resume", "oc-abc", "--", "--verbose"]
        )
        assert launcher.session_id == "session-1"
        assert launcher.resume_id == "oc-abc"
        assert launcher.extra_args == ["--verbose"]

    def test_org_file_with_dash_separator(self):
        launcher = OpencodeWorkspaceLauncher.from_argv(
            ["test.org", "--", "--verbose"]
        )
        assert launcher.session_id == ""
        assert launcher.resume_id is None
        assert launcher.extra_args == ["--verbose"]

    def test_no_args_exits(self):
        with pytest.raises(SystemExit):
            OpencodeWorkspaceLauncher.from_argv([])

    def test_flag_as_second_arg_is_not_session(self):
        launcher = OpencodeWorkspaceLauncher.from_argv(["test.org", "--verbose"])
        assert launcher.session_id == ""
        assert launcher.resume_id is None
        assert launcher.extra_args == ["--verbose"]


class TestIsValidSession:
    def test_valid(self):
        assert is_valid_session("oc-uuid-123") is True

    def test_empty(self):
        assert is_valid_session("") is False

    def test_null(self):
        assert is_valid_session("null") is False

    def test_nil(self):
        assert is_valid_session("nil") is False


class TestParseJsonc:
    def test_plain_json(self):
        assert _parse_jsonc('{"key": "value"}') == {"key": "value"}

    def test_line_comments(self):
        text = '{\n  // comment\n  "key": "value"\n}'
        assert _parse_jsonc(text) == {"key": "value"}

    def test_block_comments(self):
        text = '{\n  /* block\n     comment */\n  "key": "value"\n}'
        assert _parse_jsonc(text) == {"key": "value"}

    def test_empty_string(self):
        assert _parse_jsonc("") == {}

    def test_whitespace_only(self):
        assert _parse_jsonc("   \n  ") == {}


class TestFilterClaudeArgs:
    def test_empty_args(self):
        assert filter_claude_args([]) == []

    def test_no_claude_flags(self):
        args = ["--verbose", "--model", "opus"]
        assert filter_claude_args(args) == ["--verbose", "--model", "opus"]

    def test_strips_boolean_flags(self):
        args = ["--dangerously-skip-permissions", "--verbose"]
        assert filter_claude_args(args) == ["--verbose"]

    def test_strips_flag_with_value(self):
        args = ["--permission-mode", "plan", "--verbose"]
        assert filter_claude_args(args) == ["--verbose"]

    def test_strips_ide_flag(self):
        args = ["--ide", "--verbose"]
        assert filter_claude_args(args) == ["--verbose"]

    def test_strips_mcp_config(self):
        args = ["--mcp-config", '{"servers":{}}', "--verbose"]
        assert filter_claude_args(args) == ["--verbose"]

    def test_strips_system_prompt(self):
        args = ["--system-prompt", "You are helpful", "--verbose"]
        assert filter_claude_args(args) == ["--verbose"]

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
        assert filter_claude_args(args) == ["--verbose"]

    def test_preserves_unknown_flags(self):
        assert filter_claude_args(["--custom-flag", "value"]) == [
            "--custom-flag",
            "value",
        ]


class TestBuildArgs:
    def test_minimal(self, tmp_path):
        launcher = _make_launcher(tmp_path)
        assert launcher.build_args() == ["opencode"]

    def test_with_resume_session(self, tmp_path):
        launcher = _make_launcher(tmp_path, resume_id="oc-uuid-123")
        assert launcher.build_args() == [
            "opencode", "--session", "oc-uuid-123",
        ]

    def test_with_model(self, tmp_path):
        launcher = _make_launcher(tmp_path, model="anthropic/claude-sonnet-4-5")
        args = launcher.build_args()
        assert "--model" in args
        idx = args.index("--model")
        assert args[idx + 1] == "anthropic/claude-sonnet-4-5"

    def test_with_extra_args(self, tmp_path):
        launcher = _make_launcher(
            tmp_path, extra_args=["--verbose", "--debug"]
        )
        args = launcher.build_args()
        assert "--verbose" in args
        assert "--debug" in args

    def test_filters_claude_flags_from_extras(self, tmp_path):
        launcher = _make_launcher(tmp_path, extra_args=["--ide", "--verbose"])
        args = launcher.build_args()
        assert "--ide" not in args
        assert "--verbose" in args

    def test_resume_plus_model_plus_extras(self, tmp_path):
        launcher = _make_launcher(
            tmp_path,
            resume_id="oc-abc",
            extra_args=["--verbose"],
            model="openai/gpt-4o",
        )
        args = launcher.build_args()
        assert args[0] == "opencode"
        assert "--session" in args
        assert "--model" in args
        assert "--verbose" in args


class TestInjectEmacsMcp:
    def test_creates_config_when_none_exists(self, tmp_path):
        _inject_emacs_mcp(str(tmp_path), "http://localhost:9999/mcp")
        config_path = tmp_path / "opencode.jsonc"
        assert config_path.exists()
        config = json.loads(config_path.read_text())
        assert config["mcp"]["emacs"]["type"] == "remote"
        assert config["mcp"]["emacs"]["url"] == "http://localhost:9999/mcp"
        assert config["mcp"]["emacs"]["enabled"] is True

    def test_merges_into_existing_config(self, tmp_path):
        existing = tmp_path / "opencode.jsonc"
        existing.write_text(
            '{"model": "gpt-4o", "mcp": {"other": {"type": "local"}}}'
        )
        _inject_emacs_mcp(str(tmp_path), "http://localhost:8080/mcp")
        config = json.loads(existing.read_text())
        assert config["mcp"]["other"]["type"] == "local"
        assert config["mcp"]["emacs"]["url"] == "http://localhost:8080/mcp"
        assert config["model"] == "gpt-4o"

    def test_reads_json_variant(self, tmp_path):
        existing = tmp_path / "opencode.json"
        existing.write_text('{"model": "claude"}')
        _inject_emacs_mcp(str(tmp_path), "http://localhost:9999/mcp")
        jsonc = tmp_path / "opencode.jsonc"
        assert jsonc.exists()
        config = json.loads(jsonc.read_text())
        assert config["model"] == "claude"
        assert config["mcp"]["emacs"]["url"] == "http://localhost:9999/mcp"

    def test_handles_jsonc_with_comments(self, tmp_path):
        existing = tmp_path / "opencode.jsonc"
        existing.write_text('{\n  // My config\n  "model": "gpt-4o"\n}')
        _inject_emacs_mcp(str(tmp_path), "http://localhost:9999/mcp")
        config = json.loads(existing.read_text())
        assert config["model"] == "gpt-4o"
        assert "emacs" in config["mcp"]


class TestWriteAgentsMd:
    def test_creates_agents_md_when_none_exists(self, tmp_path):
        _write_agents_md(str(tmp_path), "You are a helpful agent.")
        agents_md = tmp_path / "AGENTS.md"
        assert agents_md.exists()
        content = agents_md.read_text()
        assert "You are a helpful agent." in content
        assert "BEGIN emacs-agent session instructions" in content

    def test_prepends_to_existing_agents_md(self, tmp_path):
        existing = tmp_path / "AGENTS.md"
        existing.write_text("# Existing project instructions\n\nDo good work.")
        _write_agents_md(str(tmp_path), "Session-specific instructions.")
        content = (tmp_path / "AGENTS.md").read_text()
        session_pos = content.find("Session-specific instructions.")
        existing_pos = content.find("Existing project instructions")
        assert session_pos < existing_pos
        assert "Do good work." in content

    def test_header_and_footer_markers(self, tmp_path):
        _write_agents_md(str(tmp_path), "Instructions here.")
        content = (tmp_path / "AGENTS.md").read_text()
        assert "<!-- BEGIN emacs-agent session instructions" in content
        assert "<!-- END emacs-agent session instructions -->" in content
