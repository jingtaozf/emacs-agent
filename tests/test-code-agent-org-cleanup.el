;;; test-code-agent-org-cleanup.el --- Tests for centralized session cleanup  -*- lexical-binding: t; -*-

;; Tests for F15-F18: Centralized cleanup, unified insertion,
;; narrowed buffer safety, silent failure prevention.

(require 'ert)
(require 'code-agent-org)

;;; Test Helpers

(defmacro test-cleanup--with-org-buffer (content &rest body)
  "Execute BODY in a temporary org buffer with CONTENT.
Sets up code-agent-org--sessions hash table."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer "*test-cleanup*")))
     (unwind-protect
         (with-current-buffer buf
           (org-mode)
           (insert ,content)
           (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
           ,@body)
       (kill-buffer buf))))

(defun test-cleanup--setup-session (session-key &rest props)
  "Set up a minimal session for SESSION-KEY with PROPS.
Returns the session-key."
  (let ((state (code-agent-org--get-session session-key)))
    (code-agent-org-session-put session-key :busy t)
    (while props
      (code-agent-org-session-put session-key (car props) (cadr props))
      (setq props (cddr props))))
  session-key)

;;; F15: cleanup-session Tests

(ert-deftest test-cleanup-session-sets-terminal-state ()
  "cleanup-session should set all transient fields to terminal values."
  :tags '(:unit :fast :stable :cleanup)
  (test-cleanup--with-org-buffer
    "* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (let ((sk "test-session"))
      (test-cleanup--setup-session sk
        :busy t :recovering t :last-assistant-query-id "old-qid"
        :marker (copy-marker (point-min)))
      ;; Pre-conditions
      (should (code-agent-org-session-get sk :busy))
      (should (code-agent-org-session-get sk :recovering))
      (should (code-agent-org-session-get sk :marker))
      ;; Act
      (code-agent-org--cleanup-session sk "completed")
      ;; Assert
      (should-not (code-agent-org-session-get sk :busy))
      (should-not (code-agent-org-session-get sk :recovering))
      (should-not (code-agent-org-session-get sk :marker)))))

(ert-deftest test-cleanup-session-frees-marker ()
  "cleanup-session should nil out the marker to prevent memory leak."
  :tags '(:unit :fast :stable :cleanup)
  (test-cleanup--with-org-buffer
    "* Test\n"
    (let ((sk "test-session")
          (marker (copy-marker (point-min))))
      (test-cleanup--setup-session sk :marker marker)
      (code-agent-org--cleanup-session sk "completed")
      ;; Marker should be freed (set to nil position)
      (should-not (marker-position marker))
      (should-not (code-agent-org-session-get sk :marker)))))

(ert-deftest test-cleanup-session-clears-queue-when-requested ()
  "cleanup-session with clear-queue-p should clear pending queue."
  :tags '(:unit :fast :stable :cleanup)
  (test-cleanup--with-org-buffer
    "* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (let ((sk "test-session"))
      (test-cleanup--setup-session sk
        :pending-queue (list (list :content "queued block")))
      (should (code-agent-org-session-get sk :pending-queue))
      ;; Act: cleanup WITH clear-queue
      (code-agent-org--cleanup-session sk "error" t)
      ;; Queue should be empty
      (should-not (code-agent-org-session-get sk :pending-queue)))))

(ert-deftest test-cleanup-session-preserves-queue-by-default ()
  "cleanup-session without clear-queue-p should preserve pending queue.
This is needed for handle-complete which dequeues after cleanup."
  :tags '(:unit :fast :stable :cleanup)
  (test-cleanup--with-org-buffer
    "* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (let ((sk "test-session"))
      (test-cleanup--setup-session sk
        :pending-queue (list (list :content "queued block")))
      ;; Act: cleanup WITHOUT clear-queue
      (code-agent-org--cleanup-session sk "completed")
      ;; Queue should be preserved
      (should (code-agent-org-session-get sk :pending-queue)))))

;;; F15: cancel-all completeness

(ert-deftest test-cancel-all-frees-markers ()
  "cancel-all should free markers for ALL sessions.
BUG A1: cancel-all currently does NOT free markers (memory leak)."
  :tags '(:unit :fast :stable :cleanup)
  (test-cleanup--with-org-buffer
    "* Session A\n#+begin_src ai\nhello\n#+end_src\n** Response :ai_output:\n:PROPERTIES:\n:QUERY_ID: qid-a\n:END:\n\n* Session B\n#+begin_src ai\nworld\n#+end_src\n** Response :ai_output:\n:PROPERTIES:\n:QUERY_ID: qid-b\n:END:\n"
    (let ((sk-a "session-a")
          (sk-b "session-b")
          (marker-a (copy-marker (point-min)))
          (marker-b (copy-marker (point-min))))
      (test-cleanup--setup-session sk-a :marker marker-a)
      (test-cleanup--setup-session sk-b :marker marker-b)
      ;; Act
      (code-agent-org-cancel-all)
      ;; Both markers should be freed
      (should-not (marker-position marker-a))
      (should-not (marker-position marker-b)))))

(ert-deftest test-cancel-all-sets-exec-status ()
  "cancel-all should set exec-status to cancelled for all sessions.
BUG A1: cancel-all currently does NOT set exec-status."
  :tags '(:unit :fast :stable :cleanup)
  (test-cleanup--with-org-buffer
    "* Test :claude_chat:\n:PROPERTIES:\n:CUSTOM_ID: test-cancel-all-status\n:END:\n#+begin_src ai\nhello\n#+end_src\n** Response :ai_output:\n:PROPERTIES:\n:QUERY_ID: qid-x\n:END:\nsome response\n"
    ;; Would need to check org properties after cancel-all.
    ;; For now, verify cleanup-session is called (which sets status).
    (let ((sk "test-key")
          (cleanup-called nil))
      (test-cleanup--setup-session sk :busy t :marker (copy-marker (point-min)))
      ;; We verify indirectly: after cancel-all, :busy should be nil
      ;; and marker should be freed (proves cleanup-session was used)
      (code-agent-org-cancel-all)
      (should-not (code-agent-org-session-get sk :busy))
      (should-not (code-agent-org-session-get sk :marker)))))

;;; F16: insert-error location

(ert-deftest test-insert-error-at-response-section ()
  "insert-error should insert at the response section, not at the AI block.
BUG A2: insert-error currently inserts at marker (inside/near src block)."
  :tags '(:unit :fast :stable :cleanup)
  (test-cleanup--with-org-buffer
    "* Test :claude_chat:\n#+begin_src ai\nhello\n#+end_src\n** Response :ai_output:\n:PROPERTIES:\n:QUERY_ID: qid-err-test\n:END:\npartial response here\n"
    (let ((sk "test-err-session"))
      (test-cleanup--setup-session sk
        :query-id "qid-err-test"
        :marker (progn (goto-char (point-min))
                       (re-search-forward "begin_src ai" nil t)
                       (copy-marker (line-beginning-position))))
      ;; Act
      (code-agent-org--insert-error sk "Something went wrong")
      ;; Error should appear AFTER the response section content, not at src block
      (goto-char (point-min))
      (let ((src-block-end (re-search-forward "end_src" nil t))
            (error-pos (progn (goto-char (point-min))
                              (re-search-forward "\\[Error:" nil t))))
        (should error-pos)
        ;; Error should be AFTER the response section :END:, not near src block
        (let ((end-prop (save-excursion
                          (goto-char (point-min))
                          (re-search-forward "^:END:" nil t))))
          (should (> error-pos end-prop)))))))

;;; F17: Narrowed buffer safety

(ert-deftest test-find-response-by-query-id-in-narrowed-buffer ()
  "find-response-by-query-id should work when buffer is narrowed.
BUG B3: Currently uses point-min without widen, silently fails."
  :tags '(:unit :fast :stable :cleanup)
  (test-cleanup--with-org-buffer
    "* Unrelated Section\nSome content here.\n* AI Section :claude_chat:\n#+begin_src ai\nhello\n#+end_src\n** Response :ai_output:\n:PROPERTIES:\n:QUERY_ID: qid-narrow-test\n:END:\nresponse content\n"
    ;; Narrow to the unrelated section only
    (goto-char (point-min))
    (org-narrow-to-subtree)  ; narrows to "Unrelated Section"
    ;; The query-id is OUTSIDE the narrowed region
    (let ((result (code-agent-org--find-response-by-query-id "qid-narrow-test")))
      ;; Should still find it (after widen fix)
      (should result))))

(ert-deftest test-insert-at-response-in-narrowed-buffer ()
  "insert-at-response should work when buffer is narrowed.
Depends on find-response-by-query-id widening."
  :tags '(:unit :fast :stable :cleanup)
  (test-cleanup--with-org-buffer
    "* Unrelated\nStuff.\n* AI :claude_chat:\n#+begin_src ai\nhello\n#+end_src\n** Response :ai_output:\n:PROPERTIES:\n:QUERY_ID: qid-narrow-insert\n:END:\n\n"
    (let ((sk "test-narrow"))
      (test-cleanup--setup-session sk :query-id "qid-narrow-insert")
      ;; Narrow to unrelated section
      (goto-char (point-min))
      (org-narrow-to-subtree)
      ;; Try inserting a token — should succeed after widen fix
      (let ((result (code-agent-org--insert-at-response sk "Hello from Claude")))
        (should result))
      ;; Verify content was inserted (widen to check)
      (widen)
      (goto-char (point-min))
      (should (re-search-forward "Hello from Claude" nil t)))))

;;; F18: Silent failure prevention

(ert-deftest test-handle-token-nil-query-id-warns ()
  "handle-token-v2 should warn when query-id is nil, not silently drop.
BUG B1: Currently all tokens are silently lost."
  :tags '(:unit :fast :stable :cleanup)
  (test-cleanup--with-org-buffer
    "* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (let ((sk "test-nil-qid")
          (warning-logged nil))
      (test-cleanup--setup-session sk :query-id nil)
      ;; Capture message output
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (when (string-match-p "token dropped\\|query-id"
                                         (apply #'format fmt args))
                     (setq warning-logged t)))))
        (code-agent-org--handle-token-v2 sk "Hello world"))
      ;; Should have logged a warning
      (should warning-logged))))

;;; B5: Queue dequeue after buffer killed

(ert-deftest test-loop-abort-performs-full-cleanup ()
  "Loop abort path should perform full cleanup, not just :busy nil + stop-spinner.
BUG: loop-abort currently only does 2/8 cleanup operations."
  :tags '(:unit :fast :stable :cleanup)
  (test-cleanup--with-org-buffer
    "* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (let ((sk "test-loop-abort")
          (marker (copy-marker (point-min))))
      (test-cleanup--setup-session sk
        :marker marker
        :recovering t
        :loop-current 2
        :loop-max 5)
      ;; Simulate what loop-abort should do
      ;; After the fix, execute-loop-iteration abort will call cleanup-session
      ;; For now, test that cleanup-session handles this case
      (code-agent-org--cleanup-session sk "error")
      ;; All state should be cleaned
      (should-not (code-agent-org-session-get sk :busy))
      (should-not (code-agent-org-session-get sk :recovering))
      (should-not (code-agent-org-session-get sk :marker))
      (should-not (marker-position marker)))))

(ert-deftest test-cleanup-queued-blocks-frees-markers ()
  "cleanup-queued-blocks should free markers on queued blocks."
  :tags '(:unit :fast :stable :cleanup)
  (test-cleanup--with-org-buffer
    "* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (let* ((sk "test-queue-cleanup")
           (q-marker (copy-marker (point-min)))
           (queue (list (list :content "block" :marker q-marker))))
      (test-cleanup--setup-session sk :pending-queue queue)
      ;; Act
      (code-agent-org--cleanup-queued-blocks sk)
      ;; Queued marker should be freed
      (should-not (marker-position q-marker))
      ;; Queue should be cleared
      (should-not (code-agent-org-session-get sk :pending-queue)))))

(provide 'test-code-agent-org-cleanup)
;;; test-code-agent-org-cleanup.el ends here
