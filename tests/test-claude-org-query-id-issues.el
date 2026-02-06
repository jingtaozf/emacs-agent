;;; test-claude-org-query-id-issues.el --- Tests for query-id issues -*- lexical-binding: t -*-

;;; Commentary:
;; Tests to reproduce and verify fixes for:
;; Issue 1: Response section should be sibling of instruction, not child
;; Issue 2: Content should have newline after :END: property block

;;; Code:

(require 'ert)

;; Load the code under test using literate-elisp
(require 'literate-elisp)
(let ((project-root (file-name-directory
                     (directory-file-name
                      (file-name-directory load-file-name)))))
  (literate-elisp-load (expand-file-name "claude-org.org" project-root)))

;;; Issue 1: Response section level should match instruction level (sibling)

(ert-deftest test-response-section-is-sibling-not-child ()
  "Response section should be at same level as instruction (sibling), not child.
If instruction is level 2 (**), response should also be level 2 (**)."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n")
    (insert "** Instruction :instruction:\n")
    (insert "#+begin_src ai\nQuery\n#+end_src\n")
    ;; Set up session state - section-level should be 1 (the instruction's level is 2)
    ;; But for response to be SIBLING, it needs same level as instruction
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (puthash "test-session"
             (list :section-level 1  ;; This is parent level, response will be parent+1=2
                   :instruction-num 1)
             claude-org--sessions)
    ;; Create response section
    (goto-char (point-max))
    (claude-org--create-response-section "test-session" "20260204-100000-test" 'normal)
    ;; Check the heading level
    (goto-char (point-min))
    (search-forward "Response")
    (beginning-of-line)
    ;; Count asterisks - should be 2 for sibling of level-2 instruction
    (should (looking-at "\\*\\* Response"))
    ;; Should NOT be 3 asterisks (child)
    (should-not (looking-at "\\*\\*\\* Response"))))

;;; Issue 2: Content should have blank line after :END:

(ert-deftest test-response-section-has-newline-after-properties ()
  "Response section should have blank line after :END: before content."
  (with-temp-buffer
    (org-mode)
    (insert "* Test\n")
    ;; Set up session
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (puthash "test-session"
             (list :section-level 0
                   :instruction-num 1)
             claude-org--sessions)
    ;; Create response section
    (goto-char (point-max))
    (claude-org--create-response-section "test-session" "20260204-100000-test" 'normal)
    ;; Now insert some content using the insert function
    (claude-org--insert-at-response "test-session" "Test content")
    ;; Check buffer content
    (let ((content (buffer-substring-no-properties (point-min) (point-max))))
      ;; Should have ":END:\n\n" (blank line after END)
      (should (string-match-p ":END:\n\n" content))
      ;; Content should NOT be immediately after :END:
      (should-not (string-match-p ":END:Test content" content)))))

(ert-deftest test-create-response-section-returns-insert-position ()
  "create-response-section should return position after blank line."
  (with-temp-buffer
    (org-mode)
    (insert "* Test\n")
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (puthash "test-session"
             (list :section-level 0
                   :instruction-num 1)
             claude-org--sessions)
    (goto-char (point-max))
    (let ((insert-pos (claude-org--create-response-section
                       "test-session" "20260204-100000-test" 'normal)))
      ;; The returned position should be after :END:\n\n
      (goto-char insert-pos)
      (should (looking-back "\n\n" 2)))))

(provide 'test-claude-org-query-id-issues)
;;; test-claude-org-query-id-issues.el ends here
