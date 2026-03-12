"""Emacs E2E test harness.

Start/stop a batch Emacs process with MCP server for integration testing.
Communicates via HTTP to the MCP server endpoint.
"""

import json
import os
import signal
import socket
import subprocess
import time
from pathlib import Path

import requests


class EmacsHarness:
    """Manages a batch Emacs instance with MCP server for E2E tests."""

    def __init__(self, init_file=None):
        self.process = None
        self.port = None
        self._project_root = Path(__file__).resolve().parent.parent.parent
        self._init_file = init_file or str(
            self._project_root / "tests" / "e2e" / "emacs-e2e-init.el"
        )
        self._request_id = 0

    def start(self, timeout=30):
        """Start Emacs in batch mode with MCP server.

        Blocks until the MCP server is reachable or timeout expires.
        """
        # Find a free port
        self.port = self._find_free_port()

        env = os.environ.copy()
        env["EMACS_MCP_PORT"] = str(self.port)

        literate_elisp_dir = env.get(
            "LITERATE_ELISP_DIR",
            os.path.expanduser("~/projects/literate-elisp"),
        )
        web_server_dir = env.get(
            "WEB_SERVER_DIR",
            os.path.expanduser("~/.emacs.d/straight/build/web-server"),
        )
        company_dir = env.get(
            "COMPANY_DIR",
            os.path.expanduser("~/.emacs.d/straight/build/company"),
        )
        websocket_dir = env.get(
            "WEBSOCKET_DIR",
            os.path.expanduser("~/.emacs.d/straight/build/websocket"),
        )

        cmd = [
            "emacs",
            "-Q",
            "--batch",
            "-L", str(self._project_root),
            "-L", literate_elisp_dir,
            "-L", web_server_dir,
            "-L", company_dir,
            "-L", websocket_dir,
            "-l", self._init_file,
            "--eval", f'(emacs-e2e-start-server {self.port})',
            "--eval", "(emacs-e2e-wait-forever)",
        ]

        self.process = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        # Wait for MCP server to be reachable
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                stdout = self.process.stdout.read().decode(errors="replace")
                stderr = self.process.stderr.read().decode(errors="replace")
                raise RuntimeError(
                    f"Emacs exited prematurely (code {self.process.returncode}).\n"
                    f"stdout: {stdout}\nstderr: {stderr}"
                )
            try:
                resp = requests.post(
                    f"http://127.0.0.1:{self.port}",
                    json=self._build_request("initialize", {}),
                    timeout=2,
                )
                if resp.status_code == 200:
                    return
            except (requests.ConnectionError, requests.Timeout):
                pass
            time.sleep(0.5)

        self.stop()
        raise TimeoutError(
            f"Emacs MCP server did not become reachable within {timeout}s"
        )

    def stop(self):
        """Kill Emacs process."""
        if self.process and self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        self.process = None

    def eval_elisp(self, code, timeout=10):
        """Send evalElisp request via MCP HTTP and return the result.

        Returns the parsed JSON result dict from the MCP response.
        Raises on HTTP or MCP-level errors.
        """
        params = {"arguments": {"code": code}}
        return self.call_tool("evalElisp", params, timeout=timeout)

    def call_tool(self, tool_name, params=None, timeout=10):
        """Call an MCP tool by name.

        Returns the parsed result from the MCP response body.
        """
        if params is None:
            params = {}
        payload = self._build_request("tools/call", {
            "name": tool_name,
            **params,
        })
        resp = requests.post(
            f"http://127.0.0.1:{self.port}",
            json=payload,
            timeout=timeout,
        )
        resp.raise_for_status()
        body = resp.json()
        if "error" in body:
            raise RuntimeError(f"MCP error: {body['error']}")
        return body.get("result", body)

    def list_tools(self, timeout=10):
        """Call tools/list and return the tool definitions."""
        payload = self._build_request("tools/list", {})
        resp = requests.post(
            f"http://127.0.0.1:{self.port}",
            json=payload,
            timeout=timeout,
        )
        resp.raise_for_status()
        body = resp.json()
        return body.get("result", body)

    def initialize(self, timeout=10):
        """Perform MCP initialize handshake."""
        payload = self._build_request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test-client", "version": "0.1"},
        })
        resp = requests.post(
            f"http://127.0.0.1:{self.port}",
            json=payload,
            timeout=timeout,
        )
        resp.raise_for_status()
        return resp.json()

    def _build_request(self, method, params):
        """Build a JSON-RPC 2.0 request."""
        self._request_id += 1
        return {
            "jsonrpc": "2.0",
            "id": self._request_id,
            "method": method,
            "params": params,
        }

    @staticmethod
    def _find_free_port():
        """Find a free TCP port."""
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]
