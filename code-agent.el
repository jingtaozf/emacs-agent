;;; code-agent.el --- Claude Code SDK for Emacs -*- lexical-binding: t -*-

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
;; - code-agent.org: Core SDK for process management, query API, permissions
;; - code-agent-multiplexer.org: Abstract base for multiplexer backends
;; - code-agent-org.org: Org-mode integration with AI blocks and streaming
;; - emacs-mcp-server.org: MCP HTTP server exposing Emacs tools to Claude
;;
;; Quick Start:
;;   (require 'code-agent)
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
  :group 'code-agent)

(defun code-agent--load-module (name)
  "Load Claude Code module NAME (basename, no extension) from .org file.

After the 2026-05-26 restructure, modules live under
``claude-code-directory/lp/<group>/`` rather than at the repo root.
This function transparently searches both layouts so callers stay
agnostic.  The search order is: repo root first (back-compat with any
ad-hoc files added later), then every immediate subdir of ``lp/``."
  (let* ((basename (concat name ".org"))
         (root claude-code-directory)
         (lp-dir (expand-file-name "lp" root))
         (candidates (cons (expand-file-name basename root)
                           (and (file-directory-p lp-dir)
                                (mapcar (lambda (sub)
                                          (expand-file-name basename sub))
                                        (cl-remove-if-not
                                         #'file-directory-p
                                         (directory-files lp-dir t "\\`[^.]" t))))))
         (file (cl-find-if #'file-exists-p candidates)))
    (if file
        (literate-elisp-load file)
      (error "Claude Code module not found: %s (searched root + lp/*)" basename))))

;; Load all modules
(code-agent--load-module "code-agent-trace")
(code-agent--load-module "code-agent-backend")
(code-agent--load-module "code-agent-ide")
;; Abstract base for multiplexer backends (tri-protocol Protocol 2b —
;; see docs/design-docs/2026-tri-protocol-backend-refactor.org).
;; The agent-wire base (Protocol 2a) was removed in 2026-05: zero
;; subclasses, zero callers — every agent backend inherits directly
;; from `code-agent-backend' (Protocol 1).
(code-agent--load-module "code-agent-multiplexer")
;; Concrete multiplexer backends register here as subclasses of the
;; abstract multiplexer-backend and are added to
;; `code-agent-org-backend-registry' so the frontend dispatches on the
;; backend instance instead of string-matching CLAUDE_BACKEND.
(code-agent--load-module "code-agent-cmux-backend")
(code-agent--load-module "code-agent-tmux-backend")
(code-agent--load-module "code-agent-orca-backend")
;; Pi runs as a cmux agent profile (:AGENT_TYPE: pi in
;; code-agent-org-cmux.org), not a separate Elisp backend module — the
;; RPC-mode :CLAUDE_BACKEND: pi route (code-agent-pi-backend.org,
;; code-agent-pi-ui.org) was removed.  Pi's global emacs-mcp TS
;; extension (code-agent-pi-extensions.org) still applies; it has no
;; Elisp side to load here.
(code-agent--load-module "code-agent")
;; code-agent-chat / -translate / -refine / -title (embedded-chat
;; surfaces) were removed: the pivot direction is agents living in
;; cmux/tmux terminals, not an embedded-chat frontend.
(code-agent--load-module "code-agent-org-session")
(code-agent--load-module "code-agent-org")
(code-agent--load-module "code-agent-org-header-line")
(code-agent--load-module "code-agent-org-terminal-base")
(code-agent--load-module "code-agent-org-cmux")
(code-agent--load-module "emacs-mcp-server")

(provide 'code-agent)

;;; code-agent.el ends here
