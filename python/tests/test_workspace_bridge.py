"""Tests for the workspace bridge's SessionStart handler.

Regression tests for the 2026-07-12 stale-resume bug: launch/restart
builds ``--resume`` from the ``CLAUDE_CLI_SESSION`` org property, and
``_handle_session_start`` is the only writer of that property.  These
tests pin the emitted elisp shape (routing key, escaping, property
dispatch) with a fake MCP client — no Emacs required.
"""

from unittest.mock import MagicMock

import pytest

from code_agent.workspace_bridge import WorkspaceBridge, _cli_session_property


def _make_bridge(**kwargs):
    mcp = MagicMock()
    mcp.eval_elisp = MagicMock(return_value="t")
    bridge = WorkspaceBridge(
        mcp=mcp,
        org_file=kwargs.get("org_file", "/tmp/ws.org"),
        session_id=kwargs.get("session_id", "ws-A"),
        tracer=None,
        workspace_custom_id=kwargs.get("workspace_custom_id", ""),
        cmux_workspace="",
    )
    return bridge, mcp


def test_session_start_persists_cli_session():
    bridge, mcp = _make_bridge()
    bridge.handle("session-start", {"session_id": "new-222"})
    assert mcp.eval_elisp.call_count == 1
    elisp = mcp.eval_elisp.call_args[0][0]
    assert "code-agent-org-workspace-bridge-save-cli-session" in elisp
    assert '"/tmp/ws.org"' in elisp
    assert '"ws-A"' in elisp
    assert '"new-222"' in elisp
    assert '"CLAUDE_CLI_SESSION"' in elisp


def test_session_start_routes_by_custom_id_when_present():
    bridge, mcp = _make_bridge(workspace_custom_id="ws-custom-42")
    bridge.handle("session-start", {"session_id": "new-222"})
    elisp = mcp.eval_elisp.call_args[0][0]
    assert '"ws-custom-42"' in elisp
    assert '"ws-A"' not in elisp


def test_session_start_without_session_id_is_noop():
    bridge, mcp = _make_bridge()
    bridge.handle("session-start", {})
    mcp.eval_elisp.assert_not_called()


def test_session_start_accepts_camel_case_key():
    bridge, mcp = _make_bridge()
    bridge.handle("session-start", {"sessionId": "camel-333"})
    assert '"camel-333"' in mcp.eval_elisp.call_args[0][0]


def test_session_start_escapes_elisp_metacharacters():
    bridge, mcp = _make_bridge(org_file='/tmp/we"ird.org')
    bridge.handle("session-start", {"session_id": "new-222"})
    elisp = mcp.eval_elisp.call_args[0][0]
    assert '/tmp/we\\"ird.org' in elisp


def test_session_start_survives_mcp_failure():
    from code_agent.mcp_client import McpConnectionError

    bridge, mcp = _make_bridge()
    mcp.eval_elisp.side_effect = McpConnectionError("down")
    bridge.handle("session-start", {"session_id": "new-222"})  # must not raise


def test_cli_session_property_dispatches_on_agent_type(monkeypatch):
    monkeypatch.setenv("AGENT_TYPE", "copilot")
    assert _cli_session_property() == "COPILOT_CLI_SESSION"
    monkeypatch.setenv("AGENT_TYPE", "claude")
    assert _cli_session_property() == "CLAUDE_CLI_SESSION"
    monkeypatch.delenv("AGENT_TYPE")
    assert _cli_session_property() == "CLAUDE_CLI_SESSION"


def test_unknown_event_still_warns_not_raises(capsys):
    bridge, _ = _make_bridge()
    bridge.handle("some-future-event", {})
    assert "unknown event" in capsys.readouterr().err
