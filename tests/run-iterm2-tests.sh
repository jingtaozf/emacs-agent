#!/usr/bin/env bash
# Run all iTerm2 backend test layers in order.
# Stops on first failure.
#
# Usage:
#   bash tests/run-iterm2-tests.sh [mcp-port]
#
# Prerequisites:
#   - iTerm2 running with Python API enabled
#   - pip3 install iterm2
#   - claude CLI installed
#   - Emacs MCP server running (for Layer 4)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

MCP_PORT="${1:-9999}"

echo "============================================================"
echo "iTerm2 Backend Test Suite"
echo "============================================================"
echo

echo "=== Layer 1: iterm2-ctl unit tests ==="
python3 -m pytest tests/test-iterm2-ctl-unit.py -v --tb=short 2>&1 || {
    echo "Layer 1 FAILED"
    exit 1
}
echo

echo "=== Layer 2: iTerm2 integration ==="
python3 tests/test-iterm2-integration.py 2>&1 || {
    echo "Layer 2 FAILED"
    exit 1
}
echo

echo "=== Layer 3: iTerm2 + Claude Code ==="
python3 tests/test-iterm2-claude.py 2>&1 || {
    echo "Layer 3 FAILED"
    exit 1
}
echo

# Layer 4 requires Emacs MCP server
if curl -sf --connect-timeout 2 "http://localhost:${MCP_PORT}/mcp" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"evalElisp","arguments":{"code":"t"}}}' \
    > /dev/null 2>&1; then
    echo "=== Layer 4: Full E2E ==="
    if [ -f tests/test-iterm2-e2e.sh ]; then
        bash tests/test-iterm2-e2e.sh "$MCP_PORT" 2>&1 || {
            echo "Layer 4 FAILED"
            exit 1
        }
    else
        echo "  (Layer 4 test not yet implemented, skipping)"
    fi
else
    echo "=== Layer 4: SKIPPED (Emacs MCP server not running on port $MCP_PORT) ==="
fi

echo
echo "============================================================"
echo "All iTerm2 backend tests passed."
echo "============================================================"
