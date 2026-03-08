"""Shared MCP evalElisp HTTP client.

Handles the double-wrapped JSON response format natively in Python.
Uses stdlib urllib — no external dependencies.
"""

import json
import urllib.request
import urllib.error


class McpClient:
    """Synchronous MCP client for evalElisp calls."""

    def __init__(
        self,
        url: str = "http://localhost:9999/mcp",
        connect_timeout: float = 3.0,
        read_timeout: float = 10.0,
    ):
        self.url = url
        self.connect_timeout = connect_timeout
        self.read_timeout = read_timeout

    def eval_elisp(self, code: str) -> str | None:
        """Evaluate elisp via MCP and return the result string.

        The MCP response is double-wrapped JSON:
          {"result":{"content":[{"text":"{\\"success\\":true,\\"result\\":\\"2\\\\n\\"}"}]}}

        Returns the inner result string, or None on any failure.
        """
        payload = json.dumps({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "evalElisp",
                "arguments": {"code": code},
            },
        }).encode()
        req = urllib.request.Request(
            self.url,
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        try:
            resp = urllib.request.urlopen(req, timeout=self.read_timeout)
            body = resp.read().decode()
        except (urllib.error.URLError, OSError, TimeoutError):
            return None

        try:
            outer = json.loads(body)
            text = outer["result"]["content"][0]["text"]
            inner = json.loads(text)
            result = inner.get("result")
            if result is None:
                return None
            result = str(result).strip()
            if result.startswith('"') and result.endswith('"'):
                result = result[1:-1]
            result = result.replace("\\n", "\n")
            return result.rstrip()
        except (json.JSONDecodeError, KeyError, IndexError, TypeError):
            return None

    def ping(self) -> bool:
        """Check MCP connectivity by evaluating (+ 1 1)."""
        result = self.eval_elisp("(+ 1 1)")
        return result == "2"
