;;; claude-code.el --- Claude Code SDK for Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; URL: https://github.com/jingtaozf/claude-code
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (literate-elisp "0.8") (web-server "0.1.2") (yasnippet "0.14"))
;; Keywords: ai, tools, claude

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the MIT License.

;;; Commentary:

;; Claude Code SDK for Emacs - A native Emacs client for Claude Code CLI.
;;
;; This is the package entry point that loads all modules via literate-elisp:
;; - claude-agent.org: Core SDK for process management, query API, permissions
;; - claude-agent-multiplexer.org: Abstract base for multiplexer backends
;; - code-agent-org.org: Org-mode integration with AI blocks and streaming
;; - emacs-mcp-server.org: MCP HTTP server exposing Emacs tools to Claude
;;
;; Quick Start:
;;   (require 'claude-code)
;;   M-x claude-agent-chat    ; Interactive chat
;;   M-x code-agent-org-mode      ; Enable in org files
;;
;; For org-mode integration, add to your org file:
;;   # -*- mode: org; eval: (code-agent-org-mode 1) -*-
;;
;; See README.org for full documentation.

;;; Code:

(require 'literate-elisp)

(defgroup claude-code nil
  "Claude Code SDK for Emacs."
  :group 'tools
  :prefix "claude-")

(defcustom claude-code-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing Claude Code org files."
  :type 'directory
  :group 'claude-code)

(defun claude-code--load-module (name)
  "Load Claude Code module NAME from org file."
  (let ((file (expand-file-name (concat name ".org") claude-code-directory)))
    (if (file-exists-p file)
        (literate-elisp-load file)
      (error "Claude Code module not found: %s" file))))

;; Load all modules
(claude-code--load-module "claude-agent-trace")
(claude-code--load-module "claude-agent-backend")
(claude-code--load-module "claude-agent-permission")
(claude-code--load-module "claude-agent-ide")
;; Abstract base for multiplexer backends (tri-protocol Protocol 2b —
;; see docs/design-docs/2026-tri-protocol-backend-refactor.org).
;; The agent-wire base (Protocol 2a) was removed in 2026-05: zero
;; subclasses, zero callers — every agent backend inherits directly
;; from `claude-agent-backend' (Protocol 1).
(claude-code--load-module "claude-agent-multiplexer")
;; Concrete multiplexer backends register here as subclasses of the
;; abstract multiplexer-backend and are added to
;; `code-agent-org-backend-registry' so the frontend dispatches on the
;; backend instance instead of string-matching CLAUDE_BACKEND.
(claude-code--load-module "claude-agent-cmux-backend")
(claude-code--load-module "claude-agent-tmux-backend")
;; Pi backend (pi.dev RPC) — auto-loaded so `:CLAUDE_BACKEND: pi'
;; dispatches without the user having to add an extra `literate-elisp-load'
;; line to their init.  Loading the module does not spawn anything; the
;; subprocess is created lazily on first query.  Pi itself (the `pi'
;; binary + provider/auth config in ~/.pi/agent/) is still required at
;; runtime; absent that, dispatch fails with a clear error from the
;; factory rather than `void-function'.
(claude-code--load-module "claude-agent-pi-backend")
;; ACP backends (OpenCode / Gemini / Codex) remain OPT-IN — users load
;; them explicitly in their init file if they use those agents.
;; The `code-agent-org-backend-registry' entries reference those
;; factories by name, so invoking them without loading will raise
;; `void-function'.  This matches ARCHITECTURE.org's OPTIONAL tag.
(claude-code--load-module "claude-agent")
;; Utility / UI helpers extracted from `claude-agent.org' for clarity —
;; load right after the core SDK so any caller (code-agent-org-mode or
;; a user-written hook) can `require' or call them without further setup.
(claude-code--load-module "claude-agent-chat")
(claude-code--load-module "claude-agent-translate")
(claude-code--load-module "claude-agent-title")
(claude-code--load-module "claude-agent-refine")
(claude-code--load-module "code-agent-org-session")
(claude-code--load-module "code-agent-org-queue")
(claude-code--load-module "code-agent-org-response")
(claude-code--load-module "code-agent-org")
(claude-code--load-module "code-agent-org-header-line")
(claude-code--load-module "code-agent-org-scheduled")
(claude-code--load-module "code-agent-org-workspace-bridge")
(claude-code--load-module "code-agent-org-terminal-base")
(claude-code--load-module "code-agent-org-cmux")
(claude-code--load-module "emacs-mcp-server")

(provide 'claude-code)

;;; claude-code.el ends here
