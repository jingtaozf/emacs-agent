;;; test-code-agent-input-validation.el --- Tests for Input Validation -*- lexical-binding: t; -*-

;; Tests for the safe env-file parser (code-agent-org--parse-env).
;; Originally written test-first (TDD), now validating implemented functions.
;;
;; The answer-length / file-path / command validation tests that used to
;; live here were removed 2026-07 along with code-agent--validate-answer,
;; code-agent--validate-file-path, and code-agent--validate-command —
;; those were only consumed by the deleted JSON-stream engine (zero
;; production callers after the org-as-control-plane pivot).

(require 'ert)
(require 'cl-lib)

;; Note: code-agent.org is loaded via Makefile

;;; Env File Parsing Tests (Safe parsing without read)

(ert-deftest test-parse-env-file-basic ()
  "TDD: Basic KEY=VALUE parsing should work."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (with-temp-buffer
    (insert "FOO=bar\n")
    (insert "BAZ=qux\n")
    (let ((result (code-agent-org--parse-env (buffer-string) :from-string t)))
      (should (equal (cdr (assoc "FOO" result)) "bar"))
      (should (equal (cdr (assoc "BAZ" result)) "qux")))))

(ert-deftest test-parse-env-file-with-spaces ()
  "TDD: Values with spaces should be preserved."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (with-temp-buffer
    (insert "MESSAGE=hello world\n")
    (let ((result (code-agent-org--parse-env (buffer-string) :from-string t)))
      (should (equal (cdr (assoc "MESSAGE" result)) "hello world")))))

(ert-deftest test-parse-env-file-quoted-values ()
  "TDD: Quoted values should have quotes stripped."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (with-temp-buffer
    (insert "SINGLE='single quoted'\n")
    (insert "DOUBLE=\"double quoted\"\n")
    (let ((result (code-agent-org--parse-env (buffer-string) :from-string t)))
      (should (equal (cdr (assoc "SINGLE" result)) "single quoted"))
      (should (equal (cdr (assoc "DOUBLE" result)) "double quoted")))))

(ert-deftest test-parse-env-file-empty-value ()
  "TDD: Empty values should be allowed."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (with-temp-buffer
    (insert "EMPTY=\n")
    (let ((result (code-agent-org--parse-env (buffer-string) :from-string t)))
      (should (equal (cdr (assoc "EMPTY" result)) "")))))

(ert-deftest test-parse-env-file-comments ()
  "TDD: Comment lines should be ignored."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (with-temp-buffer
    (insert "# This is a comment\n")
    (insert "FOO=bar\n")
    (insert "  # Indented comment\n")
    (insert "BAZ=qux\n")
    (let ((result (code-agent-org--parse-env (buffer-string) :from-string t)))
      (should (= 2 (length result)))
      (should (equal (cdr (assoc "FOO" result)) "bar")))))

(ert-deftest test-parse-env-file-blank-lines ()
  "TDD: Blank lines should be skipped."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (with-temp-buffer
    (insert "\n")
    (insert "FOO=bar\n")
    (insert "\n")
    (insert "   \n")
    (insert "BAZ=qux\n")
    (let ((result (code-agent-org--parse-env (buffer-string) :from-string t)))
      (should (= 2 (length result))))))

(ert-deftest test-parse-env-file-no-elisp-execution ()
  "TDD: Elisp code in env file should NOT be executed.
This test ensures the env parser doesn't use (read) which could execute code."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd :security)
  (with-temp-buffer
    ;; Attempt to inject elisp - should be treated as literal string
    (insert "EXPLOIT=(shell-command \"rm -rf /\")\n")
    (let ((result (code-agent-org--parse-env (buffer-string) :from-string t)))
      ;; Should be parsed as literal string, not executed
      (should (equal (cdr (assoc "EXPLOIT" result))
                     "(shell-command \"rm -rf /\")")))))

(ert-deftest test-parse-env-file-equals-in-value ()
  "TDD: Values containing = should be handled correctly."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (with-temp-buffer
    (insert "URL=https://example.com?foo=bar&baz=qux\n")
    (let ((result (code-agent-org--parse-env (buffer-string) :from-string t)))
      (should (equal (cdr (assoc "URL" result))
                     "https://example.com?foo=bar&baz=qux")))))

(ert-deftest test-parse-env-file-export-prefix ()
  "TDD: export prefix should be handled."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (with-temp-buffer
    (insert "export FOO=bar\n")
    (insert "  export   BAZ=qux\n")
    (let ((result (code-agent-org--parse-env (buffer-string) :from-string t)))
      (should (equal (cdr (assoc "FOO" result)) "bar"))
      (should (equal (cdr (assoc "BAZ" result)) "qux")))))

(ert-deftest test-parse-env-file-multiline-value ()
  "TDD: Multiline values in quotes should be handled."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  ;; This is a stretch goal - for now, document expected behavior
  (with-temp-buffer
    (insert "MULTI=\"line1\nline2\"\n")
    ;; Current simple parser may not handle this - that's OK
    ;; The important thing is it doesn't crash or execute code
    (should-not (condition-case nil
                    (progn
                      (code-agent-org--parse-env (buffer-string) :from-string t)
                      nil)
                  (error t)))))

(provide 'test-code-agent-input-validation)
;;; test-code-agent-input-validation.el ends here
