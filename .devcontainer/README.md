# Claude Code Docker Container

This Docker setup enables running Claude Code in an isolated container for long-running tasks.
Uses the [official Docker sandbox pattern](https://docs.docker.com/ai/sandboxes/claude-code/)
for persistent authentication.

## Quick Start

```bash
# First time only: authenticate (opens browser for OAuth)
make docker-auth

# Start the container
make docker-up

# Verify Claude is working
docker compose exec claude claude --version

# Run a query
docker compose exec claude claude -p "Hello from Docker!"

# Stop the container
make docker-down
```

## Authentication

The Docker container uses a persistent volume (`claude-sandbox-data`) to store
OAuth credentials, following the [official Docker sandbox pattern](https://docs.docker.com/ai/sandboxes/claude-code/).

**First-time setup:**
```bash
make docker-auth
```

This runs `claude /login` in the container, opening a browser for OAuth authentication.
Credentials are stored in the Docker volume and persist across container restarts.

**Check auth status:**
```bash
make docker-status
```

## Integration with claude-org-mode

### Basic Setup

Set these properties in your org file:

```org
#+PROPERTY: PROJECT_ROOT /path/to/your/project
#+PROPERTY: CLAUDE_CODE_PATH docker compose exec claude claude
#+PROPERTY: CLAUDE_HOST_PATH /path/to/your/project
#+PROPERTY: CLAUDE_CONTAINER_PATH /workspace
```

Then execute AI blocks as usual with `C-c C-c`. The container will auto-start if needed.

### Property Reference

| Property | Description | Example |
|----------|-------------|---------|
| `PROJECT_ROOT` | Host path to project (sets cwd) | `/home/user/myproject` |
| `CLAUDE_CODE_PATH` | Claude CLI command | `docker compose exec claude claude` |
| `CLAUDE_HOST_PATH` | Host path for path mapping | `/home/user/myproject` |
| `CLAUDE_CONTAINER_PATH` | Container path for mapping | `/workspace` |

### Path Translation

When `CLAUDE_HOST_PATH` and `CLAUDE_CONTAINER_PATH` are both set, automatic path
translation occurs:

- MCP requests from Claude in the container (e.g., `/workspace/src/main.py`) are
  translated to host paths (`/home/user/myproject/src/main.py`) before Emacs
  operates on them.

- Results containing host paths are translated back to container paths before
  being returned to Claude.

## Volume Mounts

| Host Path | Container Path | Mode | Purpose |
|-----------|----------------|------|---------|
| Docker volume `claude-sandbox-data` | `/root/.claude` | rw | OAuth credentials (persistent) |
| `~/.ssh` | `/root/.ssh` | ro | Git SSH keys |
| `~/.gitconfig` | `/root/.gitconfig` | ro | Git identity |
| `$PROJECT_DIR` or `..` | `/workspace` | rw | Project files |
| Docker volume `claude-agent-history` | `/root/.bash_history` | rw | Command history |

## Makefile Commands

| Command | Description |
|---------|-------------|
| `make docker-auth` | First-time authentication (opens browser) |
| `make docker-up` | Start the container |
| `make docker-down` | Stop the container |
| `make docker-status` | Show container and auth volume status |

## Connecting to Host Emacs MCP Server

The container can reach the host via `host.docker.internal`. Configure your MCP
server to bind to all interfaces:

```elisp
;; In your Emacs config
(setq emacs-mcp-server-host "0.0.0.0")
(emacs-mcp-server-start)
```

The default port is 9999. Test connectivity from container:

```bash
docker compose exec claude curl -s http://host.docker.internal:9999
```

## Troubleshooting

### "Invalid API key" error

Run `make docker-auth` to authenticate. Credentials are stored in the
`claude-sandbox-data` Docker volume.

### Container won't start

```bash
docker compose logs claude
```

### Git operations fail

Verify SSH keys are accessible:

```bash
docker compose exec claude ssh -T git@github.com
```

### Path translation not working

1. Verify both `CLAUDE_HOST_PATH` and `CLAUDE_CONTAINER_PATH` are set:
   ```elisp
   (claude-org--get-path-mappings)
   ;; Should return: (("/home/user/project" . "/workspace"))
   ```

2. Check the MCP server is running with correct host binding:
   ```elisp
   (emacs-mcp-server-running-p)
   emacs-mcp-server-host  ;; Should be "0.0.0.0" for Docker access
   ```

### Reset authentication

To re-authenticate or fix credential issues:

```bash
# Remove the auth volume
docker volume rm claude-sandbox-data

# Re-authenticate
make docker-auth
```

## Sources

- [Docker Docs: Configure Claude Code Sandbox](https://docs.docker.com/ai/sandboxes/claude-code/)
- [Docker Docs: Sandbox Get Started](https://docs.docker.com/ai/sandboxes/get-started/)
- [Anthropic: Claude Code Sandboxing](https://www.anthropic.com/engineering/claude-code-sandboxing)
