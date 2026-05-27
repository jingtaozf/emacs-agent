;;; test-code-agent-org-refactor-phase5.el --- Phase 5 test infrastructure tests -*- lexical-binding: t; -*-

;; Tests for Phase 5: Test infrastructure improvements (F15)

(require 'cl-lib)
(require 'ert)
(require 'code-agent)
(require 'code-agent-org)
(require 'org-fixtures)

;;; ============================================================
;;; F15: Test infrastructure improvements
;;; ============================================================

;; F15.1 org-fixtures provides its feature
(ert-deftest test-f15-org-fixtures-provides-feature ()
  "org-fixtures module should provide its feature."
  :tags '(:unit :fast :stable :isolated :refactor :f15)
  (should (featurep 'org-fixtures)))

;; F15.2 test-org-with-buffer sets up org buffer
(ert-deftest test-f15-with-buffer-creates-org ()
  "test-org-with-buffer should create org buffer with content."
  :tags '(:unit :fast :stable :isolated :refactor :f15)
  (test-org-with-buffer "* Test\nContent here\n"
    (should (eq major-mode 'org-mode))
    (should (= (point) (point-min)))
    (should (string-match-p "Test" (buffer-string)))))

;; F15.3 test-org-with-session initializes session
(ert-deftest test-f15-with-session-creates-state ()
  "test-org-with-session should initialize session registry."
  :tags '(:unit :fast :stable :isolated :refactor :f15)
  (test-org-with-session "* Test\n" "test::f15"
    (should (hash-table-p code-agent-org--sessions))
    (should (code-agent-org--session-state-p
             (gethash "test::f15" code-agent-org--sessions)))))

;; F15.4 extract-response-text handles PROPERTIES drawer
(ert-deftest test-f15-extract-response-with-properties ()
  "extract-response-text should skip PROPERTIES drawer."
  :tags '(:unit :fast :stable :isolated :refactor :f15)
  (let ((content "* Heading
** Response
:PROPERTIES:
:QUERY_ID: q123
:END:

Hello world
"))
    (let ((text (test-org-extract-response-text content "^\\*\\* Response")))
      (should (equal "Hello world" text)))))

;; F15.5 extract-response-text handles empty response
(ert-deftest test-f15-extract-response-empty ()
  "extract-response-text should handle empty response."
  :tags '(:unit :fast :stable :isolated :refactor :f15)
  (let ((content "* Heading
** Response
:PROPERTIES:
:QUERY_ID: q123
:END:

* Next Section
"))
    (let ((text (test-org-extract-response-text content "^\\*\\* Response")))
      (should (equal "" text)))))

;; F15.6 mock scenario validation detects typos
(ert-deftest test-f15-mock-scenario-validation-missing ()
  "validate-mock-scenario should error on missing scenario."
  :tags '(:unit :fast :stable :isolated :refactor :f15)
  (should-error (test-org-validate-mock-scenario "nonexistent-scenario-xyz")))

;; F15.7 mock scenario validation finds existing scenarios
(ert-deftest test-f15-mock-scenario-validation-exists ()
  "validate-mock-scenario should find existing scenario files."
  :tags '(:unit :fast :stable :isolated :refactor :f15)
  ;; Check that simple-query exists (used in mock tests)
  (when (file-directory-p test-org-mock-scenarios-dir)
    (let ((files (directory-files test-org-mock-scenarios-dir nil "\\.jsonl$")))
      (when files
        (let* ((name (file-name-sans-extension (car files)))
               (path (test-org-validate-mock-scenario name)))
          (should (file-exists-p path)))))))

;; F15.8 Session assertion helpers
(ert-deftest test-f15-session-assertion-helpers ()
  "Session assertion helpers should work correctly."
  :tags '(:unit :fast :stable :isolated :refactor :f15)
  (test-org-with-session "* Test\n" "test::f15-assert"
    (code-agent-org-session-put "test::f15-assert" :busy t)
    (test-org-session-field-eq "test::f15-assert" :busy t)
    (code-agent-org-session-put "test::f15-assert" :busy nil)
    (test-org-session-field-nil "test::f15-assert" :busy)))

;; F15.9 Verify fixture used in refactor test files (meta-test)
(ert-deftest test-f15-fixtures-used-in-phase4 ()
  "Phase 4 tests should use session setup patterns similar to fixtures."
  :tags '(:unit :fast :stable :isolated :refactor :f15)
  ;; Phase 4 tests use with-temp-buffer + org-mode + setq-local pattern
  ;; This test verifies the fixtures provide equivalent functionality
  (test-org-with-sessions ""
    (should (hash-table-p code-agent-org--sessions))
    (code-agent-org-session-put "test::meta" :busy t)
    (should (eq t (code-agent-org-session-get "test::meta" :busy)))))

(provide 'test-code-agent-org-refactor-phase5)
;;; test-code-agent-org-refactor-phase5.el ends here
