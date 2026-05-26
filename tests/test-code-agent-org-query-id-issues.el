;;; test-code-agent-org-query-id-issues.el --- Tests for query-id issues -*- lexical-binding: t -*-

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
  (literate-elisp-load (expand-file-name "lp/org/code-agent-org.org" project-root)))

;;; Issue 2: Content should have blank line after :END:

(ert-deftest test-response-section-has-newline-after-properties ()
  "Response section should have blank line after :END: before content."
  (with-temp-buffer
    (org-mode)
    (insert "* Test\n")
    ;; Set up session
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (puthash "test-session"
             (list :section-level 0
                   :instruction-num 1)
             code-agent-org--sessions)
    ;; Create response section
    (goto-char (point-max))
    (code-agent-org--create-response-section "test-session" "20260204-100000-test" 'normal)
    ;; Now insert some content using the insert function
    (code-agent-org--insert-at-response "test-session" "Test content")
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
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (puthash "test-session"
             (list :section-level 0
                   :instruction-num 1)
             code-agent-org--sessions)
    (goto-char (point-max))
    (let ((insert-pos (code-agent-org--create-response-section
                       "test-session" "20260204-100000-test" 'normal)))
      ;; The returned position should be after :END:\n\n
      (goto-char insert-pos)
      (should (looking-back "\n\n" 2)))))

(provide 'test-code-agent-org-query-id-issues)
;;; test-code-agent-org-query-id-issues.el ends here
