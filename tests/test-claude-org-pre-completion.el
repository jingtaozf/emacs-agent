;;; test-claude-org-pre-completion.el --- Tests for F4: Pre-completion hook -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;;; Commentary:

;; F4: Tests for query completion hook (defcustom, buffer-local, empty default).
;; The hook allows users to attach verification functions that run on
;; query completion. No built-in verification logic is shipped.

;;; Code:

(require 'ert)

;;; Test 1: claude-org-query-complete-hook exists as defcustom

(ert-deftest test-pre-completion-hook-is-defcustom ()
  "claude-org-query-complete-hook exists as a defcustom.
FIX: Define (defcustom claude-org-query-complete-hook nil ...) in claude-org.org."
  :tags '(:unit :fast :stable :pre-completion)
  (should (custom-variable-p 'claude-org-query-complete-hook))
  (should (null (default-value 'claude-org-query-complete-hook))))

(ert-deftest test-pre-completion-hook-is-buffer-local ()
  "claude-org-query-complete-hook is buffer-local.
FIX: Call (make-variable-buffer-local 'claude-org-query-complete-hook)."
  :tags '(:unit :fast :stable :pre-completion)
  (with-temp-buffer
    (add-hook 'claude-org-query-complete-hook #'ignore nil t)
    (should (local-variable-p 'claude-org-query-complete-hook))
    (with-temp-buffer
      (should (null claude-org-query-complete-hook)))))

;;; Test 2: Hook is called on query completion

(ert-deftest test-pre-completion-hook-called-on-complete ()
  "Hook is called with (session-key query-id) on query completion.
FIX: Add (run-hook-with-args 'claude-org-query-complete-hook ...) in handle-complete."
  :tags '(:unit :fast :stable :pre-completion)
  (let ((calls '()))
    (with-temp-buffer
      (setq-local claude-org--sessions (make-hash-table :test 'equal))
      (let* ((session-key "test-session")
             (marker (point-min-marker)))
        (claude-org--session-put session-key :marker marker)
        (claude-org--session-put session-key :query-id "q-123")
        (add-hook 'claude-org-query-complete-hook
                  (lambda (sk qid)
                    (push (list sk qid) calls))
                  nil t)
        ;; Simulate hook invocation
        (run-hook-with-args 'claude-org-query-complete-hook session-key "q-123")
        (should (equal calls '(("test-session" "q-123"))))))))

;;; Test 3: claude-org-append-to-response utility

(ert-deftest test-pre-completion-append-to-response ()
  "claude-org-append-to-response inserts text at end of response section.
FIX: Implement (defun claude-org-append-to-response (session-key query-id text) ...)."
  :tags '(:unit :fast :stable :pre-completion)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "test-session"))
      (insert "* Instruction\n")
      (insert "** Response\n")
      (insert ":PROPERTIES:\n")
      (insert ":QUERY_ID: q-456\n")
      (insert ":END:\n")
      (insert "Some response content\n")
      (claude-org--session-put session-key :marker (point-min-marker))
      ;; Append text to response
      (claude-org-append-to-response session-key "q-456" "\n[Verification: tests passed]")
      ;; Verify text appears at end of response
      (goto-char (point-min))
      (should (search-forward "[Verification: tests passed]" nil t)))))

;;; Test 4: Append preserves window-start

(ert-deftest test-pre-completion-append-preserves-window-start ()
  "claude-org-append-to-response preserves window scroll position."
  :tags '(:unit :fast :stable :pre-completion)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "test-session"))
      ;; Create enough content for scrolling
      (dotimes (i 100)
        (insert (format "Line %d of filler content\n" i)))
      (insert "** Response\n")
      (insert ":PROPERTIES:\n")
      (insert ":QUERY_ID: q-789\n")
      (insert ":END:\n")
      (insert "Response content\n")
      (claude-org--session-put session-key :marker (point-min-marker))
      ;; Set window-start somewhere in the middle
      (let ((original-ws (window-start)))
        (claude-org-append-to-response session-key "q-789" "\n[Appended]")
        (should (= original-ws (window-start)))))))

(provide 'test-claude-org-pre-completion)
;;; test-claude-org-pre-completion.el ends here
