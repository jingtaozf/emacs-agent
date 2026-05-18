;;; test-code-agent-org-sdd.el --- Tests for workspace insertion -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit and integration tests for workspace workflow.
;; Tests the code-agent-org-insert-workspace command and tag inheritance.
;;
;; Workspace structure: * Workspace > ** Story > *** System Prompt + *** Workflow.
;; Story sub-heading is inserted between workspace and notebook sections.

;;; Code:

(require 'ert)
(require 'org)
(require 'code-agent-org)

;;; Unit Tests - Structure Creation

(ert-deftest test-workspace-insert-creates-system-prompt-first ()
  "Test that code-agent-org-insert-workspace creates System Prompt as the first subsection.
The default content should indicate the current workspace story name."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "My SDD Story")))
      (code-agent-org-insert-workspace))
    ;; Verify System Prompt exists with :system_prompt: tag (level 3, under story)
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\*\\* System Prompt :system_prompt:" nil t))
    ;; Verify it has CUSTOM_ID
    (should (org-entry-get nil "CUSTOM_ID"))
    ;; Verify it comes BEFORE Workflow (first subsection under story)
    (let ((system-prompt-pos (point)))
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\*\\* Workflow :sdd:" nil t))
      (let ((workflow-pos (point)))
        (should (< system-prompt-pos workflow-pos))))
    ;; Verify default content contains the workspace story name
    (goto-char (point-min))
    (re-search-forward "^\\*\\*\\* System Prompt :system_prompt:")
    (forward-line 1)
    ;; Skip past PROPERTIES drawer
    (when (looking-at ":PROPERTIES:")
      (re-search-forward ":END:" nil t)
      (forward-line 1))
    ;; Should find the default content with the story name
    (should (re-search-forward "The current workspace story is \"My SDD Story\"" nil t))))

(ert-deftest test-workspace-insert-creates-story-and-notebook-sections ()
  "Test that code-agent-org-insert-workspace creates story heading, System Prompt, and Workflow.
The workspace has: * Workspace > ** Story > *** System Prompt + *** Workflow."
  :tags '(:unit :fast :stable :isolated :org :sdd :tdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (code-agent-org-insert-workspace))
    ;; Verify structure
    (goto-char (point-min))
    ;; Top-level workspace heading
    (should (re-search-forward "^\\* Test Feature" nil t))
    ;; Story sub-heading
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\* First Story" nil t))
    ;; System Prompt section (level 3, under story)
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\*\\* System Prompt :system_prompt:" nil t))
    (should (org-entry-get nil "CUSTOM_ID"))
    ;; Workflow section with :sdd: tag and CUSTOM_ID (level 3, under story)
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\*\\* Workflow :sdd:" nil t))
    (should (org-entry-get nil "CUSTOM_ID"))
    ;; AI block under Workflow (level 4)
    (goto-char (point-min))
    (let ((tag-pattern (format ":%s:" code-agent-org-heading-tag)))
      (should (re-search-forward (format "^\\*\\*\\*\\* Instruction 1 .*%s" tag-pattern) nil t))
      (should (re-search-forward "^#\\+begin_src ai" nil t)))
    ;; MUST NOT have Research Output, Spec, or Features sections
    (goto-char (point-min))
    (should-not (re-search-forward "^\\*\\*\\* Research Output" nil t))
    (goto-char (point-min))
    (should-not (re-search-forward "^\\*\\*\\* Spec" nil t))
    (goto-char (point-min))
    (should-not (re-search-forward "^\\*\\*\\* Features" nil t))))

(ert-deftest test-workspace-insert-sets-session-id ()
  "Test that workspace structure has unique CLAUDE_SESSION_ID."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "My Feature")))
      (code-agent-org-insert-workspace))
    (goto-char (point-min))
    (re-search-forward "^\\* My Feature")
    (let ((session-id (org-entry-get nil "CLAUDE_SESSION_ID")))
      (should session-id)
      (should (string-prefix-p "sdd-" session-id)))))

(ert-deftest test-workspace-insert-sets-active-story ()
  "Test that workspace heading has ACTIVE_STORY property set to workspace name."
  :tags '(:unit :fast :stable :isolated :org :sdd :tdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (code-agent-org-insert-workspace))
    (goto-char (point-min))
    (re-search-forward "^\\* Test Feature")
    (should (equal "First Story" (org-entry-get nil "ACTIVE_STORY"))))
)

(ert-deftest test-workspace-level-alignment ()
  "Test that new workspace aligns with previous workspace level."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    ;; Insert first workspace at level 2
    (insert "* Existing Section\n\n")
    (insert "** First Feature\n")
    (insert ":PROPERTIES:\n:CLAUDE_SESSION_ID: sdd-existing\n:END:\n\n")
    ;; Now insert new workspace
    (goto-char (point-max))
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Second Feature")))
      (code-agent-org-insert-workspace))
    ;; Verify it's at level 2
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Second Feature")
    (should (= 2 (org-current-level)))))

(ert-deftest test-workspace-cursor-in-first-ai-block ()
  "Test that cursor is positioned inside the first AI block after insert."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (code-agent-org-insert-workspace))
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

(ert-deftest test-workspace-single-ai-block ()
  "Test that simplified workspace has exactly one AI block under Workflow."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (code-agent-org-insert-workspace))
    (goto-char (point-min))
    ;; Count AI blocks - should be 1 (only under Workflow, no phase subsections)
    (let ((count 0))
      (while (re-search-forward "^#\\+begin_src ai" nil t)
        (setq count (1+ count)))
      (should (= 1 count)))))

;;; Unit Tests - Block Insertion

(ert-deftest test-workspace-block-insert ()
  "Test inserting block with only the heading tag."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd.org")
    (insert "* Feature\n** Workflow :sdd:\n")
    (goto-char (point-max))
    ;; Insert block
    (code-agent-org--do-insert-block nil)
    (goto-char (point-min))
    ;; Should only have code-agent-org-heading-tag
    (should (re-search-forward (format ":%s:" code-agent-org-heading-tag) nil t))
    (goto-char (point-min))
    (should-not (re-search-forward ":research:" nil t))
    (should-not (re-search-forward ":design:" nil t))))

;;; Unit Tests - Tag Inheritance

(ert-deftest test-workspace-tag-inheritance-in-workflow ()
  "Test that AI blocks in workspace phases inherit both :sdd: and phase tags."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n")
    (insert "** Workflow :sdd:\n")
    (insert "*** Research :research:\n")
    (insert "#+begin_src ai\ntest query\n#+end_src\n")
    (goto-char (point-min))
    (re-search-forward "test query")
    (let ((tags (code-agent-org--get-current-tags)))
      ;; Should have both tags (inherited)
      (should (member "sdd" tags))
      (should (member "research" tags)))))

;;; Unit Tests - Tag Inheritance

(ert-deftest test-workspace-tag-inheritance ()
  "Test that tags are inherited from parent headings.
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
    (let ((tags (code-agent-org--get-current-tags)))
      ;; Should have all THREE tags: sdd (from Workflow), research (from Research),
      ;; and claude_chat (from Instruction 1)
      (should (member "sdd" tags))
      (should (member "research" tags))
      (should (member "claude_chat" tags)))))

;;; Unit Tests - Find Previous Workspace Level

(ert-deftest test-find-previous-workspace-level ()
  "Test finding previous workspace section level."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (insert "* Section\n")
    (insert "** My Feature\n")
    (insert ":PROPERTIES:\n:CLAUDE_SESSION_ID: sdd-test\n:END:\n\n")
    (insert "*** Workflow :sdd:\n")
    (goto-char (point-max))
    ;; Should find level 2
    (should (= 2 (code-agent-org--find-previous-workspace-level)))))

(ert-deftest test-find-previous-workspace-level-none ()
  "Test finding previous workspace when none exists."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (insert "* Section\n")
    (insert "** Subsection\n")
    (goto-char (point-max))
    ;; Should return nil
    (should-not (code-agent-org--find-previous-workspace-level))))

(ert-deftest test-workspace-find-workspace-root ()
  "Test code-agent-org--find-workspace-root finds correct parent."
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
    (should (equal "My Feature" (code-agent-org--find-workspace-root)))))

(ert-deftest test-workspace-find-workspace-root-not-in-workspace ()
  "Test code-agent-org--find-workspace-root returns nil when not in workspace."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (insert "* Regular Section\n")
    (insert "** Subsection\n")
    (goto-char (point-max))
    (should-not (code-agent-org--find-workspace-root))))

;;; Integration Tests (require API)

(ert-deftest test-workspace-integration-workflow ()
  "Test that workspace workflow uses correct behavior prompt."
  :tags '(:integration :slow :api :org :sdd)
  ;; Skip if running in batch mode without interactive features
  (skip-unless (not noninteractive))
  ;; Ensure test-config is loadable - use robust path finding
  (let ((test-dir (or (and load-file-name (file-name-directory load-file-name))
                      (expand-file-name "tests/" (locate-dominating-file default-directory "code-agent-org.org")))))
    (when test-dir
      (add-to-list 'load-path (expand-file-name "fixtures" test-dir))))
  (require 'test-config nil t)
  (when (fboundp 'test-claude-skip-unless-cli-available)
    (test-claude-skip-unless-cli-available))

  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name (make-temp-file "sdd-test-" nil ".org"))
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (code-agent-org-insert-workspace))
    ;; Navigate to Workflow section and add a query
    (goto-char (point-min))
    (re-search-forward "^#\\+begin_src ai")
    (forward-line 1)
    (let ((query-start (point)))
      (insert "What is 2+2?")
      (save-buffer)
      ;; Position inside the query for execution
      (goto-char query-start)
      (code-agent-org-mode 1)
      (let ((session-key (code-agent-org--current-session-key)))
        (code-agent-org-execute)
        ;; Wait for completion
        (when (test-claude-wait-for-completion session-key 30)
          ;; Verify we got a response
          (goto-char (point-min))
          (should (or (re-search-forward "4" nil t)
                      (re-search-forward "four" nil t))))))
    ;; Cleanup
    (delete-file buffer-file-name)))

;;; End-to-End Tests - Full Workspace Workflow

(ert-deftest test-workspace-e2e-create-and-verify-structure ()
  "End-to-end: Create workspace, verify notebook structure with story heading."
  :tags '(:e2e :slow :org :sdd :tdd)
  (let ((test-dir (make-temp-file "sdd-e2e-" t)))
    (unwind-protect
        (let ((default-directory test-dir)
              (test-file (expand-file-name "test-notebook.org" test-dir)))
          (with-temp-buffer
            (org-mode)
            (setq buffer-file-name test-file)
            ;; Create workspace structure
            (cl-letf (((symbol-function 'read-string) (lambda (_) "E2E Test Feature")))
              (code-agent-org-insert-workspace))
            (save-buffer)
            ;; Navigate to first AI block
            (goto-char (point-min))
            (re-search-forward "^#\\+begin_src ai")
            (forward-line 1)
            ;; Verify context
            (should (equal "E2E Test Feature" (code-agent-org--find-workspace-root)))
            (should (member "sdd" (code-agent-org--get-current-tags)))
            ;; Verify structure: workspace > story > system prompt + workflow
            (goto-char (point-min))
            (should (re-search-forward "^\\* E2E Test Feature" nil t))
            (goto-char (point-min))
            (should (re-search-forward "^\\*\\* First Story" nil t))
            (goto-char (point-min))
            (should (re-search-forward "^\\*\\*\\* System Prompt :system_prompt:" nil t))
            (goto-char (point-min))
            (should (re-search-forward "^\\*\\*\\* Workflow :sdd:" nil t))
            ;; Verify NO Research Output/Spec/Features in notebook
            (goto-char (point-min))
            (should-not (re-search-forward "^\\*\\*\\* Research Output" nil t))
            (goto-char (point-min))
            (should-not (re-search-forward "^\\*\\*\\* Spec" nil t))
            (goto-char (point-min))
            (should-not (re-search-forward "^\\*\\*\\* Features" nil t))))
      ;; Cleanup
      (delete-directory test-dir t))))

;;; CUSTOM_ID Tests - Stable Link Support

(ert-deftest test-workspace-generate-custom-id ()
  "Test code-agent-org--generate-custom-id creates valid IDs."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  ;; Workspace section IDs without file-base (legacy format)
  (should (equal "sdd-12345-workflow"
                 (code-agent-org--generate-custom-id "sdd-12345" "Workflow")))
  (should (equal "sdd-12345-research-output"
                 (code-agent-org--generate-custom-id "sdd-12345" "Research Output")))
  ;; Workspace section IDs with file-base (new format for cross-file uniqueness)
  (should (equal "my-notes-workflow-sdd-12345"
                 (code-agent-org--generate-custom-id "sdd-12345" "Workflow" "my-notes")))
  (should (equal "claude-agent-dev-research-output-sdd-12345"
                 (code-agent-org--generate-custom-id "sdd-12345" "Research Output" "claude-agent-dev")))
  (should (equal "claude-agent-dev-spec-sdd-12345"
                 (code-agent-org--generate-custom-id "sdd-12345" "Spec" "claude-agent-dev")))
  ;; Handle special characters
  (should (equal "sdd-12345-non-goals"
                 (code-agent-org--generate-custom-id "sdd-12345" "Non-Goals"))))

(ert-deftest test-workspace-generate-custom-id-nil-handling ()
  "Test code-agent-org--generate-custom-id handles nil inputs."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (should-not (code-agent-org--generate-custom-id nil "Workflow"))
  (should-not (code-agent-org--generate-custom-id "sdd-12345" nil))
  (should-not (code-agent-org--generate-custom-id nil nil)))

(ert-deftest test-workspace-insert-adds-custom-id-to-notebook-sections ()
  "Test that code-agent-org-insert-workspace adds CUSTOM_ID to notebook sections."
  :tags '(:unit :fast :stable :isolated :org :sdd :tdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-custom-id.org")
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (code-agent-org-insert-workspace))
    ;; Verify CUSTOM_ID on top-level workspace heading
    (goto-char (point-min))
    (re-search-forward "^\\* Test Feature")
    (should (org-entry-get nil "CUSTOM_ID"))
    ;; Verify CUSTOM_ID on System Prompt (level 3, under story)
    (goto-char (point-min))
    (re-search-forward "^\\*\\*\\* System Prompt :system_prompt:")
    (should (org-entry-get nil "CUSTOM_ID"))
    (should (string-match-p "^test-custom-id-system-prompt-sdd-" (org-entry-get nil "CUSTOM_ID")))
    ;; Verify CUSTOM_ID on Workflow section (level 3, under story)
    (goto-char (point-min))
    (re-search-forward "^\\*\\*\\* Workflow :sdd:")
    (should (org-entry-get nil "CUSTOM_ID"))
    (should (string-match-p "^test-custom-id-workflow-sdd-" (org-entry-get nil "CUSTOM_ID")))
    ;; MUST NOT have Research Output, Spec, or Features sections at all
    (goto-char (point-min))
    (should-not (re-search-forward "^\\*\\*\\* Research Output" nil t))
    (goto-char (point-min))
    (should-not (re-search-forward "^\\*\\*\\* Spec" nil t))
    (goto-char (point-min))
    (should-not (re-search-forward "^\\*\\*\\* Features" nil t))))

(provide 'test-code-agent-org-workspace)
;;; test-code-agent-org-sdd.el ends here
