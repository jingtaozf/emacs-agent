;;; code-agent.el --- Claude Code SDK for Emacs -*- lexical-binding: t -*-

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

;; Emacs MCP server + home for custom in-Emacs agents.
;;
;; This is the package entry point that loads modules via literate-elisp:
;; - lp/trace/code-agent-trace.org: OTel span macros
;; - lp/sdk/emacs-mcp-server.org: MCP HTTP server exposing Emacs tools
;;   to external agents (Claude Code, Pi, ...) at localhost:9999
;; - lp/org/pi-topic.org: the pure org layer of pi-topics — topic
;;   headings, PI_STATE lifecycle, Goal/Result sections
;; - lp/org/pi-topic-io.org: the write-back path — address a topic by
;;   PI_TOPIC_ID, replace a section body, hand the id to the process
;; - lp/org/pi-topic-chat.org: the engine layer — turns a topic into a
;;   live pi-coding-agent session (degrades to an error when absent)
;; - lp/org/pi-topic-workflow.org: capture, topic list, reap, menu
;;
;; Quick Start:
;;   (require 'code-agent)
;;   M-x emacs-mcp-server-start
;;
;; See README.org for full documentation; the org-ai-agent-pi-topics
;; design lives in lp/_drafts/draft.org.

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

;; Load all modules.  The 2026-08-13 cleanup narrowed this repo to the
;; Emacs MCP server (everything else lives on the legacy-2026-08-13
;; branch); new in-Emacs agents (org-ai-agent-pi-topics, see
;; lp/_drafts/draft.org) will register their modules here as they land.
(code-agent--load-module "code-agent-trace")
(code-agent--load-module "emacs-mcp-server")
(code-agent--load-module "pi-topic")
(code-agent--load-module "pi-topic-io")
(code-agent--load-module "pi-topic-chat")
(code-agent--load-module "pi-topic-workflow")

(provide 'code-agent)

;;; code-agent.el ends here
