"""Shared pytest fixtures for code-agent tests."""

import pytest

from claude_agent.mcp_client import McpClient

MCP_URL = "http://localhost:9999/mcp"


@pytest.fixture
def mcp():
    """Real Emacs MCP client. Skips test if server is not running."""
    client = McpClient(url=MCP_URL)
    if not client.ping():
        pytest.skip("Emacs MCP server not running")
    return client
