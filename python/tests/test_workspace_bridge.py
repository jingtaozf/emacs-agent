"""Tests for the workspace bridge hook handler.

After the refactor the bridge is a class (``WorkspaceBridge``); tests
construct a bridge and call methods on it rather than free functions.
A small ``make_bridge`` helper keeps the boilerplate down.
"""

import json

import pytest

from unittest.mock import MagicMock

from claude_agent.mcp_client import McpConnectionError

from claude_agent.workspace_bridge import (
    WorkspaceBridge,
    _escape_elisp_string,
    _extract_copilot_response,
    _extract_full_response,
    _format_todos_as_elisp,
    write_status,
)


# ----------------------------------------------------------------------
# Fixture helpers
# ----------------------------------------------------------------------


def make_bridge(mcp=None, org_file="/tmp/f.org", session_id="sid"):
    """Return a WorkspaceBridge with a default MagicMock MCP client."""
    return WorkspaceBridge(
        mcp=mcp if mcp is not None else MagicMock(),
        org_file=org_file,
        session_id=session_id,
    )


class TestWriteStatus:
    def test_writes_status_file(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        write_status("test-session", "busy")
        assert (tmp_path / "test-session").read_text() == "busy"

    def test_overwrites_existing(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        write_status("test-session", "busy")
        write_status("test-session", "ready")
        assert (tmp_path / "test-session").read_text() == "ready"


class TestCustomIdPersistence:
    """Custom-id read/write/clear are now methods on the bridge."""

    def test_write_and_read(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        bridge = make_bridge(session_id="sid")
        bridge._write_custom_id("sdd-123-instr-3")
        assert bridge._read_custom_id() == "sdd-123-instr-3"

    def test_read_missing(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        bridge = make_bridge(session_id="nonexistent")
        assert bridge._read_custom_id() is None

    def test_overwrite(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        bridge = make_bridge(session_id="sid")
        bridge._write_custom_id("sdd-123-instr-1")
        bridge._write_custom_id("sdd-123-instr-2")
        assert bridge._read_custom_id() == "sdd-123-instr-2"

    def test_clear_removes_file(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        bridge = make_bridge(session_id="sid")
        bridge._write_custom_id("cid")
        bridge._clear_custom_id()
        assert bridge._read_custom_id() is None

    def test_clear_missing_is_noop(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        bridge = make_bridge(session_id="never-written")
        bridge._clear_custom_id()  # should not raise


class TestCustomIdQueue:
    """Regression tests for the queue-based custom-id storage (PCR dev1 bug)."""

    def test_append_preserves_order(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        bridge = make_bridge(session_id="sid")
        bridge._append_custom_id("a")
        bridge._append_custom_id("b")
        bridge._append_custom_id("c")
        assert bridge._read_custom_ids() == ["a", "b", "c"]

    def test_read_custom_id_returns_newest(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        bridge = make_bridge(session_id="sid")
        bridge._append_custom_id("older")
        bridge._append_custom_id("newer")
        assert bridge._read_custom_id() == "newer"

    def test_clear_drains_queue(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        bridge = make_bridge(session_id="sid")
        bridge._append_custom_id("a")
        bridge._append_custom_id("b")
        bridge._clear_custom_ids()
        assert bridge._read_custom_ids() == []

    def test_write_custom_id_is_append(self, tmp_path, monkeypatch):
        """Back-compat alias should append, not overwrite (bug fix)."""
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        bridge = make_bridge(session_id="sid")
        bridge._write_custom_id("first")
        bridge._write_custom_id("second")
        assert bridge._read_custom_ids() == ["first", "second"]


class TestExtractTurns:
    """Per-turn transcript extraction — the other half of the supersede fix."""

    def _write_transcript(self, tmp_path, entries):
        path = tmp_path / "transcript.jsonl"
        path.write_text("\n".join(json.dumps(e) for e in entries))
        return str(path)

    def _user(self, text):
        return {
            "type": "user",
            "message": {"content": [{"type": "text", "text": text}]},
        }

    def _assistant(self, text):
        return {
            "type": "assistant",
            "message": {"content": [{"type": "text", "text": text}]},
        }

    def _assistant_tool(self, text):
        return {
            "type": "assistant",
            "message": {
                "content": [
                    {"type": "text", "text": text},
                    {"type": "tool_use", "name": "Bash", "input": {}},
                ]
            },
        }

    def test_single_turn(self, tmp_path):
        from claude_agent.workspace_bridge import _extract_turns

        path = self._write_transcript(
            tmp_path,
            [
                self._user("q"),
                self._assistant("a"),
            ],
        )
        assert _extract_turns(path) == [("q", "a")]

    def test_two_sequential_turns(self, tmp_path):
        from claude_agent.workspace_bridge import _extract_turns

        path = self._write_transcript(
            tmp_path,
            [
                self._user("q1"),
                self._assistant("a1"),
                self._user("q2"),
                self._assistant("a2"),
            ],
        )
        assert _extract_turns(path) == [("q1", "a1"), ("q2", "a2")]

    def test_superseded_first_turn_has_empty_assistant(self, tmp_path):
        """The PCR dev1 bug: user typed q2 before Claude finished q1."""
        from claude_agent.workspace_bridge import _extract_turns

        path = self._write_transcript(
            tmp_path,
            [
                self._user("q1"),
                self._user("q2"),
                self._assistant("a2"),
            ],
        )
        assert _extract_turns(path) == [("q1", ""), ("q2", "a2")]

    def test_tool_use_turns_skipped(self, tmp_path):
        from claude_agent.workspace_bridge import _extract_turns

        path = self._write_transcript(
            tmp_path,
            [
                self._user("q1"),
                self._assistant_tool("Let me check"),
                self._assistant("final answer"),
            ],
        )
        assert _extract_turns(path) == [("q1", "final answer")]

    def test_empty_transcript(self, tmp_path):
        from claude_agent.workspace_bridge import _extract_turns

        path = self._write_transcript(tmp_path, [])
        assert _extract_turns(path) == []

    def test_user_without_assistant(self, tmp_path):
        """Final user entry with no assistant follow-up (cancelled during generation)."""
        from claude_agent.workspace_bridge import _extract_turns

        path = self._write_transcript(
            tmp_path,
            [
                self._user("q1"),
                self._assistant("a1"),
                self._user("q2"),
            ],
        )
        assert _extract_turns(path) == [("q1", "a1"), ("q2", "")]


class TestHandleDispatch:
    """The ``handle`` method routes events to ``_handle_<event>``."""

    def test_known_event_dispatches(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        bridge = make_bridge()
        seen = []
        bridge._handle_prompt = lambda data: seen.append(("prompt", data))
        bridge.handle("prompt", {"prompt": "hi"})
        assert seen == [("prompt", {"prompt": "hi"})]

    def test_hyphenated_event_dispatches(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        bridge = make_bridge()
        seen = []
        bridge._handle_permission_clear = lambda data: seen.append(data)
        bridge.handle("permission-clear", {"tool_name": "X"})
        assert seen == [{"tool_name": "X"}]

    def test_unknown_event_warns_and_returns(self, capsys, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        bridge = make_bridge()
        bridge.handle("never-seen-event", {})
        assert "unknown event" in capsys.readouterr().err


class TestHandleResponseQueryCompleted:
    """``_handle_response`` notifies query-completed on every exit path."""

    def test_query_completed_called(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()
        bridge = make_bridge(mcp, session_id="sid")
        bridge._write_custom_id("instr-custom-id")
        bridge._handle_response({"last_assistant_message": "hello"})
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        assert any("code-agent-org--terminal-query-completed" in c for c in calls)

    def test_query_completed_called_even_without_response(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()
        bridge = make_bridge(mcp, session_id="sid")
        bridge._handle_response({})
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        assert any("code-agent-org--terminal-query-completed" in c for c in calls)


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
        return {
            "type": "user",
            "message": {"content": [{"type": "text", "text": text}]},
        }

    def _assistant(self, text):
        return {
            "type": "assistant",
            "message": {"content": [{"type": "text", "text": text}]},
        }

    def _assistant_with_tool(self, text, tool_name="Bash"):
        return {
            "type": "assistant",
            "message": {
                "content": [
                    {"type": "text", "text": text},
                    {"type": "tool_use", "name": tool_name, "input": {}},
                ]
            },
        }

    def _assistant_thinking(self, thinking, text):
        return {
            "type": "assistant",
            "message": {
                "content": [
                    {"type": "thinking", "text": thinking},
                    {"type": "text", "text": text},
                ]
            },
        }

    def test_single_turn(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._user("hello"),
                self._assistant("world"),
            ],
        )
        assert _extract_full_response(path) == "world"

    def test_multi_turn_skips_tool_use_turns(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._user("do X"),
                self._assistant_with_tool("Let me check"),
                self._assistant("Done! Here's the result."),
            ],
        )
        assert _extract_full_response(path) == "Done! Here's the result."

    def test_multi_turn_keeps_pure_text_turns(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._user("do X"),
                self._assistant_with_tool("Let me check"),
                self._assistant("First part."),
                self._assistant("Second part."),
            ],
        )
        assert _extract_full_response(path) == "First part.\n\nSecond part."

    def test_user_in_middle(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._user("first question"),
                self._assistant("first answer"),
                self._user("second question"),
                self._assistant("second answer"),
            ],
        )
        assert _extract_full_response(path) == "second answer"

    def test_thinking_blocks_skipped(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._user("think about this"),
                self._assistant_thinking("deep thoughts", "visible text"),
            ],
        )
        assert _extract_full_response(path) == "visible text"

    def test_empty_transcript(self, tmp_path):
        path = self._make_transcript(tmp_path, [])
        assert _extract_full_response(path) == ""

    def test_no_user_entry(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._assistant("hello"),
                self._assistant("world"),
            ],
        )
        assert _extract_full_response(path) == "hello\n\nworld"

    def test_all_tool_use_turns_returns_empty(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._user("do X"),
                self._assistant_with_tool("checking..."),
                self._assistant_with_tool("still working..."),
            ],
        )
        assert _extract_full_response(path) == ""

    def test_content_null_does_not_crash(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._user("hello"),
                {"type": "assistant", "message": {"content": None}},
                self._assistant("final answer"),
            ],
        )
        assert _extract_full_response(path) == "final answer"

    def test_content_null_only(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._user("hello"),
                {"type": "assistant", "message": {"content": None}},
            ],
        )
        assert _extract_full_response(path) == ""


class TestExtractCopilotResponse:
    """Tests for Copilot events.jsonl transcript parsing."""

    def _make_transcript(self, tmp_path, entries):
        transcript = tmp_path / "events.jsonl"
        lines = [json.dumps(e) for e in entries]
        transcript.write_text("\n".join(lines))
        return str(transcript)

    def _session_start(self):
        return {"type": "session.start", "data": {"sessionId": "abc-123"}}

    def _user_msg(self, text):
        return {"type": "user.message", "data": {"content": text}}

    def _assistant_msg(self, text, tool_requests=None):
        return {
            "type": "assistant.message",
            "data": {
                "content": text,
                "toolRequests": tool_requests or [],
            },
        }

    def test_single_turn(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._session_start(),
                self._user_msg("hello"),
                self._assistant_msg("Hello there!"),
            ],
        )
        assert _extract_copilot_response(path) == "Hello there!"

    def test_skips_tool_use_turns(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._session_start(),
                self._user_msg("do X"),
                self._assistant_msg(
                    "Let me check...", tool_requests=[{"tool": "bash"}]
                ),
                self._assistant_msg("Done! Here's the result."),
            ],
        )
        assert _extract_copilot_response(path) == "Done! Here's the result."

    def test_only_last_turn_after_user(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._session_start(),
                self._user_msg("first question"),
                self._assistant_msg("first answer"),
                self._user_msg("second question"),
                self._assistant_msg("second answer"),
            ],
        )
        assert _extract_copilot_response(path) == "second answer"

    def test_empty_transcript(self, tmp_path):
        path = self._make_transcript(tmp_path, [])
        assert _extract_copilot_response(path) == ""

    def test_no_user_message(self, tmp_path):
        path = self._make_transcript(
            tmp_path,
            [
                self._session_start(),
                self._assistant_msg("hello"),
                self._assistant_msg("world"),
            ],
        )
        assert _extract_copilot_response(path) == "hello\n\nworld"


class TestHandleResponseCopilotFormat:
    """handle_response handles Copilot's camelCase fields."""

    def test_camelcase_transcript_path(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        transcript = tmp_path / "events.jsonl"
        transcript.write_text(
            json.dumps({"type": "session.start", "data": {"sessionId": "abc"}})
            + "\n"
            + json.dumps({"type": "user.message", "data": {"content": "q"}})
            + "\n"
            + json.dumps(
                {
                    "type": "assistant.message",
                    "data": {"content": "answer", "toolRequests": []},
                }
            )
        )
        mcp = MagicMock()
        bridge = make_bridge(mcp, session_id="sid")
        bridge._write_custom_id("cid")
        bridge._handle_response({"transcriptPath": str(transcript), "sessionId": "abc"})
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        assert any("answer" in c for c in calls)

    def test_camelcase_session_id_saved(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()
        bridge = make_bridge(mcp, session_id="sid")
        bridge._write_custom_id("cid")
        bridge._handle_response(
            {"last_assistant_message": "hi", "sessionId": "copilot-session-123"}
        )
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        assert len(calls) > 0

    def test_auto_discover_copilot_events_jsonl(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        copilot_session_id = "abc-123-def"
        session_dir = tmp_path / ".copilot" / "session-state" / copilot_session_id
        session_dir.mkdir(parents=True)
        events_file = session_dir / "events.jsonl"
        events_file.write_text(
            json.dumps(
                {"type": "session.start", "data": {"sessionId": copilot_session_id}}
            )
            + "\n"
            + json.dumps({"type": "user.message", "data": {"content": "q"}})
            + "\n"
            + json.dumps(
                {
                    "type": "assistant.message",
                    "data": {"content": "discovered answer", "toolRequests": []},
                }
            )
        )
        monkeypatch.setattr(
            "os.path.expanduser", lambda p: str(tmp_path / p.lstrip("~/"))
        )
        mcp = MagicMock()
        bridge = make_bridge(mcp, session_id="sid")
        bridge._write_custom_id("cid")
        bridge._handle_response({"sessionId": copilot_session_id})
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        assert any("discovered answer" in c for c in calls)


class TestFormatTodosAsElisp:
    def test_basic(self):
        todos = [
            {"content": "Do X", "status": "completed"},
            {"content": "Do Y", "status": "pending"},
        ]
        result = _format_todos_as_elisp(todos)
        assert (
            result
            == '((:content "Do X" :status "completed" :priority 0) (:content "Do Y" :status "pending" :priority 0))'
        )

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
        todos = [{"content": "X", "status": "pending", "priority": "high"}]
        result = _format_todos_as_elisp(todos)
        assert ":priority 0" in result

    def test_non_numeric_priority_safe(self):
        todos = [{"content": "X", "status": "pending", "priority": "1) (evil"}]
        result = _format_todos_as_elisp(todos)
        assert ":priority 0" in result


class TestHandlePromptFiltering:
    """``_handle_prompt`` skips non-human prompts and saves custom_id."""

    def _make_mcp(self):
        mcp = MagicMock()
        mcp.eval_elisp = MagicMock(return_value="ok")
        return mcp

    def test_normal_prompt_calls_mcp(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = self._make_mcp()
        mcp.eval_elisp.return_value = "sid-instr-1"
        bridge = make_bridge(mcp)
        bridge._handle_prompt({"prompt": "explain this function"})
        assert mcp.eval_elisp.called

    def test_prompt_saves_custom_id(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = self._make_mcp()
        mcp.eval_elisp.return_value = "sdd-123-instr-5"
        bridge = make_bridge(mcp, session_id="sid")
        bridge._handle_prompt({"prompt": "do X"})
        assert bridge._read_custom_id() == "sdd-123-instr-5"

    def test_task_notification_skipped(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = self._make_mcp()
        prompt = (
            "<task-notification>\n"
            "<task-id>abc123</task-id>\n"
            "<status>completed</status>\n"
            '<summary>Agent "Research" completed</summary>\n'
            "<result>Found the answer.</result>\n"
            "</task-notification>"
        )
        bridge = make_bridge(mcp)
        bridge._handle_prompt({"prompt": prompt})
        assert not mcp.eval_elisp.called

    def test_system_reminder_skipped(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = self._make_mcp()
        prompt = "<system-reminder>\nThe task tools haven't been used recently.\n</system-reminder>"
        bridge = make_bridge(mcp)
        bridge._handle_prompt({"prompt": prompt})
        assert not mcp.eval_elisp.called

    def test_empty_prompt_skipped(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = self._make_mcp()
        bridge = make_bridge(mcp)
        bridge._handle_prompt({"prompt": ""})
        assert not mcp.eval_elisp.called


class TestHandleResponseSupersede:
    """PCR dev1 bug regression tests: two prompts + one Stop.

    Before the fix, only the newest prompt got a response and the older
    was stuck at AI_EXEC_STATUS: executing.  After the fix, the older
    gets marked cancelled and the newer gets its response.
    """

    def _mcp_returning_each_prompt_id(self, ids):
        """Mock that returns a different custom-id per insert-prompt call."""
        mcp = MagicMock()
        remaining = list(ids)

        def _side_effect(elisp):
            if "insert-prompt" in elisp:
                return remaining.pop(0) if remaining else "leftover"
            return None

        mcp.eval_elisp.side_effect = _side_effect
        return mcp

    def _write_transcript(self, tmp_path, entries):
        path = tmp_path / "transcript.jsonl"
        path.write_text("\n".join(json.dumps(e) for e in entries))
        return str(path)

    def test_two_prompts_one_stop_inserts_both_actions(self, tmp_path, monkeypatch):
        """Two UserPromptSubmit events followed by one Stop: response
        for the newer prompt + cancelled mark for the older prompt."""
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = self._mcp_returning_each_prompt_id(["cid-older", "cid-newer"])
        bridge = make_bridge(mcp, session_id="sid", org_file="/tmp/test.org")

        bridge._handle_prompt({"prompt": "q1"})
        bridge._handle_prompt({"prompt": "q2"})
        assert bridge._read_custom_ids() == ["cid-older", "cid-newer"]

        transcript = self._write_transcript(
            tmp_path,
            [
                {
                    "type": "user",
                    "message": {"content": [{"type": "text", "text": "q1"}]},
                },
                {
                    "type": "user",
                    "message": {"content": [{"type": "text", "text": "q2"}]},
                },
                {
                    "type": "assistant",
                    "message": {"content": [{"type": "text", "text": "a2"}]},
                },
            ],
        )

        mcp.eval_elisp.side_effect = None
        calls = []
        mcp.eval_elisp.side_effect = lambda elisp: calls.append(elisp) or None

        bridge._handle_response({"transcript_path": transcript})

        flat = "\n".join(calls)
        assert "workspace-bridge-mark-cancelled" in flat
        assert "cid-older" in flat
        assert "workspace-bridge-insert-response" in flat
        assert "cid-newer" in flat
        # The queue should be drained after Stop processes it.
        assert bridge._read_custom_ids() == []

    def test_three_prompts_two_responses_one_cancelled(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = self._mcp_returning_each_prompt_id(["A", "B", "C"])
        bridge = make_bridge(mcp, session_id="sid", org_file="/tmp/test.org")
        bridge._handle_prompt({"prompt": "q1"})
        bridge._handle_prompt({"prompt": "q2"})
        bridge._handle_prompt({"prompt": "q3"})

        # Transcript: q1→a1, then q2 superseded by q3, then a3.
        transcript = self._write_transcript(
            tmp_path,
            [
                {
                    "type": "user",
                    "message": {"content": [{"type": "text", "text": "q1"}]},
                },
                {
                    "type": "assistant",
                    "message": {"content": [{"type": "text", "text": "a1"}]},
                },
                {
                    "type": "user",
                    "message": {"content": [{"type": "text", "text": "q2"}]},
                },
                {
                    "type": "user",
                    "message": {"content": [{"type": "text", "text": "q3"}]},
                },
                {
                    "type": "assistant",
                    "message": {"content": [{"type": "text", "text": "a3"}]},
                },
            ],
        )

        calls = []
        mcp.eval_elisp.side_effect = lambda elisp: calls.append(elisp) or None
        bridge._handle_response({"transcript_path": transcript})

        responses = [c for c in calls if "insert-response" in c]
        cancels = [c for c in calls if "mark-cancelled" in c]
        assert len(responses) == 2, "A and C should get responses"
        assert any('"A"' in c or "a1" in c for c in responses)
        assert any('"C"' in c or "a3" in c for c in responses)
        assert len(cancels) == 1, "B should be cancelled"
        assert any('"B"' in c for c in cancels)
        assert bridge._read_custom_ids() == []


class TestHandleResponseSentinelPrompt:
    """Regression guard: /loop autonomous sentinels + other `<`-prefixed
    prompts whose UserPromptSubmit was filtered must still route their
    assistant response to the most-recent instruction's Response section.

    Observed 2026-04-22 in `skills-network-dev.org :: PCR dev1`: the
    autonomous-loop iteration's substantive response ("Profiling done —
    byte-identical parity preserved") was silently dropped because
    `_mint_missing_custom_id` couldn't mint a new instruction from the
    sentinel's `last_user_message` and the code returned early.
    """

    def test_sentinel_response_routes_to_latest_instruction(
        self, tmp_path, monkeypatch
    ):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()

        # Simulate the autonomous-loop scenario:
        # - _mint_missing_custom_id sees empty last_user_message → returns None
        # - Our fallback queries the latest-instruction-custom-id
        # - Then inserts response under that id
        def _side_effect(elisp):
            if "latest-instruction-custom-id" in elisp:
                return "skills-network-dev-instruction-52-sdd-82544"
            return None

        mcp.eval_elisp.side_effect = _side_effect
        bridge = make_bridge(mcp, session_id="sid-982", org_file="/tmp/test.org")

        # Transcript path exists so we don't hit the spurious-Stop branch.
        transcript = tmp_path / "t.jsonl"
        transcript.write_text(
            json.dumps(
                {
                    "type": "user",
                    "message": {
                        "content": [
                            {"type": "text", "text": "<<autonomous-loop-dynamic>>"}
                        ]
                    },
                }
            )
            + "\n"
            + json.dumps(
                {
                    "type": "assistant",
                    "message": {
                        "content": [
                            {"type": "text", "text": "Profiling done — parity OK"}
                        ]
                    },
                }
            )
        )

        bridge._handle_response(
            {
                "transcript_path": str(transcript),
                # Claude Code often omits the sentinel from last_user_message
                # (or leaves it empty) — our fallback must handle both.
                "last_user_message": "",
            }
        )

        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        joined = "\n".join(calls)
        assert "latest-instruction-custom-id" in joined, (
            "fallback should query for the newest instruction"
        )
        # Response should be inserted under the returned latest cid.
        assert any(
            "insert-response" in c
            and "instruction-52-sdd-82544" in c
            and "Profiling done" in c
            for c in calls
        ), "response must be inserted under the latest instruction's cid"

    def test_sentinel_no_existing_instruction_drops_response(
        self, tmp_path, monkeypatch
    ):
        """If the workspace has no instructions at all, the fallback
        returns None and we drop the response rather than synthesise a
        ghost heading."""
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()
        mcp.eval_elisp.return_value = None  # no latest cid
        bridge = make_bridge(mcp, session_id="empty-sid", org_file="/tmp/t.org")

        transcript = tmp_path / "t.jsonl"
        transcript.write_text(
            json.dumps(
                {
                    "type": "user",
                    "message": {
                        "content": [
                            {"type": "text", "text": "<<autonomous-loop-dynamic>>"}
                        ]
                    },
                }
            )
            + "\n"
            + json.dumps(
                {
                    "type": "assistant",
                    "message": {"content": [{"type": "text", "text": "some work"}]},
                }
            )
        )
        bridge._handle_response(
            {"transcript_path": str(transcript), "last_user_message": ""}
        )
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        # No insert-response happens when there's nowhere to route to.
        assert all("insert-response" not in c for c in calls)


class TestHandleResponseSpuriousStop:
    """A Stop without a Claude Code transcript must NOT drain the queue.

    Regression guard for the 2026-04-22 bug where a spurious Stop
    (opencode E2E hook leaking through shared env vars during a
    parallel test run) drained the queue and inserted the wrong
    response text ("first") under a queued claude instruction.
    """

    def test_spurious_stop_preserves_queue(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()
        bridge = make_bridge(mcp, session_id="sid", org_file="/tmp/test.org")
        bridge._append_custom_id("cid-genuine")
        # Stop arrives with no transcript_path and a foreign
        # last_assistant_message (the opencode E2E output).
        bridge._handle_response(
            {"last_assistant_message": "first", "last_user_message": "Say only: first"}
        )
        # Queue is preserved — the real Claude Code Stop will drain it later.
        assert bridge._read_custom_ids() == ["cid-genuine"]
        # No insert-response MCP call happened with "first".
        for call in mcp.eval_elisp.call_args_list:
            elisp = call[0][0]
            assert "insert-response" not in elisp or "first" not in elisp

    def test_spurious_stop_empty_queue_falls_through_legacy(
        self, tmp_path, monkeypatch
    ):
        """When queue IS empty, the legacy path still mints a custom-id
        and inserts the response — preserves backward-compat for
        terminal-typed prompts that never fired UserPromptSubmit."""
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()
        mcp.eval_elisp.side_effect = ["freshly-minted-cid", None, None]
        bridge = make_bridge(mcp, session_id="sid", org_file="/tmp/test.org")
        bridge._handle_response(
            {"last_assistant_message": "hello", "last_user_message": "hi"}
        )
        calls = "\n".join(str(c) for c in mcp.eval_elisp.call_args_list)
        assert "insert-prompt" in calls  # minted a custom-id
        assert "insert-response" in calls  # inserted the response


class TestHandlePermission:
    """Tests for PreToolUse permission notification."""

    def test_ask_user_question_notifies_emacs(self, capsys):
        mcp = MagicMock()
        bridge = make_bridge(mcp)
        bridge._handle_permission({"tool_name": "AskUserQuestion"})
        call_arg = mcp.eval_elisp.call_args[0][0]
        assert "code-agent-org--terminal-permission-needed" in call_arg
        assert "AskUserQuestion" in call_arg
        output = json.loads(capsys.readouterr().out)
        assert output["hookSpecificOutput"]["permissionDecision"] == "ask"

    def test_exit_plan_mode_notifies_emacs(self, capsys):
        mcp = MagicMock()
        bridge = make_bridge(mcp)
        bridge._handle_permission({"tool_name": "ExitPlanMode"})
        assert mcp.eval_elisp.called
        output = json.loads(capsys.readouterr().out)
        assert output["hookSpecificOutput"]["permissionDecision"] == "ask"

    def test_regular_tool_no_notification(self, capsys):
        mcp = MagicMock()
        bridge = make_bridge(mcp)
        bridge._handle_permission({"tool_name": "Bash"})
        assert not mcp.eval_elisp.called
        assert capsys.readouterr().out == ""

    def test_ask_even_on_mcp_failure(self, capsys):
        mcp = MagicMock()
        mcp.eval_elisp.side_effect = McpConnectionError("unreachable")
        bridge = make_bridge(mcp)
        bridge._handle_permission({"tool_name": "AskUserQuestion"})
        output = json.loads(capsys.readouterr().out)
        assert output["hookSpecificOutput"]["permissionDecision"] == "ask"


class TestHandlePermissionClear:
    """Tests for PostToolUse permission clear."""

    def test_clears_in_emacs_for_interactive_tool(self):
        mcp = MagicMock()
        bridge = make_bridge(mcp)
        bridge._handle_permission_clear({"tool_name": "AskUserQuestion"})
        call_arg = mcp.eval_elisp.call_args[0][0]
        assert "code-agent-org--terminal-permission-resolved" in call_arg
        assert "sid" in call_arg

    def test_clears_in_emacs_for_exit_plan_mode(self):
        mcp = MagicMock()
        bridge = make_bridge(mcp)
        bridge._handle_permission_clear({"tool_name": "ExitPlanMode"})
        call_arg = mcp.eval_elisp.call_args[0][0]
        assert "code-agent-org--terminal-permission-resolved" in call_arg

    def test_skips_mcp_for_non_interactive_tool(self):
        mcp = MagicMock()
        bridge = make_bridge(mcp)
        bridge._handle_permission_clear({"tool_name": "Bash"})
        mcp.eval_elisp.assert_not_called()

    def test_skips_mcp_for_unknown_tool(self):
        mcp = MagicMock()
        bridge = make_bridge(mcp)
        bridge._handle_permission_clear({})
        mcp.eval_elisp.assert_not_called()

    def test_swallows_mcp_errors(self):
        mcp = MagicMock()
        mcp.eval_elisp.side_effect = McpConnectionError("gone")
        bridge = make_bridge(mcp)
        bridge._handle_permission_clear({"tool_name": "AskUserQuestion"})


class TestMcpEval:
    """Tests for the bridge's ``_mcp_eval`` method (trace-context wrapping)."""

    def test_passes_elisp_without_active_span(self):
        mcp = MagicMock()
        mcp.eval_elisp.return_value = "result"
        bridge = make_bridge(mcp)
        result = bridge._mcp_eval("(+ 1 2)")
        assert result == "result"
        call_arg = mcp.eval_elisp.call_args[0][0]
        # No active span → no wrapping
        assert "(+ 1 2)" in call_arg

    def test_wraps_elisp_with_active_span(self, monkeypatch):
        mock_ctx = MagicMock()
        mock_ctx.is_valid = True
        mock_ctx.trace_id = 0xAABBCCDDEEFF0011AABBCCDDEEFF0011
        mock_ctx.span_id = 0x1122334455667788

        mock_span = MagicMock()
        mock_span.get_span_context.return_value = mock_ctx

        import claude_agent.workspace_bridge as bridge_mod

        monkeypatch.setattr(
            bridge_mod.otel_trace, "get_current_span", lambda: mock_span
        )

        mcp = MagicMock()
        mcp.eval_elisp.return_value = "ok"
        bridge = make_bridge(mcp)
        bridge._mcp_eval("(my-func)")
        call_arg = mcp.eval_elisp.call_args[0][0]
        assert "claude-agent-trace--current-context" in call_arg
        assert "aabbccddeeff0011aabbccddeeff0011" in call_arg
        assert "1122334455667788" in call_arg
        assert "(my-func)" in call_arg

    def test_propagates_mcp_errors(self):
        mcp = MagicMock()
        mcp.eval_elisp.side_effect = McpConnectionError("timeout")
        bridge = make_bridge(mcp)
        with pytest.raises(McpConnectionError):
            bridge._mcp_eval("(fail)")


class TestHandleResponsePromptInsertion:
    """``_handle_response`` mints a custom_id when OpenCode provides none."""

    def test_terminal_prompt_inserts_prompt_then_response(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()
        mcp.eval_elisp.side_effect = ["test-custom-id", None, None]
        bridge = make_bridge(mcp, session_id="sid")
        bridge._handle_response(
            {
                "last_assistant_message": "the response",
                "last_user_message": "the prompt",
            }
        )
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        assert "insert-prompt" in calls[0]
        assert "the prompt" in calls[0]
        assert "insert-response" in calls[1]
        assert "test-custom-id" in calls[1]
        assert "the response" in calls[1]

    def test_no_custom_id_no_user_message_falls_back_to_latest(
        self, tmp_path, monkeypatch
    ):
        """Updated 2026-04-22: no last_user_message → can't mint a new
        instruction, but the fallback now queries for the latest
        instruction and appends there so the response isn't lost."""
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()
        # Fallback returns a fake latest-instruction cid.
        mcp.eval_elisp.side_effect = lambda elisp: (
            "latest-cid" if "latest-instruction-custom-id" in elisp else None
        )
        bridge = make_bridge(mcp, session_id="sid")
        bridge._handle_response({"last_assistant_message": "orphan response"})
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        assert any("latest-instruction-custom-id" in c for c in calls)
        assert any(
            "insert-response" in c and "latest-cid" in c and "orphan response" in c
            for c in calls
        )

    def test_no_custom_id_no_user_message_no_latest_drops(self, tmp_path, monkeypatch):
        """If there's no instruction at all, the response is dropped."""
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()
        mcp.eval_elisp.return_value = None
        bridge = make_bridge(mcp, session_id="sid")
        bridge._handle_response({"last_assistant_message": "orphan response"})
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        assert all("insert-response" not in c for c in calls)

    def test_from_emacs_flag_without_transcript_preserves_queue(
        self, tmp_path, monkeypatch
    ):
        """Updated 2026-04-22 for the 'first' regression fix.

        A Stop arriving without a usable transcript_path no longer
        drains the queue via `last_assistant_message'.  The queued
        custom-id is kept intact so the real Claude Code Stop (with a
        valid transcript) can route against it later.  Prevents
        cross-agent response leakage observed when opencode test
        output was inserted under a claude instruction."""
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        (tmp_path / "sid.from-emacs").write_text("1")
        bridge = make_bridge(MagicMock(), session_id="sid")
        bridge._write_custom_id("emacs-custom-id")
        mcp = MagicMock()
        bridge = make_bridge(mcp, session_id="sid")
        bridge._handle_response(
            {"last_assistant_message": "response", "last_user_message": "prompt"}
        )
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        # Queue preserved — no insert-response fired.
        assert all("insert-response" not in c for c in calls)
        assert all("insert-prompt" not in c for c in calls)
        assert bridge._read_custom_ids() == ["emacs-custom-id"]

    def test_from_emacs_flag_no_custom_id_falls_back_to_latest(
        self, tmp_path, monkeypatch
    ):
        """Updated 2026-04-22: from-emacs flag present but no custom-id
        in file → mint returns None → fallback queries latest
        instruction so the response still lands somewhere visible."""
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        (tmp_path / "sid.from-emacs").write_text("1")
        mcp = MagicMock()
        mcp.eval_elisp.side_effect = lambda elisp: (
            "latest-cid" if "latest-instruction-custom-id" in elisp else None
        )
        bridge = make_bridge(mcp, session_id="sid")
        bridge._handle_response(
            {"last_assistant_message": "response", "last_user_message": "prompt"}
        )
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        # Fallback used — no NEW prompt minted, response routed to latest.
        assert all("insert-prompt" not in c for c in calls)
        assert any("insert-response" in c and "latest-cid" in c for c in calls)
        assert not (tmp_path / "sid.from-emacs").exists()

    def test_insert_prompt_failure_returns_early(self, tmp_path, monkeypatch):
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()
        mcp.eval_elisp.side_effect = McpConnectionError("timeout")
        bridge = make_bridge(mcp, session_id="sid")
        bridge._handle_response(
            {"last_assistant_message": "response", "last_user_message": "prompt"}
        )
        calls = [str(c) for c in mcp.eval_elisp.call_args_list]
        assert all("insert-response" not in c for c in calls)

    def test_custom_id_written_after_prompt_insertion(self, tmp_path, monkeypatch):
        """After successful insert-prompt, custom_id is persisted to disk."""
        monkeypatch.setattr("claude_agent.workspace_bridge.STATUS_DIR", str(tmp_path))
        mcp = MagicMock()
        mcp.eval_elisp.side_effect = ["new-custom-id", None, None]
        bridge = make_bridge(mcp, session_id="sid")
        bridge._handle_response(
            {"last_assistant_message": "resp", "last_user_message": "prompt"}
        )
        assert bridge._read_custom_id() == "new-custom-id"


class TestWorkspaceBridgeProtocol:
    """The published protocol is satisfied by the concrete class (structural)."""

    def test_concrete_has_handle_method(self):
        from claude_agent.workspace_bridge import WorkspaceBridgeProtocol

        bridge = make_bridge()
        # Structural: any object with a callable `handle(event, data)` fits.
        assert callable(getattr(bridge, "handle", None))
        # typing.Protocol isinstance check (requires runtime_checkable — we
        # didn't decorate it because the contract is compile-time; just verify
        # the method signature exists).
        assert "handle" in dir(WorkspaceBridgeProtocol)
