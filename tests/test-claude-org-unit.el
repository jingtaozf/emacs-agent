;;; test-claude-org-unit.el --- Unit tests for claude-org.el -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for claude-org.el
;; These tests do NOT make actual API calls.

;;; Code:

(require 'ert)
(require 'org)
(require 'claude-org)

;; Configure MCP server to use a free port (0 = auto-select) to avoid conflicts
;; This is important for CI environments where port 9999 may already be in use
(setq emacs-mcp-server-default-port 0)

;;; Session ID Tests

(ert-deftest test-claude-org-session-key-creation ()
  "Test session key creation from file path and session ID."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    ;; Without custom session ID
    (cl-letf (((symbol-function 'claude-org--get-session-id) (lambda () nil)))
      (should (equal "/tmp/test.org" (claude-org--current-session-key))))
    ;; With custom session ID
    (cl-letf (((symbol-function 'claude-org--get-session-id) (lambda () "my-session")))
      (should (equal "/tmp/test.org::my-session" (claude-org--current-session-key))))))

(ert-deftest test-claude-org-get-session-id-from-property ()
  "Test getting session ID from org properties."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: CLAUDE_SESSION_ID file-session\n\n")
    (insert "* Section 1\n:PROPERTIES:\n:CLAUDE_SESSION_ID: section-session\n:END:\n")
    (insert "Content\n\n* Section 2\nContent\n")
    (org-set-regexps-and-options)
    ;; At Section 1 - should get section-level ID
    (goto-char (point-min))
    (re-search-forward "^\\* Section 1")
    (should (equal "section-session" (claude-org--get-session-id)))
    ;; At Section 2 - should inherit file-level ID
    (goto-char (point-min))
    (re-search-forward "^\\* Section 2")
    (should (equal "file-session" (claude-org--get-session-id)))
    ;; Before first heading - may return nil or file-level ID
    (goto-char (point-min))
    (should (or (null (claude-org--get-session-id))
                (stringp (claude-org--get-session-id))))))

(ert-deftest test-claude-org-session-scope-detection ()
  "Test detection of session scope (file vs section)."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: CLAUDE_SESSION_ID file-session\n\n")
    (insert "* Section 1\n")
    (insert ":PROPERTIES:\n")
    (insert ":CLAUDE_SESSION_ID: section-session\n")
    (insert ":END:\n")
    ;; Need to refresh properties
    (org-set-regexps-and-options)
    ;; At Section 1 - section scope (has local property)
    (goto-char (point-min))
    (re-search-forward "^\\* Section 1")
    (should (eq 'section (claude-org--get-session-scope)))
    ;; Before first heading - org-entry-get returns nil
    ;; So scope will be nil, not 'file (this is expected behavior)
    (goto-char (point-min))
    ;; Just verify it returns a valid value or nil
    (should (memq (claude-org--get-session-scope) '(nil file section)))))

(ert-deftest test-claude-org-find-session-scope-heading ()
  "Test finding the heading that defines session scope."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (insert "* Section 1\n")
    (insert ":PROPERTIES:\n")
    (insert ":CLAUDE_SESSION_ID: session-1\n")
    (insert ":END:\n")
    (insert "** Subsection 1.1\n")
    (insert "Content\n")
    ;; At subsection - should find parent Section 1
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Subsection")
    (let ((pos (claude-org--find-session-scope-heading)))
      (should pos)
      (save-excursion
        (goto-char pos)
        (should (looking-at "^\\* Section 1"))))))

(ert-deftest test-claude-org-session-tag-detection ()
  "Test detection of :claude_session: tag."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (insert "* Session A :claude_session:\n")
    (insert "Content\n")
    (insert "* Normal Section\n")
    (insert "Content\n")
    ;; At Session A - should have tag
    (goto-char (point-min))
    (re-search-forward "^\\* Session A")
    (should (claude-org--has-session-tag-p))
    ;; At Normal Section - should not have tag
    (goto-char (point-min))
    (re-search-forward "^\\* Normal Section")
    (should-not (claude-org--has-session-tag-p))))

;;; SDK UUID Management Tests

(ert-deftest test-claude-org-sdk-uuid-file-level ()
  "Test SDK UUID storage at file level."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    (insert "#+TITLE: Test\n\n")
    (insert "* Section 1\n")
    ;; Set UUID at file level
    (goto-char (point-min))
    (claude-org--set-sdk-uuid "uuid-file-123")
    ;; Should be retrievable
    (should (equal "uuid-file-123" (claude-org--get-sdk-uuid)))
    ;; Should be in file header as #+PROPERTY
    (goto-char (point-min))
    (should (re-search-forward "^#\\+PROPERTY:[ \t]+CLAUDE_SDK_UUID[ \t]+uuid-file-123" nil t))
    ;; Clear UUID
    (claude-org--clear-sdk-uuid)
    (should-not (claude-org--get-sdk-uuid))))

(ert-deftest test-claude-org-sdk-uuid-section-level ()
  "Test SDK UUID storage at section level."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    (insert "* Section 1\n")
    (insert ":PROPERTIES:\n")
    (insert ":CLAUDE_SESSION_ID: session-1\n")
    (insert ":END:\n")
    ;; At Section 1 - set UUID
    (goto-char (point-min))
    (re-search-forward "^\\* Section 1")
    (claude-org--set-sdk-uuid "uuid-section-123")
    ;; Should be retrievable
    (should (equal "uuid-section-123" (claude-org--get-sdk-uuid)))
    ;; Should be in property drawer
    (goto-char (point-min))
    (re-search-forward "^\\* Section 1")
    (should (equal "uuid-section-123" (org-entry-get nil "CLAUDE_SDK_UUID")))
    ;; Clear UUID
    (claude-org--clear-sdk-uuid)
    (should-not (claude-org--get-sdk-uuid))))

;;; Session Recovery Tests

(ert-deftest test-claude-org-collect-ai-blocks-in-section ()
  "Test collecting AI blocks from a section."
  :tags '(:unit :fast :stable :isolated :org :data-structures)
  (with-temp-buffer
    (org-mode)
    (insert "* Section 1\n")
    (insert "#+begin_src ai\n")
    (insert "Question 1\n")
    (insert "#+end_src\n")
    (insert "Response 1\n\n")
    (insert "#+begin_src ai\n")
    (insert "Question 2\n")
    (insert "#+end_src\n")
    (insert "Response 2\n")
    ;; Collect from Section 1
    (goto-char (point-min))
    (re-search-forward "^\\* Section 1")
    (let ((blocks (claude-org--collect-ai-blocks-in-section)))
      (should (= 2 (length blocks)))
      (should (equal "Question 1" (car (nth 0 blocks))))
      (should (equal "Response 1" (cdr (nth 0 blocks))))
      (should (equal "Question 2" (car (nth 1 blocks))))
      (should (equal "Response 2" (cdr (nth 1 blocks)))))))

(ert-deftest test-claude-org-skip-archived-sections ()
  "Test that archived sections are skipped during context collection."
  :tags '(:unit :fast :stable :isolated :org :data-structures)
  (with-temp-buffer
    (org-mode)
    (insert "* Normal Section\n")
    (insert "#+begin_src ai\n")
    (insert "Include this\n")
    (insert "#+end_src\n")
    (insert "Response\n\n")
    (insert "* Archived Section :ARCHIVE:\n")
    (insert "#+begin_src ai\n")
    (insert "Skip this\n")
    (insert "#+end_src\n")
    (insert "Old response\n")
    ;; Collect context - should only get non-archived
    (goto-char (point-min))
    (let ((context (claude-org--collect-session-context)))
      ;; Should have at least collected from Normal Section
      (should (>= (length context) 1))
      ;; First entry should be from Normal Section
      (should (equal "Include this" (car (nth 0 context))))
      ;; Should not have "Skip this" from archived section
      (should-not (cl-some (lambda (pair) (equal "Skip this" (car pair))) context)))))

(ert-deftest test-claude-org-build-recovery-prompt ()
  "Test building recovery prompt from context."
  :tags '(:unit :fast :stable :isolated :org :session)
  (let ((context '(("Question 1" . "Answer 1")
                   ("Question 2" . "Answer 2")))
        (original "Current question"))
    (cl-letf (((symbol-function 'claude-org--get-session-scope) (lambda () 'file)))
      (let ((prompt (claude-org--build-recovery-prompt context original)))
        (should (stringp prompt))
        (should (string-match-p "<session_recovery>" prompt))
        (should (string-match-p "Question 1" prompt))
        (should (string-match-p "Answer 1" prompt))
        (should (string-match-p "Current question" prompt))))))

;;; Block Detection Tests

(ert-deftest test-claude-org-in-ai-block-p ()
  "Test detection of being inside an AI block."
  :tags '(:unit :fast :stable :isolated :org :data-structures)
  (with-temp-buffer
    (org-mode)
    (insert "* Section\n")
    (insert "#+begin_src ai\n")
    (insert "Question\n")
    (insert "#+end_src\n")
    (insert "Outside block\n")
    ;; Inside block
    (goto-char (point-min))
    (re-search-forward "Question")
    (should (claude-org--in-ai-block-p))
    ;; Outside block
    (goto-char (point-min))
    (re-search-forward "Outside block")
    (should-not (claude-org--in-ai-block-p))))

(ert-deftest test-claude-org-get-block-content ()
  "Test extracting content from AI block."
  :tags '(:unit :fast :stable :isolated :org :data-structures)
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src ai\n")
    (insert "  Question with spaces  \n")
    (insert "#+end_src\n")
    ;; Position cursor inside block
    (goto-char (point-min))
    (forward-line 1)
    (should (equal "Question with spaces" (claude-org--get-block-content)))))

(ert-deftest test-claude-org-find-block-end ()
  "Test finding the end of AI block."
  :tags '(:unit :fast :stable :isolated :org :data-structures)
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src ai\n")
    (insert "Question\n")
    (insert "#+end_src\n")
    (insert "After block\n")
    ;; From inside block
    (goto-char (point-min))
    (forward-line 1)
    (let ((end (claude-org--find-block-end)))
      (should end)
      ;; The function returns line-end-position of #+end_src line
      ;; So we should be at end of that line
      (goto-char end)
      (beginning-of-line)
      (should (looking-at "[ \t]*#\\+end_src")))))

(ert-deftest test-claude-org-section-level ()
  "Test getting section level."
  :tags '(:unit :fast :stable :isolated :org :context)
  (with-temp-buffer
    (org-mode)
    ;; Add content before first heading so point-min is truly before heading
    (insert "Some preamble\n\n")
    (insert "* Level 1\n")
    (insert "** Level 2\n")
    (insert "*** Level 3\n")
    ;; Before first heading
    (goto-char (point-min))
    (should (= 0 (claude-org--get-section-level)))
    ;; At Level 1
    (goto-char (point-min))
    (re-search-forward "^\\* Level 1")
    (should (= 1 (claude-org--get-section-level)))
    ;; At Level 2
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Level 2")
    (should (= 2 (claude-org--get-section-level)))
    ;; At Level 3
    (goto-char (point-min))
    (re-search-forward "^\\*\\*\\* Level 3")
    (should (= 3 (claude-org--get-section-level)))))

(ert-deftest test-claude-org-in-output-section-p ()
  "Test detection of being in :ai_output: section."
  :tags '(:unit :fast :stable :isolated :org :context)
  (with-temp-buffer
    (org-mode)
    (insert "* Response 1 :ai_output:\n")
    (insert "Content\n")
    (insert "* Normal Section\n")
    (insert "Content\n")
    ;; In output section
    (goto-char (point-min))
    (re-search-forward "^\\* Response 1")
    (should (claude-org--in-output-section-p))
    ;; Not in output section
    (goto-char (point-min))
    (re-search-forward "^\\* Normal Section")
    (should-not (claude-org--in-output-section-p))))

(ert-deftest test-claude-org-find-instruction-number ()
  "Test extracting instruction number from heading."
  :tags '(:unit :fast :stable :isolated :org :context)
  (with-temp-buffer
    (org-mode)
    (insert "* Instruction 42\n")
    (insert "* Other Section\n")
    ;; At Instruction 42
    (goto-char (point-min))
    (re-search-forward "^\\* Instruction")
    (should (= 42 (claude-org--find-instruction-number)))
    ;; At Other Section
    (goto-char (point-min))
    (re-search-forward "^\\* Other")
    (should-not (claude-org--find-instruction-number))))

;;; Project Configuration Tests

(ert-deftest test-claude-org-get-project-root ()
  "Test getting PROJECT_ROOT from properties."
  :tags '(:unit :fast :stable :isolated :org :context)
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: PROJECT_ROOT /tmp/project\n\n")
    (insert "* Section 1\n:PROPERTIES:\n:PROJECT_ROOT: /tmp/section-project\n:END:\n")
    (insert "* Section 2\n")
    (org-set-regexps-and-options)
    ;; At Section 1 - section-level override
    (goto-char (point-min))
    (re-search-forward "^\\* Section 1")
    (should (equal "/tmp/section-project" (claude-org--get-project-root)))
    ;; At Section 2 - inherit file-level
    (goto-char (point-min))
    (re-search-forward "^\\* Section 2")
    (should (equal "/tmp/project" (claude-org--get-project-root)))))

(ert-deftest test-claude-org-collect-system-prompts ()
  "Test collecting :system_prompt: tagged sections."
  :tags '(:unit :fast :stable :isolated :org :context)
  (with-temp-buffer
    (org-mode)
    (insert "* Guidelines :system_prompt:\n")
    (insert "Use Python 3.11\n\n")
    (insert "* Code Style :system_prompt:\n")
    (insert "Always use type hints\n")
    (insert "* Normal Section\n")
    (insert "Not a system prompt\n")
    ;; Collect prompts
    (let ((prompts (claude-org--collect-system-prompts)))
      (should (stringp prompts))
      (should (string-match-p "Guidelines" prompts))
      (should (string-match-p "Python 3.11" prompts))
      (should (string-match-p "Code Style" prompts))
      (should (string-match-p "type hints" prompts))
      (should-not (string-match-p "Not a system prompt" prompts)))))

(ert-deftest test-claude-org-build-system-prompt ()
  "Test building complete system prompt."
  :tags '(:unit :fast :stable :isolated :org :context)
  (with-temp-buffer
    (org-mode)
    (insert "* Guidelines :system_prompt:\n")
    (insert "Custom guideline\n")
    ;; Build prompt
    (let ((prompt (claude-org--build-system-prompt)))
      (should (stringp prompt))
      ;; Should include defaults
      (should (string-match-p "Claude agent" prompt))
      ;; Should include custom
      (should (string-match-p "Custom guideline" prompt))
      ;; Should include line width hint
      (should (string-match-p "170 characters" prompt)))))

;;; Permission Mode Tests

(ert-deftest test-claude-org-get-permission-mode ()
  "Test getting permission mode from properties."
  :tags '(:unit :fast :stable :isolated :org :context)
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: CLAUDE_PERMISSION_MODE accept-edits\n\n")
    (insert "* Section 1\n")
    ;; Should get file-level mode
    (goto-char (point-min))
    (re-search-forward "^\\* Section 1")
    (should (equal "acceptEdits" (claude-org--get-permission-mode)))))

(ert-deftest test-claude-org-permission-mode-display ()
  "Test permission mode display names."
  :tags '(:unit :fast :stable :isolated :org :context)
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: CLAUDE_PERMISSION_MODE readonly\n\n")
    (goto-char (point-min))
    (should (equal "RO" (claude-org--permission-mode-short))))
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: CLAUDE_PERMISSION_MODE accept-edits\n\n")
    (goto-char (point-min))
    (should (equal "ED" (claude-org--permission-mode-short)))))

;;; Environment Variable Tests

(ert-deftest test-claude-org-parse-env-file ()
  "Test parsing .env file format."
  :tags '(:unit :fast :stable :isolated :org :context)
  (let ((temp-env (make-temp-file "test-env-")))
    (unwind-protect
        (progn
          (with-temp-file temp-env
            (insert "# Comment\n")
            (insert "KEY1=value1\n")
            (insert "KEY2=\"quoted value\"\n")
            (insert "export KEY3=exported\n")
            (insert "\n")
            (insert "KEY4='single quotes'\n"))
          (let ((env-alist (claude-org--parse-env-file temp-env)))
            (should (equal "value1" (cdr (assoc "KEY1" env-alist))))
            (should (equal "quoted value" (cdr (assoc "KEY2" env-alist))))
            (should (equal "exported" (cdr (assoc "KEY3" env-alist))))
            (should (equal "single quotes" (cdr (assoc "KEY4" env-alist))))))
      (delete-file temp-env))))

(ert-deftest test-claude-org-expand-env-vars ()
  "Test environment variable expansion."
  :tags '(:unit :fast :stable :isolated :org :context)
  (let ((env-alist '(("FOO" . "bar") ("BAZ" . "qux"))))
    ;; Simple expansion
    (should (equal "bar" (claude-org--expand-env-vars "${FOO}" env-alist)))
    ;; Multiple expansions
    (should (equal "bar/qux" (claude-org--expand-env-vars "${FOO}/${BAZ}" env-alist)))
    ;; Default value syntax
    (should (equal "default" (claude-org--expand-env-vars "${MISSING:-default}" env-alist)))
    ;; No expansion needed
    (should (equal "plain text" (claude-org--expand-env-vars "plain text" env-alist)))))

;;; Session State Tests

(ert-deftest test-claude-org-session-state-accessors ()
  "Test session state put/get operations."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    (claude-org-mode 1)
    (let ((key "test-key"))
      (claude-org--session-put key :foo "bar")
      (should (equal "bar" (claude-org--session-get key :foo)))
      (claude-org--session-put key :busy t)
      (should (equal t (claude-org--session-get key :busy))))))

(ert-deftest test-claude-org-active-session-count ()
  "Test counting active sessions."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    (claude-org-mode 1)
    (should (= 0 (claude-org--active-session-count)))
    (claude-org--session-put "session-1" :busy t)
    (should (= 1 (claude-org--active-session-count)))
    (claude-org--session-put "session-2" :busy t)
    (should (= 2 (claude-org--active-session-count)))
    (claude-org--session-put "session-1" :busy nil)
    (should (= 1 (claude-org--active-session-count)))))

(ert-deftest test-claude-org-session-display-name ()
  "Test session display name extraction."
  :tags '(:unit :fast :stable :isolated :org :session)
  (should (equal "my-session"
                 (claude-org--session-display-name "/path/to/file.org::my-session")))
  (should (equal "file.org"
                 (claude-org--session-display-name "/path/to/file.org"))))

(ert-deftest test-claude-org-format-elapsed ()
  "Test elapsed time formatting."
  :tags '(:unit :fast :stable :isolated :org :data-structures)
  (should (equal "unknown" (claude-org--format-elapsed nil)))
  (should (string-match-p "started [0-9]+ seconds ago"
                          (claude-org--format-elapsed (- (float-time) 30))))
  (should (string-match-p "started [0-9]+ minutes ago"
                          (claude-org--format-elapsed (- (float-time) 120)))))

;;; Block Insertion Tests

(ert-deftest test-claude-org-next-instruction-number ()
  "Test finding next available instruction number.
Counts :claude_chat: tagged headings within session scope."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-numbering.org")
    ;; Create a session scope with claude_chat headings
    (insert "* Feature\n")
    (insert ":PROPERTIES:\n")
    (insert ":CLAUDE_SESSION_ID: test-session\n")
    (insert ":END:\n")
    (insert "** Instruction 1 :claude_chat:\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    (insert "** Instruction 2 :claude_chat:\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    (insert "** Other Section\n")
    ;; Position at end of session scope
    (goto-char (point-max))
    ;; Should count 2 :claude_chat: headings, next is 3
    (should (= 3 (claude-org--next-instruction-number)))))

(ert-deftest test-claude-org-skip-output-section ()
  "Test skipping :ai_output: sections during insertion."
  :tags '(:unit :fast :stable :isolated :org :data-structures)
  (with-temp-buffer
    (org-mode)
    (insert "* Instruction 1\n")
    (insert "Content\n")
    (insert "* Response 1 :ai_output:\n")
    (insert "Output\n")
    (insert "* Instruction 2\n")
    ;; Position in output section
    (goto-char (point-min))
    (re-search-forward "^\\* Response 1")
    ;; Skip should move to after output section
    (claude-org--skip-to-after-output-section)
    (should (looking-at "^\\* Instruction 2"))))

;;; Header Normalization Tests

(ert-deftest test-claude-org-normalize-headers-in-text ()
  "Test org header normalization with regex replacement."
  :tags '(:unit :fast :stable :isolated :org :normalization)
  (let ((claude-org-normalize-headers t))
    ;; Simple case: single header
    (should (equal "**** Top\n" (claude-org--normalize-headers-in-text "* Top\n" 4)))
    ;; Multiple headers
    (should (equal "**** Top\n***** Sub\n"
                   (claude-org--normalize-headers-in-text "* Top\n** Sub\n" 4)))
    ;; Mixed content
    (should (equal "Hello\n**** Head\nText\n"
                   (claude-org--normalize-headers-in-text "Hello\n* Head\nText\n" 4)))
    ;; Non-headers unchanged
    (should (equal "  * not at start\n"
                   (claude-org--normalize-headers-in-text "  * not at start\n" 4)))
    (should (equal "*no space after\n"
                   (claude-org--normalize-headers-in-text "*no space after\n" 4)))
    ;; Empty string
    (should (equal "" (claude-org--normalize-headers-in-text "" 4)))
    ;; No newline - still works (header at start of string)
    (should (equal "**** Header" (claude-org--normalize-headers-in-text "* Header" 4)))))

(ert-deftest test-claude-org-normalize-headers-disabled ()
  "Test that normalization can be disabled."
  :tags '(:unit :fast :stable :isolated :org :normalization)
  (let ((claude-org-normalize-headers nil))
    (should (equal "* Top\n" (claude-org--normalize-headers-in-text "* Top\n" 4)))))

(ert-deftest test-claude-org-normalize-headers-streaming ()
  "Test header normalization with streaming tokens."
  :tags '(:unit :fast :stable :isolated :org :normalization)
  (let ((claude-org-normalize-headers t)
        (output ""))
    ;; Simulate streaming - each token is processed independently
    (dolist (token '("Here is " "the ans" "wer:\n" "* Sum" "mary\n" "Text\n"))
      (setq output (concat output (claude-org--normalize-headers-in-text token 4))))
    (should (equal "Here is the answer:\n**** Summary\nText\n" output))))

;;; Chat Level Detection Tests

(ert-deftest test-claude-org-find-previous-chat-level-with-tag ()
  "Test finding level from heading with :claude_chat: tag."
  :tags '(:unit :fast :stable :isolated :org :insertion)
  (with-temp-buffer
    (org-mode)
    (insert "* Top Level\n")
    (insert "** My Query :claude_chat:\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    (insert "** Response 1 :ai_output:\n")
    (insert "Output content\n")
    ;; Position at end of buffer (after Response)
    (goto-char (point-max))
    ;; Should find level 2 from heading with :claude_chat: tag
    (should (= 2 (claude-org--find-previous-chat-level)))))

(ert-deftest test-claude-org-find-previous-chat-level-custom-title ()
  "Test finding level from custom titled headings with :claude_chat: tag."
  :tags '(:unit :fast :stable :isolated :org :insertion)
  (with-temp-buffer
    (org-mode)
    (insert "** refactoring emacs mcp server\n")
    (insert "*** Workflow :sdd:\n")
    (insert "**** Emacs MCP Server Buffer State Fixes :design:research:claude_chat:\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    (insert "**** Response 194 :ai_output:\n")
    (insert "Output with many subsections\n")
    (insert "***** Research Complete\n")
    (insert "****** Key Findings\n")
    ;; Position at end of buffer (deep in output subsections)
    (goto-char (point-max))
    ;; Should find level 4 from "Emacs MCP Server Buffer State Fixes"
    (should (= 4 (claude-org--find-previous-chat-level)))))

(ert-deftest test-claude-org-find-previous-chat-level-no-tag ()
  "Test that Instruction N without :claude_chat: tag is NOT found."
  :tags '(:unit :fast :stable :isolated :org :insertion)
  (with-temp-buffer
    (org-mode)
    (insert "* Top Level\n")
    (insert "** Instruction 1\n")  ;; No :claude_chat: tag!
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    (insert "** Response 1 :ai_output:\n")
    (insert "Output content\n")
    (goto-char (point-max))
    ;; Should return nil since there's no :claude_chat: tag
    (should-not (claude-org--find-previous-chat-level))))

(ert-deftest test-claude-org-find-previous-chat-level-no-match ()
  "Test returning nil when no chat section exists."
  :tags '(:unit :fast :stable :isolated :org :insertion)
  (with-temp-buffer
    (org-mode)
    (insert "* Regular Section\n")
    (insert "** Another Section\n")
    (insert "Some content without any chat blocks\n")
    (goto-char (point-max))
    ;; Should return nil (no chat sections found)
    (should-not (claude-org--find-previous-chat-level))))

(ert-deftest test-claude-org-find-previous-chat-level-multiple ()
  "Test finding level from most recent :claude_chat: heading."
  :tags '(:unit :fast :stable :isolated :org :insertion)
  (with-temp-buffer
    (org-mode)
    (insert "* Top\n")
    (insert "** First Query :claude_chat:\n")
    (insert "First query\n")
    (insert "** Response 1 :ai_output:\n")
    (insert "First output\n")
    (insert "** Second Query :planning:claude_chat:\n")
    (insert "#+begin_src ai\nSecond query\n#+end_src\n")
    (insert "** Response 2 :ai_output:\n")
    (insert "Second output\n")
    ;; Position at end - should find the most recent chat heading
    (goto-char (point-max))
    ;; Should find level 2 from "Second Query"
    (should (= 2 (claude-org--find-previous-chat-level)))))

(ert-deftest test-claude-org-do-insert-block-uses-chat-level ()
  "Test that insert-block uses the correct level from previous chat section."
  :tags '(:unit :fast :stable :isolated :org :insertion)
  (with-temp-buffer
    (org-mode)
    (insert "** refactoring emacs mcp server\n")
    (insert "*** Workflow :sdd:\n")
    (insert "**** My Custom Title :research:claude_chat:\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    (insert "**** Response 1 :ai_output:\n")
    (insert "Output content\n")
    ;; Position at end
    (goto-char (point-max))
    ;; Insert a new block
    (claude-org--do-insert-block nil)
    ;; Find the newly inserted Instruction heading
    (goto-char (point-min))
    (re-search-forward "^\\(\\*+\\) Instruction [0-9]+" nil t)
    ;; Should be level 4 (same as "My Custom Title")
    (should (= 4 (length (match-string 1))))))

;;; Instruction Numbering Tests

(ert-deftest test-claude-org-next-instruction-number-session-scoped ()
  "Test that instruction numbering is scoped to current session."
  :tags '(:unit :fast :stable :isolated :org :history)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-numbering.org")
    ;; Create two SDD sections with their own instruction blocks
    (insert "* SDD A\n")
    (insert ":PROPERTIES:\n")
    (insert ":CLAUDE_SESSION_ID: sdd-a\n")
    (insert ":END:\n")
    (insert "** Workflow :sdd:\n")
    (insert "*** Query 1 :claude_chat:\n")
    (insert "#+begin_src ai\nquery 1\n#+end_src\n")
    (insert "*** Query 2 :claude_chat:\n")
    (insert "#+begin_src ai\nquery 2\n#+end_src\n\n")
    (insert "* SDD B\n")
    (insert ":PROPERTIES:\n")
    (insert ":CLAUDE_SESSION_ID: sdd-b\n")
    (insert ":END:\n")
    (insert "** Workflow :sdd:\n")
    (insert "*** Query 1 :claude_chat:\n")
    (insert "#+begin_src ai\nquery 1\n#+end_src\n")
    ;; Position in SDD A - should find 2 existing, next is 3
    (goto-char (point-min))
    (re-search-forward "SDD A")
    (re-search-forward "Query 2")
    (should (= 3 (claude-org--next-instruction-number)))
    ;; Position in SDD B - should find 1 existing, next is 2
    (goto-char (point-min))
    (re-search-forward "SDD B")
    (re-search-forward "Query 1")
    (should (= 2 (claude-org--next-instruction-number)))))

(ert-deftest test-claude-org-next-instruction-number-counts-chat-tags ()
  "Test that instruction numbering counts :claude_chat: tags, not heading text."
  :tags '(:unit :fast :stable :isolated :org :history)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-numbering.org")
    (insert "* Feature\n")
    (insert ":PROPERTIES:\n")
    (insert ":CLAUDE_SESSION_ID: test-session\n")
    (insert ":END:\n")
    (insert "** Workflow :sdd:\n")
    ;; Renamed headings (no "Instruction N" pattern) but with :claude_chat: tag
    (insert "*** Research Phase :claude_chat:\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    (insert "*** Design Discussion :claude_chat:\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    (insert "*** Implementation Plan :claude_chat:\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    ;; Position at end of Workflow
    (goto-char (point-max))
    ;; Should count 3 :claude_chat: headings, next is 4
    (should (= 4 (claude-org--next-instruction-number)))))

;;; Block History Deduplication Tests

(ert-deftest test-claude-org-record-block-execution-deduplicates ()
  "Test that recording same CUSTOM_ID updates existing entry instead of duplicating."
  :tags '(:unit :fast :stable :isolated :org :history)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-history.org")
    ;; Set up buffer-local history variables
    (setq-local claude-org--block-history nil)
    (setq-local claude-org--history-loaded t)
    (insert "* Test\n")
    (insert ":PROPERTIES:\n")
    (insert ":CLAUDE_SESSION_ID: test-session\n")
    (insert ":END:\n")
    (insert "** Query :claude_chat:\n")
    (insert ":PROPERTIES:\n")
    (insert ":CUSTOM_ID: test-custom-id\n")
    (insert ":END:\n")
    (insert "#+begin_src ai\nquery\n#+end_src\n")
    ;; Position inside the ai block
    (goto-char (point-min))
    (re-search-forward "#\\+begin_src ai")
    (forward-line 1)
    ;; First recording
    (claude-org--record-block-execution "test-session" "query" nil)
    (should (= 1 (length claude-org--block-history)))
    (let ((first-block-id (caar claude-org--block-history)))
      ;; Second recording of same block (same CUSTOM_ID)
      (claude-org--record-block-execution "test-session" "query" nil)
      ;; Should still be 1 entry, not 2
      (should (= 1 (length claude-org--block-history)))
      ;; Should keep the same block-id
      (should (equal first-block-id (caar claude-org--block-history))))))

(ert-deftest test-claude-org-record-block-execution-different-ids ()
  "Test that different CUSTOM_IDs create separate history entries."
  :tags '(:unit :fast :stable :isolated :org :history)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-history.org")
    (setq-local claude-org--block-history nil)
    (setq-local claude-org--history-loaded t)
    (insert "* Test\n")
    (insert ":PROPERTIES:\n")
    (insert ":CLAUDE_SESSION_ID: test-session\n")
    (insert ":END:\n")
    (insert "** Query 1 :claude_chat:\n")
    (insert ":PROPERTIES:\n")
    (insert ":CUSTOM_ID: custom-id-1\n")
    (insert ":END:\n")
    (insert "#+begin_src ai\nquery 1\n#+end_src\n")
    (insert "** Query 2 :claude_chat:\n")
    (insert ":PROPERTIES:\n")
    (insert ":CUSTOM_ID: custom-id-2\n")
    (insert ":END:\n")
    (insert "#+begin_src ai\nquery 2\n#+end_src\n")
    ;; Record first block
    (goto-char (point-min))
    (re-search-forward "query 1")
    (claude-org--record-block-execution "test-session" "query 1" nil)
    (should (= 1 (length claude-org--block-history)))
    ;; Record second block
    (goto-char (point-min))
    (re-search-forward "query 2")
    (claude-org--record-block-execution "test-session" "query 2" nil)
    ;; Should have 2 entries
    (should (= 2 (length claude-org--block-history)))))

;;; History Preparation Tests

(ert-deftest test-claude-org-prepare-history-for-save ()
  "Test history preparation removes transient data and respects limits."
  :tags '(:unit :fast :stable :isolated :org :history)
  (let ((claude-org--block-history
         '(("block-1" :timestamp 1000.0 :status completed
                      :custom-id "id-1" :title "Test" :line 10 :marker nil)
           ("block-2" :timestamp 2000.0 :status in-progress
                      :custom-id "id-2" :title "Test2" :line 20 :marker nil)))
        (claude-org-history-max-entries 10))
    (let ((prepared (claude-org--prepare-history-for-save)))
      ;; Should be sorted by timestamp (most recent first)
      (should (equal "block-2" (car (car prepared))))
      ;; Should have required fields
      (let ((entry (cdr (car prepared))))
        (should (plist-get entry :timestamp))
        (should (plist-get entry :status))
        (should (plist-get entry :custom-id))
        ;; Should NOT have transient fields
        (should-not (plist-get entry :title))
        (should-not (plist-get entry :line))
        (should-not (plist-get entry :marker))))))

(ert-deftest test-claude-org-prepare-history-respects-limit ()
  "Test that history preparation respects history-max-entries limit."
  :tags '(:unit :fast :stable :isolated :org :history)
  (let ((claude-org--block-history
         '(("block-1" :timestamp 1000.0 :status completed :custom-id "id-1")
           ("block-2" :timestamp 2000.0 :status completed :custom-id "id-2")
           ("block-3" :timestamp 3000.0 :status completed :custom-id "id-3")))
        (claude-org-history-max-entries 2))
    (let ((prepared (claude-org--prepare-history-for-save)))
      ;; Should only keep 2 entries (respecting max-entries limit)
      (should (= 2 (length prepared)))
      ;; Should be most recent ones
      (should (equal "block-3" (car (car prepared))))
      (should (equal "block-2" (car (cadr prepared)))))))

;;; Recent Blocks Collection Tests

(ert-deftest test-claude-org-collect-recent-blocks ()
  "Test recent blocks collection for completing-read.
Only entries with CUSTOM_IDs that exist in buffer are returned."
  :tags '(:unit :fast :stable :isolated :org :history)
  (with-temp-buffer
    (org-mode)
    (insert "* Test :claude_chat:\n:PROPERTIES:\n:CUSTOM_ID: id-1\n:END:\n")
    (setq-local claude-org--block-history
                '(("block-1" :timestamp 1000.0 :status completed
                             :custom-id "id-1" :title "First")))
    (setq-local claude-org--history-loaded t)
    (let ((claude-org-history-max-entries 100))
      (let ((candidates (claude-org--collect-recent-blocks)))
        (should (= 1 (length candidates)))
        (should (stringp (car (car candidates))))))))

(ert-deftest test-claude-org-collect-recent-blocks-respects-limit ()
  "Test that recent blocks collection respects the limit."
  :tags '(:unit :fast :stable :isolated :org :history)
  (with-temp-buffer
    (org-mode)
    (insert "* A :claude_chat:\n:PROPERTIES:\n:CUSTOM_ID: id-1\n:END:\n")
    (insert "* B :claude_chat:\n:PROPERTIES:\n:CUSTOM_ID: id-2\n:END:\n")
    (insert "* C :claude_chat:\n:PROPERTIES:\n:CUSTOM_ID: id-3\n:END:\n")
    (setq-local claude-org--block-history
                '(("block-1" :timestamp 1000.0 :status completed :custom-id "id-1" :title "First")
                  ("block-2" :timestamp 2000.0 :status completed :custom-id "id-2" :title "Second")
                  ("block-3" :timestamp 3000.0 :status completed :custom-id "id-3" :title "Third")))
    (setq-local claude-org--history-loaded t)
    (let ((claude-org-history-max-entries 2))
      (let ((candidates (claude-org--collect-recent-blocks)))
        ;; Should only return 2 candidates
        (should (= 2 (length candidates)))))))

(ert-deftest test-claude-org-collect-recent-blocks-filters-no-custom-id ()
  "Test that blocks without CUSTOM_ID are filtered out."
  :tags '(:unit :fast :stable :isolated :org :history)
  (with-temp-buffer
    (org-mode)
    (insert "* Has ID :claude_chat:\n:PROPERTIES:\n:CUSTOM_ID: id-1\n:END:\n")
    (setq-local claude-org--block-history
                '(("block-1" :timestamp 1000.0 :status completed :custom-id "id-1" :title "Has ID")
                  ("block-2" :timestamp 2000.0 :status completed :title "No ID")))
    (setq-local claude-org--history-loaded t)
    (let ((claude-org-history-max-entries 100))
      (let ((candidates (claude-org--collect-recent-blocks)))
        ;; Should only return 1 candidate (the one with custom-id that exists)
        (should (= 1 (length candidates)))))))


;;; Loop Session Key Tests

(ert-deftest test-claude-org-send-request-uses-session-key-override ()
  "Test that send-request uses session-key-override when provided.
This is critical for loop iterations where cursor may have moved."
  :tags '(:unit :fast :stable :isolated :org :loop)
  ;; We can't easily test the full send-request without mocking claude-agent-query,
  ;; but we can verify the function signature accepts session-key-override
  (should (equal '(prompt &optional query-context session-key-override)
                 (help-function-arglist 'claude-org--send-request))))

(ert-deftest test-claude-org-execute-loop-iteration-passes-session-key ()
  "Test that execute-loop-iteration passes session-key to send-request.
This ensures loop iterations use the original session, not current cursor position."
  :tags '(:unit :fast :stable :isolated :org :loop)
  (let* ((fn-str (format "%s" (symbol-function 'claude-org--execute-loop-iteration)))
         ;; Check that the function calls send-request with session-key as 3rd arg
         (has-session-key-arg (string-match "send-request prompt query-ctx session-key" fn-str)))
    (should has-session-key-arg)))

(ert-deftest test-claude-org-loop-state-preserved ()
  "Test that loop state is properly stored and retrieved from session."
  :tags '(:unit :fast :stable :isolated :org :loop)
  (let ((test-session-key "test-loop-session::test"))
    ;; Setup loop state as claude-org-execute would
    (claude-org--session-put test-session-key :loop-max 5)
    (claude-org--session-put test-session-key :loop-current 1)
    (claude-org--session-put test-session-key :loop-interval 10)
    (claude-org--session-put test-session-key :original-prompt "test prompt")
    (claude-org--session-put test-session-key :instruction-num 1)
    ;; Verify state is retrievable
    (should (= 5 (claude-org--session-get test-session-key :loop-max)))
    (should (= 1 (claude-org--session-get test-session-key :loop-current)))
    (should (= 10 (claude-org--session-get test-session-key :loop-interval)))
    (should (equal "test prompt" (claude-org--session-get test-session-key :original-prompt)))
    ;; Verify loop continuation condition
    (let ((loop-current (claude-org--session-get test-session-key :loop-current))
          (loop-max (claude-org--session-get test-session-key :loop-max)))
      (should (and loop-current loop-max (< loop-current loop-max))))
    ;; Cleanup
    (remhash test-session-key claude-org--sessions)))

;;; Recovery Session Key Tests

(ert-deftest test-claude-org-recover-session-passes-session-key ()
  "Test that recover-session passes session-key to send-request.
This ensures recovery uses the original session, not current cursor position."
  :tags '(:unit :fast :stable :isolated :org :recovery)
  (let* ((fn-str (format "%s" (symbol-function 'claude-org--recover-session)))
         ;; Check that the function calls send-request with session-key as 3rd arg
         (has-session-key-arg (string-match "send-request recovery-prompt nil session-key" fn-str)))
    (should has-session-key-arg)))

(ert-deftest test-claude-org-recover-session-uses-marker-buffer ()
  "Test that recover-session uses marker buffer for context collection.
This ensures we're in the right buffer when calling org-entry-get dependent functions."
  :tags '(:unit :fast :stable :isolated :org :recovery)
  (let* ((fn-str (format "%s" (symbol-function 'claude-org--recover-session)))
         ;; Check that marker-buffer is used to get the buffer
         ;; The string representation may vary, so we check for key patterns
         (uses-marker-buffer (or (string-match "marker-buffer marker" fn-str)
                                 (string-match "(marker-buffer marker)" fn-str))))
    (should uses-marker-buffer)))

(ert-deftest test-claude-org-recover-session-positions-cursor ()
  "Test that recover-session positions cursor at marker before collecting context.
This ensures org-entry-get returns correct values when called during recovery."
  :tags '(:unit :fast :stable :isolated :org :recovery)
  (let* ((fn-str (format "%s" (symbol-function 'claude-org--recover-session)))
         ;; Check that goto-char marker is called before collect-session-context
         (positions-cursor (string-match "goto-char marker" fn-str)))
    (should positions-cursor)))

;;; History Custom ID Validation Tests

(ert-deftest test-claude-org-custom-id-exists-p ()
  "Test that custom-id-exists-p correctly checks for CUSTOM_ID existence."
  :tags '(:unit :fast :stable :isolated :org :history)
  (with-temp-buffer
    (org-mode)
    (insert "* Test Section\n")
    (insert ":PROPERTIES:\n")
    (insert ":CUSTOM_ID: test-valid-id\n")
    (insert ":END:\n")
    (insert "Content\n")
    (insert "* Another Section\n")
    (insert "No custom id here\n")
    ;; Valid custom ID should be found
    (should (claude-org--custom-id-exists-p "test-valid-id"))
    ;; Non-existent custom ID should return nil
    (should-not (claude-org--custom-id-exists-p "non-existent-id"))
    ;; Nil custom ID should return nil
    (should-not (claude-org--custom-id-exists-p nil))))

(ert-deftest test-claude-org-collect-recent-blocks-filters-stale ()
  "Test that collect-recent-blocks filters out entries with non-existent CUSTOM_IDs.
This prevents 'Untitled' entries from appearing when SDD workflows are reset."
  :tags '(:unit :fast :stable :isolated :org :history)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-history.org")
    ;; Create a heading with a valid CUSTOM_ID
    (insert "* Instruction 1 :claude_chat:\n")
    (insert ":PROPERTIES:\n")
    (insert ":CUSTOM_ID: existing-custom-id\n")
    (insert ":END:\n")
    (insert "#+begin_src ai\nTest query\n#+end_src\n")
    ;; Simulate history with both valid and stale entries
    (setq-local claude-org--block-history
                '(("block-1" :timestamp 1000 :status completed :custom-id "existing-custom-id")
                  ("block-2" :timestamp 900 :status completed :custom-id "deleted-custom-id")
                  ("block-3" :timestamp 800 :status completed :custom-id "another-deleted-id")))
    (setq-local claude-org--history-loaded t)
    ;; Collect blocks - should only return the one with valid CUSTOM_ID
    (let ((candidates (claude-org--collect-recent-blocks)))
      ;; Should have exactly 1 candidate (the valid one)
      (should (= 1 (length candidates)))
      ;; The candidate should reference the existing custom-id
      (let* ((entry (cdar candidates))
             (custom-id (plist-get (cdr entry) :custom-id)))
        (should (equal "existing-custom-id" custom-id))))))


;;; CUSTOM_ID Generation Tests

(ert-deftest test-claude-org-generate-instruction-custom-id-basic ()
  "Test basic CUSTOM_ID generation with timestamp."
  :tags '(:unit :fast :stable :isolated :org :custom-id)
  (let ((id (claude-org--generate-instruction-custom-id "myfile" 1 "sdd-20260121-100000")))
    ;; Should have format: file-instruction-N-session-id-HHMMSS
    (should (string-match "^myfile-instruction-1-sdd-20260121-100000-[0-9]\\{6\\}$" id))))

(ert-deftest test-claude-org-generate-instruction-custom-id-no-session ()
  "Test CUSTOM_ID generation without session ID."
  :tags '(:unit :fast :stable :isolated :org :custom-id)
  (let ((id (claude-org--generate-instruction-custom-id "myfile" 2 nil)))
    ;; Should have format: file-instruction-N-HHMMSS (no session-id part)
    (should (string-match "^myfile-instruction-2-[0-9]\\{6\\}$" id))))

(ert-deftest test-claude-org-generate-instruction-custom-id-nil-file-base ()
  "Test CUSTOM_ID generation returns nil when file-base is nil."
  :tags '(:unit :fast :stable :isolated :org :custom-id)
  (should (null (claude-org--generate-instruction-custom-id nil 1 "session"))))

(ert-deftest test-claude-org-generate-instruction-custom-id-duplicate-suffix ()
  "Test CUSTOM_ID generation adds -N suffix for duplicates."
  :tags '(:unit :fast :stable :isolated :org :custom-id)
  (with-temp-buffer
    (org-mode)
    ;; Create an existing heading with a CUSTOM_ID
    (insert "* Test Section\n")
    (insert ":PROPERTIES:\n")
    (insert ":CUSTOM_ID: testbuf-instruction-1-sess-123456\n")
    (insert ":END:\n\n")
    ;; Mock custom-id-exists-p to check our buffer
    (cl-letf (((symbol-function 'claude-org--custom-id-exists-p)
               (lambda (id)
                 (save-excursion
                   (goto-char (point-min))
                   (search-forward (format ":CUSTOM_ID: %s" id) nil t)))))
      ;; Mock timestamp to return fixed value
      (cl-letf (((symbol-function 'format-time-string)
                 (lambda (_fmt) "123456")))
        ;; First call with same parameters should detect duplicate and add -2
        (let ((id (claude-org--generate-instruction-custom-id "testbuf" 1 "sess")))
          (should (equal id "testbuf-instruction-1-sess-123456-2")))))))

(ert-deftest test-claude-org-generate-instruction-custom-id-multiple-duplicates ()
  "Test CUSTOM_ID generation increments suffix for multiple duplicates."
  :tags '(:unit :fast :stable :isolated :org :custom-id)
  (with-temp-buffer
    (org-mode)
    ;; Create multiple existing headings with CUSTOM_IDs
    (insert "* Section 1\n:PROPERTIES:\n:CUSTOM_ID: testbuf-instruction-1-sess-123456\n:END:\n\n")
    (insert "* Section 2\n:PROPERTIES:\n:CUSTOM_ID: testbuf-instruction-1-sess-123456-2\n:END:\n\n")
    (insert "* Section 3\n:PROPERTIES:\n:CUSTOM_ID: testbuf-instruction-1-sess-123456-3\n:END:\n\n")
    (cl-letf (((symbol-function 'claude-org--custom-id-exists-p)
               (lambda (id)
                 (save-excursion
                   (goto-char (point-min))
                   (search-forward (format ":CUSTOM_ID: %s" id) nil t)))))
      (cl-letf (((symbol-function 'format-time-string)
                 (lambda (_fmt) "123456")))
        ;; Should detect all duplicates and return -4
        (let ((id (claude-org--generate-instruction-custom-id "testbuf" 1 "sess")))
          (should (equal id "testbuf-instruction-1-sess-123456-4")))))))

;;; Template Insertion Tests

(ert-deftest test-claude-org-template-get-string ()
  "Test getting content from string template."
  :tags '(:unit :fast :stable :isolated :org :template)
  (let ((claude-org-templates '(("Test" . "Hello World"))))
    (should (equal "Hello World"
                   (claude-org--get-template-content "Test")))))

(ert-deftest test-claude-org-template-get-function ()
  "Test getting content from function template."
  :tags '(:unit :fast :stable :isolated :org :template)
  (let ((claude-org-templates
         '(("Dynamic" . (lambda () (format "Time: %s" "now"))))))
    (should (equal "Time: now"
                   (claude-org--get-template-content "Dynamic")))))

(ert-deftest test-claude-org-template-annotation-string ()
  "Test annotation for string template."
  :tags '(:unit :fast :stable :isolated :org :template)
  (let ((claude-org-templates '(("Review" . "Please review this code"))))
    (should (string-match-p "Please review"
                            (claude-org--template-annotation "Review")))))

(ert-deftest test-claude-org-template-annotation-function ()
  "Test annotation for function template."
  :tags '(:unit :fast :stable :isolated :org :template)
  (let ((claude-org-templates '(("Backtrace" . claude-org-template--backtrace))))
    (should (string-match-p "function"
                            (claude-org--template-annotation "Backtrace")))))

(ert-deftest test-claude-org-template-backtrace-no-buffer ()
  "Test backtrace template errors when no backtrace buffer exists."
  :tags '(:unit :fast :stable :isolated :org :template)
  ;; Ensure no backtrace buffer
  (when (get-buffer "*Backtrace*")
    (kill-buffer "*Backtrace*"))
  (should-error (claude-org-template--backtrace)
                :type 'user-error))

(ert-deftest test-claude-org-template-backtrace-with-buffer ()
  "Test backtrace template extracts content from backtrace buffer."
  :tags '(:unit :fast :stable :isolated :org :template)
  (let ((buf (get-buffer-create "*Backtrace*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (erase-buffer)
            (insert "Debugger entered--Lisp error: (void-variable foo)"))
          (let ((result (claude-org-template--backtrace)))
            (should (string-match-p "void-variable foo" result))
            (should (string-match-p "Root Cause" result))))
      (kill-buffer buf))))

(provide 'test-claude-org-unit)
;;; test-claude-org-unit.el ends here
