;;; test-claude-org-sdd.el --- Tests for SDD workflow -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit and integration tests for SDD (Spec-Driven Development) workflow.
;; Tests the claude-org-insert-sdd command and tag inheritance.
;;
;; SDD notebook structure: System Prompt + Workflow only.
;; Knowledge artifacts (research, spec, features) live in docs/ folder.

;;; Code:

(require 'ert)
(require 'org)
(require 'claude-org)

;;; Unit Tests - Structure Creation

(ert-deftest test-sdd-insert-creates-system-prompt-first ()
  "Test that claude-org-insert-sdd creates System Prompt as the first subsection.
The default content should indicate the current SDD story name."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "My SDD Story")))
      (claude-org-insert-sdd))
    ;; Verify System Prompt exists with :system_prompt: tag
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\* System Prompt :system_prompt:" nil t))
    ;; Verify it has CUSTOM_ID
    (should (org-entry-get nil "CUSTOM_ID"))
    ;; Verify it comes BEFORE Workflow (first subsection)
    (let ((system-prompt-pos (point)))
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\* Workflow :sdd:" nil t))
      (let ((workflow-pos (point)))
        (should (< system-prompt-pos workflow-pos))))
    ;; Verify default content contains the SDD story name
    (goto-char (point-min))
    (re-search-forward "^\\*\\* System Prompt :system_prompt:")
    (forward-line 1)
    ;; Skip past PROPERTIES drawer
    (when (looking-at ":PROPERTIES:")
      (re-search-forward ":END:" nil t)
      (forward-line 1))
    ;; Should find the default content with the story name
    (should (re-search-forward "The current SDD story is \"My SDD Story\"" nil t))))

(ert-deftest test-sdd-insert-creates-two-notebook-sections ()
  "Test that claude-org-insert-sdd creates only System Prompt and Workflow sections.
Research Output, Spec, and Features now live in docs/ folder, not the notebook."
  :tags '(:unit :fast :stable :isolated :org :sdd :tdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (claude-org-insert-sdd))
    ;; Verify structure - only 2 sections in notebook
    (goto-char (point-min))
    ;; Top-level heading
    (should (re-search-forward "^\\* Test Feature" nil t))
    ;; System Prompt section
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\* System Prompt :system_prompt:" nil t))
    (should (org-entry-get nil "CUSTOM_ID"))
    ;; Workflow section with :sdd: tag and CUSTOM_ID
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\* Workflow :sdd:" nil t))
    (should (org-entry-get nil "CUSTOM_ID"))
    ;; AI block under Workflow
    (goto-char (point-min))
    (let ((tag-pattern (format ":%s:" claude-org-heading-tag)))
      (should (re-search-forward (format "^\\*\\*\\* Instruction 1 .*%s" tag-pattern) nil t))
      (should (re-search-forward "^#\\+begin_src ai" nil t)))
    ;; MUST NOT have Research Output, Spec, or Features sections
    (goto-char (point-min))
    (should-not (re-search-forward "^\\*\\* Research Output" nil t))
    (goto-char (point-min))
    (should-not (re-search-forward "^\\*\\* Spec" nil t))
    (goto-char (point-min))
    (should-not (re-search-forward "^\\*\\* Features" nil t))))

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

(ert-deftest test-sdd-insert-creates-docs-files ()
  "Test that claude-org-insert-sdd creates research and design-doc files in docs/."
  :tags '(:unit :fast :stable :isolated :org :sdd :tdd)
  (let ((default-directory (make-temp-file "sdd-test-project-" t)))
    (unwind-protect
        (progn
          ;; Create docs/ structure
          (make-directory (expand-file-name "docs/research") t)
          (make-directory (expand-file-name "docs/design-docs") t)
          (with-temp-file (expand-file-name "docs/research/INDEX.md")
            (insert "# Research Index\n\n| Date | Title | Status | SDD Session |\n|------|-------|--------|-------------|\n"))
          (with-temp-file (expand-file-name "docs/design-docs/INDEX.md")
            (insert "# Design Docs Index\n\n| Date | Title | Status | SDD Session |\n|------|-------|--------|-------------|\n"))
          (with-temp-buffer
            (org-mode)
            (setq buffer-file-name (expand-file-name "notebook.org"))
            (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
              (claude-org-insert-sdd))
            ;; Verify docs files were created
            (let* ((session-id (save-excursion
                                 (goto-char (point-min))
                                 (re-search-forward "^\\* Test Feature")
                                 (org-entry-get nil "CLAUDE_SESSION_ID")))
                   (year (substring session-id 4 8))
                   (slug "test-feature")
                   (research-file (expand-file-name
                                   (format "docs/research/%s-%s.org" year slug)))
                   (design-file (expand-file-name
                                 (format "docs/design-docs/%s-%s.org" year slug))))
              (should (file-exists-p research-file))
              (should (file-exists-p design-file))
              ;; Verify research file has correct structure
              (with-temp-buffer
                (insert-file-contents research-file)
                (should (string-match-p "TITLE.*Research.*Test Feature" (buffer-string)))
                (should (string-match-p "SDD_SESSION" (buffer-string))))
              ;; Verify design doc has correct structure
              (with-temp-buffer
                (insert-file-contents design-file)
                (should (string-match-p "TITLE.*Design.*Test Feature" (buffer-string)))
                (should (string-match-p "Goals" (buffer-string)))
                (should (string-match-p "Features" (buffer-string)))))))
      ;; Cleanup
      (delete-directory default-directory t))))

(ert-deftest test-sdd-insert-system-prompt-includes-docs-paths ()
  "Test that System Prompt default content includes docs/ file paths."
  :tags '(:unit :fast :stable :isolated :org :sdd :tdd)
  (let ((default-directory (make-temp-file "sdd-test-project-" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "docs/research") t)
          (make-directory (expand-file-name "docs/design-docs") t)
          (with-temp-file (expand-file-name "docs/research/INDEX.md")
            (insert "# Research Index\n\n| Date | Title | Status | SDD Session |\n|------|-------|--------|-------------|\n"))
          (with-temp-file (expand-file-name "docs/design-docs/INDEX.md")
            (insert "# Design Docs Index\n\n| Date | Title | Status | SDD Session |\n|------|-------|--------|-------------|\n"))
          (with-temp-buffer
            (org-mode)
            (setq buffer-file-name (expand-file-name "notebook.org"))
            (cl-letf (((symbol-function 'read-string) (lambda (_) "My Story")))
              (claude-org-insert-sdd))
            ;; System Prompt should reference docs/ files
            (goto-char (point-min))
            (re-search-forward "^\\*\\* System Prompt :system_prompt:")
            (let ((section-end (save-excursion (org-end-of-subtree t) (point))))
              (should (re-search-forward "docs/research/" section-end t))
              (goto-char (point-min))
              (re-search-forward "^\\*\\* System Prompt :system_prompt:")
              (should (re-search-forward "docs/design-docs/" section-end t)))))
      (delete-directory default-directory t))))

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

(ert-deftest test-sdd-cursor-in-first-ai-block ()
  "Test that cursor is positioned inside the first AI block after insert."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (claude-org-insert-sdd))
    ;; Cursor should be between begin_src and end_src
    (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
      ;; Should be on empty line inside the src block
      (should (string= "" line)))
    ;; Previous line should be #+begin_src ai
    (forward-line -1)
    (should (looking-at "^#\\+begin_src ai"))
    ;; Next line (from original pos) should be #+end_src
    (forward-line 2)
    (should (looking-at "^#\\+end_src"))))

(ert-deftest test-sdd-single-ai-block ()
  "Test that simplified SDD has exactly one AI block under Workflow."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (claude-org-insert-sdd))
    (goto-char (point-min))
    ;; Count AI blocks - should be 1 (only under Workflow, no phase subsections)
    (let ((count 0))
      (while (re-search-forward "^#\\+begin_src ai" nil t)
        (setq count (1+ count)))
      (should (= 1 count)))))

;;; Unit Tests - Tag Selection

(ert-deftest test-sdd-tag-toggle ()
  "Test tag toggling for block insertion."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  ;; Clear any previous state
  (setq claude-org--selected-tags nil)
  ;; Toggle on
  (claude-org--toggle-tag "research")
  (should (member "research" claude-org--selected-tags))
  ;; Toggle off
  (claude-org--toggle-tag "research")
  (should-not (member "research" claude-org--selected-tags))
  ;; Multiple tags
  (claude-org--toggle-tag "research")
  (claude-org--toggle-tag "design")
  (should (member "research" claude-org--selected-tags))
  (should (member "design" claude-org--selected-tags))
  ;; Cleanup
  (setq claude-org--selected-tags nil))

(ert-deftest test-sdd-block-with-workflow-tags ()
  "Test inserting block with workflow tags."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (insert "* Feature\n** Workflow :sdd:\n")
    (goto-char (point-max))
    ;; Insert block with research and design tags
    (claude-org--do-insert-block '("research" "design"))
    (goto-char (point-min))
    ;; Verify tags are present
    (should (re-search-forward ":research:" nil t))
    (goto-char (point-min))
    (should (re-search-forward ":design:" nil t))
    (goto-char (point-min))
    (should (re-search-forward (format ":%s:" claude-org-heading-tag) nil t))))

(ert-deftest test-sdd-block-without-tags ()
  "Test inserting block without workflow tags."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (insert "* Feature\n** Workflow :sdd:\n")
    (goto-char (point-max))
    ;; Insert block with no workflow tags
    (claude-org--do-insert-block nil)
    (goto-char (point-min))
    ;; Should only have claude-org-heading-tag, not workflow tags
    (should (re-search-forward (format ":%s:" claude-org-heading-tag) nil t))
    (goto-char (point-min))
    (should-not (re-search-forward ":research:" nil t))
    (should-not (re-search-forward ":design:" nil t))))

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

(ert-deftest test-sdd-tag-inheritance-for-behavior-prompt ()
  "Test that tags are inherited from parent headings for behavior prompts.
This is the critical test for the bug where :sdd: and :research: tags
were not inherited because org-get-tags was called with LOCAL=t."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    ;; Create nested structure with tags at different levels
    (insert "* Feature\n")
    (insert "** Workflow :sdd:\n")
    (insert "*** Research :research:\n")
    (insert "**** Instruction 1 :claude_chat:\n")
    (insert "#+begin_src ai\ntest query\n#+end_src\n")
    ;; Position inside the ai block
    (goto-char (point-min))
    (re-search-forward "test query")
    ;; Verify tag inheritance
    (let ((tags (claude-org--get-current-tags)))
      ;; Should have all THREE tags: sdd (from Workflow), research (from Research),
      ;; and claude_chat (from Instruction 1)
      (should (member "sdd" tags))
      (should (member "research" tags))
      (should (member "claude_chat" tags)))
    ;; Verify behavior prompt includes both SDD and RESEARCH content
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (stringp prompt))
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

;;; Unit Tests - Tag-Based Prompt Dispatch

(ert-deftest test-sdd-tag-prompt-generic-dispatch ()
  "Test that cl-defgeneric claude-org-tag-prompt dispatches correctly."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  ;; Default method should load from file
  (let ((prompt (claude-org-tag-prompt 'explore nil)))
    (should (or (null prompt)  ; File may not exist
                (stringp prompt)))))

(ert-deftest test-sdd-find-sdd-root ()
  "Test claude-org--find-sdd-root finds correct parent."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (insert "* My Feature\n")
    (insert "** Workflow :sdd:\n")
    (insert "*** Research :research:\n")
    (insert "**** Instruction 1 :claude_chat:\n")
    (insert "#+begin_src ai\ntest\n#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "test")
    (should (equal "My Feature" (claude-org--find-sdd-root)))))

(ert-deftest test-sdd-find-sdd-root-not-in-sdd ()
  "Test claude-org--find-sdd-root returns nil when not in SDD."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (insert "* Regular Section\n")
    (insert "** Subsection\n")
    (goto-char (point-max))
    (should-not (claude-org--find-sdd-root))))

(ert-deftest test-sdd-build-behavior-context ()
  "Test claude-org--build-behavior-context builds correct plist."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-context.org")
    (insert "* Feature\n")
    (insert "** Workflow :sdd:\n")
    (insert "*** Research :research:\n")
    (goto-char (point-max))
    (let ((context (claude-org--build-behavior-context)))
      (should (plistp context))
      (should (equal "/tmp/test-context.org" (plist-get context :file-path)))
      (should (equal "Feature" (plist-get context :sdd-root)))
      (should (member "sdd" (plist-get context :current-tags)))
      (should (member "research" (plist-get context :current-tags))))))

;;; Integration Tests (require API)

(ert-deftest test-sdd-integration-workflow ()
  "Test that SDD workflow uses correct behavior prompt."
  :tags '(:integration :slow :api :org :sdd)
  ;; Skip if running in batch mode without interactive features
  (skip-unless (not noninteractive))
  ;; Ensure test-config is loadable - use robust path finding
  (let ((test-dir (or (and load-file-name (file-name-directory load-file-name))
                      (expand-file-name "tests/" (locate-dominating-file default-directory "claude-org.org")))))
    (when test-dir
      (add-to-list 'load-path (expand-file-name "fixtures" test-dir))))
  (require 'test-config nil t)
  (when (fboundp 'test-claude-skip-unless-cli-available)
    (test-claude-skip-unless-cli-available))

  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name (make-temp-file "sdd-test-" nil ".org"))
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (claude-org-insert-sdd))
    ;; Navigate to Workflow section and add a query
    (goto-char (point-min))
    (re-search-forward "^#\\+begin_src ai")
    (forward-line 1)
    (let ((query-start (point)))
      (insert "What is 2+2?")
      (save-buffer)
      ;; Position inside the query for execution
      (goto-char query-start)
      (claude-org-mode 1)
      (let ((session-key (claude-org--current-session-key)))
        (claude-org-execute)
        ;; Wait for completion
        (when (test-claude-wait-for-completion session-key 30)
          ;; Verify we got a response
          (goto-char (point-min))
          (should (or (re-search-forward "4" nil t)
                      (re-search-forward "four" nil t))))))
    ;; Cleanup
    (delete-file buffer-file-name)))

;;; Integration Tests - SDD Prompt Building

(ert-deftest test-sdd-integration-behavior-prompt-with-links ()
  "Test that behavior prompt includes docs/ links when session-id is present."
  :tags '(:integration :fast :stable :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd-links.org")
    (insert "* My Feature\n")
    (insert ":PROPERTIES:\n")
    (insert ":CLAUDE_SESSION_ID: sdd-test-12345\n")
    (insert ":END:\n")
    (insert "** Workflow :sdd:\n")
    (insert "*** Research :research:\n")
    (insert "**** Instruction 1 :claude_chat:\n")
    (insert "#+begin_src ai\ntest query\n#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "test query")
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (stringp prompt))
      ;; Should have SDD content
      (should (string-match-p "SDD" prompt))
      ;; Should have docs/ links
      (should (string-match-p "docs/research/" prompt))
      (should (string-match-p "docs/design-docs/" prompt)))))

(ert-deftest test-sdd-integration-multiple-tags-ordered ()
  "Test that multiple tags are processed in correct order with context."
  :tags '(:integration :fast :stable :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd-order.org")
    (insert "* Feature\n")
    (insert "** Workflow :sdd:\n")
    (insert "*** Research :research:\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "query")
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (stringp prompt))
      ;; SDD should appear before RESEARCH (sdd priority 0, research priority 10)
      (let ((sdd-pos (string-match "SDD WORKFLOW" prompt))
            (research-pos (string-match "RESEARCH" prompt)))
        (when (and sdd-pos research-pos)
          (should (< sdd-pos research-pos)))))))

;;; End-to-End Tests - Full SDD Workflow

(ert-deftest test-sdd-e2e-create-and-verify-structure ()
  "End-to-end: Create SDD, verify docs/ files and notebook structure."
  :tags '(:e2e :slow :org :sdd :tdd)
  (let ((test-dir (make-temp-file "sdd-e2e-" t)))
    (unwind-protect
        (progn
          ;; Set up docs/ structure
          (make-directory (expand-file-name "docs/research" test-dir) t)
          (make-directory (expand-file-name "docs/design-docs" test-dir) t)
          (with-temp-file (expand-file-name "docs/research/INDEX.md" test-dir)
            (insert "# Research Index\n\n| Date | Title | Status | SDD Session |\n|------|-------|--------|-------------|\n"))
          (with-temp-file (expand-file-name "docs/design-docs/INDEX.md" test-dir)
            (insert "# Design Docs Index\n\n| Date | Title | Status | SDD Session |\n|------|-------|--------|-------------|\n"))
          (let ((default-directory test-dir)
                (test-file (expand-file-name "test-notebook.org" test-dir)))
            (with-temp-buffer
              (org-mode)
              (setq buffer-file-name test-file)
              ;; Create SDD structure
              (cl-letf (((symbol-function 'read-string) (lambda (_) "E2E Test Feature")))
                (claude-org-insert-sdd))
              (save-buffer)
              ;; Navigate to first AI block
              (goto-char (point-min))
              (re-search-forward "^#\\+begin_src ai")
              (forward-line 1)
              ;; Verify context
              (let* ((context (claude-org--build-behavior-context))
                     (prompt (claude-org--build-behavior-prompt)))
                ;; Context should have correct values
                (should (equal "E2E Test Feature" (plist-get context :sdd-root)))
                (should (member "sdd" (plist-get context :current-tags)))
                ;; Prompt should have docs/ links
                (should (string-match-p "docs/research/" prompt))
                (should (string-match-p "docs/design-docs/" prompt)))
              ;; Verify NO Research Output/Spec/Features in notebook
              (goto-char (point-min))
              (should-not (re-search-forward "^\\*\\* Research Output" nil t))
              (goto-char (point-min))
              (should-not (re-search-forward "^\\*\\* Spec" nil t))
              (goto-char (point-min))
              (should-not (re-search-forward "^\\*\\* Features" nil t)))))
      ;; Cleanup
      (delete-directory test-dir t))))

;;; CUSTOM_ID Tests - Stable Link Support

(ert-deftest test-sdd-generate-custom-id ()
  "Test claude-org--generate-custom-id creates valid IDs."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  ;; SDD section IDs without file-base (legacy format)
  (should (equal "sdd-12345-workflow"
                 (claude-org--generate-custom-id "sdd-12345" "Workflow")))
  (should (equal "sdd-12345-research-output"
                 (claude-org--generate-custom-id "sdd-12345" "Research Output")))
  ;; SDD section IDs with file-base (new format for cross-file uniqueness)
  (should (equal "my-notes-workflow-sdd-12345"
                 (claude-org--generate-custom-id "sdd-12345" "Workflow" "my-notes")))
  (should (equal "claude-agent-dev-research-output-sdd-12345"
                 (claude-org--generate-custom-id "sdd-12345" "Research Output" "claude-agent-dev")))
  (should (equal "claude-agent-dev-spec-sdd-12345"
                 (claude-org--generate-custom-id "sdd-12345" "Spec" "claude-agent-dev")))
  ;; Handle special characters
  (should (equal "sdd-12345-non-goals"
                 (claude-org--generate-custom-id "sdd-12345" "Non-Goals"))))

(ert-deftest test-sdd-generate-custom-id-nil-handling ()
  "Test claude-org--generate-custom-id handles nil inputs."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (should-not (claude-org--generate-custom-id nil "Workflow"))
  (should-not (claude-org--generate-custom-id "sdd-12345" nil))
  (should-not (claude-org--generate-custom-id nil nil)))

(ert-deftest test-sdd-insert-adds-custom-id-to-notebook-sections ()
  "Test that claude-org-insert-sdd adds CUSTOM_ID to notebook sections only."
  :tags '(:unit :fast :stable :isolated :org :sdd :tdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-custom-id.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (claude-org-insert-sdd))
    ;; Verify CUSTOM_ID on top-level heading
    (goto-char (point-min))
    (re-search-forward "^\\* Test Feature")
    (should (org-entry-get nil "CUSTOM_ID"))
    ;; Verify CUSTOM_ID on System Prompt
    (goto-char (point-min))
    (re-search-forward "^\\*\\* System Prompt :system_prompt:")
    (should (org-entry-get nil "CUSTOM_ID"))
    (should (string-match-p "^test-custom-id-system-prompt-sdd-" (org-entry-get nil "CUSTOM_ID")))
    ;; Verify CUSTOM_ID on Workflow section
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Workflow :sdd:")
    (should (org-entry-get nil "CUSTOM_ID"))
    (should (string-match-p "^test-custom-id-workflow-sdd-" (org-entry-get nil "CUSTOM_ID")))
    ;; MUST NOT have Research Output, Spec, or Features sections at all
    (goto-char (point-min))
    (should-not (re-search-forward "^\\*\\* Research Output" nil t))
    (goto-char (point-min))
    (should-not (re-search-forward "^\\*\\* Spec" nil t))
    (goto-char (point-min))
    (should-not (re-search-forward "^\\*\\* Features" nil t))))

;;; Structural Tests - docs/ Directory

(ert-deftest test-sdd-docs-directories-exist ()
  "Test that required docs/ subdirectories exist."
  :tags '(:unit :fast :stable :structural :sdd :tdd)
  (let ((project-root (locate-dominating-file default-directory "claude-org.org")))
    (skip-unless project-root)
    (should (file-directory-p (expand-file-name "docs/research" project-root)))
    (should (file-directory-p (expand-file-name "docs/design-docs" project-root)))
    (should (file-directory-p (expand-file-name "docs/product-specs" project-root)))
    (should (file-directory-p (expand-file-name "docs/references" project-root)))))

(ert-deftest test-sdd-docs-index-files-exist ()
  "Test that INDEX.md files exist in docs/ subdirectories."
  :tags '(:unit :fast :stable :structural :sdd :tdd)
  (let ((project-root (locate-dominating-file default-directory "claude-org.org")))
    (skip-unless project-root)
    (dolist (subdir '("research" "design-docs" "product-specs" "references"))
      (should (file-exists-p
               (expand-file-name (format "docs/%s/INDEX.md" subdir) project-root))))))

(provide 'test-claude-org-sdd)
;;; test-claude-org-sdd.el ends here
