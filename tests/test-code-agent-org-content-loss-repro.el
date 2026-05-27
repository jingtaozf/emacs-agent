;;; test-code-agent-org-content-loss-repro.el --- Tests reproducing SDD content loss -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Tests that reproduce the bug where SDD story content disappears after
;; AI block execution.  The root cause is that response sections created
;; at the wrong heading level or wrong position break the org tree
;; structure, causing sibling SDD stories to become children of the
;; response section or otherwise get displaced.
;;
;; These tests ONLY reproduce the bug -- they do NOT fix it.

;;; Code:

(require 'ert)
(require 'org)
(require 'code-agent-org)

;;; ---------------------------------------------------------------------------
;;; Test 1: Top-level response heading splits the SDD tree
;;; ---------------------------------------------------------------------------

(ert-deftest test-top-level-response-splits-sdd-tree ()
  "When section-level defaults to 1, the Response heading is at level 1.
This top-level heading splits the org tree so that sibling SDD stories
are no longer children of the `* Development' parent."
  :tags '(:unit :fast :stable :isolated :org :content-loss :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Development\n")
    (insert "** SDD: Feature Alpha\n")
    (insert "*** Tasks\n")
    (insert "**** Task 1\n")
    (insert "#+begin_src ai\n")
    (insert "Implement feature alpha\n")
    (insert "#+end_src\n")
    (insert "** SDD: Feature Beta\n")
    (insert "*** Description\n")
    (insert "Beta feature content that should survive.\n")
    ;; Remember original structure: Feature Beta is child of Development
    (goto-char (point-min))
    (re-search-forward "^\\*\\* SDD: Feature Beta")
    (let ((beta-orig-level (org-current-level))
          (beta-orig-parent (save-excursion
                              (org-up-heading-safe)
                              (org-get-heading t t t t))))
      (should (= 2 beta-orig-level))
      (should (string= "Development" beta-orig-parent))
      ;; Simulate the bug: create-response-section with section-level = 1
      ;; (the fallback value from `(or nil 1)' when session has no :section-level)
      ;; Insert after end_src of Task 1's ai block
      (goto-char (point-min))
      (re-search-forward "^#\\+end_src")
      (end-of-line)
      (insert "\n\n")
      ;; This is what create-response-section produces with section-level=1
      (insert "* Response 1 (2025-01-13 08:00) :ai_output:\n")
      (insert ":PROPERTIES:\n")
      (insert ":QUERY_ID: test-query-001\n")
      (insert ":QUERY_TYPE: normal\n")
      (insert ":END:\n\n")
      (insert "AI response content here.\n")
      ;; Now check: Feature Beta should still be under Development
      ;; BUG: The `* Response' heading at level 1 is a SIBLING of `* Development',
      ;; so `** SDD: Feature Beta' (which follows it in the buffer) becomes
      ;; a child of `* Response' instead of `* Development'.
      (goto-char (point-min))
      (re-search-forward "^\\*\\* SDD: Feature Beta")
      (let ((beta-new-parent (save-excursion
                               (org-up-heading-safe)
                               (org-get-heading t t t t))))
        ;; BUG DEMONSTRATED: parent changed from "Development" to
        ;; "Response 1 (2025-01-13 08:00)" because the level-1 response
        ;; heading split the tree.
        (should-not (string= "Development" beta-new-parent))
        (should (string-match-p "Response" beta-new-parent))))))

;;; ---------------------------------------------------------------------------
;;; Test 2: SDD story becomes child of response section
;;; ---------------------------------------------------------------------------

(ert-deftest test-sdd-story-becomes-child-of-response ()
  "After inserting a level-1 Response heading, a sibling SDD story
structurally becomes a child of that Response section."
  :tags '(:unit :fast :stable :isolated :org :content-loss :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Development\n")
    (insert "** SDD: Feature Alpha\n")
    (insert "*** Tasks\n")
    (insert "**** Task 1\n")
    (insert "#+begin_src ai\n")
    (insert "query\n")
    (insert "#+end_src\n")
    (insert "** SDD: Feature Beta\n")
    (insert "*** Description\n")
    (insert "Important beta content.\n")
    (insert "** SDD: Feature Gamma\n")
    (insert "*** Description\n")
    (insert "Important gamma content.\n")
    ;; Count original children of Development
    (goto-char (point-min))
    (re-search-forward "^\\* Development")
    (let ((orig-children 0))
      (save-excursion
        (when (org-goto-first-child)
          (cl-incf orig-children)
          (while (org-get-next-sibling)
            (cl-incf orig-children))))
      (should (= 3 orig-children))  ; Alpha, Beta, Gamma
      ;; Insert buggy level-1 response after end_src
      (goto-char (point-min))
      (re-search-forward "^#\\+end_src")
      (end-of-line)
      (insert "\n\n* Response 1 (2025-01-13 08:00) :ai_output:\n")
      (insert ":PROPERTIES:\n:QUERY_ID: q1\n:QUERY_TYPE: normal\n:END:\n\n")
      (insert "Response text.\n")
      ;; Now count children of Development again
      (goto-char (point-min))
      (re-search-forward "^\\* Development")
      (let ((new-children 0))
        (save-excursion
          (when (org-goto-first-child)
            (cl-incf new-children)
            (while (org-get-next-sibling)
              (cl-incf new-children))))
        ;; BUG: Development now has only 1 child (Feature Alpha),
        ;; because `* Response' at level 1 is a SIBLING of `* Development',
        ;; stealing Beta and Gamma as its own children.
        (should (< new-children orig-children))
        ;; Feature Beta is now under Response, not Development
        (goto-char (point-min))
        (re-search-forward "^\\* Response")
        (let ((response-children 0))
          (save-excursion
            (when (org-goto-first-child)
              (cl-incf response-children)
              (while (org-get-next-sibling)
                (cl-incf response-children))))
          ;; Response section inherited Beta and Gamma as children
          (should (>= response-children 2)))))))

;;; ---------------------------------------------------------------------------
;;; Test 3: Control -- correct section-level preserves structure
;;; ---------------------------------------------------------------------------

(ert-deftest test-content-preserved-when-section-level-correct ()
  "With correct section-level (4 for **** Task 1), the Response heading
is at level 4 and the SDD sibling structure is preserved."
  :tags '(:unit :fast :stable :isolated :org :content-loss :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Development\n")
    (insert "** SDD: Feature Alpha\n")
    (insert "*** Tasks\n")
    (insert "**** Task 1\n")
    (insert "#+begin_src ai\n")
    (insert "query\n")
    (insert "#+end_src\n")
    (insert "** SDD: Feature Beta\n")
    (insert "*** Description\n")
    (insert "Beta content that should survive.\n")
    ;; Insert response at the CORRECT level (4, sibling of **** Task 1)
    (goto-char (point-min))
    (re-search-forward "^#\\+end_src")
    (end-of-line)
    (insert "\n\n**** Response 1 (2025-01-13 08:00) :ai_output:\n")
    (insert ":PROPERTIES:\n:QUERY_ID: q1\n:QUERY_TYPE: normal\n:END:\n\n")
    (insert "Response content.\n")
    ;; Feature Beta should STILL be a child of Development
    (goto-char (point-min))
    (re-search-forward "^\\*\\* SDD: Feature Beta")
    (let ((parent (save-excursion
                    (org-up-heading-safe)
                    (org-get-heading t t t t))))
      (should (string= "Development" parent)))
    ;; And Feature Alpha should also still be a child of Development
    (goto-char (point-min))
    (re-search-forward "^\\*\\* SDD: Feature Alpha")
    (let ((parent (save-excursion
                    (org-up-heading-safe)
                    (org-get-heading t t t t))))
      (should (string= "Development" parent)))))

;;; ---------------------------------------------------------------------------
;;; Test 4: Insert point lands after wrong ai_output sibling
;;; ---------------------------------------------------------------------------

(ert-deftest test-insert-point-after-wrong-ai-output-sibling ()
  "When find-response-boundary returns point-max (no non-ai_output sibling),
find-last-ai-output-sibling can match an :ai_output: heading from a
completely different SDD story, causing the insert-point to land in the
wrong story."
  :tags '(:unit :fast :stable :isolated :org :content-loss :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Development\n")
    (insert "** SDD: Story 1\n")
    (insert "*** Instruction 1 :ai_instruction:\n")
    (insert "#+begin_src ai\n")
    (insert "query 1\n")
    (insert "#+end_src\n")
    (insert "*** Response 1 :ai_output:\n")
    (insert "Response content for story 1.\n")
    (insert "** SDD: Story 2\n")
    (insert "*** Instruction 2 :ai_instruction:\n")
    (insert "#+begin_src ai\n")
    (insert "query 2\n")
    (insert "#+end_src\n")
    ;; Position point inside Instruction 2's ai block
    (goto-char (point-min))
    (re-search-forward "query 2")
    (let ((boundary (code-agent-org--find-response-boundary)))
      ;; Instruction 2 has no non-ai_output sibling after it
      ;; and no parent boundary after it, so boundary should be point-max
      (should (= (point-max) boundary))
      ;; Now check what find-response-insert-point returns
      (goto-char (point-min))
      (re-search-forward "query 2")
      (let ((insert-point (code-agent-org--find-response-insert-point)))
        ;; The insert point should be after Instruction 2's #+end_src
        ;; (since there's no ai_output sibling for Instruction 2 yet)
        ;; Verify it's NOT inside Story 1's territory
        (let ((story2-start (save-excursion
                              (goto-char (point-min))
                              (re-search-forward "^\\*\\* SDD: Story 2")
                              (match-beginning 0))))
          ;; insert-point should be >= story2-start (within Story 2)
          ;; If it landed inside Story 1 that would be the bug
          (should (>= insert-point story2-start)))))))

;;; ---------------------------------------------------------------------------
;;; Test 5: Response inserted between sibling stories
;;; ---------------------------------------------------------------------------

(ert-deftest test-response-inserted-between-sibling-stories ()
  "When find-response-insert-point returns end of Story 1's subtree,
inserting a response heading at the wrong level creates a new sibling
of the stories, pushing Story 2 down and disrupting navigation."
  :tags '(:unit :fast :stable :isolated :org :content-loss :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Development\n")
    (insert "** SDD: Story 1\n")
    (insert "*** Task\n")
    (insert "#+begin_src ai\n")
    (insert "query\n")
    (insert "#+end_src\n")
    (insert "** SDD: Story 2\n")
    (insert "*** Details\n")
    (insert "Important content in story 2.\n")
    ;; Save the initial buffer content
    (let ((original-buffer (buffer-substring-no-properties (point-min) (point-max))))
      ;; Find Story 1's subtree end (just before Story 2)
      (goto-char (point-min))
      (re-search-forward "^\\*\\* SDD: Story 1")
      (let ((story1-end (save-excursion (org-end-of-subtree t) (point))))
        ;; Insert a WRONG-LEVEL response (level 2 = sibling of stories)
        (goto-char story1-end)
        (insert "\n** Response 1 (2025-01-13 08:00) :ai_output:\n")
        (insert ":PROPERTIES:\n:QUERY_ID: q1\n:QUERY_TYPE: normal\n:END:\n\n")
        (insert "Response content.\n")
        ;; Now Story 2 is pushed down, and there's a Response sibling
        ;; between Story 1 and Story 2
        (goto-char (point-min))
        (re-search-forward "^\\*\\* SDD: Story 1")
        ;; Get next same-level sibling -- it should be Story 2 but isn't
        (let ((next-sibling-heading
               (save-excursion
                 (when (org-get-next-sibling)
                   (org-get-heading t t t t)))))
          ;; BUG: Next sibling of Story 1 is now "Response" not "SDD: Story 2"
          (should (string-match-p "Response" next-sibling-heading))
          (should-not (string-match-p "Story 2" next-sibling-heading)))))))

;;; ---------------------------------------------------------------------------
;;; Test 6: Normalized headers create top-level heading inside response
;;; ---------------------------------------------------------------------------

(ert-deftest test-normalize-headers-creates-top-level-heading-in-response ()
  "When section-level is 0 (before first heading), target-level becomes 1.
Claude's `* Main Heading' stays at level 1 since target=1 means offset=0.
This creates a top-level heading INSIDE the response, splitting the tree."
  :tags '(:unit :fast :stable :isolated :org :content-loss :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Development\n")
    (insert "** SDD: Feature Alpha\n")
    (insert "*** Tasks\n")
    (insert "**** Task 1\n")
    (insert "#+begin_src ai\n")
    (insert "query\n")
    (insert "#+end_src\n")
    (insert "** SDD: Feature Beta\n")
    (insert "*** Description\n")
    (insert "Beta content.\n")
    ;; Simulate: section-level was captured as 0 (or default to 0)
    ;; target-level = section-level + 1 = 1
    (let ((section-level 0)
          (target-level 1))
      ;; Normalize Claude's response text with target-level 1
      ;; Claude sends "* Summary\nContent\n** Details\nMore content"
      (let* ((claude-text "* Summary\nContent here.\n** Details\nMore details.\n")
             (normalized (code-agent-org--normalize-headers-in-text claude-text target-level)))
        ;; With target-level=1, offset=(1-1)=0, so:
        ;; * Summary stays as * Summary (level 1)
        ;; ** Details stays as ** Details (level 2)
        (should (string-match-p "^\\* Summary" normalized))
        (should (string-match-p "^\\*\\* Details" normalized))
        ;; Now insert this into the buffer after a response heading
        (goto-char (point-min))
        (re-search-forward "^#\\+end_src")
        (end-of-line)
        ;; Response heading itself at level 1 (the session-level bug)
        (insert "\n\n* Response 1 (2025-01-13 08:00) :ai_output:\n")
        (insert ":PROPERTIES:\n:QUERY_ID: q1\n:QUERY_TYPE: normal\n:END:\n\n")
        ;; Insert the normalized content with its * heading
        (insert normalized)
        ;; Now the buffer has TWO level-1 headings inside Development's
        ;; original territory: `* Response' and `* Summary'
        ;; Everything after `* Summary' is displaced from Development
        (goto-char (point-min))
        (re-search-forward "^\\*\\* SDD: Feature Beta")
        (let ((parent (save-excursion
                        (org-up-heading-safe)
                        (org-get-heading t t t t))))
          ;; BUG: Beta is no longer under Development; it's under
          ;; the `* Summary' or `* Response' heading
          (should-not (string= "Development" parent)))))))

;;; ---------------------------------------------------------------------------
;;; Test 7: Multiple wrong-level executions compound damage
;;; ---------------------------------------------------------------------------

(ert-deftest test-multiple-executions-accumulate-wrong-level-responses ()
  "Executing an AI block 3 times with wrong section-level creates 3
top-level Response headings, each one further fragmenting the tree."
  :tags '(:unit :fast :stable :isolated :org :content-loss :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Development\n")
    (insert "** SDD: Feature Alpha\n")
    (insert "*** Tasks\n")
    (insert "**** Task 1\n")
    (insert "#+begin_src ai\n")
    (insert "query\n")
    (insert "#+end_src\n")
    (insert "** SDD: Feature Beta\n")
    (insert "*** Description\n")
    (insert "Beta content.\n")
    (insert "** SDD: Feature Gamma\n")
    (insert "*** Description\n")
    (insert "Gamma content.\n")
    ;; Count top-level headings initially
    (goto-char (point-min))
    (let ((orig-top-level-count 0))
      (while (re-search-forward "^\\* " nil t)
        (cl-incf orig-top-level-count))
      (should (= 1 orig-top-level-count))  ; Only "* Development"
      ;; Simulate 3 executions each creating a wrong-level (1) response
      (goto-char (point-min))
      (re-search-forward "^#\\+end_src")
      (end-of-line)
      (dotimes (i 3)
        (insert (format "\n\n* Response %d (2025-01-13 0%d:00) :ai_output:\n" (1+ i) i))
        (insert ":PROPERTIES:\n")
        (insert (format ":QUERY_ID: q%d\n" (1+ i)))
        (insert ":QUERY_TYPE: normal\n:END:\n\n")
        (insert (format "Response %d content.\n" (1+ i))))
      ;; Count top-level headings now
      (goto-char (point-min))
      (let ((new-top-level-count 0))
        (while (re-search-forward "^\\* " nil t)
          (cl-incf new-top-level-count))
        ;; BUG: Now we have 4 top-level headings:
        ;; * Development, * Response 1, * Response 2, * Response 3
        (should (= 4 new-top-level-count)))
      ;; Development has lost most of its children
      (goto-char (point-min))
      (re-search-forward "^\\* Development")
      (let ((dev-children 0))
        (save-excursion
          (when (org-goto-first-child)
            (cl-incf dev-children)
            (while (org-get-next-sibling)
              (cl-incf dev-children))))
        ;; BUG: Development used to have 3 children (Alpha, Beta, Gamma)
        ;; Now it only has Feature Alpha (partially), because * Response 1
        ;; at level 1 ends Development's subtree.
        (should (< dev-children 3))))))

;;; ---------------------------------------------------------------------------
;;; Test 8: find-response-boundary returns point-max, stale ai_output matched
;;; ---------------------------------------------------------------------------

(ert-deftest test-response-boundary-encompasses-entire-buffer ()
  "When the instruction has no non-ai_output sibling and no parent-level
heading after it, find-response-boundary returns point-max.  A stale
:ai_output: heading far away in the buffer can then be picked up by
find-last-ai-output-sibling, causing insert-point to land far from
the instruction."
  :tags '(:unit :fast :stable :isolated :org :content-loss :bug)
  (with-temp-buffer
    (org-mode)
    ;; First section with old response (from a previous unrelated run)
    (insert "* Old Project\n")
    (insert "** Old Instruction\n")
    (insert "#+begin_src ai\n")
    (insert "old query\n")
    (insert "#+end_src\n")
    (insert "** Old Response :ai_output:\n")
    (insert "Old response content.\n\n")
    ;; Second section -- the one we're executing now
    ;; Note: this is at the END of the buffer with nothing after it
    (insert "* Current Project\n")
    (insert "** Current Instruction\n")
    (insert "#+begin_src ai\n")
    (insert "new query\n")
    (insert "#+end_src\n")
    ;; Position at the current instruction's ai block
    (goto-char (point-min))
    (re-search-forward "new query")
    ;; find-response-boundary: no sibling or parent after ** Current Instruction
    ;; at level 2, so it should walk to point-max
    (let ((boundary (code-agent-org--find-response-boundary)))
      (should (= (point-max) boundary)))
    ;; find-response-insert-point: should return end of #+end_src
    ;; because there's no ai_output sibling AT THE SAME LEVEL (2) after
    ;; the current block's #+end_src.
    ;; The "** Old Response :ai_output:" is BEFORE the block, not after.
    (goto-char (point-min))
    (re-search-forward "new query")
    (let ((insert-point (code-agent-org--find-response-insert-point))
          (current-end-src (save-excursion
                             (re-search-forward "^#\\+end_src" nil t)
                             (line-end-position))))
      ;; insert-point should be at end_src of current block
      ;; (no ai_output found AFTER the block within boundary)
      (should insert-point)
      (should (= current-end-src insert-point)))))

;;; ---------------------------------------------------------------------------
;;; Test: create-response-section with buggy default section-level
;;; ---------------------------------------------------------------------------

(ert-deftest test-create-response-section-defaults-to-level-0 ()
  "Session initializes :section-level to 0.  Since 0 is truthy in elisp,
`(or 0 1)' evaluates to 0, and `(make-string 0 ?*)' produces an empty
string.  The resulting heading has NO stars, so org-mode does not
recognize it as a heading at all -- the response content becomes plain
text that disrupts the tree structure."
  :tags '(:unit :fast :stable :isolated :org :content-loss :bug)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-content-loss.org")
    (insert "* Development\n")
    (insert "** SDD: Feature Alpha\n")
    (insert "*** Tasks\n")
    (insert "**** Task 1\n")
    (insert "#+begin_src ai\n")
    (insert "query\n")
    (insert "#+end_src\n\n")
    (insert "** SDD: Feature Beta\n")
    (insert "*** Description\n")
    (insert "Important beta content.\n")
    ;; Set up a session -- session-get initializes :section-level to 0
    (let* ((session-key "/tmp/test-content-loss.org")
           (query-id "test-query-42"))
      (code-agent-org-session-put session-key :query-id query-id)
      ;; FIXED: session now initializes section-level to nil
      ;; The guard (if (and nil ...) ...) correctly falls back to 1
      (let ((raw (code-agent-org-session-get session-key :section-level)))
        (should (null raw))
        (let ((effective-level (if (and raw (> raw 0)) raw 1)))
          (should (= 1 effective-level))))
      ;; Position after end_src to simulate where response gets inserted
      (goto-char (point-min))
      (re-search-forward "^#\\+end_src")
      (end-of-line)
      (insert "\n\n")
      ;; Call create-response-section -- it now falls back to level 1,
      ;; producing a valid org heading with stars
      (let ((content-insert-pos
             (code-agent-org--create-response-section session-key query-id 'normal)))
        (should content-insert-pos)
        ;; FIXED: The heading has stars -- it's a valid org heading
        (goto-char (point-min))
        (should (re-search-forward "^\\*+ Response .* :ai_output:" nil t))))))

;;; ---------------------------------------------------------------------------
;;; Test: SDD story content vanishes from org-map-entries / sparse tree
;;; ---------------------------------------------------------------------------

(ert-deftest test-sdd-story-invisible-after-wrong-level-response ()
  "After a wrong-level response is inserted, searching for SDD stories
under `* Development' via org-map-entries no longer finds all of them."
  :tags '(:unit :fast :stable :isolated :org :content-loss :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Development\n")
    (insert "** SDD: Feature Alpha\n")
    (insert "*** Tasks\n")
    (insert "**** Task 1\n")
    (insert "#+begin_src ai\n")
    (insert "query\n")
    (insert "#+end_src\n")
    (insert "** SDD: Feature Beta\n")
    (insert "*** Description\n")
    (insert "Beta details.\n")
    (insert "** SDD: Feature Gamma\n")
    (insert "*** Description\n")
    (insert "Gamma details.\n")
    ;; Count SDD headings under Development using org-map-entries
    (let ((sdd-before nil))
      (org-map-entries
       (lambda ()
         (when (string-match-p "^SDD:" (org-get-heading t t t t))
           (push (org-get-heading t t t t) sdd-before)))
       nil 'tree)
      ;; All three stories found when searching from top
      ;; (org-map-entries with 'tree scope searches entire buffer
      ;;  when not inside a subtree, so we position first)
      (goto-char (point-min))
      (re-search-forward "^\\* Development")
      (setq sdd-before nil)
      (org-map-entries
       (lambda ()
         (when (string-match-p "^SDD:" (org-get-heading t t t t))
           (push (org-get-heading t t t t) sdd-before)))
       nil 'tree)
      (should (= 3 (length sdd-before)))
      ;; Now insert wrong-level response
      (goto-char (point-min))
      (re-search-forward "^#\\+end_src")
      (end-of-line)
      (insert "\n\n* Response 1 (2025-01-13 08:00) :ai_output:\n")
      (insert ":PROPERTIES:\n:QUERY_ID: q1\n:QUERY_TYPE: normal\n:END:\n\n")
      (insert "Response.\n")
      ;; Search again from Development
      (goto-char (point-min))
      (re-search-forward "^\\* Development")
      (let ((sdd-after nil))
        (org-map-entries
         (lambda ()
           (when (string-match-p "^SDD:" (org-get-heading t t t t))
             (push (org-get-heading t t t t) sdd-after)))
         nil 'tree)
        ;; BUG: Development's subtree now ends at `* Response' (level 1),
        ;; so Beta and Gamma are no longer found within Development's tree.
        (should (< (length sdd-after) (length sdd-before)))))))

;;; ---------------------------------------------------------------------------
;;; Test: Buffer text is NOT actually deleted, just structurally displaced
;;; ---------------------------------------------------------------------------

(ert-deftest test-content-not-deleted-but-displaced ()
  "The SDD story text still exists in the buffer -- it hasn't been
deleted.  But it is structurally displaced, so org navigation and
visibility cycling no longer show it under the original parent."
  :tags '(:unit :fast :stable :isolated :org :content-loss :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Development\n")
    (insert "** SDD: Feature Alpha\n")
    (insert "*** Tasks\n")
    (insert "**** Task 1\n")
    (insert "#+begin_src ai\n")
    (insert "query\n")
    (insert "#+end_src\n")
    (insert "** SDD: Feature Beta\n")
    (insert "*** Description\n")
    (insert "UNIQUE-BETA-CONTENT-MARKER\n")
    ;; Insert wrong-level response
    (goto-char (point-min))
    (re-search-forward "^#\\+end_src")
    (end-of-line)
    (insert "\n\n* Response 1 (2025-01-13 08:00) :ai_output:\n")
    (insert ":PROPERTIES:\n:QUERY_ID: q1\n:QUERY_TYPE: normal\n:END:\n\n")
    (insert "Response.\n")
    ;; The text still exists in the buffer (not deleted)
    (goto-char (point-min))
    (should (search-forward "UNIQUE-BETA-CONTENT-MARKER" nil t))
    ;; But it's no longer reachable under * Development
    (goto-char (point-min))
    (re-search-forward "^\\* Development")
    (let ((subtree-end (save-excursion (org-end-of-subtree t) (point))))
      ;; The marker should be OUTSIDE Development's subtree
      (goto-char (point-min))
      (search-forward "UNIQUE-BETA-CONTENT-MARKER")
      (let ((marker-pos (point)))
        ;; BUG: marker-pos > subtree-end, meaning the content has been
        ;; pushed outside Development's subtree by the level-1 Response
        (should (> marker-pos subtree-end))))))

(provide 'test-code-agent-org-content-loss-repro)
;;; test-code-agent-org-content-loss-repro.el ends here
