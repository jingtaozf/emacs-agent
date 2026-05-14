"""Tests for the Claude workspace launcher.

After the class refactor, most tests construct a
``ClaudeWorkspaceLauncher`` and exercise ``build_args`` directly.
Pure-function helpers that stayed module-level (slug normaliser, IDE
cleanup) are tested by name.
"""

import json

import pytest

from unittest.mock import MagicMock, patch

from claude_agent.claude_workspace import (
    ClaudeWorkspaceLauncher,
    _cleanup_ide_server,
    _normalize_story_slug,
)
from claude_agent.workspace_launcher import (
    is_valid_session,
    split_positional_args,
)


def _make_launcher(
    plugin_dir,
    org_file="/tmp/test.org",
    session_id="",
    extra_args=None,
    story_name="",
    system_prompt="",
    mcp_url="http://localhost:9999/mcp",
):
    """Build a launcher wired to PLUGIN_DIR without running the flow."""
    launcher = ClaudeWorkspaceLauncher(org_file, session_id, extra_args or [])
    launcher.plugin_dir = str(plugin_dir)
    launcher.mcp_url = mcp_url
    launcher.story_name = story_name
    launcher.system_prompt = system_prompt
    return launcher


class TestArgParsing:
    def test_org_file_only(self):
        org_file, session_id, extra = split_positional_args(["test.org"])
        assert org_file == "test.org"
        assert session_id == ""
        assert extra == []

    def test_org_file_and_session(self):
        org_file, session_id, extra = split_positional_args(["test.org", "session-1"])
        assert org_file == "test.org"
        assert session_id == "session-1"
        assert extra == []

    def test_org_file_session_and_extras(self):
        _org_file, _sid, extra = split_positional_args(
            ["test.org", "session-1", "--", "--verbose", "--model", "opus"]
        )
        assert extra == ["--verbose", "--model", "opus"]

    def test_org_file_with_dash_separator(self):
        _org_file, session_id, extra = split_positional_args(
            ["test.org", "--", "--verbose"]
        )
        assert session_id == ""
        assert extra == ["--verbose"]

    def test_no_args_exits(self):
        with pytest.raises(SystemExit):
            split_positional_args([])

    def test_flag_as_second_arg_is_not_session(self):
        _org_file, session_id, extra = split_positional_args(["test.org", "--verbose"])
        assert session_id == ""
        assert extra == ["--verbose"]


class TestIsValidSession:
    def test_valid(self):
        assert is_valid_session("cli-123") is True

    def test_empty(self):
        assert is_valid_session("") is False

    def test_null(self):
        assert is_valid_session("null") is False

    def test_nil(self):
        assert is_valid_session("nil") is False


class TestBuildArgs:
    def test_minimal(self, tmp_path):
        launcher = _make_launcher(tmp_path)
        args = launcher.build_args()
        assert args[0] == "claude"
        assert "--plugin-dir" in args
        assert "--mcp-config" in args
        assert "--system-prompt" not in args
        assert "--resume" not in args

    def test_with_system_prompt(self, tmp_path):
        launcher = _make_launcher(tmp_path, system_prompt="You are helpful")
        args = launcher.build_args()
        idx = args.index("--system-prompt")
        assert args[idx + 1] == "You are helpful"

    def test_resume_via_extra_args(self, tmp_path):
        launcher = _make_launcher(tmp_path, extra_args=["--resume", "cli-123"])
        args = launcher.build_args()
        idx = args.index("--resume")
        assert args[idx + 1] == "cli-123"

    def test_no_resume_without_extra_args(self, tmp_path):
        args = _make_launcher(tmp_path).build_args()
        assert "--resume" not in args

    def test_extra_args(self, tmp_path):
        launcher = _make_launcher(tmp_path, extra_args=["--verbose", "--model", "opus"])
        args = launcher.build_args()
        assert "--verbose" in args and "opus" in args

    def test_mcp_config_contains_url(self, tmp_path):
        launcher = _make_launcher(tmp_path, mcp_url="http://custom:8080/mcp")
        args = launcher.build_args()
        config = json.loads(args[args.index("--mcp-config") + 1])
        assert config["mcpServers"]["emacs"]["url"] == "http://custom:8080/mcp"

    def test_writes_workspace_hooks_json(self, tmp_path):
        _make_launcher(tmp_path).build_args()
        hooks_file = tmp_path / "workspace-hooks.json"
        assert hooks_file.exists()
        data = json.loads(hooks_file.read_text())
        assert "Stop" in data["hooks"]
        assert "UserPromptSubmit" in data["hooks"]
        assert "SessionStart" in data["hooks"]


class TestBuildArgsIde:
    def test_ide_flag_always_present(self, tmp_path):
        args = _make_launcher(tmp_path).build_args()
        assert "--ide" in args

    def test_ide_flag_with_extra_args(self, tmp_path):
        args = _make_launcher(tmp_path, extra_args=["--verbose"]).build_args()
        assert "--ide" in args
        assert "--verbose" in args


class TestCleanupIdeServer:
    def test_cleanup_calls_mcp(self):
        mcp = MagicMock()
        _cleanup_ide_server(mcp, "test-123")
        assert mcp.eval_elisp.called
        call_arg = mcp.eval_elisp.call_args[0][0]
        assert "claude-ide-stop-server" in call_arg
        assert "test-123" in call_arg

    def test_cleanup_swallows_errors(self):
        mcp = MagicMock()
        mcp.eval_elisp.side_effect = ConnectionError("unreachable")
        _cleanup_ide_server(mcp, "test")  # should not raise

    def test_cleanup_skips_empty_session(self):
        mcp = MagicMock()
        _cleanup_ide_server(mcp, "")
        assert not mcp.eval_elisp.called


class TestNormalizeStorySlug:
    def test_simple_ascii(self):
        assert _normalize_story_slug("my story") == "my-story"

    def test_mixed_case(self):
        assert _normalize_story_slug("My Story Name") == "my-story-name"

    def test_special_chars(self):
        assert _normalize_story_slug("fix: bug #123!") == "fix-bug-123"

    def test_all_unicode_returns_empty(self):
        """All-unicode name normalises to empty string."""
        assert _normalize_story_slug("混合中文") == ""

    def test_empty_slug_not_passed_to_cli(self, tmp_path):
        """Empty normalised name must NOT produce --name ''."""
        launcher = _make_launcher(tmp_path, story_name="混合中文")
        args = launcher.build_args()
        assert "--name" not in args

    def test_valid_slug_passed_to_cli(self, tmp_path):
        launcher = _make_launcher(tmp_path, story_name="My Story")
        args = launcher.build_args()
        idx = args.index("--name")
        assert args[idx + 1] == "my-story"
