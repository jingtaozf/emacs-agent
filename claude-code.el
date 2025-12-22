;;; claude-code.el --- Claude Code SDK for Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; URL: https://github.com/jingtaozf/claude-code
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (literate-elisp "0.8") (web-server "0.1.2"))
;; Keywords: ai, tools, claude

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the MIT License.

;;; Commentary:

;; Claude Code SDK for Emacs - A native Emacs client for Claude Code CLI.
;;
;; This is the package entry point that loads all modules via literate-elisp:
;; - claude-agent.org: Core SDK for process management, query API, permissions
;; - claude-org.org: Org-mode integration with AI blocks and streaming
;; - emacs-mcp-server.org: MCP HTTP server exposing Emacs tools to Claude
;;
;; Quick Start:
;;   (require 'claude-code)
;;   M-x claude-agent-chat    ; Interactive chat
;;   M-x claude-org-mode      ; Enable in org files
;;
;; For org-mode integration, add to your org file:
;;   # -*- mode: org; eval: (claude-org-mode 1) -*-
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
(claude-code--load-module "claude-agent")
(claude-code--load-module "claude-org")
(claude-code--load-module "emacs-mcp-server")

(provide 'claude-code)

;;; claude-code.el ends here
