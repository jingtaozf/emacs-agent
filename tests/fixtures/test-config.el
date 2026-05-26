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

;; Note: code-agent.org and code-agent-org.org are loaded by Makefile
;; via literate-elisp-load before this file is loaded.
;; We don't use (require 'code-agent) or (require 'code-agent-org) because
;; the features are provided by the org files, not compiled .el files.

;; Configure MCP server to use a free port (0 = auto-select) to avoid conflicts
;; This is important for CI environments where port 9999 may already be in use
(when (boundp 'emacs-mcp-server-default-port)
  (setq emacs-mcp-server-default-port 0))

;; IMPORTANT: Skip user-level settings (plugins) during tests
;; This prevents tests from hanging due to plugin updates/git operations
;; By using "local" setting-source, we only use project-local settings
(defvar test-claude-default-setting-sources '("local")
  "Default setting-sources for tests to skip slow plugin loading.")

;;; Configuration Variables

(defvar test-claude-fixture-dir
  (file-name-directory
   (or load-file-name
       (buffer-file-name)))
  "Directory containing test fixtures.")

(defvar test-claude-session-org
  (expand-file-name "test-session.org" test-claude-fixture-dir)
  "Path to test session org file.")

(defvar test-claude-timeout 60
  "Default timeout for integration tests in seconds.")

(defvar test-claude-project-root
  (or (getenv "CLAUDE_TEST_PROJECT_ROOT")
      ;; Default: parent of fixtures directory (i.e., project root)
      (file-name-directory
       (directory-file-name
        (file-name-directory
         (directory-file-name test-claude-fixture-dir)))))
  "Project root for test fixtures.
Can be overridden via CLAUDE_TEST_PROJECT_ROOT environment variable.")


;;; Environment Setup

(defun test-claude-check-cli-available ()
  "Check if Claude CLI is available.
Returns t if claude command is found, nil otherwise."
  (executable-find "claude"))

(defun test-claude-default-options (&rest args)
  "Create default options for tests, merged with ARGS.
Uses `test-claude-default-setting-sources' to skip slow plugin loading."
  (apply #'code-agent-options
         :setting-sources test-claude-default-setting-sources
         args))

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
Returns the path to the temporary file.
Dynamically replaces PROJECT_ROOT with `test-claude-project-root'."
  (let ((temp-file (make-temp-file "claude-test-" nil ".org")))
    (copy-file test-claude-session-org temp-file t)
    ;; Replace PROJECT_ROOT placeholder with actual project root
    (with-current-buffer (find-file-noselect temp-file)
      (goto-char (point-min))
      (when (re-search-forward "^#\\+PROPERTY: PROJECT_ROOT .*$" nil t)
        (replace-match (format "#+PROPERTY: PROJECT_ROOT %s"
                               test-claude-project-root)))
      (save-buffer)
      (kill-buffer))
    temp-file))

(defun test-claude-clean-fixture (file)
  "Clean up temporary fixture FILE."
  (when file
    (ignore-errors (delete-file file))))

(defun test-claude-with-fixture (body-fn)
  "Execute BODY-FN with a fresh fixture file.
BODY-FN is called with the temporary file path as argument.
Cleans up automatically after execution, including killing any spawned processes."
  (let ((temp-file (test-claude-copy-fixture)))
    (unwind-protect
        (funcall body-fn temp-file)
      ;; Clean up fixture file
      (test-claude-clean-fixture temp-file)
      ;; Kill any Claude processes spawned during this test
      (test-claude-cleanup-all))))

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
   (lambda () (not (code-agent-org--session-get session-key :busy)))
   timeout))

(defun test-claude-execute-and-wait (org-file instruction-num &optional timeout)
  "Execute instruction INSTRUCTION-NUM in ORG-FILE and wait for completion.
Returns the response text or nil if timeout."
  (with-current-buffer (find-file-noselect org-file)
    (code-agent-org-mode 1)
    (goto-char (point-min))
    (when (re-search-forward
           (format "^\\*+ Instruction %d" instruction-num)
           nil t)
      ;; Find the ai block
      (when (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai" nil t)
        (let ((session-key (code-agent-org--current-session-key)))
          ;; Execute
          (code-agent-org-execute)
          ;; Wait for completion
          (if (test-claude-wait-for-completion session-key timeout)
              ;; Extract response - handle both with and without Response section
              (save-excursion
                (re-search-forward "^[ \t]*#\\+end_src" nil t)
                (forward-line 1)
                ;; Skip blank lines
                (while (and (not (eobp)) (looking-at "^[ \t]*$"))
                  (forward-line 1))
                ;; If we hit a Response section, skip into it
                (when (looking-at "^\\*+ Response [0-9]+")
                  (forward-line 1)
                  ;; Skip blank lines after Response heading
                  (while (and (not (eobp)) (looking-at "^[ \t]*$"))
                    (forward-line 1)))
                (let ((start (point)))
                  ;; Find next non-output heading or end of buffer
                  ;; Skip over :ai_output: tagged sections
                  (let ((end-pos nil))
                    (while (and (not end-pos)
                                (re-search-forward "^\\*+ " nil t))
                      (goto-char (match-beginning 0))
                      (unless (member code-agent-org-output-tag (org-get-tags nil nil))
                        (setq end-pos (point)))
                      (unless end-pos (forward-line 1)))
                    (buffer-substring-no-properties start (or end-pos (point-max))))))
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
  (let ((uuid (code-agent-org--get-sdk-uuid)))
    (should uuid)
    (should (stringp uuid))
    (should (> (length uuid) 0))))

;;; Mock CLI Support

(defvar test-claude-mock-cli-path
  (expand-file-name "mock-claude-cli.sh" test-claude-fixture-dir)
  "Path to mock Claude CLI for fast integration tests.
This script speaks the same JSON protocol as the real CLI.")

(defun test-claude-mock-options (&rest args)
  "Create options using mock CLI instead of real Claude.
Uses `test-claude-mock-cli-path' and skips slow plugin loading.
Pass :env to set MOCK_SCENARIO for explicit scenario selection."
  (apply #'code-agent-options
         :cli-path test-claude-mock-cli-path
         :setting-sources test-claude-default-setting-sources
         args))

(defun test-claude-mock-options-with-scenario (scenario &rest args)
  "Create mock options with explicit SCENARIO selection.
SCENARIO is the name of a fixture file in mock-scenarios/ (without .jsonl).
ARGS are additional options passed to `code-agent-options'."
  (apply #'test-claude-mock-options
         :env (list (cons "MOCK_SCENARIO" scenario))
         args))

;;; Cleanup

(defun test-claude-cleanup-all ()
  "Clean up all test resources.
Kills active Claude processes tracked by code-agent.
Only kills processes registered in the unified `code-agent--registry' and
`code-agent--active-queries' - does NOT kill other Claude instances."
  ;; First, try graceful cancellation via code-agent-org sessions
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (bound-and-true-p code-agent-org-mode)
          (ignore-errors (code-agent-org-cancel-all))))))
  ;; Then forcefully kill any remaining tracked processes
  ;; This only kills processes registered by code-agent, NOT other sessions
  (when (fboundp 'code-agent-kill-all-processes)
    (code-agent-kill-all-processes)))

(provide 'test-config)
;;; test-config.el ends here
