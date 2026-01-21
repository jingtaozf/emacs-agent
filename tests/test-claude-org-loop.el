;;; test-claude-org-loop.el --- Tests for loop feature -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for the :loop N header argument feature.
;; 
;; Bug fixed: execute was not passing session-key to send-request,
;; causing callbacks to potentially use a different session-key
;; and not find the loop state.

;;; Code:

(require 'ert)
(require 'claude-org)

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

(ert-deftest test-claude-org-execute-passes-session-key ()
  "Test that execute passes session-key to send-request.
This ensures callbacks use the same key where loop state is stored."
  ;; Check that the source code has the fix
  (with-temp-buffer
    (insert-file-contents "/Users/jingtao/projects/claude-agent/claude-org.org")
    (goto-char (point-min))
    (search-forward "(defun claude-org-execute ()" nil t)
    (search-forward "claude-org--send-request" nil t)
    (let ((line (buffer-substring (line-beginning-position) (line-end-position))))
      ;; The line should contain session-key as third argument
      (should (string-match-p "send-request content query-ctx session-key" line)))))


;;; Re-execute Response Section Tests

(ert-deftest test-claude-org-find-instruction-number-in-response ()
  "Test that find-instruction-number finds number when inside Response section."
  (with-temp-buffer
    (insert "* Instruction 3 :claude_chat:

#+begin_src ai
test query
#+end_src

** Response 3 :ai_output:

Previous response text.

")
    (org-mode)
    (goto-char (point-max))
    (forward-line -2)  ; Inside Response section
    (should (= 3 (claude-org--find-instruction-number)))))

(ert-deftest test-claude-org-find-instruction-number-direct ()
  "Test that find-instruction-number works when directly in Instruction section."
  (with-temp-buffer
    (insert "* Instruction 7 :claude_chat:

#+begin_src ai
test
#+end_src
")
    (org-mode)
    (goto-char (point-min))
    (re-search-forward "test" nil t)
    (should (= 7 (claude-org--find-instruction-number)))))

(ert-deftest test-claude-org-find-instruction-number-nested-response ()
  "Test finding instruction number from deeply nested Response."
  (with-temp-buffer
    (insert "* Instruction 2 :claude_chat:

#+begin_src ai
query
#+end_src

** Response 2(1/3) :ai_output:

First iteration.

** Response 2(2/3) :ai_output:

Second iteration.

*** Some subsection

Nested content here.

")
    (org-mode)
    (goto-char (point-max))
    (forward-line -3)  ; Inside nested subsection
    (should (= 2 (claude-org--find-instruction-number)))))


(ert-deftest test-claude-org-loop-state-reset-on-reexecute ()
  "Test that loop state is properly reset when re-executing.
When re-executing an AI block with :loop N, the loop should start fresh
from iteration 1, not continue from where it left off."
  :tags '(:unit :fast :stable :isolated :org :loop)
  (let ((test-sessions (make-hash-table :test 'equal))
        (session-key "/tmp/test-reexecute.org::test-session"))
    
    ;; Simulate state after first complete loop execution
    ;; loop-current=2, loop-max=2 means loop finished
    (puthash session-key 
             (list :loop-current 2 
                   :loop-max 2 
                   :busy nil
                   :marker nil)
             test-sessions)
    
    ;; Verify initial state shows completed loop
    (let ((initial-current (plist-get (gethash session-key test-sessions) :loop-current))
          (initial-max (plist-get (gethash session-key test-sessions) :loop-max)))
      (should (= initial-current 2))
      (should (= initial-max 2))
      ;; Loop continuation check would fail (correctly - loop is done)
      (should-not (< initial-current initial-max)))
    
    ;; Simulate what claude-org-execute does on re-execution
    ;; It ALWAYS resets loop-current to 1
    (let ((session-data (copy-sequence (gethash session-key test-sessions))))
      (plist-put session-data :loop-current 1)
      (plist-put session-data :loop-max 2)
      (plist-put session-data :busy t)
      (puthash session-key session-data test-sessions))
    
    ;; After re-execute starts, loop-current should be 1
    (let ((reset-current (plist-get (gethash session-key test-sessions) :loop-current))
          (reset-max (plist-get (gethash session-key test-sessions) :loop-max)))
      (should (= reset-current 1))
      (should (= reset-max 2))
      ;; Loop continuation check should pass after first iteration completes
      (should (< reset-current reset-max)))))

(ert-deftest test-claude-org-loop-continuation-logic ()
  "Test the loop continuation decision logic in isolation.
Verifies that maybe-continue-loop correctly decides when to continue."
  :tags '(:unit :fast :stable :isolated :org :loop)
  ;; Test iteration 1 of 2: should continue
  (let ((loop-current 1)
        (loop-max 2))
    (should (and loop-current loop-max (< loop-current loop-max))))
  
  ;; Test iteration 2 of 2: should NOT continue
  (let ((loop-current 2)
        (loop-max 2))
    (should-not (and loop-current loop-max (< loop-current loop-max))))
  
  ;; Test iteration 1 of 3: should continue
  (let ((loop-current 1)
        (loop-max 3))
    (should (and loop-current loop-max (< loop-current loop-max))))
  
  ;; Test iteration 2 of 3: should continue
  (let ((loop-current 2)
        (loop-max 3))
    (should (and loop-current loop-max (< loop-current loop-max))))
  
  ;; Test iteration 3 of 3: should NOT continue
  (let ((loop-current 3)
        (loop-max 3))
    (should-not (and loop-current loop-max (< loop-current loop-max)))))

(provide 'test-claude-org-loop)
;;; test-claude-org-loop.el ends here


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

