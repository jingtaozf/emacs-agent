#!/bin/sh
set -e

# Self-update Claude to latest version
echo "Updating Claude CLI..."
claude update 2>/dev/null || echo "Claude update skipped (not installed or failed)"

# Dynamic MCP config (requires runtime host IP detection)
HOST_IP=$(getent hosts host.docker.internal | awk '{print $1}')
if [ -n "$HOST_IP" ]; then
    echo "{\"mcpServers\":{\"emacs\":{\"type\":\"http\",\"url\":\"http://$HOST_IP:9999/mcp\"}}}" > /workspace/.mcp.json
    echo "MCP config created with host IP: $HOST_IP"

    # Start MCP proxy (localhost:9999 -> host:9999)
    socat TCP-LISTEN:9999,fork,reuseaddr TCP:$HOST_IP:9999 &
    sleep 1
    echo "MCP proxy started"
fi

echo "Container ready."
exec sleep infinity
