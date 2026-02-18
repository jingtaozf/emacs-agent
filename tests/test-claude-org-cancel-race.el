;;; test-claude-org-cancel-race.el --- Integration test for cancel/complete race condition -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for the race condition where handle-complete can overwrite
;; the "cancelled" status with "completed".
;;
;; Bug scenario:
;; 1. Query starts, status set to "executing"
;; 2. User cancels, status set to "cancelled"
;; 3. Process sentinel runs (delayed), calls handle-complete
;; 4. handle-complete sets status to "completed" - WRONG!
;;
;; The status should remain "cancelled" after cancel, even if
;; handle-complete runs afterward.

;;; Code:

(require 'ert)
(require 'claude-org)
(require 'test-config)

(ert-deftest test-org-integration-cancel-status-not-overwritten ()
  "Test that AI_EXEC_STATUS stays 'cancelled' after cancel.
This verifies the race condition is fixed:
1. Start query -> status = executing
2. Cancel -> status = cancelled
3. Wait for process to fully exit (sentinel calls handle-complete)
4. Verify status is STILL 'cancelled', not 'completed'"
  :tags '(:integration :slow :api :org :status :race)
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
         (should (equal (claude-org--get-exec-status) "executing"))

         ;; Cancel it
         (claude-org-cancel)

         ;; Immediately check - status should be "cancelled"
         (goto-char block-pos)
         (should (equal (claude-org--get-exec-status) "cancelled"))

         ;; Now wait for the process to fully terminate
         ;; This gives time for the sentinel to run handle-complete
         (sleep-for 2.0)
         (accept-process-output nil 1.0)

         ;; The critical test: status should STILL be "cancelled"
         ;; If the bug exists, it would be "completed" now
         (goto-char block-pos)
         (let ((final-status (claude-org--get-exec-status)))
           (message "DEBUG: final status after waiting = %s" final-status)
           (should (equal final-status "cancelled"))))))))

(ert-deftest test-org-integration-cancel-sets-status-via-custom-id ()
  "Test that cancel sets exec-status to cancelled via custom-id lookup."
  :tags '(:integration :slow :api :org :status :race)
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

         ;; Wait for query to start
         (sleep-for 1.0)
         (accept-process-output nil 0.5)

         ;; Verify executing
         (goto-char block-pos)
         (should (equal (claude-org--get-exec-status) "executing"))

         ;; Verify custom-id is available
         (let ((custom-id (claude-org--session-get session-key :custom-id)))
           (should custom-id))

         ;; Cancel it
         (claude-org-cancel)

         ;; Check status - should be "cancelled" via custom-id
         (goto-char block-pos)
         (let ((status-after-cancel (claude-org--get-exec-status)))
           (should (equal status-after-cancel "cancelled"))))))))

(provide 'test-claude-org-cancel-race)
;;; test-claude-org-cancel-race.el ends here
