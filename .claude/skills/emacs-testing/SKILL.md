---
name: emacs-testing
description: Test Emacs Lisp code using ERT (Emacs Lisp Regression Testing) - provides patterns for unit tests, integration tests, and test-driven development
allowed-tools: [mcp__emacs__evalElisp]
---

# Emacs Lisp Testing Skill

This skill teaches testing patterns for Emacs Lisp using ERT and related tools.

## When to Use This Skill

Use when:
- Writing unit tests for elisp functions
- Setting up test suites for packages
- Running tests programmatically
- Mocking/stubbing dependencies
- Testing interactive commands

## ERT Basics

### Define a Test

```elisp
(require 'ert)

(ert-deftest my-function-test ()
  "Test that my-function works correctly."
  (should (equal (my-function 1 2) 3))
  (should-not (my-function nil nil))
  (should-error (my-function "bad" "args")))
```

### Assertion Macros

```elisp
;; Basic assertions
(should FORM)                    ; FORM should be non-nil
(should-not FORM)                ; FORM should be nil
(should-error FORM)              ; FORM should signal an error

;; Error type checking
(should-error FORM :type 'wrong-type-argument)

;; Custom failure message (via test name/docstring)
(ert-deftest descriptive-test-name ()
  "Clear description of what this tests."
  (should ...))
```

### Run Tests

```elisp
;; Run all tests
(ert-run-tests-batch-and-exit)

;; Run specific test
(ert-run-tests-interactively "my-function-test")

;; Run tests matching pattern
(ert-run-tests-batch "^my-package-")

;; Run and get results programmatically
(let ((results (ert-run-tests-batch "^test-")))
  (list :passed (ert-stats-completed-expected results)
        :failed (ert-stats-completed-unexpected results)
        :total (ert-stats-total results)))
```

## Test Organization

### Test File Structure

```elisp
;;; test-my-package.el --- Tests for my-package -*- lexical-binding: t -*-

(require 'ert)
(require 'my-package)

;;; Helper functions

(defun test-helper-setup ()
  "Set up test environment."
  ...)

;;; Unit tests

(ert-deftest test-my-package-basic ()
  "Test basic functionality."
  ...)

(ert-deftest test-my-package-edge-cases ()
  "Test edge cases."
  ...)

;;; Integration tests

(ert-deftest test-my-package-integration ()
  "Test component integration."
  ...)

(provide 'test-my-package)
;;; test-my-package.el ends here
```

### Test Fixtures (Setup/Teardown)

```elisp
(ert-deftest test-with-temp-buffer ()
  "Test using temporary buffer."
  (with-temp-buffer
    (insert "test content")
    (should (equal (buffer-string) "test content"))))

(ert-deftest test-with-temp-file ()
  "Test using temporary file."
  (let ((temp-file (make-temp-file "test-")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "test data"))
          (should (file-exists-p temp-file)))
      (delete-file temp-file))))
```

### Shared Fixtures

```elisp
(defvar test-fixture nil)

(defun test-setup ()
  "Run before each test."
  (setq test-fixture (create-test-data)))

(defun test-teardown ()
  "Run after each test."
  (cleanup-test-data test-fixture)
  (setq test-fixture nil))

(ert-deftest test-with-fixture ()
  "Test using shared fixture."
  (test-setup)
  (unwind-protect
      (should (valid-fixture-p test-fixture))
    (test-teardown)))
```

## Mocking and Stubbing

### Using cl-letf for Mocking

```elisp
(require 'cl-lib)

(ert-deftest test-with-mock ()
  "Test with mocked function."
  (cl-letf (((symbol-function 'external-api-call)
             (lambda (arg) (format "mocked: %s" arg))))
    (should (equal (my-function-using-api "test")
                   "mocked: test"))))
```

### Mock Return Values

```elisp
(ert-deftest test-mock-return-sequence ()
  "Test with sequential return values."
  (let ((call-count 0))
    (cl-letf (((symbol-function 'get-next-item)
               (lambda ()
                 (cl-incf call-count)
                 (nth (1- call-count) '("first" "second" "third")))))
      (should (equal (get-next-item) "first"))
      (should (equal (get-next-item) "second"))
      (should (equal (get-next-item) "third")))))
```

### Verify Function Calls

```elisp
(ert-deftest test-verify-calls ()
  "Verify function was called with expected args."
  (let ((call-log nil))
    (cl-letf (((symbol-function 'tracked-function)
               (lambda (&rest args) (push args call-log))))
      (my-function-that-calls-tracked)
      (should (equal (length call-log) 1))
      (should (equal (car call-log) '("expected" "args"))))))
```

## Testing Async Code

### Test Timers

```elisp
(ert-deftest test-timer-callback ()
  "Test that timer callback is set up correctly."
  (let ((timer (my-function-with-timer)))
    (unwind-protect
        (progn
          (should (timerp timer))
          (should (equal (timer--function timer) #'expected-callback)))
      (cancel-timer timer))))
```

### Test Process Output

```elisp
(ert-deftest test-process-filter ()
  "Test process filter handles output."
  (let ((output-received nil))
    (cl-letf (((symbol-function 'handle-output)
               (lambda (out) (setq output-received out))))
      (my-process-filter nil "test output")
      (should (equal output-received "test output")))))
```

## Testing Interactive Commands

### Simulate User Input

```elisp
(ert-deftest test-interactive-command ()
  "Test interactive command."
  (let ((read-string-result "user input"))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) read-string-result)))
      (should (equal (call-interactively 'my-command)
                     "processed: user input")))))
```

### Test Buffer Changes

```elisp
(ert-deftest test-command-modifies-buffer ()
  "Test that command modifies buffer correctly."
  (with-temp-buffer
    (insert "original")
    (goto-char (point-min))
    (my-transform-command)
    (should (equal (buffer-string) "transformed"))))
```

## Running Tests from MCP

### Run All Package Tests

```elisp
;; Load test file and run
(load-file "/path/to/test-my-package.el")
(let ((ert-quiet t))  ; Suppress interactive output
  (ert-run-tests-batch "^test-my-package-"))
```

### Get Test Results as Data

```elisp
(defun run-tests-get-results (selector)
  "Run tests matching SELECTOR and return results."
  (let* ((stats (ert-run-tests-batch selector))
         (passed (ert-stats-completed-expected stats))
         (failed (ert-stats-completed-unexpected stats)))
    (list :selector selector
          :passed passed
          :failed failed
          :total (+ passed failed)
          :success (= failed 0))))

(run-tests-get-results "^test-claude-")
```

### Run Single Test

```elisp
(defun run-single-test (test-name)
  "Run single test and return result."
  (let ((result (ert-run-test (ert-get-test test-name))))
    (list :name test-name
          :status (ert-test-result-type-p result :passed)
          :duration (ert-test-result-duration result))))
```

## Test-Driven Development Pattern

```elisp
;; 1. Write failing test first
(ert-deftest test-new-feature ()
  "Test the new feature."
  (should (equal (new-feature "input") "expected")))

;; 2. Run test - should fail
;; (ert-run-tests-interactively "test-new-feature")

;; 3. Implement minimal code to pass
(defun new-feature (input)
  "Implement new feature."
  "expected")

;; 4. Run test - should pass
;; 5. Refactor if needed, keeping tests passing
```

## Quick Reference

| Task | Code |
|------|------|
| Define test | `(ert-deftest name () (should ...))` |
| Run all | `(ert-run-tests-batch-and-exit)` |
| Run pattern | `(ert-run-tests-batch "^prefix-")` |
| Assert true | `(should FORM)` |
| Assert nil | `(should-not FORM)` |
| Assert error | `(should-error FORM)` |
| Mock function | `(cl-letf (((symbol-function 'f) #'mock)) ...)` |
| Temp buffer | `(with-temp-buffer ...)` |
| Temp file | `(make-temp-file "prefix")` |
