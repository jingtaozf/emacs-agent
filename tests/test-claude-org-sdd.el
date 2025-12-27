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
    ;; Workflow section with :sdd: tag and single AI block
    (should (re-search-forward "^\\*\\* Workflow :sdd:" nil t))
    (let ((tag-pattern (format ":%s:" claude-org-heading-tag)))
      (should (re-search-forward (format "^\\*\\*\\* Instruction 1 %s" tag-pattern) nil t))
      (should (re-search-forward "^#\\+begin_src ai" nil t)))
    ;; Research Output section
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

;;; Integration Tests (require API)

(ert-deftest test-sdd-integration-workflow ()
  "Test that SDD workflow uses correct behavior prompt."
  :tags '(:integration :slow :api :org :sdd)
  (require 'test-config)
  (test-claude-skip-unless-cli-available)

  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name (make-temp-file "sdd-test-" nil ".org"))
    (cl-letf (((symbol-function 'read-string) (lambda (_) "Test Feature")))
      (claude-org-insert-sdd))
    ;; Navigate to Workflow section and add a query
    (goto-char (point-min))
    (re-search-forward "^#\\+begin_src ai")
    (forward-line 1)
    (insert "What is 2+2?")
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

;;; Unit Tests - Tag-Based Prompt Dispatch

(ert-deftest test-sdd-tag-prompt-generic-dispatch ()
  "Test that cl-defgeneric claude-org-tag-prompt dispatches correctly."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  ;; Default method should load from file
  (let ((prompt (claude-org-tag-prompt 'explore nil)))
    (should (or (null prompt)  ; File may not exist
                (stringp prompt)))))

(ert-deftest test-sdd-tag-prompt-sdd-method ()
  "Test that SDD tag method returns combined prompt with links."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (let* ((context (list :file-path "/tmp/test.org"
                        :sdd-root "My Feature"
                        :current-tags '("sdd" "research")))
         (prompt (claude-org-tag-prompt 'sdd context)))
    (should (stringp prompt))
    ;; Should contain SDD workflow content
    (should (string-match-p "SDD" prompt))
    ;; Should contain dynamic links section
    (should (string-match-p "SDD Section Links" prompt))
    (should (string-match-p "Research Output" prompt))
    (should (string-match-p "Spec" prompt))
    (should (string-match-p "Features" prompt))))

(ert-deftest test-sdd-tag-prompt-sdd-without-context ()
  "Test SDD method gracefully handles nil context."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (let ((prompt (claude-org-tag-prompt 'sdd nil)))
    (should (stringp prompt))
    ;; Should still have static SDD content
    (should (string-match-p "SDD" prompt))
    ;; But no dynamic links (no file-path/sdd-root)
    (should-not (string-match-p "SDD Section Links" prompt))))

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

(ert-deftest test-sdd-generate-links ()
  "Test claude-org--generate-sdd-links creates valid org links."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (let ((links (claude-org--generate-sdd-links "/tmp/test.org" "My Feature")))
    (should (stringp links))
    (should (string-match-p "SDD Section Links" links))
    ;; Should contain org links in format [[file:path::*Heading][desc]]
    (should (string-match-p "\\[\\[file:/tmp/test.org::\\*Research Output\\]\\[Research Output\\]\\]" links))
    (should (string-match-p "\\[\\[file:/tmp/test.org::\\*Spec\\]\\[Spec\\]\\]" links))
    (should (string-match-p "\\[\\[file:/tmp/test.org::\\*Features\\]\\[Features\\]\\]" links))))

(ert-deftest test-sdd-generate-links-nil-args ()
  "Test claude-org--generate-sdd-links handles nil arguments."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (should-not (claude-org--generate-sdd-links nil "Root"))
  (should-not (claude-org--generate-sdd-links "/tmp/test.org" nil))
  (should-not (claude-org--generate-sdd-links nil nil)))

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

;;; Integration Tests - SDD Prompt Building

(ert-deftest test-sdd-integration-behavior-prompt-with-links ()
  "Test that behavior prompt includes dynamic SDD links."
  :tags '(:integration :fast :stable :org :sdd)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sdd-links.org")
    (insert "* My Feature\n")
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
      ;; Should have dynamic links
      (should (string-match-p "SDD Section Links" prompt))
      (should (string-match-p "file:/tmp/test-sdd-links.org" prompt)))))

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

(ert-deftest test-sdd-e2e-create-and-verify-links ()
  "End-to-end: Create SDD, verify dynamic links in system prompt."
  :tags '(:e2e :slow :org :sdd)
  (let ((test-file (make-temp-file "sdd-e2e-" nil ".org")))
    (unwind-protect
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
          ;; Verify context and links
          (let* ((context (claude-org--build-behavior-context))
                 (prompt (claude-org--build-behavior-prompt)))
            ;; Context should have correct values
            (should (equal "E2E Test Feature" (plist-get context :sdd-root)))
            (should (member "sdd" (plist-get context :current-tags)))
            ;; Prompt should have dynamic links pointing to this file
            (should (string-match-p "SDD Section Links" prompt))
            (should (string-match-p (regexp-quote test-file) prompt))
            ;; Links should reference actual sections we created
            (should (string-match-p "Research Output" prompt))
            (should (string-match-p "Spec" prompt))
            (should (string-match-p "Features" prompt))))
      ;; Cleanup
      (when (file-exists-p test-file)
        (delete-file test-file)))))

(ert-deftest test-sdd-e2e-links-resolve-correctly ()
  "End-to-end: Verify generated links point to actual sections."
  :tags '(:e2e :slow :org :sdd)
  (let ((test-file (make-temp-file "sdd-links-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-buffer
            (org-mode)
            (setq buffer-file-name test-file)
            (cl-letf (((symbol-function 'read-string) (lambda (_) "Link Test")))
              (claude-org-insert-sdd))
            (save-buffer))
          ;; Reopen file and verify links work
          (with-current-buffer (find-file-noselect test-file)
            (goto-char (point-min))
            ;; Verify all linked sections exist
            (should (re-search-forward "^\\*\\* Research Output" nil t))
            (goto-char (point-min))
            (should (re-search-forward "^\\*\\* Spec" nil t))
            (goto-char (point-min))
            (should (re-search-forward "^\\*\\* Features" nil t))
            (kill-buffer)))
      ;; Cleanup
      (when (file-exists-p test-file)
        (delete-file test-file)))))

(provide 'test-claude-org-sdd)
;;; test-claude-org-sdd.el ends here
