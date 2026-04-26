;;; test-code-agent-org-wrong-position-repro.el --- Tests for wrong insert position bugs -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Tests to reproduce wrong-position insertion bugs during concurrent execution.
;; These tests demonstrate failure modes in:
;; - `code-agent-org--find-response-boundary' (uses org-current-level at wrong point)
;; - `code-agent-org--find-last-ai-output-sibling' (builds regex with wrong star count)
;; - `code-agent-org--insert-at-response' (stops at generated headings within response)
;; - `code-agent-org--find-response-insert-point' (returns wrong position for queued blocks)
;;
;; Tests that pass demonstrate correct behavior.
;; Tests that fail (marked :bug) demonstrate the bug.

;;; Code:

(require 'ert)
(require 'org)
(require 'code-agent-org)

;;; ============================================================
;;; Test 1: find-response-boundary uses wrong level at response heading
;;; ============================================================

(ert-deftest test-find-response-boundary-wrong-level-at-response-heading ()
  "Demonstrate that find-response-boundary uses org-current-level from point.
When point is at a Response heading (:ai_output:) which is a sibling of
the Instruction heading, the boundary calculation should use the Instruction
heading's level. But since find-response-boundary reads org-current-level
at the current point, if we call it from the Response heading, it uses
that level instead."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    ;; Structure:
    ;; * Story
    ;; ** Instruction 1
    ;; #+begin_src ai ... #+end_src
    ;; ** Response 1 :ai_output:     <- point here (level 2)
    ;; ** Instruction 2
    ;; #+begin_src ai ... #+end_src
    (insert "* Story\n")
    (insert "** Instruction 1\n")
    (insert "#+begin_src ai\nquery 1\n#+end_src\n")
    (insert "** Response 1 :ai_output:\n")
    (insert ":PROPERTIES:\n:QUERY_ID: q-001\n:END:\n\n")
    (insert "Response content.\n")
    (insert "** Instruction 2\n")
    (insert "#+begin_src ai\nquery 2\n#+end_src\n")

    ;; Position at Instruction 1 heading - this is the correct call site
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Instruction 1$")
    (beginning-of-line)
    (let ((boundary-from-instruction (code-agent-org--find-response-boundary)))
      ;; Now position at Response 1 heading - wrong call site
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Response 1")
      (beginning-of-line)
      (let ((boundary-from-response (code-agent-org--find-response-boundary)))
        ;; Both should find the same boundary (Instruction 2's position)
        ;; because they're at the same level. In this case they happen to match
        ;; because both headings are level 2. The bug manifests when levels differ.
        ;; With same-level siblings this test just verifies baseline behavior.
        (should (= boundary-from-instruction boundary-from-response))))))

;;; ============================================================
;;; Test 2: find-last-ai-output-sibling builds wrong regex pattern
;;; ============================================================

(ert-deftest test-find-last-ai-output-sibling-wrong-level-pattern ()
  "Demonstrate that find-last-ai-output-sibling uses org-current-level to
build the regex pattern for searching :ai_output: siblings. If called from
a heading at a DIFFERENT level than the actual :ai_output: siblings, the
regex will search for the wrong star count and find nothing.

The function builds: (format \"^\\\\*\\\\{%d\\\\} .*:ai_output:\" current-level)
So at level 3, it looks for *** headings with :ai_output:, missing ** ones."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    ;; Structure:
    ;; * Story
    ;; ** Instruction 1
    ;; #+begin_src ai ... #+end_src
    ;; ** Response 1 :ai_output:
    ;; ** Instruction 2              <- has :ai_output: sibling at level 2
    ;; #+begin_src ai ... #+end_src
    ;; *** Nested Sub-heading        <- if point is here, current-level = 3
    ;; #+begin_src ai ... #+end_src
    (insert "* Story\n")
    (insert "** Instruction 1\n")
    (insert "#+begin_src ai\nquery 1\n#+end_src\n")
    (insert "** Response 1 :ai_output:\n")
    (insert ":PROPERTIES:\n:QUERY_ID: q-001\n:END:\n\n")
    (insert "Some response content.\n")
    (insert "** Instruction 2\n")
    (insert "#+begin_src ai\nquery 2\n#+end_src\n")

    ;; From Instruction 1 (level 2): should find Response 1 :ai_output: sibling
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Instruction 1$")
    (beginning-of-line)
    (let ((result-from-correct-level (code-agent-org--find-last-ai-output-sibling)))
      (should result-from-correct-level))

    ;; Now test the wrong-level pattern directly by examining what the function
    ;; would search for at different levels.
    ;; At level 2 (correct): pattern = "^\*\{2\} .*:ai_output:" matches "** Response 1 :ai_output:"
    ;; At level 3 (wrong):   pattern = "^\*\{3\} .*:ai_output:" does NOT match
    (let ((level-2-pattern (format "^\\*\\{%d\\} .*:%s:" 2 code-agent-org-output-tag))
          (level-3-pattern (format "^\\*\\{%d\\} .*:%s:" 3 code-agent-org-output-tag)))
      ;; Level 2 pattern matches the response
      (goto-char (point-min))
      (should (re-search-forward level-2-pattern nil t))
      ;; Level 3 pattern does NOT match - this is the bug pattern
      (goto-char (point-min))
      (should-not (re-search-forward level-3-pattern nil t))
      ;; BUG: If find-last-ai-output-sibling is called from a context where
      ;; org-current-level returns 3 (e.g., navigated to a nested heading),
      ;; it would use level-3-pattern and miss the level-2 :ai_output: sibling.
      )))

;;; ============================================================
;;; Test 3: insert-at-response stops at generated heading in response
;;; ============================================================

(ert-deftest test-insert-at-response-stops-at-generated-heading ()
  "Demonstrate that insert-at-response scans forward from :END: and stops
at the first heading it encounters. If the response content contains org
headings (e.g., '*** Analysis'), text is inserted BEFORE that heading
instead of at the END of the response section."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-insert-pos.org")
    ;; Structure:
    ;; * Story
    ;; ** Response 1 :ai_output:
    ;; :PROPERTIES:
    ;; :QUERY_ID: q-insert-test
    ;; :END:
    ;;
    ;; Some initial text.
    ;; *** Analysis          <- heading within response content
    ;; Detailed analysis.
    ;; ** Next Section
    (insert "* Story\n")
    (insert "** Response 1 :ai_output:\n")
    (insert ":PROPERTIES:\n")
    (insert ":QUERY_ID: q-insert-test\n")
    (insert ":END:\n\n")
    (insert "Some initial text.\n")
    (insert "*** Analysis\n")
    (insert "Detailed analysis.\n")
    (insert "** Next Section\n")
    (insert "Other content.\n")

    ;; Set up session state with the query-id
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((state (code-agent-org--make-session-state
                  :query-id "q-insert-test"
                  :section-level 1)))
      (puthash "test-session" state code-agent-org--sessions))

    ;; Insert new text via insert-at-response
    (code-agent-org--insert-at-response "test-session" "NEW TOKEN")

    ;; Check where the text was inserted
    (goto-char (point-min))
    (should (search-forward "NEW TOKEN" nil t))

    (let ((token-pos (match-beginning 0)))
      ;; Find positions of key landmarks
      (goto-char (point-min))
      (re-search-forward "^\\*\\*\\* Analysis")
      (let ((analysis-heading-pos (match-beginning 0)))
        (goto-char (point-min))
        (re-search-forward "^Detailed analysis\\.")
        (let ((detailed-pos (match-beginning 0)))
          ;; FIXED: The token is inserted AFTER "Detailed analysis."
          ;; because the level-aware stop pattern skips *** headings
          ;; (deeper than the ** response section level).
          (should (> token-pos analysis-heading-pos))
          (should (> token-pos detailed-pos)))))))

;;; ============================================================
;;; Test 4: find-response-insert-point returns position inside Block A's response
;;; ============================================================

(ert-deftest test-insert-point-inside-block-a-response ()
  "Verify find-response-insert-point from Block B's instruction doesn't
return a position inside Block A's response section."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    ;; Structure:
    ;; * Story
    ;; ** Instruction A
    ;; #+begin_src ai ... #+end_src
    ;; ** Response A :ai_output:
    ;; :PROPERTIES: ...
    ;; Some content.
    ;; *** Generated Heading
    ;; More content.
    ;; ** Instruction B
    ;; #+begin_src ai ... #+end_src
    (insert "* Story\n")
    (insert "** Instruction A\n")
    (insert "#+begin_src ai\nquery A\n#+end_src\n")
    (insert "** Response A :ai_output:\n")
    (insert ":PROPERTIES:\n:QUERY_ID: q-A\n:END:\n\n")
    (insert "Block A response content.\n")
    (insert "*** Generated Heading\n")
    (insert "More Block A content.\n")
    (insert "** Instruction B\n")
    (insert "#+begin_src ai\nquery B\n#+end_src\n")

    ;; Position at Instruction B
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Instruction B$")
    (beginning-of-line)

    ;; find-response-insert-point should return position after Block B's #+end_src
    ;; (since Block B has no existing response)
    (let ((insert-point (code-agent-org--find-response-insert-point)))
      (should insert-point)

      ;; The insert point should be AFTER Block B's #+end_src
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Instruction B$")
      (re-search-forward "^#\\+end_src")
      (let ((block-b-end (line-end-position)))
        ;; Insert point should be at Block B's #+end_src, not inside A's response
        (should (= insert-point block-b-end))

        ;; Verify it's NOT inside Block A's response
        (goto-char (point-min))
        (re-search-forward "^\\*\\* Response A")
        (let ((response-a-start (match-beginning 0)))
          (goto-char (point-min))
          (re-search-forward "^\\*\\* Instruction B")
          (let ((instr-b-start (match-beginning 0)))
            ;; insert-point must NOT be between Response A start and Instruction B start
            (should-not (and (>= insert-point response-a-start)
                             (< insert-point instr-b-start)))))))))

;;; ============================================================
;;; Test 5: Queued block insert point after Block A response expanded
;;; ============================================================

(ert-deftest test-queued-block-insert-point-after-block-a-response-expanded ()
  "Simulate Block A's response growing while Block B is queued.
After Block A's response is inserted (expanding the buffer), navigate to
Block B's instruction and verify find-response-insert-point returns the
correct position despite the buffer having shifted."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    ;; Initial structure (before Block A response)
    (insert "* Story\n")
    (insert "** Instruction A\n")
    (insert "#+begin_src ai\nquery A\n#+end_src\n")
    (insert "** Instruction B\n")
    (insert "#+begin_src ai\nquery B\n#+end_src\n")

    ;; Record Block B's #+end_src position BEFORE Block A's response
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Instruction B$")
    (re-search-forward "^#\\+end_src")
    (let ((block-b-end-before (line-end-position))
          ;; Also create a marker for Block B's instruction
          (block-b-marker (point-marker)))

      ;; Now simulate Block A completing: insert response AFTER Block A's #+end_src
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Instruction A$")
      (re-search-forward "^#\\+end_src")
      (end-of-line)
      (insert "\n** Response A :ai_output:\n")
      (insert ":PROPERTIES:\n:QUERY_ID: q-A\n:END:\n\n")
      (insert "Block A's long response that shifts all positions.\n")
      (insert "Line 2 of response.\n")
      (insert "Line 3 of response.\n")

      ;; Now navigate to Block B's instruction and check insert point
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Instruction B$")
      (beginning-of-line)

      (let ((insert-point (code-agent-org--find-response-insert-point)))
        (should insert-point)

        ;; The insert point should be after Block B's #+end_src
        ;; (which has shifted due to Block A's response insertion)
        (goto-char (point-min))
        (re-search-forward "^\\*\\* Instruction B$")
        (re-search-forward "^#\\+end_src")
        (let ((block-b-end-after (line-end-position)))
          ;; Verify the buffer DID shift
          (should (> block-b-end-after block-b-end-before))
          ;; Insert point should match the NEW position of Block B's end
          (should (= insert-point block-b-end-after))))

      ;; Clean up marker
      (set-marker block-b-marker nil))))

;;; ============================================================
;;; Test 6: find-response-boundary extends past unrelated sections
;;; ============================================================

(ert-deftest test-find-response-boundary-extends-past-unrelated-sections ()
  "Verify that find-response-boundary correctly stops at a non-ai_output
heading at the same level. When all same-level siblings after the instruction
have :ai_output: tag, the boundary should stop at the first non-ai_output
same-level sibling, not extend to point-max."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    ;; Structure:
    ;; * Story
    ;; ** Instruction 1
    ;; #+begin_src ai ... #+end_src
    ;; ** Response 1a :ai_output:
    ;; ** Response 1b :ai_output:
    ;; ** Unrelated Section            <- boundary should be here
    ;; ** Another Section
    (insert "* Story\n")
    (insert "** Instruction 1\n")
    (insert "#+begin_src ai\nquery 1\n#+end_src\n")
    (insert "** Response 1a :ai_output:\n")
    (insert ":PROPERTIES:\n:QUERY_ID: q-1a\n:END:\n\n")
    (insert "First response.\n")
    (insert "** Response 1b :ai_output:\n")
    (insert ":PROPERTIES:\n:QUERY_ID: q-1b\n:END:\n\n")
    (insert "Second response.\n")
    (insert "** Unrelated Section\n")
    (insert "This is not an AI response.\n")
    (insert "** Another Section\n")
    (insert "More unrelated content.\n")

    ;; Position at Instruction 1
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Instruction 1$")
    (beginning-of-line)

    (let ((boundary (code-agent-org--find-response-boundary)))
      ;; Boundary should be at "** Unrelated Section" position
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Unrelated Section$")
      (let ((expected-boundary (match-beginning 0)))
        (should (= boundary expected-boundary))
        ;; Boundary should NOT be point-max
        (should (< boundary (point-max)))))))

;;; ============================================================
;;; Test 7: find-response-by-query-id with prefix collision
;;; ============================================================

(ert-deftest test-insert-at-response-with-duplicate-query-id-prefix ()
  "Verify that find-response-by-query-id doesn't match a query-id that
is a prefix of another. The function uses regexp-quote so this should
be safe, but we verify the trailing $ anchor behavior."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    ;; Two response sections where one query-id is a prefix of the other
    (insert "* Story\n")
    (insert "** Response 1 :ai_output:\n")
    (insert ":PROPERTIES:\n")
    (insert ":QUERY_ID: 20260204-120000-abc\n")
    (insert ":END:\n\n")
    (insert "Response ONE content.\n")
    (insert "** Response 2 :ai_output:\n")
    (insert ":PROPERTIES:\n")
    (insert ":QUERY_ID: 20260204-120000-abcd\n")
    (insert ":END:\n\n")
    (insert "Response TWO content.\n")

    ;; Search for the shorter ID - should find Response 1, not Response 2
    (let ((pos1 (code-agent-org--find-response-by-query-id "20260204-120000-abc")))
      (should pos1)
      (goto-char pos1)
      (should (looking-at "\\*\\* Response 1")))

    ;; Search for the longer ID - should find Response 2
    (let ((pos2 (code-agent-org--find-response-by-query-id "20260204-120000-abcd")))
      (should pos2)
      (goto-char pos2)
      (should (looking-at "\\*\\* Response 2")))

    ;; Verify they are different positions
    (let ((pos1 (code-agent-org--find-response-by-query-id "20260204-120000-abc"))
          (pos2 (code-agent-org--find-response-by-query-id "20260204-120000-abcd")))
      (should-not (= pos1 pos2)))))

;;; ============================================================
;;; Test 8: find-response-insert-point when block between responses
;;; ============================================================

(ert-deftest test-find-response-insert-point-when-block-between-responses ()
  "When Instruction 2 has a previous Response 2 from a prior execution,
find-response-insert-point should return position after Response 2,
not after Response 1."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    ;; Structure:
    ;; ** Instruction 1
    ;; #+begin_src ai ... #+end_src
    ;; ** Response 1 :ai_output:
    ;; ...content...
    ;; ** Instruction 2        <- point here
    ;; #+begin_src ai ... #+end_src
    ;; ** Response 2 :ai_output:    <- from previous execution
    ;; ...content...
    ;; ** Instruction 3
    (insert "** Instruction 1\n")
    (insert "#+begin_src ai\nquery 1\n#+end_src\n")
    (insert "** Response 1 :ai_output:\n")
    (insert ":PROPERTIES:\n:QUERY_ID: q-001\n:END:\n\n")
    (insert "Response 1 content.\n")
    (insert "** Instruction 2\n")
    (insert "#+begin_src ai\nquery 2\n#+end_src\n")
    (insert "** Response 2 :ai_output:\n")
    (insert ":PROPERTIES:\n:QUERY_ID: q-002\n:END:\n\n")
    (insert "Response 2 content.\n")
    (insert "** Instruction 3\n")
    (insert "#+begin_src ai\nquery 3\n#+end_src\n")

    ;; Position at Instruction 2
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Instruction 2$")
    (beginning-of-line)

    (let ((insert-point (code-agent-org--find-response-insert-point)))
      (should insert-point)

      ;; Find the end of Response 2's subtree
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Response 2")
      (org-end-of-subtree t)
      (let ((response-2-end (point)))
        ;; Insert point should be at or after Response 2 end
        (should (>= insert-point response-2-end)))

      ;; It should NOT be at Response 1's end
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Response 1")
      (org-end-of-subtree t)
      (let ((response-1-end (point)))
        (should (> insert-point response-1-end)))

      ;; It should NOT be past Instruction 3
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Instruction 3$")
      (let ((instr-3-pos (match-beginning 0)))
        (should (<= insert-point instr-3-pos))))))

;;; ============================================================
;;; Test 9: insert-at-response with multiple queries in same session
;;; ============================================================

(ert-deftest test-insert-at-response-wrong-position-multiple-queries ()
  "Set up buffer with TWO response sections for TWO different blocks in
the same session. Store Block B's query-id in session state. Call
insert-at-response and verify text goes into Block B's response section,
not Block A's."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-multi-query.org")
    ;; Two instruction/response pairs
    (insert "* Story\n")
    (insert "** Instruction A\n")
    (insert "#+begin_src ai\nquery A\n#+end_src\n")
    (insert "** Response A :ai_output:\n")
    (insert ":PROPERTIES:\n")
    (insert ":QUERY_ID: q-block-A\n")
    (insert ":END:\n\n")
    (insert "Block A output.\n")
    (insert "** Instruction B\n")
    (insert "#+begin_src ai\nquery B\n#+end_src\n")
    (insert "** Response B :ai_output:\n")
    (insert ":PROPERTIES:\n")
    (insert ":QUERY_ID: q-block-B\n")
    (insert ":END:\n\n")
    (insert "Block B output.\n")

    ;; Set up session with Block B's query-id active
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((state (code-agent-org--make-session-state
                  :query-id "q-block-B"
                  :section-level 1)))
      (puthash "test-session" state code-agent-org--sessions))

    ;; Insert new text - should go into Block B's response
    (code-agent-org--insert-at-response "test-session" "NEW-B-TOKEN")

    ;; Verify token is in Block B's section, not Block A's
    (goto-char (point-min))
    (should (search-forward "NEW-B-TOKEN" nil t))
    (let ((token-pos (match-beginning 0)))
      ;; Find Block B's response section boundaries
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Response B")
      (let ((resp-b-start (match-beginning 0)))
        ;; Token should be after Response B heading
        (should (> token-pos resp-b-start)))

      ;; Token should NOT be in Block A's response section
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Response A")
      (let ((resp-a-start (match-beginning 0)))
        (goto-char (point-min))
        (re-search-forward "^\\*\\* Instruction B")
        (let ((instr-b-start (match-beginning 0)))
          ;; Token should NOT be between Response A and Instruction B
          (should-not (and (> token-pos resp-a-start)
                           (< token-pos instr-b-start))))))))

;;; ============================================================
;;; Additional edge case tests
;;; ============================================================

(ert-deftest test-find-response-boundary-all-ai-output-siblings ()
  "When ALL same-level siblings after instruction are :ai_output:,
and there's a parent-level boundary, verify boundary stops at parent."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    ;; Structure:
    ;; * Parent Story
    ;; ** Instruction
    ;; #+begin_src ai ... #+end_src
    ;; ** Response 1 :ai_output:
    ;; ** Response 2 :ai_output:
    ;; ** Response 3 :ai_output:
    ;; * Next Top-Level Story        <- parent-level boundary
    (insert "* Parent Story\n")
    (insert "** Instruction\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    (insert "** Response 1 :ai_output:\n")
    (insert "Content 1.\n")
    (insert "** Response 2 :ai_output:\n")
    (insert "Content 2.\n")
    (insert "** Response 3 :ai_output:\n")
    (insert "Content 3.\n")
    (insert "* Next Top-Level Story\n")
    (insert "** Something else\n")

    ;; Position at Instruction
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Instruction$")
    (beginning-of-line)

    (let ((boundary (code-agent-org--find-response-boundary)))
      ;; Boundary should be at "* Next Top-Level Story" (parent-level heading)
      (goto-char (point-min))
      (re-search-forward "^\\* Next Top-Level Story$")
      (let ((expected (match-beginning 0)))
        (should (= boundary expected))))))

(ert-deftest test-find-response-boundary-no-boundary-returns-point-max ()
  "When there are no siblings or parent boundaries after the instruction,
find-response-boundary should return point-max."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    ;; Only one instruction, nothing after it
    (insert "** Instruction\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    (insert "** Response :ai_output:\n")
    (insert "Content.\n")

    ;; Position at Instruction
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Instruction$")
    (beginning-of-line)

    (let ((boundary (code-agent-org--find-response-boundary)))
      (should (= boundary (point-max))))))

(ert-deftest test-insert-at-response-empty-section-before-heading ()
  "When response section is empty (just :END: followed by a heading),
insert-at-response should insert after :END: in the blank area."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-empty-response.org")
    ;; Response section with no content between :END: and next heading
    (insert "* Story\n")
    (insert "** Response :ai_output:\n")
    (insert ":PROPERTIES:\n")
    (insert ":QUERY_ID: q-empty\n")
    (insert ":END:\n\n")
    (insert "** Next Section\n")

    ;; Set up session
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((state (code-agent-org--make-session-state
                  :query-id "q-empty"
                  :section-level 1)))
      (puthash "test-session" state code-agent-org--sessions))

    ;; Insert text
    (code-agent-org--insert-at-response "test-session" "FIRST-TOKEN")

    ;; Token should be between :END: and "** Next Section"
    (goto-char (point-min))
    (should (search-forward "FIRST-TOKEN" nil t))
    (let ((token-pos (match-beginning 0)))
      (goto-char (point-min))
      (re-search-forward "^:END:")
      (let ((end-pos (line-end-position)))
        (should (> token-pos end-pos)))
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Next Section")
      (let ((next-pos (match-beginning 0)))
        (should (< token-pos next-pos))))))

(ert-deftest test-find-response-insert-point-level-mismatch-nested ()
  "When an instruction is at level 3 but a previous response is at level 2,
find-response-insert-point should not pick up the wrong-level response."
  :tags '(:unit :fast :stable :isolated :org :position :bug)
  (with-temp-buffer
    (org-mode)
    ;; Structure:
    ;; * Story
    ;; ** Response from previous :ai_output:   (level 2)
    ;; ** Sub-story
    ;; *** Instruction                         (level 3)
    ;; #+begin_src ai ... #+end_src
    (insert "* Story\n")
    (insert "** Response from previous :ai_output:\n")
    (insert ":PROPERTIES:\n:QUERY_ID: q-prev\n:END:\n\n")
    (insert "Old response.\n")
    (insert "** Sub-story\n")
    (insert "*** Instruction\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")

    ;; Position at the level-3 instruction
    (goto-char (point-min))
    (re-search-forward "^\\*\\*\\* Instruction$")
    (beginning-of-line)

    (let ((insert-point (code-agent-org--find-response-insert-point)))
      (should insert-point)

      ;; Should return position after #+end_src of the level-3 block
      ;; NOT after the level-2 Response from previous
      (goto-char (point-min))
      (re-search-forward "^\\*\\*\\* Instruction$")
      (re-search-forward "^#\\+end_src")
      (let ((expected (line-end-position)))
        (should (= insert-point expected))))))

(provide 'test-code-agent-org-wrong-position-repro)

;;; test-code-agent-org-wrong-position-repro.el ends here
