;;; test-config.el --- Test configuration and helpers -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Shared configuration and helper functions for integration tests.
;; This file provides utilities for:
;; - Setting up test environment
;; - Managing test fixtures
;; - Common assertions
;; - Test result reporting

;;; Code:

;; Note: claude-agent.org and claude-org.org are loaded by Makefile
;; via literate-elisp-load before this file is loaded.
;; We don't use (require 'claude-agent) or (require 'claude-org) because
;; the features are provided by the org files, not compiled .el files.

;; Configure MCP server to use a free port (0 = auto-select) to avoid conflicts
;; This is important for CI environments where port 9999 may already be in use
(when (boundp 'emacs-mcp-server-default-port)
  (setq emacs-mcp-server-default-port 0))

;;; Configuration Variables

(defvar test-claude-fixture-dir
  (file-name-directory
   (or load-file-name
       (buffer-file-name)))
  "Directory containing test fixtures.")

(defvar test-claude-session-org
  (expand-file-name "test-session.org" test-claude-fixture-dir)
  "Path to test session org file.")

(defvar test-claude-timeout 30
  "Default timeout for integration tests in seconds.")


;;; Environment Setup

(defun test-claude-check-cli-available ()
  "Check if Claude CLI is available.
Returns t if claude command is found, nil otherwise."
  (executable-find "claude"))

(defun test-claude-skip-unless-cli-available ()
  "Skip test if Claude CLI is not available."
  (unless (test-claude-check-cli-available)
    (ert-skip "Claude CLI not found - skipping integration test")))

(defun test-claude-skip-unless-mcp-server-available ()
  "Skip test if MCP server cannot be started (e.g., web-server not available)."
  (unless (and (fboundp 'emacs-mcp-server-running-p)
               (fboundp 'ws-start))
    (ert-skip "MCP server not available (web-server package missing) - skipping MCP test")))

;;; Fixture Management

(defun test-claude-copy-fixture ()
  "Create a temporary copy of test-session.org for testing.
Returns the path to the temporary file."
  (let ((temp-file (make-temp-file "claude-test-" nil ".org")))
    (copy-file test-claude-session-org temp-file t)
    temp-file))

(defun test-claude-clean-fixture (file)
  "Clean up temporary fixture FILE."
  (when file
    (ignore-errors (delete-file file))))

(defun test-claude-with-fixture (body-fn)
  "Execute BODY-FN with a fresh fixture file.
BODY-FN is called with the temporary file path as argument.
Cleans up automatically after execution."
  (let ((temp-file (test-claude-copy-fixture)))
    (unwind-protect
        (funcall body-fn temp-file)
      (test-claude-clean-fixture temp-file))))

;;; Test Execution Helpers

(defun test-claude-wait-until (predicate &optional timeout)
  "Wait until PREDICATE returns non-nil or TIMEOUT (default 30s).
Returns the value of PREDICATE on success, nil on timeout."
  (let ((timeout (or timeout test-claude-timeout))
        (start (float-time))
        (result nil))
    (while (and (not result)
                (< (- (float-time) start) timeout))
      (setq result (funcall predicate))
      (unless result
        (sleep-for 0.1)
        (accept-process-output nil 0.1)))
    result))

(defun test-claude-wait-for-completion (session-key &optional timeout)
  "Wait for SESSION-KEY to complete or TIMEOUT (default 30s).
Returns t if completed successfully, nil if timed out."
  (test-claude-wait-until
   (lambda () (not (claude-org--session-get session-key :busy)))
   timeout))

(defun test-claude-execute-and-wait (org-file instruction-num &optional timeout)
  "Execute instruction INSTRUCTION-NUM in ORG-FILE and wait for completion.
Returns the response text or nil if timeout."
  (with-current-buffer (find-file-noselect org-file)
    (claude-org-mode 1)
    (goto-char (point-min))
    (when (re-search-forward
           (format "^\\*+ Instruction %d" instruction-num)
           nil t)
      ;; Find the ai block
      (when (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai" nil t)
        (let ((session-key (claude-org--current-session-key)))
          ;; Execute
          (claude-org-execute)
          ;; Wait for completion
          (if (test-claude-wait-for-completion session-key timeout)
              ;; Extract response
              (save-excursion
                (re-search-forward "^[ \t]*#\\+end_src" nil t)
                (forward-line 1)
                (let ((start (point)))
                  ;; Find next heading or end of buffer
                  (if (re-search-forward "^\\*+ " nil t)
                      (buffer-substring-no-properties start (line-beginning-position))
                    (buffer-substring-no-properties start (point-max)))))
            (error "Timeout waiting for instruction %d" instruction-num)))))))

;;; Org Test Helpers

(defmacro test-claude-with-org-buffer (props &rest body)
  "Create temporary org buffer with PROPS and execute BODY.
PROPS is a string inserted at buffer start (properties, headings, etc).
Automatically sets org-mode and refreshes property cache."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,props)
     (org-set-regexps-and-options)
     (goto-char (point-min))
     ,@body))

;;; Assertion Helpers

(defun test-claude-assert-response-contains (response expected)
  "Assert that RESPONSE contains EXPECTED string."
  (should (stringp response))
  (should (string-match-p (regexp-quote expected) response)))

(defun test-claude-assert-response-not-empty (response)
  "Assert that RESPONSE is not empty."
  (should (stringp response))
  (should (> (length (string-trim response)) 0)))

(defun test-claude-assert-session-uuid-stored (session-key)
  "Assert that SDK UUID is stored for SESSION-KEY."
  (let ((uuid (claude-org--get-sdk-uuid)))
    (should uuid)
    (should (stringp uuid))
    (should (> (length uuid) 0))))

;;; Cleanup

(defun test-claude-cleanup-all ()
  "Clean up all test resources."
  ;; Cancel any active queries
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (bound-and-true-p claude-org-mode)
          (claude-org-cancel-all))))))

(provide 'test-config)
;;; test-config.el ends here
