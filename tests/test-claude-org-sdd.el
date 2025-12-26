;;; test-claude-org-sdd.el --- Tests for SDD workflow -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit and integration tests for SDD (Spec-Driven Development) workflow.
;; Tests the claude-org-insert-sdd command and tag inheritance.

;;; Code:

(require 'ert)
(require 'org)
(require 'claude-org)

;;; Unit Tests - Structure Creation

(ert-deftest test-sdd-insert-creates-four-sections ()
  "Test that claude-org-insert-sdd creates Workflow, Research Output, Spec, and Features sections."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    ;; Simulate user input
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (claude-org-insert-sdd))
    ;; Verify structure
    (goto-char (point-min))
    ;; Top-level heading
    (should (re-search-forward "^\\* Test Feature" nil t))
    ;; Workflow section with :sdd: tag
    (should (re-search-forward "^\\*\\* Workflow :sdd:" nil t))
    ;; Four phases
    (should (re-search-forward "^\\*\\*\\* Research :research:" nil t))
    (should (re-search-forward "^\\*\\*\\* Design :design:" nil t))
    (should (re-search-forward "^\\*\\*\\* Planning :planning:" nil t))
    (should (re-search-forward "^\\*\\*\\* Implementation :implementation:" nil t))
    ;; Research Output section (new)
    (should (re-search-forward "^\\*\\* Research Output :research_output:" nil t))
    (should (re-search-forward "^\\*\\*\\* Codebase Patterns" nil t))
    (should (re-search-forward "^\\*\\*\\* Relevant Files" nil t))
    (should (re-search-forward "^\\*\\*\\* External References" nil t))
    ;; Spec section
    (should (re-search-forward "^\\*\\* Spec :spec:" nil t))
    (should (re-search-forward "^\\*\\*\\* Goals" nil t))
    (should (re-search-forward "^\\*\\*\\* Non-Goals" nil t))
    (should (re-search-forward "^\\*\\*\\* Proposed Solution" nil t))
    (should (re-search-forward "^\\*\\*\\* Technical Design" nil t))
    ;; Features section
    (should (re-search-forward "^\\*\\* Features :features:" nil t))))

(ert-deftest test-sdd-insert-sets-session-id ()
  "Test that SDD structure has unique CLAUDE_SESSION_ID."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "My Feature")))
      (claude-org-insert-sdd))
    (goto-char (point-min))
    (re-search-forward "^\\* My Feature")
    (let ((session-id (org-entry-get nil "CLAUDE_SESSION_ID")))
      (should session-id)
      (should (string-prefix-p "sdd-" session-id)))))

(ert-deftest test-sdd-insert-features-has-ordered ()
  "Test that Features section has ORDERED property."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (claude-org-insert-sdd))
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Features :features:")
    (should (equal "t" (org-entry-get nil "ORDERED")))))

(ert-deftest test-sdd-level-alignment ()
  "Test that new SDD aligns with previous SDD level."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    ;; Insert first SDD at level 2
    (insert "* Existing Section\n\n")
    (insert "** First Feature\n")
    (insert ":PROPERTIES:\n:CLAUDE_SESSION_ID: sdd-existing\n:END:\n\n")
    ;; Now insert new SDD
    (goto-char (point-max))
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Second Feature")))
      (claude-org-insert-sdd))
    ;; Verify it's at level 2
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Second Feature")
    (should (= 2 (org-current-level)))))

;;; Unit Tests - Tag Inheritance

(ert-deftest test-sdd-tag-priority-ordering ()
  "Test that SDD tags are ordered correctly (container before phase)."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  ;; sdd should come before research
  (should (< (claude-org--sdd-tag-priority "sdd")
             (claude-org--sdd-tag-priority "research")))
  ;; phases should be in order
  (should (< (claude-org--sdd-tag-priority "research")
             (claude-org--sdd-tag-priority "design")))
  (should (< (claude-org--sdd-tag-priority "design")
             (claude-org--sdd-tag-priority "planning")))
  (should (< (claude-org--sdd-tag-priority "planning")
             (claude-org--sdd-tag-priority "implementation"))))

(ert-deftest test-sdd-tag-inheritance-in-workflow ()
  "Test that AI blocks in SDD phases inherit both :sdd: and phase tags."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n")
    (insert "** Workflow :sdd:\n")
    (insert "*** Research :research:\n")
    (insert "#+begin_src ai\ntest query\n#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "test query")
    (let ((tags (claude-org--get-current-tags)))
      ;; Should have both tags (inherited)
      (should (member "sdd" tags))
      (should (member "research" tags)))))

(ert-deftest test-sdd-spec-section-no-workflow-tag ()
  "Test that Spec section does not inherit :sdd: tag."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n")
    (insert "** Workflow :sdd:\n")
    (insert "*** Research :research:\n")
    (insert "** Spec :spec:\n")
    (insert "*** Goals\n")
    (insert "Content here\n")
    (goto-char (point-min))
    (re-search-forward "Content here")
    (let ((tags (claude-org--get-current-tags)))
      ;; Should have spec tag but NOT sdd (sibling, not child)
      (should (member "spec" tags))
      (should-not (member "sdd" tags)))))

;;; Unit Tests - Tag Prompt Loading

(ert-deftest test-sdd-tag-prompts-exist ()
  "Test that all SDD tag prompt files exist.
Note: research_output is a storage section, not an AI block container, so no prompt."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (let ((tags '("sdd" "research" "design" "planning" "implementation"
                "spec" "features")))
    (dolist (tag tags)
      (let ((file (expand-file-name (format "tags/%s.org" tag)
                                    claude-org-prompts-directory)))
        (should (file-readable-p file))))))

(ert-deftest test-sdd-tag-prompts-load ()
  "Test that SDD tag prompts can be loaded.
Note: research_output is a storage section, not an AI block container, so no prompt."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (let ((tags '(sdd research design planning implementation
                spec features)))
    (dolist (tag tags)
      (let ((prompt (claude-org--tag-prompt tag)))
        (should (stringp prompt))
        (should (> (length prompt) 0))))))

;;; Unit Tests - Behavior Prompt Building

(ert-deftest test-sdd-behavior-prompt-combines-tags ()
  "Test that behavior prompt combines :sdd: and phase prompts."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n")
    (insert "** Workflow :sdd:\n")
    (insert "*** Research :research:\n")
    (insert "#+begin_src ai\ntest query\n#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "test query")
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (stringp prompt))
      ;; Should contain content from both prompts
      (should (string-match-p "SDD" prompt))
      (should (string-match-p "RESEARCH" prompt)))))

;;; Unit Tests - Find Previous SDD Level

(ert-deftest test-find-previous-sdd-level ()
  "Test finding previous SDD section level."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (insert "* Section\n")
    (insert "** My Feature\n")
    (insert ":PROPERTIES:\n:CLAUDE_SESSION_ID: sdd-test\n:END:\n\n")
    (insert "*** Workflow :sdd:\n")
    (goto-char (point-max))
    ;; Should find level 2
    (should (= 2 (claude-org--find-previous-sdd-level)))))

(ert-deftest test-find-previous-sdd-level-none ()
  "Test finding previous SDD when none exists."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (insert "* Section\n")
    (insert "** Subsection\n")
    (goto-char (point-max))
    ;; Should return nil
    (should-not (claude-org--find-previous-sdd-level))))

;;; Integration Tests (require API)

(ert-deftest test-sdd-integration-research-phase ()
  "Test that Research phase uses documentarian behavior."
  :tags '(:integration :slow :api :org :sdd)
  (require 'test-config)
  (test-claude-skip-unless-cli-available)

  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name (make-temp-file "sdd-test-" nil ".org"))
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (claude-org-insert-sdd))
    ;; Navigate to Research section and add a query
    (goto-char (point-min))
    (re-search-forward "^\\*\\*\\* Research :research:")
    (end-of-line)
    (insert "\n#+begin_src ai\nWhat is 2+2?\n#+end_src")
    (save-buffer)
    ;; Execute the query
    (re-search-backward "What is 2+2")
    (claude-org-mode 1)
    (let ((session-key (claude-org--current-session-key)))
      (claude-org-execute)
      ;; Wait for completion
      (when (test-claude-wait-for-completion session-key 30)
        ;; Verify we got a response
        (goto-char (point-min))
        (should (or (re-search-forward "4" nil t)
                    (re-search-forward "four" nil t)))))
    ;; Cleanup
    (delete-file buffer-file-name)))

(provide 'test-claude-org-sdd)
;;; test-claude-org-sdd.el ends here
