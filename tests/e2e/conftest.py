"""Pytest fixtures for E2E tests against Emacs MCP server."""

import pytest

from emacs_harness import EmacsHarness


@pytest.fixture(scope="session")
def emacs():
    """Session-scoped Emacs harness.

    Starts a batch Emacs with MCP server before any tests run,
    and stops it after all tests complete.
    """
    h = EmacsHarness()
    h.start(timeout=30)
    yield h
    h.stop()
