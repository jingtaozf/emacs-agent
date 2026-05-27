;;; test-code-agent-org-cancel-active-queries.el --- Test cancel removes query from active queries -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for the bug where terminal query states (cancel, complete, error)
;; did NOT remove the query from the active queries hash table.
;;
;; Cancel bug scenario:
;; 1. User starts an AI block query (registered in code-agent--active-queries)
;; 2. User cancels via code-agent-org-menu (C-c C-k or "k" in transient menu)
;; 3. code-agent-org-cancel calls code-agent-query-interrupt (SIGINT only)
;; 4. BUT it does NOT call code-agent--unregister-query or set closed=t
;; 5. The query remains in active-queries hash table
;; 6. Mode line still shows active query spinner
;; 7. Active Queries buffer still shows the query
;; 8. User must cancel again in Active Queries buffer to remove it
;;
;; Completion bug scenario:
;; 1. Query completes normally (handle-complete fires)
;; 2. handle-complete sets :busy nil but does NOT unregister from active-queries
;; 3. CLI process stays alive (common with --print mode)
;; 4. Sentinel never fires, query stays in hash table indefinitely
;;
;; Expected: After any terminal state (cancel, complete, error), the query
;; should be immediately removed from code-agent--active-queries.

;;; Code:

(require 'ert)
(require 'code-agent-org)
(require 'test-config)

(ert-deftest test-org-cancel-removes-from-active-queries ()
  "Test that code-agent-org-cancel removes the query from active queries hash table.
After cancellation, the specific request-id should no longer be registered
and should not appear in mode line or Active Queries buffer."
  :tags '(:integration :slow :api :org :cancel :active-queries)
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

         ;; Wait for query to start and get a request-id
         (should (test-claude-wait-until
                  (lambda ()
                    (let ((ps (code-agent-org-session-get session-key :process-state)))
                      (and ps (code-agent--process-state-request-id ps))))
                  10))
         (sleep-for 0.5)
         (accept-process-output nil 0.3)

         (let* ((process-state (code-agent-org-session-get session-key :process-state))
                (request-id (code-agent--process-state-request-id process-state)))
           (should request-id)
           ;; Before cancel: this specific request-id should be in the hash table
           (should (gethash request-id code-agent--active-queries))
           ;; And query-active-p should return t for this state
           (should (code-agent--query-active-p process-state))

           ;; Cancel via code-agent-org-cancel (same as menu "k" or C-c C-k)
           (goto-char block-pos)
           (code-agent-org-cancel)

           ;; The critical assertion: this request-id should be gone from hash table
           (let ((entry-after (gethash request-id code-agent--active-queries)))
             (message "DEBUG: active-queries entry after cancel = %S" entry-after)
             (should-not entry-after))

           ;; Also query-active-p should return nil (closed=t)
           (should-not (code-agent--query-active-p process-state))))))))

(ert-deftest test-org-cancel-marks-process-state-closed ()
  "Test that code-agent-org-cancel marks the process state as closed.
This ensures `code-agent--query-active-p' returns nil for the cancelled query."
  :tags '(:integration :slow :api :org :cancel :active-queries)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       (let ((code-agent-org-auto-start-mcp-server nil))
         (code-agent-org-mode 1))

       (goto-char (point-min))
       (re-search-forward "^\\*+ Instruction 1" nil t)
       (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai" nil t)
       (let ((session-key (code-agent-org-current-session-key))
             (block-pos (point)))

         (code-agent-org-execute)

         ;; Wait for query to start
         (should (test-claude-wait-until
                  (lambda ()
                    (code-agent-org-session-get session-key :process-state))
                  10))
         (sleep-for 0.5)
         (accept-process-output nil 0.3)

         (let ((process-state (code-agent-org-session-get session-key :process-state)))
           (should process-state)
           ;; Before cancel: process state should NOT be closed
           (should-not (code-agent--process-state-closed process-state))

           ;; Cancel
           (goto-char block-pos)
           (code-agent-org-cancel)

           ;; After cancel: process state SHOULD be marked closed
           (should (code-agent--process-state-closed process-state))))))))

(ert-deftest test-org-cancel-unregisters-request-id ()
  "Test that code-agent-org-cancel unregisters the request-id from active queries.
The request-id should no longer be in `code-agent--active-queries' hash table."
  :tags '(:integration :slow :api :org :cancel :active-queries)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       (let ((code-agent-org-auto-start-mcp-server nil))
         (code-agent-org-mode 1))

       (goto-char (point-min))
       (re-search-forward "^\\*+ Instruction 1" nil t)
       (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai" nil t)
       (let ((session-key (code-agent-org-current-session-key))
             (block-pos (point)))

         (code-agent-org-execute)

         ;; Wait for query to start and get registered
         (should (test-claude-wait-until
                  (lambda ()
                    (let ((ps (code-agent-org-session-get session-key :process-state)))
                      (and ps (code-agent--process-state-request-id ps))))
                  10))
         (sleep-for 0.5)
         (accept-process-output nil 0.3)

         (let* ((process-state (code-agent-org-session-get session-key :process-state))
                (request-id (code-agent--process-state-request-id process-state)))
           (should request-id)
           ;; Before cancel: request-id should be in hash table
           (should (gethash request-id code-agent--active-queries))

           ;; Cancel
           (goto-char block-pos)
           (code-agent-org-cancel)

           ;; After cancel: request-id should be removed from hash table
           (let ((entry-after (gethash request-id code-agent--active-queries)))
             (message "DEBUG: active-queries entry after cancel = %S" entry-after)
             (should-not entry-after))))))))

;;; Completion Tests

(ert-deftest test-org-complete-unregisters-from-active-queries ()
  "Test that handle-complete removes the query from active queries hash table.
After normal completion, the query should not linger in active-queries
even if the CLI process hasn't exited yet."
  :tags '(:integration :slow :api :org :complete :active-queries)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       (let ((code-agent-org-auto-start-mcp-server nil))
         (code-agent-org-mode 1))

       (goto-char (point-min))
       (re-search-forward "^\\*+ Instruction 1" nil t)
       (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai" nil t)
       (let ((session-key (code-agent-org-current-session-key))
             (block-pos (point)))

         (code-agent-org-execute)

         ;; Wait for query to start and get a request-id
         (should (test-claude-wait-until
                  (lambda ()
                    (let ((ps (code-agent-org-session-get session-key :process-state)))
                      (and ps (code-agent--process-state-request-id ps))))
                  10))

         (let* ((process-state (code-agent-org-session-get session-key :process-state))
                (request-id (code-agent--process-state-request-id process-state)))
           (should request-id)
           ;; Before completion: request-id should be registered
           (should (gethash request-id code-agent--active-queries))

           ;; Wait for query to complete normally
           (should (test-claude-wait-for-completion session-key 30))

           ;; After completion: request-id should be removed from hash table
           (let ((entry-after (gethash request-id code-agent--active-queries)))
             (message "DEBUG: active-queries entry after complete = %S" entry-after)
             (should-not entry-after))

           ;; Process state should be marked closed
           (should (code-agent--process-state-closed process-state))))))))

(provide 'test-code-agent-org-cancel-active-queries)
;;; test-code-agent-org-cancel-active-queries.el ends here
