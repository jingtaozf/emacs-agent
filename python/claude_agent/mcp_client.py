"""Synchronous MCP ``evalElisp`` client over HTTP.

Thin wrapper around the single MCP tool this project cares about —
``evalElisp`` — exposed by the Emacs-side MCP server running inside
the user's Emacs. Every other module that needs to talk to Emacs goes
through this class so the transport is swappable (tests substitute a
``MagicMock()``), the JSON-RPC protocol details stay here, and the
awkward double-wrapped response format is decoded once.

Why synchronous: the launchers and hook handlers run as short-lived
subprocesses — a blocking ``urlopen`` is simpler than an async loop
and the extra latency is irrelevant at that scale. A long-running
caller (agent trace exporter, live dashboard) should wrap the client
in a thread rather than awaitifying it.

No external dependencies — only ``stdlib.urllib``. This keeps the
bridge usable from bare-minimum Python environments (the CLI hook
scripts especially).
"""

from __future__ import annotations

import itertools
import json
import urllib.error
import urllib.request
from typing import Protocol


# ======================================================================
# Exceptions
# ======================================================================


class McpElispError(Exception):
    """Raised when Emacs reports an error while evaluating elisp."""


class McpConnectionError(Exception):
    """Raised when the HTTP call to the Emacs MCP server fails."""


# ======================================================================
# Protocol — the published contract other modules depend on
# ======================================================================


class McpClientProtocol(Protocol):
    """Contract every MCP client implementation must satisfy.

    Declared as a ``typing.Protocol`` (structural) so tests can
    substitute a ``MagicMock()`` without inheriting from the concrete
    class; the Smalltalk-style guidance in
    ``.claude/rules/oop-smalltalk-protocols.md`` calls this pattern out
    explicitly.
    """

    def eval_elisp(self, code: str) -> str | None: ...

    def ping(self) -> bool: ...


# ======================================================================
# McpClient
# ======================================================================


class McpClient:
    """Concrete synchronous MCP client.

    One instance holds the target URL, the two timeouts, and a
    monotonic request-id counter. Multiple clients point at different
    Emacs instances side-by-side without sharing id space.
    """

    def __init__(
        self,
        url: str = "http://localhost:9999/mcp",
        connect_timeout: float = 3.0,
        read_timeout: float = 10.0,
    ):
        self.url = url
        self.connect_timeout = connect_timeout
        self.read_timeout = read_timeout
        # Per-instance id generator — JSON-RPC id space is
        # per-connection, not global.
        self._id_counter = itertools.count(1)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def eval_elisp(self, code: str) -> str | None:
        """Evaluate CODE in Emacs and return the unwrapped result string.

        The MCP response is JSON around JSON::

            {"result": {"content": [{"text":
              "{\\"success\\":true,\\"result\\":\\"2\\\\n\\"}"
            }]}}

        We decode the outer envelope, parse the inner payload, strip
        surrounding quotes, and return the trimmed result. Returns
        ``None`` on a malformed envelope so callers that care treat it
        as "no value". ``success: false`` raises :class:`McpElispError`.
        """
        body = self._post_jsonrpc(code)
        return self._decode_response(body)

    def ping(self) -> bool:
        """Return True iff Emacs answers ``(+ 1 1)`` with ``"2"``."""
        try:
            return self.eval_elisp("(+ 1 1)") == "2"
        except (McpConnectionError, McpElispError):
            return False

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _post_jsonrpc(self, code: str) -> str:
        """Send the JSON-RPC ``tools/call`` request; return the raw body."""
        payload = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": next(self._id_counter),
                "method": "tools/call",
                "params": {
                    "name": "evalElisp",
                    "arguments": {"code": code},
                },
            }
        ).encode()
        req = urllib.request.Request(
            self.url,
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        try:
            resp = urllib.request.urlopen(req, timeout=self.read_timeout)
            return resp.read().decode()
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            raise McpConnectionError(f"Connection failed: {exc}") from exc

    def _decode_response(self, body: str) -> str | None:
        """Unwrap the double-JSON envelope or return None on malformation."""
        try:
            outer = json.loads(body)
            text = outer["result"]["content"][0]["text"]
            inner = json.loads(text)
            if not inner.get("success", True):
                raise McpElispError(inner.get("error", "Emacs returned success=false"))
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
