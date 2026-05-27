;;; test-code-agent-org-exec-status.el --- Integration tests for AI_EXEC_STATUS -*- lexical-binding: t -*-

;;; Commentary:
;; Integration tests for AI_EXEC_STATUS property tracking.
;; These tests make REAL API calls to verify execution status is correctly updated.

;;; Code:

(require 'ert)
(require 'code-agent-org)
(require 'test-config)

(ert-deftest test-org-integration-exec-status-cancelled ()
  "Test that AI_EXEC_STATUS is set to 'cancelled' after cancel.
This is an integration test that verifies:
1. Status is 'executing' when query starts
2. Status changes to 'cancelled' after code-agent-org-cancel"
  :tags '(:integration :slow :api :org :status)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       ;; Disable MCP auto-start for testing
       (let ((code-agent-org-auto-start-mcp-server nil))
         (code-agent-org-mode 1))

       ;; Start a query
       (goto-char (point-min))
       (re-search-forward "^\\*+ Instruction 1" nil t)
       (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai" nil t)
       (let ((session-key (code-agent-org-current-session-key))
             (block-pos (point)))
         (code-agent-org-execute)

         ;; Wait for query to actually start
         (sleep-for 1.0)
         (accept-process-output nil 0.5)

         ;; Verify status is "executing"
         (goto-char block-pos)
         (let ((status-before (code-agent-org--get-exec-status)))
           (should (equal status-before "executing")))

         ;; Cancel it
         (code-agent-org-cancel)

         ;; Wait for cleanup
         (sleep-for 0.3)
         (accept-process-output nil 0.3)

         ;; Verify status is now "cancelled"
         (goto-char block-pos)
         (let ((status-after (code-agent-org--get-exec-status)))
           (should (equal status-after "cancelled")))

         ;; Should no longer be busy
         (should-not (code-agent-org-session-get session-key :busy)))))))

(ert-deftest test-org-integration-exec-status-completed ()
  "Test that AI_EXEC_STATUS is set to 'completed' after successful execution."
  :tags '(:integration :slow :api :org :status)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       ;; Disable MCP auto-start for testing
       (let ((code-agent-org-auto-start-mcp-server nil))
         (code-agent-org-mode 1))

       ;; Execute a simple query
       (goto-char (point-min))
       (re-search-forward "^\\*+ Instruction 1" nil t)
       (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai" nil t)
       (let ((session-key (code-agent-org-current-session-key))
             (block-pos (point)))
         (code-agent-org-execute)

         ;; Wait for completion
         (test-claude-wait-for-completion session-key 30)

         ;; Verify status is "completed"
         (goto-char block-pos)
         (let ((status (code-agent-org--get-exec-status)))
           (should (equal status "completed"))))))))

(provide 'test-code-agent-org-exec-status)
;;; test-code-agent-org-exec-status.el ends here
