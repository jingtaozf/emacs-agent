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

(ert-deftest test-org-integration-cancel-with-invalid-exec-marker ()
  "Test cancel when exec-status-marker becomes invalid.
This simulates a scenario where the marker buffer is killed or narrowing
changes, and verifies status is still set correctly using custom-id fallback."
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

         ;; Manually invalidate the exec-status-marker to simulate edge case
         (let ((esm (claude-org--session-get session-key :exec-status-marker)))
           (message "DEBUG: exec-status-marker before invalidate = %s buffer = %s"
                    esm (and esm (marker-buffer esm)))
           (when esm
             (set-marker esm nil))
           (message "DEBUG: exec-status-marker after invalidate = %s buffer = %s"
                    esm (and esm (marker-buffer esm))))

         ;; Check custom-id is available for fallback
         (let ((custom-id (claude-org--session-get session-key :custom-id)))
           (message "DEBUG: custom-id = %s" custom-id))

         ;; Cancel it - this should still work via custom-id fallback
         (claude-org-cancel)

         ;; Check status - should be "cancelled" even without valid marker
         (goto-char block-pos)
         (let ((status-after-cancel (claude-org--get-exec-status)))
           (message "DEBUG: status after cancel with invalid marker = %s" status-after-cancel)
           ;; If this fails, we found the bug!
           (should (equal status-after-cancel "cancelled"))))))))

(provide 'test-claude-org-cancel-race)
;;; test-claude-org-cancel-race.el ends here
