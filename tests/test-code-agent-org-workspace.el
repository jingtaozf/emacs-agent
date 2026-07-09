;;; test-code-agent-org-sdd.el --- Tests for workspace insertion -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit and integration tests for workspace workflow: the
;; `code-agent-org-new-workspace' command, workspace navigation, and tag
;; inheritance.
;;
;; `code-agent-org-new-workspace' replaced the older, more elaborate
;; `code-agent-org-insert-workspace' command (which built a full
;; * Workspace > ** System Prompt + ** Workflow > *** Instruction 1 AI-block
;; skeleton) when that command — along with the AI-block execution /
;; response-sync feature it served — was removed in commit 7980a53. The new
;; command just stamps a bare heading with :CMUX_WORKSPACE: and
;; :CLAUDE_SESSION_ID: properties (see lp/org/code-agent-org.org, added in
;; commit ef9c0ca); tests below target that surviving behavior.

;;; Code:

(require 'ert)
(require 'org)
(require 'code-agent-org)

;;; Unit Tests - New Workspace Command

(ert-deftest test-new-workspace-creates-heading ()
  "Test that code-agent-org-new-workspace inserts a top-level heading named NAME."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (code-agent-org-new-workspace "My Workspace")
    (goto-char (point-min))
    (should (re-search-forward "^\\* My Workspace$" nil t))))

(ert-deftest test-new-workspace-sets-cmux-workspace-property ()
  "Test that the new heading's CMUX_WORKSPACE property equals NAME."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (code-agent-org-new-workspace "Test Feature")
    (goto-char (point-min))
    (re-search-forward "^\\* Test Feature$")
    (should (equal "Test Feature" (org-entry-get nil "CMUX_WORKSPACE")))))

(ert-deftest test-new-workspace-sets-session-id ()
  "Test that the new heading has a unique CLAUDE_SESSION_ID prefixed sdd-."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (code-agent-org-new-workspace "My Feature")
    (goto-char (point-min))
    (re-search-forward "^\\* My Feature$")
    (let ((session-id (org-entry-get nil "CLAUDE_SESSION_ID")))
      (should session-id)
      (should (string-prefix-p "sdd-" session-id)))))

(ert-deftest test-new-workspace-appends-after-existing-content ()
  "Test that a new workspace heading lands after pre-existing buffer content."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    (insert "* Existing Section\n\nsome notes\n")
    (code-agent-org-new-workspace "Second Feature")
    (goto-char (point-min))
    (let ((existing-pos (progn (re-search-forward "^\\* Existing Section" nil t) (point)))
          (new-pos (progn (re-search-forward "^\\* Second Feature" nil t) (point))))
      (should (< existing-pos new-pos)))))

(ert-deftest test-collect-workspaces-finds-session-id-only-workspace ()
  "Workspaces marked only by CLAUDE_SESSION_ID (the SDD/cmux creation path,
no CMUX_WORKSPACE) must be found by code-agent-org--collect-workspaces.
Regression: such workspaces were invisible to navigation."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (with-temp-buffer
    (org-mode)
    ;; Workspace A: SDD/cmux layout — only CLAUDE_SESSION_ID, no CMUX_WORKSPACE.
    (insert "* dev1\n:PROPERTIES:\n:CLAUDE_SESSION_ID: sdd-20260327-194735\n"
            ":CMUX_SURFACE_ID: surface:15\n:END:\n"
            "** Workflow :sdd:\n*** Instruction 1 :ai:\n"
            "#+begin_src ai\nhi\n#+end_src\n\n")
    ;; Workspace B: named layout — CMUX_WORKSPACE present.
    (insert "* dev2\n:PROPERTIES:\n:CMUX_WORKSPACE: dev2\n:CLAUDE_SESSION_ID: sdd-x\n:END:\n"
            "** Workflow :sdd:\n")
    (let ((wss (code-agent-org--collect-workspaces)))
      (should (= 2 (length wss)))
      (should (equal "dev1" (car (nth 0 wss))))
      (should (equal "dev2" (car (nth 1 wss))))
      (should (equal "sdd-20260327-194735" (nth 2 (nth 0 wss)))))
    ;; A sub-section inherits the session id but has none of its own, so it
    ;; must NOT be classified as a workspace root.
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Workflow")
    (should-not (code-agent-org--workspace-heading-p))))

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

;;; CUSTOM_ID Tests - Stable Link Support

(ert-deftest test-workspace-generate-custom-id ()
  "Test code-agent-org-generate-custom-id creates valid IDs."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  ;; Workspace section IDs without file-base (legacy format)
  (should (equal "sdd-12345-workflow"
                 (code-agent-org-generate-custom-id "sdd-12345" "Workflow")))
  (should (equal "sdd-12345-research-output"
                 (code-agent-org-generate-custom-id "sdd-12345" "Research Output")))
  ;; Workspace section IDs with file-base (new format for cross-file uniqueness)
  (should (equal "my-notes-workflow-sdd-12345"
                 (code-agent-org-generate-custom-id "sdd-12345" "Workflow" "my-notes")))
  (should (equal "code-agent-dev-research-output-sdd-12345"
                 (code-agent-org-generate-custom-id "sdd-12345" "Research Output" "code-agent-dev")))
  (should (equal "code-agent-dev-spec-sdd-12345"
                 (code-agent-org-generate-custom-id "sdd-12345" "Spec" "code-agent-dev")))
  ;; Handle special characters
  (should (equal "sdd-12345-non-goals"
                 (code-agent-org-generate-custom-id "sdd-12345" "Non-Goals"))))

(ert-deftest test-workspace-generate-custom-id-nil-handling ()
  "Test code-agent-org-generate-custom-id handles nil inputs."
  :tags '(:unit :fast :stable :isolated :org :sdd)
  (should-not (code-agent-org-generate-custom-id nil "Workflow"))
  (should-not (code-agent-org-generate-custom-id "sdd-12345" nil))
  (should-not (code-agent-org-generate-custom-id nil nil)))

(provide 'test-code-agent-org-workspace)
;;; test-code-agent-org-sdd.el ends here
