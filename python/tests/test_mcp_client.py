"""Tests for the MCP client module."""

import pytest

from claude_agent.mcp_client import McpClient


class TestMcpClientUnit:
    """Tests that need no server."""

    def test_connection_refused(self):
        client = McpClient(url="http://127.0.0.1:1/mcp", connect_timeout=0.5)
        assert client.ping() is False
        assert client.eval_elisp("(+ 1 1)") is None


class TestMcpClientIntegration:
    """Tests against real Emacs MCP server."""

    def test_ping(self, mcp):
        assert mcp.ping() is True

    def test_eval_simple(self, mcp):
        assert mcp.eval_elisp("(+ 1 1)") == "2"

    def test_eval_string(self, mcp):
        result = mcp.eval_elisp('(concat "hello" " " "world")')
        assert result == "hello world"

    def test_eval_nil(self, mcp):
        result = mcp.eval_elisp("nil")
        assert result in (None, "nil")

    def test_eval_list(self, mcp):
        result = mcp.eval_elisp("(list 1 2 3)")
        assert result is not None
        assert "1" in result
