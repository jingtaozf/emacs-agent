"""Tests for the SDD bridge hook handler."""

import json
import os

import pytest

from unittest.mock import MagicMock

from claude_agent.sdd_bridge import (
    _escape_elisp_string,
    _extract_full_response,
    _format_todos_as_elisp,
    _read_custom_id,
    _read_request_id,
    _write_custom_id,
    handle_permission,
    handle_permission_clear,
    handle_prompt,
    handle_response,
    write_status,
)


class TestWriteStatus:
    def test_writes_status_file(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        write_status("test-session", "busy")
        assert (tmp_path / "test-session").read_text() == "busy"

    def test_overwrites_existing(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        write_status("test-session", "busy")
        write_status("test-session", "ready")
        assert (tmp_path / "test-session").read_text() == "ready"


class TestCustomIdPersistence:
    def test_write_and_read(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        _write_custom_id("sid", "sdd-123-instr-3")
        assert _read_custom_id("sid") == "sdd-123-instr-3"

    def test_read_missing(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        assert _read_custom_id("nonexistent") is None

    def test_overwrite(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        _write_custom_id("sid", "sdd-123-instr-1")
        _write_custom_id("sid", "sdd-123-instr-2")
        assert _read_custom_id("sid") == "sdd-123-instr-2"


class TestRequestIdPersistence:
    def test_read_missing(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        assert _read_request_id("nonexistent") is None

    def test_read_existing(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        (tmp_path / "sid.request-id").write_text("req-42-1234")
        assert _read_request_id("sid") == "req-42-1234"


class TestHandleResponseQueryCompleted:
    """handle_response calls query-completed to unregister from active-queries."""

    def test_query_completed_called(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        _write_custom_id("sid", "instr-custom-id")
        mcp = MagicMock()
        handle_response(
            mcp,
            {"last_assistant_message": "hello"},
            "/tmp/f.org",
            "sid",
        )
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        assert any("claude-org-iterm2--query-completed" in c for c in calls)

    def test_query_completed_called_even_without_response(self, tmp_path, monkeypatch):
        """query-completed fires even when there's no response text."""
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()
        handle_response(
            mcp,
            {},
            "/tmp/f.org",
            "sid",
        )
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        assert any("claude-org-iterm2--query-completed" in c for c in calls)


class TestEscapeElispString:
    def test_plain_string(self):
        assert _escape_elisp_string("hello") == "hello"

    def test_quotes(self):
        assert _escape_elisp_string('say "hi"') == 'say \\"hi\\"'

    def test_backslashes(self):
        assert _escape_elisp_string("a\\b") == "a\\\\b"

    def test_newlines(self):
        assert _escape_elisp_string("line1\nline2") == "line1\\nline2"

    def test_carriage_return(self):
        assert _escape_elisp_string("a\rb") == "a\\rb"


class TestExtractFullResponse:
    def _make_transcript(self, tmp_path, entries):
        transcript = tmp_path / "transcript.jsonl"
        lines = [json.dumps(e) for e in entries]
        transcript.write_text("\n".join(lines))
        return str(transcript)

    def _user(self, text):
        return {"type": "user", "message": {"content": [{"type": "text", "text": text}]}}

    def _assistant(self, text):
        return {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}

    def _assistant_with_tool(self, text, tool_name="Bash"):
        return {"type": "assistant", "message": {"content": [
            {"type": "text", "text": text},
            {"type": "tool_use", "name": tool_name, "input": {}},
        ]}}

    def _assistant_thinking(self, thinking, text):
        return {"type": "assistant", "message": {"content": [
            {"type": "thinking", "text": thinking},
            {"type": "text", "text": text},
        ]}}

    def test_single_turn(self, tmp_path):
        path = self._make_transcript(tmp_path, [
            self._user("hello"),
            self._assistant("world"),
        ])
        assert _extract_full_response(path) == "world"

    def test_multi_turn_skips_tool_use_turns(self, tmp_path):
        """Assistant turns containing tool_use blocks are skipped (intermediate noise)."""
        path = self._make_transcript(tmp_path, [
            self._user("do X"),
            self._assistant_with_tool("Let me check"),
            self._assistant("Done! Here's the result."),
        ])
        assert _extract_full_response(path) == "Done! Here's the result."

    def test_multi_turn_keeps_pure_text_turns(self, tmp_path):
        """Multiple pure-text assistant turns are all kept."""
        path = self._make_transcript(tmp_path, [
            self._user("do X"),
            self._assistant_with_tool("Let me check"),
            self._assistant("First part."),
            self._assistant("Second part."),
        ])
        assert _extract_full_response(path) == "First part.\n\nSecond part."

    def test_user_in_middle(self, tmp_path):
        """Only collects text after the LAST user entry."""
        path = self._make_transcript(tmp_path, [
            self._user("first question"),
            self._assistant("first answer"),
            self._user("second question"),
            self._assistant("second answer"),
        ])
        assert _extract_full_response(path) == "second answer"

    def test_thinking_blocks_skipped(self, tmp_path):
        path = self._make_transcript(tmp_path, [
            self._user("think about this"),
            self._assistant_thinking("deep thoughts", "visible text"),
        ])
        assert _extract_full_response(path) == "visible text"

    def test_empty_transcript(self, tmp_path):
        path = self._make_transcript(tmp_path, [])
        assert _extract_full_response(path) == ""

    def test_no_user_entry(self, tmp_path):
        """If no user entry, collects all assistant text."""
        path = self._make_transcript(tmp_path, [
            self._assistant("hello"),
            self._assistant("world"),
        ])
        assert _extract_full_response(path) == "hello\n\nworld"

    def test_all_tool_use_turns_returns_empty(self, tmp_path):
        """If every assistant turn has tool_use, returns empty string."""
        path = self._make_transcript(tmp_path, [
            self._user("do X"),
            self._assistant_with_tool("checking..."),
            self._assistant_with_tool("still working..."),
        ])
        assert _extract_full_response(path) == ""


class TestFormatTodosAsElisp:
    def test_basic(self):
        todos = [
            {"content": "Do X", "status": "completed"},
            {"content": "Do Y", "status": "pending"},
        ]
        result = _format_todos_as_elisp(todos)
        assert result == '((:content "Do X" :status "completed" :priority 0) (:content "Do Y" :status "pending" :priority 0))'

    def test_special_chars(self):
        todos = [{"content": 'Say "hello"', "status": "pending"}]
        result = _format_todos_as_elisp(todos)
        assert result == '((:content "Say \\"hello\\"" :status "pending" :priority 0))'

    def test_empty(self):
        assert _format_todos_as_elisp([]) == "()"

    def test_with_priority(self):
        todos = [{"content": "Urgent", "status": "pending", "priority": 1}]
        result = _format_todos_as_elisp(todos)
        assert result == '((:content "Urgent" :status "pending" :priority 1))'

    def test_string_priority_coerced(self):
        """Priority that can't be int-coerced defaults to 0."""
        todos = [{"content": "X", "status": "pending", "priority": "high"}]
        result = _format_todos_as_elisp(todos)
        assert ':priority 0' in result

    def test_non_numeric_priority_safe(self):
        """Malformed priority cannot inject elisp."""
        todos = [{"content": "X", "status": "pending", "priority": '1) (evil'}]
        result = _format_todos_as_elisp(todos)
        assert ':priority 0' in result


class TestHandlePromptFiltering:
    """Test that handle_prompt skips non-human prompts."""

    def _make_mcp(self):
        mcp = MagicMock()
        mcp.eval_elisp = MagicMock(return_value="ok")
        return mcp

    def test_normal_prompt_calls_mcp(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        mcp = self._make_mcp()
        mcp.eval_elisp.return_value = "sid-instr-1"
        handle_prompt(mcp, {"prompt": "explain this function"}, "/tmp/f.org", "sid")
        assert mcp.eval_elisp.called

    def test_prompt_saves_custom_id(self, tmp_path, monkeypatch):
        """handle_prompt saves the instruction CUSTOM_ID returned by MCP."""
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        mcp = self._make_mcp()
        mcp.eval_elisp.return_value = "sdd-123-instr-5"
        handle_prompt(mcp, {"prompt": "do X"}, "/tmp/f.org", "sid")
        assert _read_custom_id("sid") == "sdd-123-instr-5"

    def test_task_notification_skipped(self, tmp_path, monkeypatch):
        """Task notifications from background agents should not create Instruction headings."""
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        mcp = self._make_mcp()
        prompt = (
            '<task-notification>\n'
            '<task-id>abc123</task-id>\n'
            '<status>completed</status>\n'
            '<summary>Agent "Research" completed</summary>\n'
            '<result>Found the answer.</result>\n'
            '</task-notification>'
        )
        handle_prompt(mcp, {"prompt": prompt}, "/tmp/f.org", "sid")
        # Should NOT call eval_elisp to insert a prompt
        assert not mcp.eval_elisp.called

    def test_system_reminder_skipped(self, tmp_path, monkeypatch):
        """System reminders injected by CLI should not create Instruction headings."""
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        mcp = self._make_mcp()
        prompt = '<system-reminder>\nThe task tools haven\'t been used recently.\n</system-reminder>'
        handle_prompt(mcp, {"prompt": prompt}, "/tmp/f.org", "sid")
        assert not mcp.eval_elisp.called

    def test_empty_prompt_skipped(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.sdd_bridge.STATUS_DIR", str(tmp_path))
        mcp = self._make_mcp()
        handle_prompt(mcp, {"prompt": ""}, "/tmp/f.org", "sid")
        assert not mcp.eval_elisp.called


class TestHandlePermission:
    """Tests for PreToolUse permission notification."""

    def test_ask_user_question_notifies_emacs(self, capsys):
        """AskUserQuestion triggers notification + returns ask."""
        mcp = MagicMock()
        handle_permission(mcp, {"tool_name": "AskUserQuestion"}, "/tmp/f.org", "sid")
        call_arg = mcp.eval_elisp.call_args[0][0]
        assert "claude-org-iterm2--permission-needed" in call_arg
        assert "AskUserQuestion" in call_arg
        output = json.loads(capsys.readouterr().out)
        assert output["hookSpecificOutput"]["permissionDecision"] == "ask"

    def test_exit_plan_mode_notifies_emacs(self, capsys):
        """ExitPlanMode triggers notification + returns ask."""
        mcp = MagicMock()
        handle_permission(mcp, {"tool_name": "ExitPlanMode"}, "/tmp/f.org", "sid")
        assert mcp.eval_elisp.called
        output = json.loads(capsys.readouterr().out)
        assert output["hookSpecificOutput"]["permissionDecision"] == "ask"

    def test_regular_tool_no_notification(self, capsys):
        """Bash/Edit/etc. produce no output and no notification."""
        mcp = MagicMock()
        handle_permission(mcp, {"tool_name": "Bash"}, "/tmp/f.org", "sid")
        assert not mcp.eval_elisp.called
        assert capsys.readouterr().out == ""

    def test_ask_even_on_mcp_failure(self, capsys):
        """Permission decision is printed even if MCP call fails."""
        mcp = MagicMock()
        mcp.eval_elisp.side_effect = ConnectionError("unreachable")
        handle_permission(mcp, {"tool_name": "AskUserQuestion"}, "/tmp/f.org", "sid")
        output = json.loads(capsys.readouterr().out)
        assert output["hookSpecificOutput"]["permissionDecision"] == "ask"


class TestHandlePermissionClear:
    """Tests for PostToolUse permission clear."""

    def test_clears_in_emacs(self):
        mcp = MagicMock()
        handle_permission_clear(mcp, {"tool_name": "Bash"}, "/tmp/f.org", "sid")
        call_arg = mcp.eval_elisp.call_args[0][0]
        assert "claude-org-iterm2--permission-resolved" in call_arg
        assert "sid" in call_arg

    def test_swallows_mcp_errors(self):
        mcp = MagicMock()
        mcp.eval_elisp.side_effect = ConnectionError("gone")
        handle_permission_clear(mcp, {}, "/tmp/f.org", "sid")  # should not raise
