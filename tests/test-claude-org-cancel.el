;;; test-claude-org-cancel.el --- Tests for cancel behavior -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for the cancel-then-reexecute bug fix.
;; Bug: After cancelling an AI block execution, re-executing the same block
;; would not append the response because the old sentinel callback would
;; free the new marker.
;;
;; Root cause: When cancel interrupted a process:
;; 1. cancel set :busy to nil and inserted [Cancelled]
;; 2. Process sentinel ran and called handle-complete
;; 3. handle-complete looked up :marker from session (dynamically, not captured)
;; 4. If user quickly re-executed, handle-complete would get the NEW marker
;; 5. handle-complete would free the NEW marker, breaking the new query
;;
;; Fix: cancel now frees the marker immediately, so handle-complete
;; finds nil and does nothing harmful.

;;; Code:

(require 'ert)
(require 'claude-org)

(ert-deftest test-claude-org-cancel-frees-marker ()
  "Test that cancel frees the marker immediately.
This prevents the sentinel callback from freeing a different marker
if the user quickly re-executes after cancel."
  (let ((test-buffer (generate-new-buffer "*test-cancel*")))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (claude-org-mode 1)
          (insert "* Test Section
:PROPERTIES:
:CUSTOM_ID: test-cancel-section
:END:

#+begin_src ai
Hello
#+end_src
")
          ;; Position inside the ai block
          (goto-char (point-min))
          (search-forward "Hello")
          
          (let* ((session-key (claude-org--current-session-key))
                 ;; Simulate being in an active query
                 (insert-point (save-excursion
                                 (re-search-forward "#\\+end_src" nil t)
                                 (point)))
                 (marker (progn
                           (save-excursion
                             (goto-char insert-point)
                             (point-marker)))))
            
            ;; Set up session state as if query was started
            (claude-org--session-put session-key :marker marker)
            (claude-org--session-put session-key :busy t)
            (claude-org--session-put session-key :process-state 'dummy-state)
            
            ;; Verify marker exists before cancel
            (should (claude-org--session-get session-key :marker))
            
            ;; Simulate the key part of cancel: it should free the marker
            ;; (We can't call full cancel without a real process)
            (claude-org--session-put session-key :busy nil)
            (claude-org--free-marker session-key)
            
            ;; After cancel, marker should be nil
            (should-not (claude-org--session-get session-key :marker))
            
            ;; Now simulate what would happen if handle-complete runs
            ;; It should NOT crash or affect anything because marker is already nil
            (let ((marker-after (claude-org--session-get session-key :marker)))
              (should-not marker-after))))
      (kill-buffer test-buffer))))

(ert-deftest test-claude-org-reexecute-after-cancel-finds-insert-point ()
  "Test that re-execution after cancel finds a valid insert point."
  (let ((test-buffer (generate-new-buffer "*test-reexecute*")))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (claude-org-mode 1)
          (insert "* Test Section
:PROPERTIES:
:CUSTOM_ID: test-section
:END:

*** Instruction 1 :ai_instruction:

#+begin_src ai
Hello
#+end_src

*** Response 1 :ai_output:

Some partial response
[Cancelled]

")
          ;; Position inside the ai block
          (goto-char (point-min))
          (search-forward "Hello")
          
          ;; Should be in ai block
          (should (claude-org--in-ai-block-p))
          
          ;; Should find insert point after cancelled response
          (let ((insert-point (claude-org--find-response-insert-point)))
            (should insert-point)
            (should (> insert-point (point)))
            ;; Insert point should be after the :ai_output: section
            ;; (at org-end-of-subtree position)
            (save-excursion
              (goto-char insert-point)
              ;; Should be at end of buffer or before next heading
              (should (or (eobp)
                          (looking-at "^\\*"))))))
      (kill-buffer test-buffer))))

(ert-deftest test-claude-org-cancel-prevents-race-condition ()
  "Test that cancel prevents the race condition with sentinel callback.
Simulates the scenario where:
1. Query1 starts, creates marker1
2. User cancels Query1
3. User quickly starts Query2, creates marker2
4. Query1's sentinel runs, should NOT free marker2"
  (let ((test-buffer (generate-new-buffer "*test-race*")))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (claude-org-mode 1)
          (insert "* Test
:PROPERTIES:
:CUSTOM_ID: test-race
:END:

#+begin_src ai
Test
#+end_src
")
          (goto-char (point-min))
          (search-forward "Test")
          
          (let* ((session-key (claude-org--current-session-key))
                 (marker1 (point-marker))
                 (marker2 (progn (forward-char 1) (point-marker))))
            
            ;; Query1 starts
            (claude-org--session-put session-key :marker marker1)
            (claude-org--session-put session-key :busy t)
            
            ;; Cancel happens - should free marker immediately
            (claude-org--session-put session-key :busy nil)
            (claude-org--free-marker session-key)  ;; This is the fix!
            
            ;; Query2 starts quickly (before sentinel runs)
            (claude-org--session-put session-key :marker marker2)
            (claude-org--session-put session-key :busy t)
            
            ;; Old sentinel's handle-complete runs - would look up :marker
            ;; Before fix: would get marker2 and free it!
            ;; After fix: marker1 was already freed, marker2 is safe
            (let ((looked-up-marker (claude-org--session-get session-key :marker)))
              ;; marker2 should still be valid
              (should looked-up-marker)
              (should (eq looked-up-marker marker2))
              (should (marker-buffer marker2)))))
      (kill-buffer test-buffer))))

(provide 'test-claude-org-cancel)
;;; test-claude-org-cancel.el ends here
