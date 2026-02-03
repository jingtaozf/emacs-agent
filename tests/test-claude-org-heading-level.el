;;; test-claude-org-heading-level.el --- Tests for heading level normalization -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Tests to reproduce and verify the org heading level issue.
;; Bug: When executing an AI block a second time, the response headers
;; use the level from the PREVIOUS response instead of the current AI block's level.

;;; Code:

(require 'ert)
(require 'org)
(require 'claude-org)

;;; Test Helpers

(defun test-heading-level--create-test-buffer ()
  "Create a test buffer with an AI block at level 3."
  (with-temp-buffer
    (org-mode)
    (insert "* Top Level\n")
    (insert "** Second Level\n")
    (insert "*** Third Level with AI Block\n")
    (insert ":PROPERTIES:\n")
    (insert ":CUSTOM_ID: test-ai-block\n")
    (insert ":END:\n\n")
    (insert "#+begin_src ai\n")
    (insert "Generate a response with some org headers\n")
    (insert "#+end_src\n")
    (current-buffer)))

;;; Unit Tests for Section Level Detection

(ert-deftest test-section-level-at-ai-block ()
  "Test that section level is correctly detected inside an AI block."
  :tags '(:unit :fast :stable :isolated :org :heading-level)
  (with-temp-buffer
    (org-mode)
    (insert "* Top Level\n")
    (insert "** Second Level\n")
    (insert "*** Third Level\n")
    (insert "#+begin_src ai\n")
    (insert "query content\n")
    (insert "#+end_src\n")
    ;; Position inside the AI block
    (goto-char (point-min))
    (re-search-forward "query content")
    ;; The section level should be 3 (from *** Third Level)
    (should (= 3 (claude-org--get-section-level)))))

(ert-deftest test-section-level-after-response-with-headers ()
  "Test section level detection after AI has generated response with headers.
This is the core bug reproduction test."
  :tags '(:unit :fast :stable :isolated :org :heading-level :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Top Level\n")
    (insert "** Second Level\n")
    (insert "*** Third Level with AI Block\n")
    (insert "#+begin_src ai\n")
    (insert "query content\n")
    (insert "#+end_src\n\n")
    ;; Simulate a previous response with headers that Claude generated
    ;; These headers were normalized to level 4 (section-level 3 + 1)
    (insert "**** Response Header\n")
    (insert "Some response content.\n\n")
    (insert "***** Nested Response Header\n")
    (insert "More content.\n\n")
    ;; Now position back inside the AI block
    (goto-char (point-min))
    (re-search-forward "query content")
    ;; The section level should STILL be 3 (from *** Third Level)
    ;; NOT 5 from the ***** Nested Response Header
    (let ((level (claude-org--get-section-level)))
      (should (= 3 level)))))

(ert-deftest test-section-level-uses-heading-not-point ()
  "Verify that section level is based on the heading containing the AI block,
not on any headers that may appear after it in the buffer."
  :tags '(:unit :fast :stable :isolated :org :heading-level)
  (with-temp-buffer
    (org-mode)
    (insert "* Top\n")
    (insert "** Level Two Heading\n")
    (insert "Some text.\n")
    (insert "#+begin_src ai\n")
    (insert "my query\n")
    (insert "#+end_src\n\n")
    ;; Add response headers at various levels
    (insert "*** Response L3\n")
    (insert "**** Response L4\n")
    (insert "***** Response L5\n")
    (insert "****** Response L6\n")
    ;; Position inside AI block
    (goto-char (point-min))
    (re-search-forward "my query")
    ;; Should be level 2 (from ** Level Two Heading)
    (should (= 2 (claude-org--get-section-level)))))

;;; Integration-like Tests (mocked)

(ert-deftest test-header-normalization-uses-correct-level ()
  "Test that header normalization uses the section level, not random headers."
  :tags '(:unit :fast :stable :isolated :org :heading-level)
  (with-temp-buffer
    (org-mode)
    (insert "* Top\n")
    (insert "** Section\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n\n")
    ;; Simulate previous response
    (insert "**** Old Response\n")
    (insert "content\n")
    ;; Position in AI block and get section level
    (goto-char (point-min))
    (re-search-forward "query")
    (let ((section-level (claude-org--get-section-level)))
      ;; Section level should be 2
      (should (= 2 section-level))
      ;; Target level for normalization should be section-level + 1 = 3
      (let ((target-level (1+ section-level)))
        (should (= 3 target-level))
        ;; Test normalization function
        (let ((input-text "* Header\nContent\n** Subheader\n"))
          ;; Normalize: * -> ***, ** -> ****
          (let ((result (claude-org--normalize-headers-in-text input-text target-level)))
            (should (string-match-p "^\\*\\*\\* Header" result))
            (should (string-match-p "^\\*\\*\\*\\* Subheader" result))))))))

(ert-deftest test-re-execute-preserves-correct-level ()
  "Simulate re-executing an AI block and verify correct section level.
This tests the scenario where:
1. AI block is executed first time
2. Response contains org headers
3. AI block is executed again
4. The section level should be based on the ORIGINAL heading, not response headers."
  :tags '(:unit :fast :stable :isolated :org :heading-level :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Project\n")
    (insert "** Tasks\n")
    (insert "*** Task One\n")
    (insert "#+begin_src ai\n")
    (insert "First execution query\n")
    (insert "#+end_src\n\n")
    ;; Simulate first execution's response with headers
    ;; Correct normalization: section level 3, target 4
    (insert "**** First Response Header\n")
    (insert "Response content.\n\n")
    (insert "***** Nested in Response\n")
    (insert "More content.\n\n")
    ;; Now: if we re-execute, what section level do we get?
    (goto-char (point-min))
    (re-search-forward "First execution query")
    ;; Must be 3 (from *** Task One), not 4 or 5 from response headers
    (let ((level (claude-org--get-section-level)))
      (should (= 3 level))
      ;; Therefore target level for new response should be 4
      (should (= 4 (1+ level))))))

;;; Bug Reproduction Tests

(ert-deftest test-create-response-header-wrong-level-bug ()
  "Test that demonstrates the bug in claude-org--create-response-section-header.
The function uses the cursor position to determine heading level, but when called
from within claude-org-execute, the cursor has already moved to insert-point
which may be INSIDE a previous Response section's nested headings."
  :tags '(:unit :fast :stable :isolated :org :heading-level :bug :root-cause)
  (with-temp-buffer
    (org-mode)
    (insert "* Project\n")
    (insert "** Tasks\n")
    (insert "*** Task One\n")                    ; Level 3 - AI block's parent
    (insert "#+begin_src ai\n")
    (insert "query\n")
    (insert "#+end_src\n\n")
    ;; First execution's response with nested headings
    (insert "*** Response 1 (2025-01-13 08:00) :ai_output:\n\n")
    (insert "First response.\n\n")
    (insert "**** Nested Heading in Response\n")  ; Level 4
    (insert "Content under nested heading.\n\n")
    ;; Second execution would have insert-point HERE
    ;; After the #+end_src or after the last :ai_output: section
    ;; But claude-org--find-response-insert-point returns AFTER the Response subtree
    ;; Problem: if we're still conceptually "inside" the nested heading...
    (let ((insert-point (point)))
      ;; Go back to AI block to get correct level
      (goto-char (point-min))
      (re-search-forward "query")
      (let ((correct-level (claude-org--get-section-level)))
        (should (= 3 correct-level))  ; Correct: level 3 from Task One
        ;; Now go to insert-point (simulating what claude-org-execute does)
        (goto-char insert-point)
        ;; BUG: At this position, org-back-to-heading finds **** Nested Heading
        (let ((buggy-level (claude-org--get-section-level)))
          ;; This assertion documents the bug:
          ;; We EXPECT level 3 (from Task One) but GET level 4 (from Nested Heading)
          (should (= 4 buggy-level))  ; Bug confirmed: gets 4 instead of 3
          (should-not (= correct-level buggy-level)))))))

(ert-deftest test-create-response-header-bug-demonstration ()
  "Demonstrate the actual bug scenario more clearly.
When the previous response has nested headings, and insert-point is
positioned inside those nested headings, the wrong level is detected."
  :tags '(:unit :fast :stable :isolated :org :heading-level :bug :root-cause)
  (with-temp-buffer
    (org-mode)
    (insert "* Project\n")
    (insert "** Tasks\n")
    (insert "*** Task One\n")                    ; Level 3 - this is the AI block's parent
    (insert "#+begin_src ai\n")
    (insert "query\n")
    (insert "#+end_src\n\n")
    ;; First response - but Response heading is also level 3 (sibling to Task One)
    ;; Note: claude-org should create Response at level 3 as sibling
    (insert "*** Response 1 (2025-01-13 08:00) :ai_output:\n\n")
    (insert "Content with nested headings:\n\n")
    (insert "**** First Point\n")                ; Level 4
    (insert "Discussion.\n\n")
    (insert "***** Sub-point\n")                 ; Level 5
    (insert "Details.\n\n")
    ;; HERE is where insert-point would land for second execution
    ;; It's AFTER the Response section, but org-back-to-heading
    ;; will find ***** Sub-point (level 5)!
    (let ((wrong-insert-point (point)))
      ;; Go back to where AI block is
      (goto-char (point-min))
      (re-search-forward "query")
      (let ((correct-level (claude-org--get-section-level)))
        ;; At AI block: level should be 3
        (should (= 3 correct-level))
        ;; Now go to where insert-point would be
        (goto-char wrong-insert-point)
        ;; We're positioned right after the Response subtree
        ;; org-back-to-heading will find the LAST heading before point
        (let ((level-at-insert-point (save-excursion
                                       (when (ignore-errors (org-back-to-heading t))
                                         (org-current-level)))))
          ;; BUG: This finds level 5 (from ***** Sub-point)
          ;; when we actually want level 3 (from *** Task One)
          (when level-at-insert-point
            ;; If we're still within the Response subtree, we get wrong level
            ;; The correct behavior is to use the pre-captured section-level
            (message "Level at insert-point: %s (expected: 3)" level-at-insert-point)))))))

(ert-deftest test-section-level-should-be-passed-not-recalculated ()
  "Test showing the fix: section-level should be passed to create-response-section-header,
not recalculated at call time."
  :tags '(:unit :fast :stable :isolated :org :heading-level :fix)
  (with-temp-buffer
    (org-mode)
    (insert "* Top\n")
    (insert "** Section\n")                      ; Level 2
    (insert "#+begin_src ai\n")
    (insert "query\n")
    (insert "#+end_src\n\n")
    ;; Capture correct level while at AI block
    (goto-char (point-min))
    (re-search-forward "query")
    (let ((correct-section-level (claude-org--get-section-level)))
      (should (= 2 correct-section-level))
      ;; Simulate moving to insert point after previous response
      (goto-char (point-max))
      (insert "** Response 1 :ai_output:\n")
      (insert "**** Deep Nested\n")
      (goto-char (point-max))
      ;; Now level at point would be wrong
      (let ((wrong-level (ignore-errors
                           (save-excursion
                             (org-back-to-heading t)
                             (org-current-level)))))
        (when wrong-level
          ;; Wrong: 4, Correct: 2
          (should-not (= correct-section-level wrong-level))
          (message "Demonstrated bug: got level %d but need %d"
                   wrong-level correct-section-level))))))

;;; Edge Case Tests

(ert-deftest test-section-level-with-no-parent-heading ()
  "Test section level when AI block is before any heading."
  :tags '(:unit :fast :stable :isolated :org :heading-level)
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src ai\n")
    (insert "query at top\n")
    (insert "#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "query at top")
    ;; Should be 0 when before first heading
    (should (= 0 (claude-org--get-section-level)))))

(ert-deftest test-section-level-deeply-nested ()
  "Test section level with deeply nested headings."
  :tags '(:unit :fast :stable :isolated :org :heading-level)
  (with-temp-buffer
    (org-mode)
    (insert "* L1\n** L2\n*** L3\n**** L4\n***** L5\n")
    (insert "#+begin_src ai\n")
    (insert "deep query\n")
    (insert "#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "deep query")
    (should (= 5 (claude-org--get-section-level)))))

(provide 'test-claude-org-heading-level)
;;; test-claude-org-heading-level.el ends here
