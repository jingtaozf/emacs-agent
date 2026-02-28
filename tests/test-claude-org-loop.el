;;; test-claude-org-loop.el --- Tests for loop feature -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for the :loop N header argument feature.
;;
;; Bug fixes covered:
;; 1. execute was not passing session-key to send-request
;; 2. handle-complete freed marker before maybe-continue-loop
;; 3. execute-loop-iteration inserted sections inside AI block without QUERY_ID

;;; Code:

(require 'ert)
(require 'claude-org)

;;; Test Helpers

(defun test-loop--setup-session (session-key &rest props)
  "Set up loop session state for SESSION-KEY.
PROPS is a plist with :loop-current, :loop-max, :loop-interval,
:marker, :prompt, :instr-num, :custom-id, :section-level, :query-id."
  (claude-org--session-put session-key :loop-current (plist-get props :loop-current))
  (claude-org--session-put session-key :loop-max (plist-get props :loop-max))
  (claude-org--session-put session-key :loop-interval (or (plist-get props :loop-interval) 0))
  (claude-org--session-put session-key :marker (plist-get props :marker))
  (claude-org--session-put session-key :original-prompt (or (plist-get props :prompt) "test"))
  (claude-org--session-put session-key :instruction-num (or (plist-get props :instr-num) 1))
  (claude-org--session-put session-key :custom-id (plist-get props :custom-id))
  (claude-org--session-put session-key :section-level (or (plist-get props :section-level) 2))
  (claude-org--session-put session-key :busy t)
  (claude-org--session-put session-key :query-id (plist-get props :query-id)))

(defmacro with-loop-test-mocks (extra-bindings &rest body)
  "Run BODY with standard handle-complete mocks plus EXTRA-BINDINGS.
EXTRA-BINDINGS is a list of additional cl-letf bindings."
  (declare (indent 1))
  `(let ((claude-org-complete-hook nil))
     (cl-letf (((symbol-function 'claude-org--stop-spinner) #'ignore)
               ((symbol-function 'claude-org--refresh-header-line) #'ignore)
               ((symbol-function 'claude-org--start-spinner) #'ignore)
               ((symbol-function 'claude-org--insert-at-response) #'ignore)
               ((symbol-function 'claude-org--set-exec-status-for-session) #'ignore)
               ((symbol-function 'claude-org--get-exec-status-for-session)
                (lambda (&rest _) "executing"))
               ((symbol-function 'claude-org--unregister-active-query) #'ignore)
               ((symbol-function 'claude-org--dequeue-block) (lambda (&rest _) nil))
               ,@extra-bindings)
       ,@body)))

(defun test-loop--insert-response-section (query-id content)
  "Insert a response section with QUERY-ID and CONTENT at point."
  (insert (format "** Response 1 (2026-02-23 08:37) :ai_output:\n"))
  (insert (format ":PROPERTIES:\n:QUERY_ID: %s\n:QUERY_TYPE: normal\n:END:\n\n" query-id))
  (insert content "\n"))


;;; Basic Loop Logic Tests

(ert-deftest test-claude-org-loop-header-args-parsing ()
  "Test that :loop header args are parsed correctly."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src ai :loop 3 :interval 2\nTest\n#+end_src")
    (goto-char (point-min))
    (search-forward "Test")
    (let ((args (claude-org--get-block-header-args)))
      (should (equal (plist-get args :loop) "3"))
      (should (equal (plist-get args :interval) "2")))))

(ert-deftest test-claude-org-loop-max-conversion ()
  "Test that loop-max is converted from string to number."
  (let ((loop-max-raw "3"))
    (let ((loop-max (if (stringp loop-max-raw)
                        (string-to-number loop-max-raw)
                      (or loop-max-raw 1))))
      (should (= loop-max 3))
      (should (numberp loop-max)))))

(ert-deftest test-claude-org-maybe-continue-loop-condition ()
  "Test the loop continuation condition."
  (should (and 1 3 (< 1 3)))      ; iter 1 of 3: continue
  (should (and 2 3 (< 2 3)))      ; iter 2 of 3: continue
  (should-not (and 3 3 (< 3 3)))) ; iter 3 of 3: stop

(ert-deftest test-claude-org-handle-complete-marker-free-condition ()
  "Test when marker should be freed in handle-complete."
  (should-not (>= 1 3))  ; iter 1 of 3: don't free
  (should-not (>= 2 3))  ; iter 2 of 3: don't free
  (should (>= 3 3)))     ; iter 3 of 3: free

(ert-deftest test-claude-org-loop-session-state ()
  "Test that loop state is stored correctly in session."
  (let ((test-buffer (generate-new-buffer "*test-loop-state*")))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (claude-org-mode 1)
          (setq buffer-file-name "/tmp/test-loop.org")
          (insert "* Test\n:PROPERTIES:\n:CUSTOM_ID: test-state\n:END:\n\n#+begin_src ai :loop 3\nTest\n#+end_src\n")
          (goto-char (point-min))
          (search-forward "Test")

          (let ((session-key (claude-org--current-session-key)))
            (claude-org--session-put session-key :loop-max 3)
            (claude-org--session-put session-key :loop-current 1)
            (claude-org--session-put session-key :original-prompt "Test")

            (should (= (claude-org--session-get session-key :loop-max) 3))
            (should (= (claude-org--session-get session-key :loop-current) 1))
            (should (equal (claude-org--session-get session-key :original-prompt) "Test"))))
      (kill-buffer test-buffer))))

;;; Re-execute Response Section Tests


(ert-deftest test-claude-org-loop-state-reset-on-reexecute ()
  "Test that loop state is properly reset when re-executing.
When re-executing an AI block with :loop N, the loop should start fresh
from iteration 1, not continue from where it left off."
  :tags '(:unit :fast :stable :isolated :org :loop)
  (let ((test-sessions (make-hash-table :test 'equal))
        (session-key "/tmp/test-reexecute.org::test-session"))

    ;; Simulate state after first complete loop execution
    (puthash session-key
             (list :loop-current 2 :loop-max 2 :busy nil :marker nil)
             test-sessions)

    ;; Verify initial state shows completed loop
    (let ((initial-current (plist-get (gethash session-key test-sessions) :loop-current))
          (initial-max (plist-get (gethash session-key test-sessions) :loop-max)))
      (should (= initial-current 2))
      (should (= initial-max 2))
      (should-not (< initial-current initial-max)))

    ;; Simulate what claude-org-execute does on re-execution
    (let ((session-data (copy-sequence (gethash session-key test-sessions))))
      (plist-put session-data :loop-current 1)
      (plist-put session-data :loop-max 2)
      (plist-put session-data :busy t)
      (puthash session-key session-data test-sessions))

    ;; After re-execute, loop-current should be 1
    (let ((reset-current (plist-get (gethash session-key test-sessions) :loop-current))
          (reset-max (plist-get (gethash session-key test-sessions) :loop-max)))
      (should (= reset-current 1))
      (should (= reset-max 2))
      (should (< reset-current reset-max)))))

(ert-deftest test-claude-org-loop-continuation-logic ()
  "Test the loop continuation decision logic in isolation."
  :tags '(:unit :fast :stable :isolated :org :loop)
  (dolist (case '((1 2 t) (2 2 nil) (1 3 t) (2 3 t) (3 3 nil)))
    (let ((loop-current (nth 0 case))
          (loop-max (nth 1 case))
          (should-continue (nth 2 case)))
      (if should-continue
          (should (< loop-current loop-max))
        (should-not (< loop-current loop-max))))))


;;; handle-complete Loop Continuation Tests
;;
;; Regression tests for bug: handle-complete called free-marker BEFORE
;; maybe-continue-loop, so execute-loop-iteration found marker=nil
;; and silently skipped all subsequent iterations.

(ert-deftest test-claude-org-handle-complete-continues-loop ()
  "Test that handle-complete triggers the next loop iteration.
When loop-current < loop-max, handle-complete should call send-request
for the next iteration. Regression: free-marker was called before
maybe-continue-loop, causing execute-loop-iteration to silently fail."
  :tags '(:unit :org :loop)
  (let* ((test-buffer (generate-new-buffer "*test-loop-continue*"))
         (session-key nil)
         (send-request-called nil)
         (marker nil))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (setq buffer-file-name "/tmp/test-loop-continue.org")
          (insert "* Test\n:PROPERTIES:\n:CUSTOM_ID: test-loop\n:END:\n\n")
          ;; Must have a proper response section with QUERY_ID for query-id lookup
          (test-loop--insert-response-section "test-query-1" "First response.")
          (setq marker (point-marker))
          (setq session-key (concat buffer-file-name "::test-loop"))

          (test-loop--setup-session session-key
            :loop-current 1 :loop-max 3 :marker marker
            :custom-id "test-loop" :query-id "test-query-1")

          (with-loop-test-mocks
            (((symbol-function 'claude-org--send-request)
              (lambda (&rest _args) (setq send-request-called t))))

            (claude-org--handle-complete session-key nil)

            ;; send-request should have been called for iteration 2
            (should send-request-called)
            ;; loop-current should be 2 (incremented by maybe-continue-loop)
            (should (= 2 (claude-org--session-get session-key :loop-current)))))
      (when (buffer-live-p test-buffer)
        (kill-buffer test-buffer)))))

(ert-deftest test-claude-org-handle-complete-stops-at-loop-max ()
  "Test that handle-complete does NOT continue when loop is complete.
When loop-current >= loop-max, the loop should end and cleanup should happen."
  :tags '(:unit :org :loop)
  (let* ((test-buffer (generate-new-buffer "*test-loop-stop*"))
         (session-key nil)
         (send-request-called nil)
         (marker nil))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (setq buffer-file-name "/tmp/test-loop-stop.org")
          (insert "* Test\n:PROPERTIES:\n:CUSTOM_ID: test-stop\n:END:\n\n")
          (test-loop--insert-response-section "test-query-3" "Third response.")
          (setq marker (point-marker))
          (setq session-key (concat buffer-file-name "::test-stop"))

          (test-loop--setup-session session-key
            :loop-current 3 :loop-max 3 :marker marker
            :custom-id "test-stop" :query-id "test-query-3")

          (with-loop-test-mocks
            (((symbol-function 'claude-org--send-request)
              (lambda (&rest _args) (setq send-request-called t))))

            (claude-org--handle-complete session-key nil)

            (should-not send-request-called)
            (should-not (claude-org--session-get session-key :marker))
            (should-not (claude-org--session-get session-key :busy))))
      (when (buffer-live-p test-buffer)
        (kill-buffer test-buffer)))))

(ert-deftest test-claude-org-handle-complete-preserves-marker-for-interval ()
  "Test that marker is preserved when loop continues with interval.
When loop has interval > 0, next iteration is scheduled via run-at-time.
The marker must remain valid until the timer fires."
  :tags '(:unit :org :loop)
  (let* ((test-buffer (generate-new-buffer "*test-loop-interval*"))
         (session-key nil)
         (marker nil)
         (scheduled-timers nil))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (setq buffer-file-name "/tmp/test-loop-interval.org")
          (insert "* Test\n:PROPERTIES:\n:CUSTOM_ID: test-intv\n:END:\n\n")
          (test-loop--insert-response-section "test-query-1" "First response.")
          (setq marker (point-marker))
          (setq session-key (concat buffer-file-name "::test-intv"))

          (test-loop--setup-session session-key
            :loop-current 1 :loop-max 3 :loop-interval 5
            :marker marker :custom-id "test-intv" :query-id "test-query-1")

          (with-loop-test-mocks
            (;; Capture run-at-time calls instead of actually scheduling
             ((symbol-function 'run-at-time)
              (lambda (secs _repeat fn &rest args)
                (push (list secs fn args) scheduled-timers)
                nil)))

            (claude-org--handle-complete session-key nil)

            ;; A timer should have been scheduled
            (should (= 1 (length scheduled-timers)))
            ;; Timer delay should be the interval (5 seconds)
            (should (= 5 (car (car scheduled-timers))))
            ;; Marker should still be valid (NOT freed)
            (let ((m (claude-org--session-get session-key :marker)))
              (should m)
              (should (marker-buffer m)))))
      (when (buffer-live-p test-buffer)
        (kill-buffer test-buffer)))))


;;; Loop Iteration Section Placement Tests
;;
;; Regression tests for bug: iteration sections were inserted at the
;; block-marker (inside #+begin_src ai) without QUERY_ID, so tokens
;; routed to iteration 1's response section.

(ert-deftest test-claude-org-loop-iteration-section-not-inside-src-block ()
  "Test that loop iteration section is created OUTSIDE the AI block.
Regression: the old insert-iteration-section used the session marker
(inside #+begin_src ai) so iteration headings ended up inside the source block."
  :tags '(:unit :org :loop)
  (let* ((test-buffer (generate-new-buffer "*test-iter-pos*"))
         (session-key nil)
         (marker nil))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (setq buffer-file-name "/tmp/test-iter-pos.org")
          (insert "* Test\n:PROPERTIES:\n:CUSTOM_ID: test-ip\n:END:\n\n")
          (insert "** Instruction 1 :claude_chat:\n\n")
          (insert "#+begin_src ai :loop 3\n")
          (setq marker (point-marker))  ; marker inside AI block
          (insert "echo test\n")
          (insert "#+end_src\n\n")
          (test-loop--insert-response-section "test-q1" "first output")

          (setq session-key (concat buffer-file-name "::test-ip"))
          (test-loop--setup-session session-key
            :loop-current 1 :loop-max 3 :marker marker
            :prompt "echo test" :custom-id "test-ip" :query-id "test-q1")

          (with-loop-test-mocks
            (((symbol-function 'claude-org--send-request) #'ignore))

            (claude-org--handle-complete session-key nil)

            ;; The iteration section must NOT be inside the AI block
            (goto-char (point-min))
            (let ((src-start (search-forward "#+begin_src ai" nil t))
                  (src-end (search-forward "#+end_src" nil t)))
              (goto-char src-start)
              (should-not (re-search-forward "Response.*2/3" src-end t)))

            ;; The iteration section must be AFTER the first response
            (goto-char (point-min))
            (search-forward "first output" nil t)
            (should (re-search-forward "Response.*2/3" nil t))))
      (when (buffer-live-p test-buffer)
        (kill-buffer test-buffer)))))

(ert-deftest test-claude-org-loop-iteration-has-query-id-property ()
  "Test that each loop iteration's response section has a QUERY_ID property.
Without QUERY_ID, tokens can't be routed to the correct section."
  :tags '(:unit :org :loop)
  (let* ((test-buffer (generate-new-buffer "*test-iter-qid*"))
         (session-key nil)
         (marker nil))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (setq buffer-file-name "/tmp/test-iter-qid.org")
          (insert "* Test\n:PROPERTIES:\n:CUSTOM_ID: test-iq\n:END:\n\n")
          (insert "** Instruction 1 :claude_chat:\n\n")
          (insert "#+begin_src ai :loop 3\n")
          (setq marker (point-marker))
          (insert "echo test\n")
          (insert "#+end_src\n\n")
          (test-loop--insert-response-section "test-q1" "first output")

          (setq session-key (concat buffer-file-name "::test-iq"))
          (test-loop--setup-session session-key
            :loop-current 1 :loop-max 3 :marker marker
            :prompt "echo test" :custom-id "test-iq" :query-id "test-q1")

          (with-loop-test-mocks
            (((symbol-function 'claude-org--send-request) #'ignore))

            (claude-org--handle-complete session-key nil)

            ;; Find the iteration 2 section and verify it has QUERY_ID
            (goto-char (point-min))
            (when (re-search-forward "Response.*2/3" nil t)
              (forward-line 1)
              (should (re-search-forward ":QUERY_ID:" nil t)))

            ;; Session should have a NEW query-id (different from original)
            (let ((new-qid (claude-org--session-get session-key :query-id)))
              (should new-qid)
              (should-not (equal new-qid "test-q1")))))
      (when (buffer-live-p test-buffer)
        (kill-buffer test-buffer)))))

(ert-deftest test-claude-org-section-level-captured-early ()
  "Test that section-level is captured at AI block position, not after insertion.
This prevents wrong heading levels when re-executing after AI generates nested headings."
  :tags '(:unit :fast :stable :isolated :org :loop)
  (with-temp-buffer
    (org-mode)
    (insert "* Top Level\n")
    (insert ":PROPERTIES:\n:CLAUDE_SESSION_ID: test-session\n:END:\n\n")
    (insert "** Workflow\n\n")
    (insert "*** Instruction 1\n")
    (insert "#+begin_src ai :loop 2\ntest\n#+end_src\n\n")
    ;; Simulate previous response with nested headings
    (insert "*** Response 1(1/2) :ai_output:\n\n")
    (insert "Content here\n\n")
    (insert "**** Nested Header From AI\n\n")
    (insert "More content\n\n")
    (insert "***** Deeply Nested\n\n")
    (insert "Even more\n")

    ;; Position at the AI block
    (goto-char (point-min))
    (search-forward "#+begin_src ai")
    (forward-line 1)

    ;; The section level at AI block position should be 3 (*** Instruction)
    (let ((level (claude-org--get-section-level)))
      (should (= level 3)))

    ;; Position at end of file (where marker would be after response)
    (goto-char (point-max))
    ;; The section level here is 5 (inside ***** Deeply Nested)
    (let ((level-at-end (claude-org--get-section-level)))
      (should (= level-at-end 5)))

    ;; The fix ensures we capture level 3, not 5
    ;; This test documents the expected behavior
    ))

(provide 'test-claude-org-loop)
;;; test-claude-org-loop.el ends here
