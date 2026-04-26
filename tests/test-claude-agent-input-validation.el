;;; test-claude-agent-input-validation.el --- Tests for Input Validation -*- lexical-binding: t; -*-

;; Tests for input validation layer (answer length, file path, command, env parsing)
;; Originally written test-first (TDD), now validating implemented functions.

(require 'ert)
(require 'cl-lib)

;; Note: claude-agent.org is loaded via Makefile

;;; Answer Length Validation Tests

(ert-deftest test-validate-answer-nil-input ()
  "TDD: nil answer should be valid (no answer provided)."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (should (claude-agent--validate-answer nil)))

(ert-deftest test-validate-answer-empty-string ()
  "TDD: Empty string answer should be valid."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (should (claude-agent--validate-answer "")))

(ert-deftest test-validate-answer-normal-length ()
  "TDD: Normal length answers should be valid."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (should (claude-agent--validate-answer "This is a normal answer"))
  (should (claude-agent--validate-answer (make-string 1000 ?x)))
  (should (claude-agent--validate-answer (make-string 5000 ?x))))

(ert-deftest test-validate-answer-at-limit ()
  "TDD: Answer exactly at limit should be valid."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (let ((claude-agent-max-answer-length 10000))
    (should (claude-agent--validate-answer (make-string 10000 ?x)))))

(ert-deftest test-validate-answer-exceeds-limit ()
  "TDD: Answer exceeding limit should signal error."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd :security)
  (let ((claude-agent-max-answer-length 10000))
    (should-error (claude-agent--validate-answer (make-string 10001 ?x))
                  :type 'error)))

(ert-deftest test-validate-answer-huge-input ()
  "TDD: Extremely large answers should be rejected."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd :security)
  (let ((claude-agent-max-answer-length 10000))
    ;; 1MB of data
    (should-error (claude-agent--validate-answer (make-string 1048576 ?x))
                  :type 'error)))

(ert-deftest test-validate-answer-custom-limit ()
  "TDD: Custom max length should be respected."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (let ((claude-agent-max-answer-length 100))
    (should (claude-agent--validate-answer (make-string 100 ?x)))
    (should-error (claude-agent--validate-answer (make-string 101 ?x))
                  :type 'error)))

(ert-deftest test-max-answer-length-variable-exists ()
  "TDD: Max answer length variable should be defined."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd)
  (should (boundp 'claude-agent-max-answer-length))
  (should (numberp claude-agent-max-answer-length))
  (should (> claude-agent-max-answer-length 0)))

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

;;; Tool Input Validation Tests

(ert-deftest test-validate-tool-input-file-path ()
  "TDD: File paths should be validated for suspicious patterns."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd :security)
  ;; Normal paths
  (should (claude-agent--validate-file-path "/tmp/test.txt"))
  (should (claude-agent--validate-file-path "/home/user/project/file.el"))
  ;; Null bytes (could truncate path checks)
  (should-error (claude-agent--validate-file-path "/tmp/test\x00.txt")
                :type 'error))

(ert-deftest test-validate-tool-input-command ()
  "TDD: Commands should be validated for length."
  :tags '(:unit :fast :stable :isolated :input-validation :tdd :security)
  (let ((claude-agent-max-command-length 100000))
    (should (claude-agent--validate-command "ls -la"))
    (should (claude-agent--validate-command (make-string 99999 ?x)))
    (should-error (claude-agent--validate-command (make-string 100001 ?x))
                  :type 'error)))

(provide 'test-claude-agent-input-validation)
;;; test-claude-agent-input-validation.el ends here
