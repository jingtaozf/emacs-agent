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
        launcher = OpencodeWorkspaceLauncher.from_argv(["test.org", "--", "--verbose"])
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
            "opencode",
            "--session",
            "oc-uuid-123",
        ]

    def test_with_model(self, tmp_path):
        launcher = _make_launcher(tmp_path, model="anthropic/claude-sonnet-4-5")
        args = launcher.build_args()
        assert "--model" in args
        idx = args.index("--model")
        assert args[idx + 1] == "anthropic/claude-sonnet-4-5"

    def test_with_extra_args(self, tmp_path):
        launcher = _make_launcher(tmp_path, extra_args=["--verbose", "--debug"])
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
        existing.write_text('{"model": "gpt-4o", "mcp": {"other": {"type": "local"}}}')
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

    def test_polluted_original_does_not_self_perpetuate(self, tmp_path):
        """Regression test for 2026-04-30 self-perpetuating bloat bug.

        If a prior session's atexit cleanup did not fire (process killed,
        ``open`` exec'd OpenCode and the parent atexit ran but original
        was already polluted from the *prior* session), AGENTS.md ends
        up with stacked BEGIN/END inject blocks. Each subsequent session
        treats the polluted file as the durable base and prepends
        another inject block, growing without bound.

        Expected behavior: ``_write_agents_md`` strips any existing
        BEGIN/END inject blocks from the read content before treating
        the rest as base, so the output has *exactly one* inject block
        regardless of input pollution.
        """
        agents_md = tmp_path / "AGENTS.md"
        # Simulate a polluted file from a prior failed cleanup:
        # 3 stacked inject blocks + a small base.
        polluted = (
            "<!-- BEGIN emacs-agent session instructions (auto-removed on exit) -->\n"
            "Stale instructions from session 1\n"
            "<!-- END emacs-agent session instructions -->\n\n"
            "<!-- BEGIN emacs-agent session instructions (auto-removed on exit) -->\n"
            "Stale instructions from session 2\n"
            "<!-- END emacs-agent session instructions -->\n\n"
            "<!-- BEGIN emacs-agent session instructions (auto-removed on exit) -->\n"
            "Stale instructions from session 3\n"
            "<!-- END emacs-agent session instructions -->\n\n"
            "# Real project base\n\nKeep this content.\n"
        )
        agents_md.write_text(polluted)

        _write_agents_md(str(tmp_path), "Fresh session 4 instructions.")
        result = agents_md.read_text()

        # Exactly one BEGIN marker (the new one), not 4.
        assert result.count("<!-- BEGIN emacs-agent session instructions") == 1
        # Stale instructions from sessions 1-3 must be gone.
        assert "Stale instructions from session 1" not in result
        assert "Stale instructions from session 2" not in result
        assert "Stale instructions from session 3" not in result
        # Real base content survives.
        assert "# Real project base" in result
        assert "Keep this content." in result
        # New session content present.
        assert "Fresh session 4 instructions." in result

    def test_cleanup_is_idempotent_and_strips_inject_block(self, tmp_path):
        """Cleanup must work from current file content, not captured original.

        Calling cleanup twice should be a no-op the second time. After
        cleanup, AGENTS.md must contain no BEGIN/END markers — only the
        durable base. If the file existed before with no base content,
        cleanup deletes it.
        """
        from claude_agent.workspace_launcher import cleanup_emacs_agent_inject

        # Case 1: file existed with base content; cleanup leaves base.
        agents_md = tmp_path / "AGENTS.md"
        agents_md.write_text("# Original base\n\nProject text.\n")
        _write_agents_md(str(tmp_path), "Session inject.")
        # File now has inject + base. Run cleanup:
        cleanup_emacs_agent_inject(agents_md, file_existed_before=True)
        result = agents_md.read_text()
        assert "BEGIN emacs-agent" not in result
        assert "Session inject." not in result
        assert "# Original base" in result
        # Idempotent — second cleanup leaves it unchanged.
        cleanup_emacs_agent_inject(agents_md, file_existed_before=True)
        assert agents_md.read_text() == result

        # Case 2: file did NOT exist before; cleanup removes it.
        nofile_dir = tmp_path / "nofile"
        nofile_dir.mkdir()
        nofile = nofile_dir / "AGENTS.md"
        # Simulate inject created the file (no prior base):
        from claude_agent.opencode_workspace import _write_agents_md as wam

        wam(str(nofile_dir), "Only inject here.")
        assert nofile.exists()
        cleanup_emacs_agent_inject(nofile, file_existed_before=False)
        # No durable base, so file is removed entirely.
        assert not nofile.exists()
