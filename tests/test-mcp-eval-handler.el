;;; test-mcp-eval-handler.el --- Tests for evalElisp handler -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; TDD tests for emacs-mcp-server--handler-eval-elisp edge cases.
;; Tests valid code, errors, malformed input, state flags,
;; and output truncation.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-mcp-server)

;;; Test Helpers

(defmacro test-mcp-eval--with-clean-state (&rest body)
  "Run BODY with clean eval state (counters reset, no spinner)."
  (declare (indent 0) (debug t))
  `(let ((emacs-mcp-server--eval-active nil)
         (emacs-mcp-server--eval-count 0)
         (emacs-mcp-server--spinner-timer nil)
         (emacs-mcp-server-show-mode-line nil)
         (emacs-mcp-server-path-mappings nil)
         (emacs-mcp-server-verbose nil))
     ,@body))

(defun test-mcp-eval--parse-handler-result (result)
  "Parse RESULT from handler into decoded JSON alist.
Handler returns list of content blocks; first block's text is JSON."
  (let* ((block (car result))
         (text (alist-get 'text block)))
    (json-parse-string text :object-type 'alist)))

;;; Tests: Valid Code

(ert-deftest test-mcp-eval-handler-valid-code ()
  "Valid code returns success=t with result string."
  :tags '(:unit :fast :stable :mcp-eval-handler)
  (test-mcp-eval--with-clean-state
    (let* ((result (emacs-mcp-server--handler-eval-elisp
                    '((code . "(+ 1 2)")) nil))
           (parsed (test-mcp-eval--parse-handler-result result)))
      (should (eq t (alist-get 'success parsed)))
      (should (stringp (alist-get 'result parsed)))
      (should (string-match-p "3" (alist-get 'result parsed))))))

;;; Tests: Error Handling

(ert-deftest test-mcp-eval-handler-error-returns-false ()
  "Code that signals error returns success=false with errorType."
  :tags '(:unit :fast :stable :mcp-eval-handler)
  (test-mcp-eval--with-clean-state
    (let* ((result (emacs-mcp-server--handler-eval-elisp
                    '((code . "(error \"boom\")")) nil))
           (parsed (test-mcp-eval--parse-handler-result result)))
      (should (eq :false (alist-get 'success parsed)))
      (should (stringp (alist-get 'error parsed)))
      (should (string-match-p "boom" (alist-get 'error parsed)))
      (should (equal "error" (alist-get 'errorType parsed))))))

(ert-deftest test-mcp-eval-handler-malformed-code ()
  "Malformed code (unbalanced parens) returns error, not crash.
FIX: Ensure code string is valid elisp before sending to evalElisp."
  :tags '(:unit :fast :stable :mcp-eval-handler)
  (test-mcp-eval--with-clean-state
    ;; Unbalanced open paren
    (let* ((result (emacs-mcp-server--handler-eval-elisp
                    '((code . "(")) nil))
           (parsed (test-mcp-eval--parse-handler-result result)))
      (should (eq :false (alist-get 'success parsed)))
      (should (stringp (alist-get 'error parsed))))))

(ert-deftest test-mcp-eval-handler-nil-code ()
  "Nil code parameter returns error gracefully.
FIX: Provide a non-empty 'code' parameter to evalElisp."
  :tags '(:unit :fast :stable :mcp-eval-handler)
  (test-mcp-eval--with-clean-state
    (let* ((result (emacs-mcp-server--handler-eval-elisp
                    '((code . nil)) nil))
           (parsed (test-mcp-eval--parse-handler-result result)))
      (should (eq :false (alist-get 'success parsed))))))

;;; Tests: State Management

(ert-deftest test-mcp-eval-handler-save-state-default-true ()
  "save_current_state defaults to true (state preserved)."
  :tags '(:unit :fast :stable :mcp-eval-handler)
  (test-mcp-eval--with-clean-state
    (with-temp-buffer
      (insert "abcdef")
      (goto-char 3)
      (let ((orig-point (point)))
        ;; Code moves point, but save_current_state should restore it
        (emacs-mcp-server--handler-eval-elisp
         '((code . "(goto-char (point-max))")) nil)
        (should (= (point) orig-point))))))

(ert-deftest test-mcp-eval-handler-save-state-false ()
  "save_current_state=false skips state preservation."
  :tags '(:unit :fast :stable :mcp-eval-handler)
  (test-mcp-eval--with-clean-state
    ;; When save_current_state is false, just eval directly
    (let* ((result (emacs-mcp-server--handler-eval-elisp
                    `((code . "(+ 10 20)")
                      (save_current_state . :json-false))
                    nil))
           (parsed (test-mcp-eval--parse-handler-result result)))
      (should (eq t (alist-get 'success parsed)))
      (should (string-match-p "30" (alist-get 'result parsed))))))

;;; Tests: Eval Counter

(ert-deftest test-mcp-eval-handler-counter-balanced ()
  "Eval counter increments on start and decrements on end, even on error."
  :tags '(:unit :fast :stable :mcp-eval-handler)
  (test-mcp-eval--with-clean-state
    ;; Before: count = 0
    (should (= 0 emacs-mcp-server--eval-count))
    ;; Successful eval — count should return to 0
    (emacs-mcp-server--handler-eval-elisp '((code . "t")) nil)
    (should (= 0 emacs-mcp-server--eval-count))
    ;; Error eval — count should still return to 0 (unwind-protect)
    (emacs-mcp-server--handler-eval-elisp '((code . "(error \"x\")")) nil)
    (should (= 0 emacs-mcp-server--eval-count))))

;;; Tests: Output Truncation

(ert-deftest test-mcp-eval-handler-truncates-large-output ()
  "Handler truncates output exceeding max-output-length."
  :tags '(:unit :fast :stable :mcp-eval-handler)
  (test-mcp-eval--with-clean-state
    (let ((emacs-mcp-server-max-output-length 50))
      (let* ((result (emacs-mcp-server--handler-eval-elisp
                      '((code . "(make-string 200 ?x)")) nil))
             (block (car result))
             (text (alist-get 'text block)))
        ;; Text should be truncated to around max-output-length
        (should (<= (length text) (+ 50 10)))))))  ;; small margin for ...

(provide 'test-mcp-eval-handler)
;;; test-mcp-eval-handler.el ends here
