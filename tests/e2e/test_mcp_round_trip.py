"""MCP round-trip E2E tests.

These tests require a running Emacs with MCP server (provided by
the `emacs` session fixture in conftest.py).
"""

import json
import threading

import pytest


class TestEvalElisp:
    """Tests for evalElisp tool calls."""

    def test_eval_simple_expression(self, emacs):
        """Eval a simple arithmetic expression."""
        result = emacs.eval_elisp("(+ 1 2)")
        # Result should contain the evaluation output
        assert result is not None

    def test_eval_with_error(self, emacs):
        """Eval an expression that signals an error."""
        result = emacs.eval_elisp("(error \"test error\")")
        # Should return error information, not crash
        assert result is not None

    def test_eval_nil_result(self, emacs):
        """Eval an expression that returns nil."""
        result = emacs.eval_elisp("nil")
        assert result is not None

    def test_eval_long_output(self, emacs):
        """Eval an expression producing long output to test truncation."""
        result = emacs.eval_elisp(
            "(mapconcat #'number-to-string (number-sequence 1 1000) \" \")"
        )
        assert result is not None

    def test_eval_special_characters(self, emacs):
        """Eval with special characters in strings."""
        result = emacs.eval_elisp(
            '(concat "hello\\nworld" "\\t" "quo\\"te")'
        )
        assert result is not None


class TestReportInvocation:
    """Tests for report_invocation tool."""

    def test_report_invocation(self, emacs):
        """Call report_invocation and verify it succeeds."""
        result = emacs.call_tool("report_invocation", {
            "arguments": {
                "session_id": "test-session-123",
                "cwd": "/tmp",
            },
        })
        assert result is not None


class TestToolsList:
    """Tests for tools/list discovery."""

    def test_tools_list_returns_tools(self, emacs):
        """tools/list should return a non-empty list of tool definitions."""
        result = emacs.list_tools()
        assert result is not None
        # Should have a tools key with at least evalElisp
        tools = result.get("tools", [])
        tool_names = [t.get("name") for t in tools]
        assert "evalElisp" in tool_names


class TestInitialize:
    """Tests for MCP initialize handshake."""

    def test_initialize_handshake(self, emacs):
        """initialize should return server info and capabilities."""
        result = emacs.initialize()
        assert result is not None
        # Should be a valid JSON-RPC response
        assert "result" in result or "error" not in result


class TestConcurrency:
    """Tests for concurrent request handling."""

    def test_concurrent_requests(self, emacs):
        """Two concurrent eval requests should both complete."""
        results = [None, None]
        errors = [None, None]

        def run_eval(idx, code):
            try:
                results[idx] = emacs.eval_elisp(code)
            except Exception as e:
                errors[idx] = e

        t1 = threading.Thread(target=run_eval, args=(0, "(+ 1 1)"))
        t2 = threading.Thread(target=run_eval, args=(1, "(+ 2 2)"))

        t1.start()
        t2.start()
        t1.join(timeout=15)
        t2.join(timeout=15)

        assert errors[0] is None, f"Request 0 failed: {errors[0]}"
        assert errors[1] is None, f"Request 1 failed: {errors[1]}"
        assert results[0] is not None
        assert results[1] is not None


class TestErrorHandling:
    """Tests for error conditions."""

    def test_missing_tool_name(self, emacs):
        """Calling a non-existent tool should return an error."""
        with pytest.raises(Exception):
            emacs.call_tool("nonexistent_tool_xyz", {
                "arguments": {},
            })
