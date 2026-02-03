;;; test-claude-org-exec-status.el --- Integration tests for AI_EXEC_STATUS -*- lexical-binding: t -*-

;;; Commentary:
;; Integration tests for AI_EXEC_STATUS property tracking.
;; These tests make REAL API calls to verify execution status is correctly updated.

;;; Code:

(require 'ert)
(require 'claude-org)
(require 'test-config)

(ert-deftest test-org-integration-exec-status-cancelled ()
  "Test that AI_EXEC_STATUS is set to 'cancelled' after cancel.
This is an integration test that verifies:
1. Status is 'executing' when query starts
2. Status changes to 'cancelled' after claude-org-cancel"
  :tags '(:integration :slow :api :org :status)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       ;; Disable MCP auto-start for testing
       (let ((claude-org-auto-start-mcp-server nil))
         (claude-org-mode 1))

       ;; Start a query
       (goto-char (point-min))
       (re-search-forward "^\\*+ Instruction 1" nil t)
       (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai" nil t)
       (let ((session-key (claude-org--current-session-key))
             (block-pos (point)))
         (claude-org-execute)

         ;; Wait for query to actually start
         (sleep-for 1.0)
         (accept-process-output nil 0.5)

         ;; Verify status is "executing"
         (goto-char block-pos)
         (let ((status-before (claude-org--get-exec-status)))
           (should (equal status-before "executing")))

         ;; Cancel it
         (claude-org-cancel)

         ;; Wait for cleanup
         (sleep-for 0.3)
         (accept-process-output nil 0.3)

         ;; Verify status is now "cancelled"
         (goto-char block-pos)
         (let ((status-after (claude-org--get-exec-status)))
           (should (equal status-after "cancelled")))

         ;; Should no longer be busy
         (should-not (claude-org--session-get session-key :busy)))))))

(ert-deftest test-org-integration-exec-status-completed ()
  "Test that AI_EXEC_STATUS is set to 'completed' after successful execution."
  :tags '(:integration :slow :api :org :status)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       ;; Disable MCP auto-start for testing
       (let ((claude-org-auto-start-mcp-server nil))
         (claude-org-mode 1))

       ;; Execute a simple query
       (goto-char (point-min))
       (re-search-forward "^\\*+ Instruction 1" nil t)
       (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai" nil t)
       (let ((session-key (claude-org--current-session-key))
             (block-pos (point)))
         (claude-org-execute)

         ;; Wait for completion
         (test-claude-wait-for-completion session-key 30)

         ;; Verify status is "completed"
         (goto-char block-pos)
         (let ((status (claude-org--get-exec-status)))
           (should (equal status "completed"))))))))

(provide 'test-claude-org-exec-status)
;;; test-claude-org-exec-status.el ends here
