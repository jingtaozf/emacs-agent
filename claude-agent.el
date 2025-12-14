;;; claude-agent.el --- Claude Agent SDK for Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; URL: https://github.com/jingtaozf/emacs-claude-agent
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (literate-elisp "0.8") (web-server "0.1.2"))
;; Keywords: ai, tools, claude

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the MIT License.

;;; Commentary:

;; Claude Agent SDK for Emacs - A native Emacs client for Claude Code CLI.
;;
;; This package provides:
;; - claude-agent: Core SDK for process management, query API, permissions
;; - claude-org: Org-mode integration with AI blocks and streaming
;; - emacs-mcp-server: MCP HTTP server exposing Emacs tools to Claude
;;
;; Quick Start:
;;   (require 'claude-agent)
;;   M-x claude-agent-chat    ; Interactive chat
;;   M-x claude-org-mode      ; Enable in org files
;;
;; For org-mode integration, add to your org file:
;;   # -*- mode: org; eval: (claude-org-mode 1) -*-
;;
;; See README.org for full documentation.

;;; Code:

(require 'literate-elisp)

(defgroup claude-agent nil
  "Claude Agent SDK for Emacs."
  :group 'tools
  :prefix "claude-agent-")

(defcustom claude-agent-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing Claude Agent org files."
  :type 'directory
  :group 'claude-agent)

(defun claude-agent--load-module (name)
  "Load Claude Agent module NAME from org file."
  (let ((file (expand-file-name (concat name ".org") claude-agent-directory)))
    (if (file-exists-p file)
        (literate-elisp-load file)
      (error "Claude Agent module not found: %s" file))))

;; Load all modules
(claude-agent--load-module "claude-agent")
(claude-agent--load-module "claude-org")
(claude-agent--load-module "emacs-mcp-server")

(provide 'claude-agent)

;;; claude-agent.el ends here
