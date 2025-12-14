# Claude Agent SDK for Emacs

An Emacs client library for the [Claude Code CLI](https://claude.ai/code), implemented using literate programming in Org mode.

## Overview

This project provides three integrated modules:

| Module | File | Purpose |
|--------|------|---------|
| **claude-agent** | `claude-agent.org` | Core SDK: process management, query API, permissions, IDE context |
| **claude-org** | `claude-org.org` | Org-mode integration: AI blocks, streaming, session management |
| **emacs-mcp-server** | `emacs-mcp-server.org` | MCP HTTP server: exposes Emacs tools to Claude |

## Quick Start

### Prerequisites

- Emacs 27.1+
- Claude Code CLI: `npm install -g @anthropic-ai/claude-code`
- [literate-elisp](https://github.com/jingtaoxu/literate-elisp) for loading org files directly
- `web-server` package (for MCP server): `M-x package-install RET web-server RET`

### Installation

```elisp
;; Load the modules
(require 'literate-elisp)
(literate-elisp-load "~/projects/claude-agent/claude-agent.org")
(literate-elisp-load "~/projects/claude-agent/claude-org.org")
(literate-elisp-load "~/projects/claude-agent/emacs-mcp-server.org")
```

## Tutorial: Getting Started

### 1. Interactive Chat (Easiest)

The simplest way to interact with Claude:

```elisp
M-x claude-agent-chat
```

This opens a comint-based buffer where you can:
- Type messages and press `RET` to send
- `C-c C-k` to interrupt current request
- `C-c C-l` to clear and reset session
- `C-c C-n` to start new session without clearing

The chat automatically includes IDE context (current file, open files, selection).

### 2. Org-mode Integration (Recommended for Documentation)

Enable claude-org-mode in any org file manually:

```elisp
M-x claude-org-mode
```

Or auto-enable it via file-local variables. Create an org file with this header:

```org
# -*- mode: org; eval: (claude-org-mode 1) -*-
#+TITLE: My Project Development
#+PROPERTY: PROJECT_ROOT /path/to/your/project
#+PROPERTY: CLAUDE_PERMISSION_MODE accept-edits

* Project Context :system_prompt:

** Overview
My web application built with FastAPI and React.
- Backend: Python 3.11, FastAPI, SQLAlchemy
- Frontend: React 18, TypeScript, TailwindCSS

** Code Standards
- Use absolute imports in Python
- Follow PEP 8 style guide
- Write docstrings for all public functions
- Use type hints everywhere

** Important Rules
- Never modify files in migrations/ directly
- Always run tests before committing

* Feature: User Authentication :claude_chat:

** Design Discussion

#+begin_src ai
Help me design the user authentication flow.
What approaches do you recommend?
#+end_src

** Implementation

#+begin_src ai
Implement the login endpoint based on our discussion above.
#+end_src
```

**Key concepts:**
- `# -*- mode: org; eval: (claude-org-mode 1) -*-` - Auto-enable claude-org-mode
- `#+PROPERTY: PROJECT_ROOT` - Working directory for Claude
- `:system_prompt:` tag - The entire section (including subsections) is included as context in every query
- `:claude_chat:` tag - Groups related AI conversations as a "story"
- Subsections under `:claude_chat:` organize different aspects of the conversation

#### Key Bindings in claude-org-mode

| Key | Command | Description |
|-----|---------|-------------|
| `C-c C-c` | Execute query | Send AI block to Claude |
| `C-c C-k` | Cancel | Cancel active query |
| `C-c C-n` | New block | Insert new AI block |
| `C-c C-i` | Session info | Show current session identity |
| `C-c C-l` | List sessions | Show all sessions in buffer |
| `C-c C-v` | Verbose output | Show CLI-like output buffer |
| `C-c C-p` | Permission mode | Switch permission level |

### 3. Programmatic Queries

For scripts and automation:

```elisp
;; Simple one-shot query
(claude-agent-query
 "What is 2+2?"
 :on-message (lambda (msg)
               (when (claude-agent-assistant-message-p msg)
                 (message "Response: %s"
                          (claude-agent-extract-text msg))))
 :on-complete (lambda (_) (message "Done!")))

;; With options
(claude-agent-query
 "Explain this code"
 :options (claude-agent-options
           :model "claude-sonnet-4-5"
           :max-turns 3
           :permission-mode 'accept-edits
           :cwd "/path/to/project")
 :on-token (lambda (text) (insert text))  ; Stream tokens
 :on-message #'my-message-handler)
```

## Features

### Session Management

Sessions preserve conversation context across queries.

#### In claude-org-mode

Sessions are automatically managed per-file. You can also create section-scoped sessions:

```org
#+PROPERTY: CLAUDE_SESSION_ID my-project-session

* Task A :claude_session:
This section has its own independent session.

#+begin_src ai
Question specific to Task A context
#+end_src

* Task B :claude_session:
Tis is a separate session from Task A.

#+begin_src ai
Different context here
#+end_src
```

#### Session Recovery

When Claude sessions expire, claude-org automatically:
1. Collects conversation history from the org file
2. Rebuilds context with a recovery prompt
3. Retries transparently

### Permission System

Control which tools Claude can use with pattern-based permissions.

#### Permission Presets

```elisp
;; Set globally
(setq claude-agent-permission-preset "readonly")    ; Read, Glob, Grep only
(setq claude-agent-permission-preset "accept-edits") ; + Write, Edit, MultiEdit
(setq claude-agent-permission-preset "plan")         ; Suggests changes only
(setq claude-agent-permission-preset "bypass")       ; Allow all tools
```

#### In claude-org-mode

Set per-file or per-section:

```org
#+PROPERTY: CLAUDE_PERMISSION_MODE accept-edits

* Dangerous Section
:PROPERTIES:
:CLAUDE_PERMISSION_MODE: readonly
:END:
This section is read-only regardless of file setting.
```

#### Custom Permissions

```elisp
(setq claude-agent-permission-preset "custom")
(setq claude-agent-permissions
      '(:allow ("Read(**)" "Glob(**)" "Bash(git:*)" "mcp__emacs__*")
        :deny ("Bash(rm *)" "Bash(sudo *)")))
```

#### Pattern Syntax

| Pattern | Example | Meaning |
|---------|---------|---------|
| `*` | `*` | Match all tools |
| `ToolName` | `WebSearch` | Match tool by name |
| `ToolName(**)` | `Read(**)` | Match with any argument |
| `ToolName(pattern)` | `Bash(git:*)` | Match argument prefix |
| `mcp__*` | `mcp__emacs__*` | Glob for MCP tools |

### IDE Context

The library automatically collects IDE context from Emacs:
- Current file being edited
- List of open files (up to 10)
- Selected text region (if any)
- Current working directory

This context is prepended to prompts as `<system-reminder>` tags.

#### Excluding Buffers

```elisp
;; Exclude by name pattern (regexp)
(setq claude-agent-ide-context-exclude-buffer-names
      '("*Claude Chat*" "*Messages*" "*scratch*"))

;; Exclude by major mode
(setq claude-agent-ide-context-exclude-modes
      '(claude-agent-chat-mode special-mode dired-mode))

;; Custom predicate
(add-to-list 'claude-agent-ide-context-exclude-predicates
             (lambda (buf)
               (with-current-buffer buf
                 (bound-and-true-p my-special-mode))))
```

### Project Configuration (claude-org)

#### PROJECT_ROOT

Set working directory for Claude:

```org
#+PROPERTY: PROJECT_ROOT /path/to/project

* Or per-section via tags
** Backend Work :PROJECT_ROOT:/path/to/backend:
```

#### System Prompts

Tag sections with `:system_prompt:` to include as project guidelines:

```org
* Project Guidelines :system_prompt:
This project uses Python 3.11.
Always use absolute imports.
Follow PEP 8 style guide.

* Code Style :system_prompt:
- Use type hints
- Write docstrings for all public functions
```

These are automatically collected and included in queries.

### MCP Server (Emacs Tools for Claude)

The MCP server exposes Emacs operations to Claude Code CLI.

#### Starting the Server

```elisp
;; Manual start
M-x emacs-mcp-server-start

;; Or auto-start with claude-org-mode
(setq claude-org-auto-start-mcp-server t)
(setq claude-org-mcp-server-port 9999)
```

#### Available Tools

**Core Tool:**
- `evalElisp` - Execute arbitrary Emacs Lisp code

**Org-mode Tools (13 tools):**

| Tool | Description |
|------|-------------|
| `org_list_sections` | List all sections with paths, levels, tags |
| `org_read_section` | Read section content, properties, tags |
| `org_create_section` | Create new subsection |
| `org_update_section` | Update section body content |
| `org_delete_section` | Delete section and children |
| `org_get_property` | Get property value |
| `org_set_property` | Set property value |
| `org_delete_property` | Delete property |
| `org_list_properties` | List all properties |
| `org_get_tags` | Get section tags |
| `org_set_tags` | Replace all tags |
| `org_add_tag` | Add single tag |
| `org_remove_tag` | Remove single tag |

#### Registering Custom Tools

```elisp
(emacs-mcp-server-register-tool
 '((name . "my_tool")
   (description . "Does something useful")
   (handler . my-tool-handler)
   (inputSchema . ((type . "object")
                   (properties . ((arg1 . ((type . "string")))))
                   (required . ["arg1"])))))

(defun my-tool-handler (params session)
  "Handle my_tool call. PARAMS contains arguments."
  (let ((arg1 (alist-get 'arg1 params)))
    (list `((type . "text")
            (text . ,(format "Result: %s" arg1))))))
```

### Activity Mode-Line

Shows when Claude queries are active.

- Spinning indicator `[C:◐]` during queries
- Count for multiple: `[C:◓×3]`
- Click to open session manager
- Hover for detailed query information

```elisp
;; View active queries
M-x claude-agent-list-queries
```

In the session manager:
- `k` - Cancel query at point
- `K` - Cancel all queries
- `g` - Refresh list
- `q` - Quit

### Usage Mode-Line

Display Claude API usage statistics.

#### Setup

```elisp
;; Set your organization ID (from claude.ai URL)
(setq claude-agent-usage-org-id "your-org-id-here")

;; Set environment variable for session key
;; Get from browser: DevTools > Application > Cookies > sessionKey
;; export CLAUDE_SESSION_KEY="your-session-key"
```

#### Usage

```elisp
M-x claude-agent-usage-mode-line-start  ; Start (auto-refresh every 5 min)
M-x claude-agent-usage-mode-line-stop   ; Stop
M-x claude-agent-usage-fetch            ; Manual refresh
```

**Display Format:**
- `[C:XX|YY|ZZ]` - 5-hour | 7-day | 7-day Sonnet utilization %
- Hover for reset times (e.g., "7d 10h", "5h 30m")

### Verbose Output Buffers

Per-session verbose buffers display CLI-like output.

```elisp
;; In claude-org-mode
C-c C-v  ; Show verbose buffer for current session

;; Programmatically
M-x claude-agent-show-session-verbose
M-x claude-agent-list-session-verbose-buffers
```

Buffer shows: query headers, tool calls, thinking indicators, responses, cost summary.

## Configuration Reference

### claude-agent

```elisp
;; Model
(setq claude-agent-default-model "claude-sonnet-4-5")

;; CLI path (auto-detected if nil)
(setq claude-agent-cli-path "/path/to/claude")

;; Debug logging
(setq claude-agent-debug t)

;; Permission preset
(setq claude-agent-permission-preset "readonly")

;; Verbose buffer cleanup
(setq claude-agent-verbose-buffer-auto-kill t)
```

### claude-org

```elisp
;; Font-lock delay during streaming (lower = more responsive)
(setq claude-org-fontlock-delay 0.05)

;; Default tags
(setq claude-org-heading-tag "claude_chat")
(setq claude-org-session-tag "claude_session")

;; Include IDE context in prompts
(setq claude-org-include-ide-context t)

;; Show system messages in response
(setq claude-org-show-system-messages nil)

;; Tools to auto-approve
(setq claude-org-allowed-tools '("Read(**)" "Glob(**)" "Grep(**)"))

;; MCP server auto-start
(setq claude-org-auto-start-mcp-server t)
(setq claude-org-mcp-server-port 9999)
```

### emacs-mcp-server

```elisp
;; Default port (0 = auto-select)
(setq emacs-mcp-server-default-port 9999)

;; Permission mode for tools
(setq emacs-mcp-server-permission-mode "bypassPermissions")

;; Allowed tool patterns
(setq emacs-mcp-server-allowed-tools '("mcp__emacs__*"))

;; Max output length from evalElisp
(setq emacs-mcp-server-max-output-length 50000)
```

### claude-agent-chat

```elisp
;; Prompt string
(setq claude-agent-chat-prompt "You> ")

;; Buffer name
(setq claude-agent-chat-buffer-name "*Claude Chat*")

;; Show system messages
(setq claude-agent-chat-show-system-messages nil)

;; Show cost after each response
(setq claude-agent-chat-show-cost t)

;; Include IDE context
(setq claude-agent-chat-include-ide-context t)
```

## API Reference

### Core Functions (claude-agent)

| Function | Description |
|----------|-------------|
| `claude-agent-query` | Send one-shot query with callbacks |
| `claude-agent-options` | Create options plist |
| `claude-agent-extract-text` | Extract text from assistant message |
| `claude-agent-extract-tool-uses` | Extract tool use blocks |
| `claude-agent-extract-thinking` | Extract thinking content |
| `claude-agent-message-type` | Get message type symbol |
| `claude-agent-cancel-query` | Cancel specific query |
| `claude-agent-cancel-all-queries` | Cancel all active queries |
| `claude-agent-active-query-count` | Get number of active queries |

### Client Functions

| Function | Description |
|----------|-------------|
| `claude-agent-client-create` | Create new client |
| `claude-agent-client-connect` | Connect to Claude |
| `claude-agent-client-send` | Send message |
| `claude-agent-client-disconnect` | Disconnect |
| `claude-agent-client-interrupt` | Interrupt current operation |

### Org Functions (claude-org)

| Function | Description |
|----------|-------------|
| `claude-org-mode` | Enable/disable minor mode |
| `claude-org-execute` | Execute AI block (C-c C-c) |
| `claude-org-cancel` | Cancel current query |
| `claude-org-insert-block` | Insert new AI block |
| `claude-org-show-session-info` | Show session identity |
| `claude-org-list-sessions` | List all sessions |
| `claude-org-show-verbose` | Show verbose output |
| `claude-org-switch-permission-mode` | Change permission mode |

### MCP Server Functions

| Function | Description |
|----------|-------------|
| `emacs-mcp-server-start` | Start MCP server |
| `emacs-mcp-server-stop` | Stop MCP server |
| `emacs-mcp-server-running-p` | Check if running |
| `emacs-mcp-server-port` | Get current port |
| `emacs-mcp-server-register-tool` | Register custom tool |
| `emacs-mcp-server-unregister-tool` | Unregister tool |
| `claude-mcp-org-enable` | Enable org tools |
| `claude-mcp-org-disable` | Disable org tools |

## Running Tests

```elisp
(setq literate-elisp-test-p t)
(literate-elisp-load "~/projects/claude-agent/claude-agent.org")
(literate-elisp-load "~/projects/claude-agent/claude-org.org")
(ert t)  ; Run all tests
```

## License

MIT
