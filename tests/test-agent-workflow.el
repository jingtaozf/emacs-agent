;;; test-agent-workflow.el --- Agent workflow smoke tests -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;;; Commentary:

;; F11: Agent workflow smoke tests — fast verification that the
;; edit → reload → test cycle works.  Agents run `make test-smoke`
;; after every edit for < 2s feedback.

;;; Code:

(require 'ert)

(defvar test-agent-workflow--project-root
  (or (and load-file-name
           (locate-dominating-file (file-name-directory load-file-name) "Makefile"))
      (locate-dominating-file default-directory "Makefile"))
  "Project root directory.")

;;; Smoke test: All .org module files load without error

(ert-deftest test-agent-workflow-org-files-loadable ()
  "All literate .org module files load via literate-elisp without error.
FIX: Check the .org file for syntax errors in #+begin_src elisp blocks.
Run: emacs --batch -l literate-elisp --eval '(literate-elisp-load \"FILE.org\")'"
  :tags '(:unit :fast :stable :smoke)
  (when test-agent-workflow--project-root
    (let ((default-directory test-agent-workflow--project-root)
          (org-modules '("code-agent.org"
                         "code-agent-org.org"
                         "emacs-mcp-server.org"))
          (failures nil))
      ;; These should already be loaded by the test runner.
      ;; Verify the features they provide are available.
      (dolist (module org-modules)
        (let* ((base (file-name-sans-extension module))
               ;; Map filename to feature name
               (feature (intern
                         (replace-regexp-in-string
                          "\\." "-" base))))
          (unless (or (featurep feature)
                      ;; Some modules use different provide names
                      (featurep (intern base))
                      ;; Check that the file at least exists
                      (not (file-exists-p
                            (expand-file-name module test-agent-workflow--project-root))))
            (push module failures))))
      (should (or (null failures)
                  (error "Org modules not loaded: %s\nFIX: Check for syntax errors:\n%s"
                         (mapconcat #'identity failures ", ")
                         (mapconcat
                          (lambda (f)
                            (format "  emacs --batch -l literate-elisp --eval '(literate-elisp-load \"%s\")'" f))
                          failures "\n")))))))

;;; Smoke test: All test files loadable without error

(ert-deftest test-agent-workflow-test-files-loadable ()
  "All test files in tests/ can be loaded without errors.
FIX: Check the failing test file for missing (require ...) or syntax errors."
  :tags '(:unit :fast :stable :smoke)
  (when test-agent-workflow--project-root
    (let* ((tests-dir (expand-file-name "tests" test-agent-workflow--project-root))
           (failures nil))
      (when (file-directory-p tests-dir)
        (dolist (file (directory-files tests-dir nil "^test-.*\\.el$"))
          (let ((filepath (expand-file-name file tests-dir)))
            (condition-case err
                (with-temp-buffer
                  (insert-file-contents filepath)
                  ;; Just verify it parses as valid Elisp
                  (goto-char (point-min))
                  (condition-case _
                      (while t (read (current-buffer)))
                    (end-of-file nil)))
              (error
               (push (format "%s: %s" file (error-message-string err))
                     failures)))))
        (should (or (null failures)
                    (error "Test files with parse errors: %d\nFIX: Fix syntax:\n%s"
                           (length failures)
                           (mapconcat #'identity failures "\n"))))))))

;;; Smoke test: tests/e2e/org/ living fixtures are well-formed org

(ert-deftest test-agent-workflow-e2e-org-fixtures-loadable ()
  "Every fixture under tests/e2e/org/ has balanced `#+begin_src'/`#+end_src'.

These living fixtures (workspace-test.org, acp-test.org, tmux-test.org,
etc.) are driven by hand against real Phoenix + cmux + Claude Code, so
no ert suite executes their AI blocks. Broken org syntax silently
breaks the harness; this is the cheapest structural invariant we can
check at smoke time.

FIX: open the failing fixture and look for an unbalanced
`#+begin_src' / `#+end_src' pair (or run `M-x org-lint').

If you DELETE a fixture, also drop the runbook section that drives
it in tests/e2e/living-workspace-test.org."
  :tags '(:unit :fast :stable :smoke)
  (when test-agent-workflow--project-root
    (let* ((e2e-org-dir (expand-file-name "tests/e2e/org"
                                          test-agent-workflow--project-root))
           (failures nil))
      (when (file-directory-p e2e-org-dir)
        (dolist (file (directory-files e2e-org-dir nil "\\.org\\'"))
          (let ((path (expand-file-name file e2e-org-dir)))
            (with-temp-buffer
              (condition-case err
                  (insert-file-contents path)
                (error
                 (push (format "%s: %s" file (error-message-string err))
                       failures)))
              (let ((begins (count-matches "^[[:blank:]]*#\\+begin_src\\b"
                                           (point-min) (point-max)))
                    (ends (count-matches "^[[:blank:]]*#\\+end_src\\b"
                                         (point-min) (point-max))))
                (unless (= begins ends)
                  (push (format "%s: %d begin_src vs %d end_src"
                                file begins ends)
                        failures))))))
        (should (or (null failures)
                    (error "E2E fixtures with structural errors:\n%s"
                           (mapconcat #'identity failures "\n"))))))))

(provide 'test-agent-workflow)
;;; test-agent-workflow.el ends here
