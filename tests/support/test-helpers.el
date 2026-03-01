;;; test-helpers.el --- Shared test helper macros -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;;; Commentary:

;; Common test helper macros shared across test files.
;; F2: Remediation-aware test error helpers.

;;; Code:

(require 'ert)

(defmacro should-with-fix (form fix-message)
  "Assert FORM is non-nil, appending FIX-MESSAGE on failure.
FIX-MESSAGE should explain how to fix the violation.

Example:
  (should-with-fix (documentation sym)
    (format \"FIX: Add docstring to `%s'\" sym))"
  (declare (indent 1) (debug t))
  `(should (or ,form
               (error "Assertion failed: %S\n%s" ',form ,fix-message))))

(provide 'test-helpers)
;;; test-helpers.el ends here
