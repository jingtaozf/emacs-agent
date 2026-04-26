;;; org-fixtures.el --- Shared test helpers for code-agent-org tests -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2025 Jingtao Xu

;;; Commentary:

;; Provides shared test helpers to reduce duplication across test files.
;; Use `test-org-with-session' for setting up org buffers with session state.
;; Use `test-org-extract-response-text' for extracting response content.
;; Use `test-org-validate-mock-scenario' for validating mock scenarios.

;;; Code:

(require 'cl-lib)

;;; ============================================================
;;; Buffer and Session Setup Helpers
;;; ============================================================

(defmacro test-org-with-buffer (content &rest body)
  "Execute BODY in a temp org buffer with CONTENT.
Sets up org-mode and positions point at buffer start."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (org-mode)
     (insert ,content)
     (goto-char (point-min))
     ,@body))

(defmacro test-org-with-session (content session-key &rest body)
  "Execute BODY in a temp org buffer with CONTENT and a session for SESSION-KEY.
Initializes the session registry hash table and creates a session."
  (declare (indent 2) (debug t))
  `(with-temp-buffer
     (org-mode)
     (insert ,content)
     (goto-char (point-min))
     (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
     (code-agent-org--get-session ,session-key)
     ,@body))

(defmacro test-org-with-sessions (content &rest body)
  "Execute BODY in a temp org buffer with CONTENT and session registry.
Only initializes the hash table; does not create any session."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (org-mode)
     (insert ,content)
     (goto-char (point-min))
     (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
     ,@body))

;;; ============================================================
;;; Response Text Extraction
;;; ============================================================

(defun test-org-extract-response-text (content heading-pattern)
  "Extract response text from CONTENT under heading matching HEADING-PATTERN.
Skips PROPERTIES drawers and returns the body text.
HEADING-PATTERN is a regexp to match the heading line."
  (with-temp-buffer
    (org-mode)
    (insert content)
    (goto-char (point-min))
    (when (re-search-forward heading-pattern nil t)
      (forward-line 1)
      (let ((start (point))
            (end (save-excursion
                   (if (re-search-forward "^\\*+ " nil t)
                       (line-beginning-position)
                     (point-max)))))
        ;; Skip PROPERTIES drawer if present
        (when (looking-at "[ \t]*:PROPERTIES:")
          (re-search-forward ":END:" end t)
          (forward-line 1)
          (setq start (point)))
        ;; Trim whitespace
        (string-trim
         (buffer-substring-no-properties start end))))))

;;; ============================================================
;;; Mock Scenario Validation
;;; ============================================================

(defvar test-org-mock-scenarios-dir
  (expand-file-name "fixtures/mock-scenarios/"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing mock scenario JSONL files.")

(defun test-org-validate-mock-scenario (scenario-name)
  "Validate that mock SCENARIO-NAME exists as a .jsonl file.
Returns the full path if valid, signals error if not found."
  (let ((file (expand-file-name (concat scenario-name ".jsonl")
                                test-org-mock-scenarios-dir)))
    (unless (file-exists-p file)
      (error "Mock scenario not found: %s (expected at %s)" scenario-name file))
    file))

;;; ============================================================
;;; Common Assertion Helpers
;;; ============================================================

(defun test-org-session-field-eq (session-key field expected)
  "Assert that session SESSION-KEY's FIELD equals EXPECTED."
  (let ((actual (code-agent-org--session-get session-key field)))
    (should (equal expected actual))))

(defun test-org-session-field-nil (session-key field)
  "Assert that session SESSION-KEY's FIELD is nil."
  (should-not (code-agent-org--session-get session-key field)))

(provide 'org-fixtures)
;;; org-fixtures.el ends here
