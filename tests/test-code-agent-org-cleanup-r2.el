;;; test-code-agent-org-cleanup-r2.el --- Round 2 cleanup tests  -*- lexical-binding: t; -*-

;; Tests for F19-F23: cancel refactoring, narrowing safety completion,
;; buffer-kill cleanup, loop timer lifecycle, minor resource leaks.

(require 'ert)
(require 'code-agent-org)

;;; Test Helpers (reuse pattern from test-code-agent-org-cleanup.el)

(defmacro test-r2--with-org-buffer (content &rest body)
  "Execute BODY in a temporary org buffer with CONTENT.
Sets up code-agent-org--sessions hash table."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer "*test-r2*")))
     (unwind-protect
         (with-current-buffer buf
           (org-mode)
           (insert ,content)
           (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
           ,@body)
       (when (buffer-live-p buf) (kill-buffer buf)))))

(defun test-r2--setup-session (session-key &rest props)
  "Set up a minimal session for SESSION-KEY with PROPS."
  (code-agent-org--get-session session-key)
  (code-agent-org-session-put session-key :busy t)
  (while props
    (code-agent-org-session-put session-key (car props) (cadr props))
    (setq props (cddr props)))
  session-key)

;;; ---------------------------------------------------------------
;;; F19: cancel uses cleanup-session
;;; ---------------------------------------------------------------

(ert-deftest test-r2-cancel-clears-recovering-flag ()
  "cancel should clear :recovering flag via cleanup-session (not just :busy).
BUG B1: cancel only sets :busy nil, leaves :recovering stale."
  :tags '(:unit :fast :stable :cleanup-r2 :f19)
  (test-r2--with-org-buffer
    "* Test :claude_chat:\n#+begin_src ai\nhello\n#+end_src\n** Response :ai_output:\n:PROPERTIES:\n:QUERY_ID: qid-f19-1\n:END:\npartial\n"
    (let ((sk "test::cancel-recovering"))
      (test-r2--setup-session sk
        :recovering t
        :last-assistant-query-id "old-asst-qid"
        :query-id "qid-f19-1"
        :marker (copy-marker (point-min)))
      ;; Verify pre-conditions
      (should (code-agent-org-session-get sk :recovering))
      (should (code-agent-org-session-get sk :last-assistant-query-id))
      ;; Act: simulate cancel (without backend, just the cleanup part)
      ;; The real cancel calls backend-cancel first, then cleanup.
      ;; We test cleanup completeness by calling cleanup-session directly
      ;; with "cancelled" status — this is what cancel SHOULD do.
      (code-agent-org--cleanup-session sk "cancelled" t)
      ;; :recovering should be cleared
      (should-not (code-agent-org-session-get sk :recovering))
      ;; :last-assistant-query-id should be cleared
      (should-not (code-agent-org-session-get sk :last-assistant-query-id)))))

(ert-deftest test-r2-cancel-frees-queued-block-markers ()
  "cancel should free markers in queued blocks (via cleanup-queued-blocks).
BUG B2: cancel uses clear-queue which doesn't free markers."
  :tags '(:unit :fast :stable :cleanup-r2 :f19)
  (test-r2--with-org-buffer
    "* Test :claude_chat:\n#+begin_src ai\nhello\n#+end_src\n** Response :ai_output:\n:PROPERTIES:\n:QUERY_ID: qid-f19-2\n:END:\n\n"
    (let* ((sk "test::cancel-queue-markers")
           (q-marker-1 (copy-marker (point-min)))
           (q-marker-2 (copy-marker (point-max)))
           (queue (list (list :content "block-a" :marker q-marker-1)
                        (list :content "block-b" :marker q-marker-2))))
      (test-r2--setup-session sk
        :query-id "qid-f19-2"
        :marker (copy-marker (point-min))
        :pending-queue queue)
      ;; Pre-conditions: markers are live
      (should (marker-position q-marker-1))
      (should (marker-position q-marker-2))
      ;; Act: cancel with queue clear
      (code-agent-org--cleanup-session sk "cancelled" t)
      ;; Queued block markers should be freed
      (should-not (marker-position q-marker-1))
      (should-not (marker-position q-marker-2))
      ;; Queue should be empty
      (should-not (code-agent-org-session-get sk :pending-queue)))))

(ert-deftest test-r2-cancel-function-uses-cleanup-session ()
  "The actual code-agent-org-cancel function should use cleanup-session.
Verify by checking that :recovering is cleared (which only reset-session-state does)."
  :tags '(:unit :fast :stable :cleanup-r2 :f19)
  (test-r2--with-org-buffer
    "* Test :claude_chat:\n#+begin_src ai\nhello\n#+end_src\n** Response :ai_output:\n:PROPERTIES:\n:QUERY_ID: qid-f19-3\n:END:\npartial\n"
    ;; Need buffer-file-name for current-session-key to work
    (setq buffer-file-name "/tmp/test-f19-cancel.org")
    (goto-char (point-min))
    (re-search-forward "begin_src ai" nil t)
    (let ((sk (code-agent-org-current-session-key)))
      (should sk)  ; verify session key was generated
      ;; Set up session manually (need :backend for cancel's guard check)
      (code-agent-org-session-put sk :busy t)
      (code-agent-org-session-put sk :recovering t)
      (code-agent-org-session-put sk :backend 'mock-backend)
      (code-agent-org-session-put sk :query-id "qid-f19-3")
      (code-agent-org-session-put sk :marker (copy-marker (point-min)))
      ;; Mock backend-cancel and other side-effect functions
      (cl-letf (((symbol-function 'code-agent-backend-cancel) #'ignore)
                ((symbol-function 'code-agent-org--start-spinner) #'ignore)
                ((symbol-function 'code-agent-org--stop-spinner) #'ignore)
                ((symbol-function 'code-agent-org-refresh-header-line) #'ignore)
                ((symbol-function 'code-agent-org--unregister-active-query) #'ignore))
        (code-agent-org-cancel))
      ;; :recovering should be cleared (proves reset-session-state was called)
      (should-not (code-agent-org-session-get sk :recovering))
      ;; :busy should be nil
      (should-not (code-agent-org-session-get sk :busy)))))

;;; ---------------------------------------------------------------
;;; F20: Complete narrowing safety
;;; ---------------------------------------------------------------

(ert-deftest test-r2-insert-at-response-widened ()
  "insert-at-response should widen before goto-char to handle narrowed buffers.
BUG B3 follow-up: find-response-by-query-id widens, but insert-at-response
uses the returned position in the narrowed restriction — goto-char clamps."
  :tags '(:unit :fast :stable :cleanup-r2 :f20)
  (test-r2--with-org-buffer
    "* Unrelated\nSome unrelated content.\n* AI :claude_chat:\n#+begin_src ai\nhello\n#+end_src\n** Response :ai_output:\n:PROPERTIES:\n:QUERY_ID: qid-f20-1\n:END:\n\n"
    (let ((sk "test::narrow-insert"))
      (test-r2--setup-session sk :query-id "qid-f20-1")
      ;; Narrow to unrelated section (query-id is OUTSIDE restriction)
      (goto-char (point-min))
      (org-narrow-to-subtree)
      ;; Verify we're actually narrowed
      (should (< (- (point-max) (point-min))
                 (buffer-size)))
      ;; Insert token — should succeed and place text in the response section
      (let ((result (code-agent-org--insert-at-response sk "Token from Claude")))
        (should result))
      ;; Widen and verify text was inserted in the right place
      (widen)
      (goto-char (point-min))
      (should (re-search-forward "Token from Claude" nil t))
      ;; Token should be AFTER the :END: of the Response section
      (let ((token-pos (match-beginning 0))
            (end-pos (save-excursion
                       (goto-char (point-min))
                       (re-search-forward "^:QUERY_ID: qid-f20-1" nil t)
                       (re-search-forward "^:END:" nil t)
                       (point))))
        (should (> token-pos end-pos))))))

(ert-deftest test-r2-find-response-end-widened ()
  "find-response-end-by-query-id should work when buffer is narrowed."
  :tags '(:unit :fast :stable :cleanup-r2 :f20)
  (test-r2--with-org-buffer
    "* Unrelated\nContent.\n* AI :claude_chat:\n#+begin_src ai\nhello\n#+end_src\n** Response :ai_output:\n:PROPERTIES:\n:QUERY_ID: qid-f20-2\n:END:\nResponse text here.\n"
    ;; Narrow to unrelated section
    (goto-char (point-min))
    (org-narrow-to-subtree)
    ;; find-response-end should still find the response end
    (let ((end-pos (code-agent-org--find-response-end-by-query-id "qid-f20-2")))
      (should end-pos)
      ;; The position should be beyond the narrowed region
      (should (> end-pos (point-max))))))

;;; ---------------------------------------------------------------
;;; F21: Buffer kill cancels active sessions
;;; ---------------------------------------------------------------

(ert-deftest test-r2-buffer-kill-cancels-active-sessions ()
  "Killing a buffer should cancel active sessions to prevent zombie CLI processes.
BUG B4: on-buffer-kill only disconnects persistent clients."
  :tags '(:unit :fast :stable :cleanup-r2 :f21)
  (let ((buf (generate-new-buffer "*test-kill-cancel*"))
        (cancel-all-called nil))
    (unwind-protect
        (with-current-buffer buf
          (org-mode)
          (insert "* Test\n#+begin_src ai\nhello\n#+end_src\n")
          (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
          (setq buffer-file-name "/tmp/test-kill-cancel.org")
          ;; Set up an active session
          (let ((sk "test::kill-cancel"))
            (test-r2--setup-session sk
              :busy t
              :marker (copy-marker (point-min))))
          ;; Install the buffer-kill hook (simulates code-agent-org-mode enable)
          (add-hook 'kill-buffer-hook #'code-agent-org--on-buffer-kill nil t)
          ;; Mock cancel-all to detect it was called
          (cl-letf (((symbol-function 'code-agent-org-cancel-all)
                     (lambda () (setq cancel-all-called t)))
                    ((symbol-function 'code-agent-org-persistent-registry-disconnect-buffer)
                     (lambda (_registry _buffer) nil)))
            ;; Kill the buffer
            (kill-buffer buf)
            (setq buf nil)  ; already killed
            ;; cancel-all should have been called
            (should cancel-all-called)))
      (when (and buf (buffer-live-p buf))
        (kill-buffer buf)))))

;;; ---------------------------------------------------------------
;;; F22: Loop timer lifecycle
;;; ---------------------------------------------------------------

(ert-deftest test-r2-loop-timer-cancelled-on-cleanup ()
  "cleanup-session should cancel any pending loop timer.
BUG A6: run-at-time timer is never stored or cancelled."
  :tags '(:unit :fast :stable :cleanup-r2 :f22)
  (test-r2--with-org-buffer
    "* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (let* ((sk "test::loop-timer")
           ;; Create a timer (simulating what maybe-continue-loop does)
           (timer (run-at-time 999 nil #'ignore)))
      (test-r2--setup-session sk
        :loop-timer timer
        :marker (copy-marker (point-min)))
      ;; Timer should be active before cleanup
      (should (memq timer timer-list))
      ;; Act: cleanup
      (code-agent-org--cleanup-session sk "cancelled" t)
      ;; Timer should be cancelled
      (should-not (memq timer timer-list))
      ;; :loop-timer should be cleared from session
      (should-not (code-agent-org-session-get sk :loop-timer)))))

;;; ---------------------------------------------------------------
;;; F23: Minor resource cleanup
;;; ---------------------------------------------------------------

(ert-deftest test-r2-execute-queued-block-frees-marker-on-skip ()
  "execute-queued-block should free marker even when skipping invalid block.
BUG B5: marker not freed on early return."
  :tags '(:unit :fast :stable :cleanup-r2 :f23)
  (test-r2--with-org-buffer
    "* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (let* ((sk "test::skip-marker")
           ;; Create a marker pointing into a DIFFERENT buffer (simulates killed buffer)
           (dead-buf (generate-new-buffer "*dead*"))
           (dead-marker (with-current-buffer dead-buf
                          (insert "temp content")
                          (copy-marker (point-min)))))
      (test-r2--setup-session sk)
      ;; Kill the buffer so marker becomes invalid
      (kill-buffer dead-buf)
      ;; Marker should now be dead (no buffer)
      (should-not (marker-buffer dead-marker))
      ;; But marker object still exists (not freed)
      (should (markerp dead-marker))
      ;; Mock dequeue to avoid recursion
      (cl-letf (((symbol-function 'code-agent-org--dequeue-block)
                 (lambda (_sk) nil)))
        ;; Act: try to execute queued block with dead marker
        (code-agent-org--execute-queued-block sk
          (list :content "test" :marker dead-marker)))
      ;; Marker should be freed (set-marker nil)
      (should-not (marker-position dead-marker)))))

(provide 'test-code-agent-org-cleanup-r2)
;;; test-code-agent-org-cleanup-r2.el ends here
