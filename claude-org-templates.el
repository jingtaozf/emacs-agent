;;; claude-org-templates.el --- Default templates for claude-org AI blocks -*- no-byte-compile: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: templates, ai

;;; Commentary:

;; Default template definitions for `claude-org-templates'.
;; This is a data file — the top-level form is an alist read by
;; `claude-org--load-templates-from-file'.
;;
;; Each entry is (NAME . VALUE) where VALUE is either:
;;   - A string to insert verbatim into an AI block
;;   - A symbol naming a function (no args) that returns a string
;;
;; To customize, copy this file to your preferred location and set
;; `claude-org-templates-file' to point to it, or set
;; `claude-org-templates' directly in your init file.

;;; Data:

(("Analyze Backtrace" . claude-org-template--backtrace)
 ("Code Review" . "run code simplifier and code review to the code changes.")
 ("Explain Code" . "Please explain what this code does, including:
1. Overall purpose
2. Key functions and their roles
3. Data flow
4. Any notable patterns or techniques

")
 ("Fix Error" . "Please help fix this error:

Error:

Context:

")
 ("Git Commit and Push" . "Please commit and push the changes.

Note: If there are pre-commit hooks configured, please wait for them to complete
before considering the commit successful. If hooks fail, fix the issues and retry.

"))

;;; claude-org-templates.el ends here
