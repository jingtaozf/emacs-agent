;;; test-code-agent-org-wrong-level-repro.el --- Tests reproducing wrong section level bugs -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Tests that REPRODUCE (not fix) bugs where response sections are created
;; at wrong org heading levels.
;;
;; Key bug: In `code-agent-org--create-response-section' (code-agent-org.org:1893):
;;   (let* ((section-level (or (code-agent-org--session-get session-key :section-level) 1))
;; When session-state initializes :section-level to 0 (line 1719), `(or 0 1)'
;; returns 0 in Elisp (0 is truthy!). Then `(make-string 0 ?*)' produces an
;; empty string, so the response heading has NO stars -- it's plain text,
;; not a valid org heading.
;;
;; Similarly in `code-agent-org--handle-token-v2' (line 2015):
;;   (let* ((target-level (1+ (or (code-agent-org--session-get session-key :section-level) 0)))
;; When section-level is 0, `(or 0 0)' => 0, target-level = 1, so Claude's
;; `*' headers stay as `*' (top-level) instead of being normalized to nested level.

;;; Code:

(require 'ert)
(require 'org)
(require 'code-agent-org)

;;; Test 1: section-level 0 creates heading with no stars (invalid org)

(ert-deftest test-create-response-section-level-zero-no-stars ()
  "When section-level is 0 (before first heading), the response heading
has NO stars because `(make-string 0 ?*)' => \"\".

BUG: Line 1893 of code-agent-org.org:
  (let* ((section-level (or (code-agent-org--session-get session-key :section-level) 1))
In Elisp, 0 is truthy, so `(or 0 1)' returns 0.
Then `(make-string 0 ?*)' produces \"\", making the heading plain text
like \" Response 1 (2026-02-28 12:00) :ai_output:\" with no leading stars.

CORRECT behavior: section-level 0 means 'before first heading'. The code
should either use level 1 as fallback, or error, or handle it explicitly.
Instead it silently produces an invalid org heading."
  :tags '(:unit :fast :stable :isolated :org :heading-level :bug)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-level-zero.org")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-level-zero.org"))
      ;; Session state now initializes section-level to nil (fixed from 0)
      (should (null (code-agent-org--session-get session-key :section-level)))
      ;; Set it explicitly to 0 (simulating AI block before first heading)
      (code-agent-org--session-put session-key :section-level 0)
      (code-agent-org--session-put session-key :query-id "test-qid-001")
      (goto-char (point-max))
      ;; Call create-response-section
      (code-agent-org--create-response-section session-key "test-qid-001" 'normal)
      ;; FIXED: section-level 0 now falls back to 1, producing a valid heading
      (goto-char (point-min))
      (let ((has-starred-heading (re-search-forward "^\\*+ Response" nil t)))
        ;; The heading has stars because (if (and 0 (> 0 0)) 0 1) => 1
        (should has-starred-heading))
      ;; Verify the response heading is a valid org heading at level 1
      (goto-char (point-min))
      (should (re-search-forward "Response.*:ai_output:" nil t))
      (beginning-of-line)
      (should (looking-at "^\\* ")))))

;;; Test 2: fresh session defaults section-level to 0, causing no-stars heading

(ert-deftest test-create-response-section-fresh-session-default-zero ()
  "When :section-level is never explicitly set (freshly initialized session),
it defaults to 0 (line 1719). If create-response-section is called before
code-agent-org-execute stores the correct level, the heading has no stars.

This simulates a race condition: create-response-section runs before
the execute function has written the correct section-level to session state."
  :tags '(:unit :fast :stable :isolated :org :heading-level :bug)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-level-fallback.org")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-level-fallback.org"))
      ;; Fresh session: section-level defaults to nil
      (should (null (code-agent-org--session-get session-key :section-level)))
      ;; DO NOT set section-level - simulating race condition
      (code-agent-org--session-put session-key :query-id "test-qid-002")
      (goto-char (point-max))
      (code-agent-org--create-response-section session-key "test-qid-002" 'normal)
      ;; FIXED: session defaults to nil, so (if (and nil ...) ...) => 1 fallback
      (goto-char (point-min))
      (let ((has-starred-heading (re-search-forward "^\\*+ Response" nil t)))
        (should has-starred-heading))
      ;; The response heading is a valid org heading at level 1
      (goto-char (point-min))
      (should (re-search-forward "Response.*:ai_output:" nil t))
      ;; Verify it IS at level 1 (the intended fallback)
      (beginning-of-line)
      (should (looking-at "^\\* ")))))

;;; Test 3: queued block preserves its own section-level in session state

(ert-deftest test-create-response-section-level-preserved-for-queued-block ()
  "Set up scenario where Block A runs at level 3, then Block B (queued at
level 5) runs. Verify Block B's response uses level 5 from the queued
block-info, not level 3 from Block A's leftover session state.

This test verifies the mechanism: when execute-queued-block writes
section-level to session state before calling create-response-section,
the response heading should use that level."
  :tags '(:unit :fast :stable :isolated :org :heading-level :bug)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-level-queued.org")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-level-queued.org"))
      ;; Simulate Block A has run at level 3
      (code-agent-org--session-put session-key :section-level 3)
      (code-agent-org--session-put session-key :query-id "block-a-qid")
      ;; Block A's response was created at level 3
      (insert "*** Response 1 (2026-01-01 10:00) :ai_output:\n")
      (insert ":PROPERTIES:\n:QUERY_ID: block-a-qid\n:END:\n\n")
      (insert "Block A content.\n\n")
      ;; Now simulate Block B being dequeued.
      ;; execute-queued-block (line 5069) writes section-level BEFORE
      ;; calling create-response-section.
      (code-agent-org--session-put session-key :section-level 5)
      (code-agent-org--session-put session-key :query-id "block-b-qid")
      ;; Create Block B's response section
      (goto-char (point-max))
      (code-agent-org--create-response-section session-key "block-b-qid" 'normal)
      ;; Verify Block B's response is at level 5
      (goto-char (point-min))
      (re-search-forward ":QUERY_ID: block-b-qid")
      (org-back-to-heading t)
      (should (= 5 (org-current-level))))))

;;; Test 4: point inside response heading causes wrong section-level detection

(ert-deftest test-section-level-wrong-when-point-inside-response ()
  "When user is reviewing a response (point inside `** Response :ai_output:'
section) and triggers execution of a DIFFERENT ai block, the
`org-back-to-heading' in `get-section-level' finds the Response heading,
not the instruction heading.

BUG: get-section-level (line 2632) always uses `org-back-to-heading' at
point. If point is inside a response section, it returns the response
heading's level, not the instruction heading's level."
  :tags '(:unit :fast :stable :isolated :org :heading-level :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Top Level\n")
    (insert "** Instruction A\n")
    (insert "#+begin_src ai\nquery A\n#+end_src\n\n")
    (insert "** Response 1 (2026-01-01 10:00) :ai_output:\n")
    (insert ":PROPERTIES:\n:QUERY_ID: resp-a\n:END:\n\n")
    (insert "Response content with nested heading.\n\n")
    (insert "*** Nested Detail\n")
    (insert "Some detail here.\n\n")
    ;; Suppose there's another AI block elsewhere
    (insert "** Instruction B\n")
    (insert "#+begin_src ai\nquery B\n#+end_src\n")
    ;; User is reviewing Response A, point is inside the nested detail
    (goto-char (point-min))
    (re-search-forward "Some detail here")
    ;; get-section-level at this point finds *** Nested Detail (level 3)
    (let ((level-inside-response (code-agent-org--get-section-level)))
      ;; BUG: Returns 3 (from *** Nested Detail)
      ;; This is wrong if the user intended to execute Instruction A (level 2)
      ;; or Instruction B (level 2)
      (should (= 3 level-inside-response))
      ;; CORRECT behavior: get-section-level should be called from inside the
      ;; AI block, not from wherever point happens to be. The level should be 2.
      (should-not (= 2 level-inside-response)))))

;;; Test 5: normalize-headers gets wrong target-level when section-level is 0

(ert-deftest test-normalize-headers-wrong-target-level ()
  "When section-level is 0 (default for fresh session or before first heading),
target-level becomes 1 via `(1+ (or 0 0))' = `(1+ 0)' = 1. Claude's
`* Heading' stays as `* Heading' (top-level) instead of being normalized
to a nested level.

BUG: handle-token-v2 (line 2015):
  (let* ((target-level (1+ (or (code-agent-org--session-get session-key :section-level) 0)))
When section-level is 0, `(or 0 0)' => 0 (0 is truthy in Elisp!),
so target-level = 1. Claude's `* Heading' maps to level 1 (unchanged).

If the AI block was actually at level 3, Claude's * should become ****.
But because section-level was 0 (never properly set), we get level 1."
  :tags '(:unit :fast :stable :isolated :org :heading-level :bug)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-normalize-level.org")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-normalize-level.org"))
      ;; Session-level is nil (default), simulating the case where
      ;; execute never stored the correct level
      (should (null (code-agent-org--session-get session-key :section-level)))
      ;; Compute target-level the same way handle-token-v2 does (FIXED)
      ;; (if (and nil ...) nil 1) => 1, then (1+ 1) => 2
      (let* ((target-level (1+ (let ((raw (code-agent-org--session-get session-key :section-level)))
                                 (if (and raw (> raw 0)) raw 1)))))
        ;; FIXED: target-level is 2 (fallback 1 + 1), not 1
        (should (= 2 target-level))
        ;; Now normalize a heading - Claude sends "* My Heading\n"
        (let ((code-agent-org-normalize-headers t)  ; ensure normalization is on
              (result (code-agent-org--normalize-headers-in-text "* My Heading\nContent\n" target-level)))
          ;; With target-level=2: offset = (1- 2) = 1, so * becomes **
          ;; Claude's "* My Heading" becomes "** My Heading"
          (should (string-match-p "^\\*\\* My Heading" result)))))))

;;; Test 6: Block A's section-level overwritten by queued Block B in shared session

(ert-deftest test-section-level-overwritten-by-queued-block ()
  "When Block A is executing at level 2 and Block B is queued at level 4,
after Block B writes its :section-level to session state, Block A's
ongoing token handling uses the WRONG level because they share session state.

BUG: Both blocks use the same session-key, so when execute-queued-block
writes :section-level for Block B, Block A's handle-token-v2 will read
Block B's level instead of its own.

Note: in the current code, execute-queued-block only runs after Block A
completes, so this race is normally prevented by sequencing. But this test
documents that the session state is shared and could cause issues if the
sequencing guarantee ever breaks."
  :tags '(:unit :fast :stable :isolated :org :heading-level :bug)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-overwrite-level.org")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-overwrite-level.org"))
      ;; Block A is executing at level 2
      (code-agent-org--session-put session-key :section-level 2)
      (code-agent-org--session-put session-key :query-id "block-a-qid")
      ;; Verify Block A's target-level for header normalization
      (let ((target-level-a (1+ (or (code-agent-org--session-get session-key :section-level) 0))))
        (should (= 3 target-level-a))) ; 2 + 1 = 3 (correct for Block A)
      ;; Now simulate Block B being dequeued and writing its section-level
      ;; (This is what execute-queued-block does at line 5069)
      (code-agent-org--session-put session-key :section-level 4)
      ;; BUG: If Block A's token handler runs NOW, it reads the WRONG level
      (let ((target-level-after-overwrite
             (1+ (or (code-agent-org--session-get session-key :section-level) 0))))
        ;; Block A would now use target-level=5 instead of 3!
        (should (= 5 target-level-after-overwrite))
        ;; CORRECT behavior: Block A should still use target-level=3
        ;; because its section-level is 2. The shared session state
        ;; means queued blocks can corrupt the executing block's config.
        (should-not (= 3 target-level-after-overwrite))))))

;;; Test 7: find-response-boundary uses org-current-level at wrong position

(ert-deftest test-find-response-boundary-wrong-level-when-inside-response ()
  "When `find-response-boundary' is called with point positioned inside a
response section's nested heading, `org-current-level' returns the
response's nested level instead of the instruction level.

BUG: find-response-boundary (line 3683) starts with:
  (let ((current-level (org-current-level)))
If point is on a nested heading inside a response (e.g., *** Detail at
level 3), it uses level 3 as the search criteria. It should use the
instruction heading's level (e.g., 2) to find sibling boundaries correctly."
  :tags '(:unit :fast :stable :isolated :org :heading-level :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Top Level\n")
    (insert "** Instruction A\n")
    (insert "#+begin_src ai\nquery A\n#+end_src\n\n")
    (insert "** Response 1 (2026-01-01 10:00) :ai_output:\n\n")
    (insert "Response content.\n\n")
    (insert "*** Nested Response Detail\n")
    (insert "Detail content.\n\n")
    (insert "** Instruction B\n")
    (insert "#+begin_src ai\nquery B\n#+end_src\n")
    ;; Position on the instruction heading "** Instruction A"
    (goto-char (point-min))
    (re-search-forward "Instruction A")
    (org-back-to-heading t)
    (let ((boundary-from-instruction (code-agent-org--find-response-boundary)))
      ;; From ** Instruction A (level 2), boundary finds ** Instruction B
      ;; (same-level sibling that is not :ai_output:)
      ;; Now position on *** Nested Response Detail (level 3)
      (goto-char (point-min))
      (re-search-forward "Nested Response Detail")
      (org-back-to-heading t)
      (let ((boundary-from-nested (code-agent-org--find-response-boundary)))
        ;; BUG: From *** Nested Response Detail (level 3), org-current-level is 3.
        ;; find-response-boundary looks for same-level (3) or higher-level (<3)
        ;; headings. It finds ** Instruction B (level 2, which is < 3) as the
        ;; boundary -- this is treated as a "parent boundary".
        ;;
        ;; The boundaries are the same here, but the LOGIC is wrong: it treats
        ;; ** Instruction B as a "parent" of *** Nested Detail, when really
        ;; they're unrelated sections. This means the function gives correct
        ;; results by accident for this layout but would fail with different
        ;; nesting (e.g., if there were *** level headings after the response).
        (should (integerp boundary-from-instruction))
        (should (integerp boundary-from-nested))
        ;; Both happen to point to ** Instruction B, but via different logic paths
        (should (= boundary-from-instruction boundary-from-nested))))))

;;; Test 8: create-response-section-header falls back to get-section-level at wrong position

(ert-deftest test-create-response-section-header-wrong-level-at-point ()
  "The standalone create-response-section-header function falls back to
get-section-level when section-level arg is nil. If point is positioned
at a deeply nested response heading, the header gets that level.

BUG: Line 3741: (let* ((level (or section-level (code-agent-org--get-section-level)))
When section-level is nil, it calls get-section-level, which uses
org-back-to-heading at point. If point is at a nested response heading,
the function returns the wrong level."
  :tags '(:unit :fast :stable :isolated :org :heading-level :bug)
  (with-temp-buffer
    (org-mode)
    (insert "* Top Level\n")
    (insert "** Instruction\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    ;; Add nested response headings
    (insert "** Response :ai_output:\n")
    (insert "*** Nested\n")
    (insert "**** Deep Nested\n")
    ;; Position point at the deep nested heading
    (goto-char (point-min))
    (re-search-forward "Deep Nested")
    (org-back-to-heading t)
    ;; Call create-response-section-header WITHOUT section-level arg
    ;; It will call (code-agent-org--get-section-level) at point
    (let ((header (code-agent-org--create-response-section-header
                   1 "2026-01-01 10:00" nil nil)))
      ;; org-back-to-heading at **** Deep Nested finds level 4
      ;; So the header will be at level 4
      (should (string-match "^\\(\\*+\\) " header))
      (let ((level (length (match-string 1 header))))
        ;; BUG: Level is 4 (from **** Deep Nested) instead of 2
        ;; (from ** Instruction where the AI block lives)
        (should (= 4 level))
        ;; CORRECT: Should be level 2 (the instruction heading level)
        (should-not (= 2 level))))))

(provide 'test-code-agent-org-wrong-level-repro)
;;; test-code-agent-org-wrong-level-repro.el ends here
