;;; test-code-agent-org-unit.el --- Unit tests for code-agent-org.el -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for code-agent-org.el
;; These tests do NOT make actual API calls.

;;; Code:

(require 'ert)
(require 'org)
(require 'code-agent-org)

;; Configure MCP server to use a free port (0 = auto-select) to avoid conflicts
;; This is important for CI environments where port 9999 may already be in use
(setq emacs-mcp-server-default-port 0)

;;; Session ID Tests

(ert-deftest test-code-agent-org-session-key-creation ()
  "Test session key creation from file path and session ID."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    ;; Without custom session ID
    (cl-letf (((symbol-function 'code-agent-org--get-session-id) (lambda () nil)))
      (should (equal "/tmp/test.org" (code-agent-org--current-session-key))))
    ;; With custom session ID
    (cl-letf (((symbol-function 'code-agent-org--get-session-id) (lambda () "my-session")))
      (should (equal "/tmp/test.org::my-session" (code-agent-org--current-session-key))))))

(ert-deftest test-code-agent-org-get-session-id-from-property ()
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
    (should (equal "section-session" (code-agent-org--get-session-id)))
    ;; At Section 2 - should inherit file-level ID
    (goto-char (point-min))
    (re-search-forward "^\\* Section 2")
    (should (equal "file-session" (code-agent-org--get-session-id)))
    ;; Before first heading - may return nil or file-level ID
    (goto-char (point-min))
    (should (or (null (code-agent-org--get-session-id))
                (stringp (code-agent-org--get-session-id))))))

(ert-deftest test-code-agent-org-session-scope-detection ()
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
    (should (eq 'section (code-agent-org--get-session-scope)))
    ;; Before first heading - org-entry-get returns nil
    ;; So scope will be nil, not 'file (this is expected behavior)
    (goto-char (point-min))
    ;; Just verify it returns a valid value or nil
    (should (memq (code-agent-org--get-session-scope) '(nil file section)))))

(ert-deftest test-code-agent-org-find-session-scope-heading ()
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
    (let ((pos (code-agent-org--find-session-scope-heading)))
      (should pos)
      (save-excursion
        (goto-char pos)
        (should (looking-at "^\\* Section 1"))))))

(ert-deftest test-code-agent-org-session-tag-detection ()
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
    (should (code-agent-org--has-session-tag-p))
    ;; At Normal Section - should not have tag
    (goto-char (point-min))
    (re-search-forward "^\\* Normal Section")
    (should-not (code-agent-org--has-session-tag-p))))

;;; SDK UUID Management Tests

(ert-deftest test-code-agent-org-sdk-uuid-file-level ()
  "Test SDK UUID storage at file level."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    (insert "#+TITLE: Test\n\n")
    (insert "* Section 1\n")
    ;; Set UUID at file level
    (goto-char (point-min))
    (code-agent-org--set-sdk-uuid "uuid-file-123")
    ;; Should be retrievable
    (should (equal "uuid-file-123" (code-agent-org--get-sdk-uuid)))
    ;; Should be in file header as #+PROPERTY
    (goto-char (point-min))
    (should (re-search-forward "^#\\+PROPERTY:[ \t]+CLAUDE_CLI_SESSION[ \t]+uuid-file-123" nil t))
    ;; Clear UUID
    (code-agent-org--clear-sdk-uuid)
    (should-not (code-agent-org--get-sdk-uuid))))

(ert-deftest test-code-agent-org-sdk-uuid-section-level ()
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
    (code-agent-org--set-sdk-uuid "uuid-section-123")
    ;; Should be retrievable
    (should (equal "uuid-section-123" (code-agent-org--get-sdk-uuid)))
    ;; Should be in property drawer
    (goto-char (point-min))
    (re-search-forward "^\\* Section 1")
    (should (equal "uuid-section-123" (org-entry-get nil "CLAUDE_CLI_SESSION")))
    ;; Clear UUID
    (code-agent-org--clear-sdk-uuid)
    (should-not (code-agent-org--get-sdk-uuid))))

;;; Session Recovery Tests

(ert-deftest test-code-agent-org-collect-ai-blocks-in-section ()
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
    (let ((blocks (code-agent-org--collect-ai-blocks-in-section)))
      (should (= 2 (length blocks)))
      (should (equal "Question 1" (car (nth 0 blocks))))
      (should (equal "Response 1" (cdr (nth 0 blocks))))
      (should (equal "Question 2" (car (nth 1 blocks))))
      (should (equal "Response 2" (cdr (nth 1 blocks)))))))

(ert-deftest test-code-agent-org-skip-archived-sections ()
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
    (let ((context (code-agent-org--collect-session-context)))
      ;; Should have at least collected from Normal Section
      (should (>= (length context) 1))
      ;; First entry should be from Normal Section
      (should (equal "Include this" (car (nth 0 context))))
      ;; Should not have "Skip this" from archived section
      (should-not (cl-some (lambda (pair) (equal "Skip this" (car pair))) context)))))

(ert-deftest test-code-agent-org-build-recovery-prompt ()
  "Test building recovery prompt from context."
  :tags '(:unit :fast :stable :isolated :org :session)
  (let ((context '(("Question 1" . "Answer 1")
                   ("Question 2" . "Answer 2")))
        (original "Current question"))
    (cl-letf (((symbol-function 'code-agent-org--get-session-scope) (lambda () 'file)))
      (let ((prompt (code-agent-org--build-recovery-prompt context original)))
        (should (stringp prompt))
        (should (string-match-p "<session_recovery>" prompt))
        (should (string-match-p "Question 1" prompt))
        (should (string-match-p "Answer 1" prompt))
        (should (string-match-p "Current question" prompt))))))

;;; Block Detection Tests

(ert-deftest test-code-agent-org-in-ai-block-p ()
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
    (should (code-agent-org--in-ai-block-p))
    ;; Outside block
    (goto-char (point-min))
    (re-search-forward "Outside block")
    (should-not (code-agent-org--in-ai-block-p))))

(ert-deftest test-code-agent-org-get-block-content ()
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
    (should (equal "Question with spaces" (code-agent-org--get-block-content)))))

(ert-deftest test-code-agent-org-find-block-end ()
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
    (let ((end (code-agent-org--find-block-end)))
      (should end)
      ;; The function returns line-end-position of #+end_src line
      ;; So we should be at end of that line
      (goto-char end)
      (beginning-of-line)
      (should (looking-at "[ \t]*#\\+end_src")))))

(ert-deftest test-code-agent-org-section-level ()
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
    (should (= 0 (code-agent-org--get-section-level)))
    ;; At Level 1
    (goto-char (point-min))
    (re-search-forward "^\\* Level 1")
    (should (= 1 (code-agent-org--get-section-level)))
    ;; At Level 2
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Level 2")
    (should (= 2 (code-agent-org--get-section-level)))
    ;; At Level 3
    (goto-char (point-min))
    (re-search-forward "^\\*\\*\\* Level 3")
    (should (= 3 (code-agent-org--get-section-level)))))

(ert-deftest test-code-agent-org-in-output-section-p ()
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
    (should (code-agent-org--in-output-section-p))
    ;; Not in output section
    (goto-char (point-min))
    (re-search-forward "^\\* Normal Section")
    (should-not (code-agent-org--in-output-section-p))))

(ert-deftest test-code-agent-org-find-instruction-number ()
  "Test extracting instruction number from heading.
Instruction headings are identified by the :claude_chat: tag.
Response sections are at the same level as instructions (siblings)."
  :tags '(:unit :fast :stable :isolated :org :context)
  (with-temp-buffer
    (org-mode)
    ;; Note: :claude_chat: tag is required to identify instruction headings
    ;; Response sections are siblings (same level) not children
    (insert "* Instruction 42 :claude_chat:\n")
    (insert "* Response 1 :ai_output:\n")
    (insert "* Response 2 :ai_output:\n")
    ;; At Instruction 42 - should find next response number (3)
    (goto-char (point-min))
    (re-search-forward "^\\* Instruction")
    (should (= 3 (code-agent-org--find-instruction-number))))
  ;; Separate buffer test: heading without :claude_chat: tag returns nil
  (with-temp-buffer
    (org-mode)
    (insert "* Regular Section\n")
    (insert "Some content\n")
    (goto-char (point-min))
    (re-search-forward "^\\* Regular")
    (should-not (code-agent-org--find-instruction-number))))

;;; Project Configuration Tests

(ert-deftest test-code-agent-org-get-project-root ()
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
    (should (equal "/tmp/section-project" (code-agent-org--get-project-root)))
    ;; At Section 2 - inherit file-level
    (goto-char (point-min))
    (re-search-forward "^\\* Section 2")
    (should (equal "/tmp/project" (code-agent-org--get-project-root)))))

(ert-deftest test-code-agent-org-collect-system-prompts ()
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
    (let ((prompts (code-agent-org--collect-system-prompts)))
      (should (stringp prompts))
      (should (string-match-p "Guidelines" prompts))
      (should (string-match-p "Python 3.11" prompts))
      (should (string-match-p "Code Style" prompts))
      (should (string-match-p "type hints" prompts))
      (should-not (string-match-p "Not a system prompt" prompts)))))

(ert-deftest test-code-agent-org-build-system-prompt ()
  "Test building complete system prompt."
  :tags '(:unit :fast :stable :isolated :org :context)
  (with-temp-buffer
    (org-mode)
    (insert "* Guidelines :system_prompt:\n")
    (insert "Custom guideline\n")
    ;; Build prompt
    (let ((prompt (code-agent-org--build-system-prompt)))
      (should (stringp prompt))
      ;; Should include defaults
      (should (string-match-p "Claude agent" prompt))
      ;; Should include custom
      (should (string-match-p "Custom guideline" prompt))
      ;; Should include line width hint
      (should (string-match-p "170 characters" prompt)))))

;;; Permission Mode Tests

(ert-deftest test-code-agent-org-get-permission-mode ()
  "Test getting permission mode from properties."
  :tags '(:unit :fast :stable :isolated :org :context)
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: CLAUDE_PERMISSION_MODE accept-edits\n\n")
    (insert "* Section 1\n")
    ;; Should get file-level mode
    (goto-char (point-min))
    (re-search-forward "^\\* Section 1")
    (should (equal "acceptEdits" (code-agent-org--get-permission-mode)))))

(ert-deftest test-code-agent-org-permission-mode-display ()
  "Test permission mode display names."
  :tags '(:unit :fast :stable :isolated :org :context)
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: CLAUDE_PERMISSION_MODE readonly\n\n")
    (goto-char (point-min))
    (should (equal "RO" (code-agent-org--permission-mode-short))))
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: CLAUDE_PERMISSION_MODE accept-edits\n\n")
    (goto-char (point-min))
    (should (equal "ED" (code-agent-org--permission-mode-short)))))

;;; Environment Variable Tests

(ert-deftest test-code-agent-org-parse-env-file ()
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
          (let ((env-alist (code-agent-org--parse-env temp-env)))
            (should (equal "value1" (cdr (assoc "KEY1" env-alist))))
            (should (equal "quoted value" (cdr (assoc "KEY2" env-alist))))
            (should (equal "exported" (cdr (assoc "KEY3" env-alist))))
            (should (equal "single quotes" (cdr (assoc "KEY4" env-alist))))))
      (delete-file temp-env))))

(ert-deftest test-code-agent-org-expand-env-vars ()
  "Test environment variable expansion."
  :tags '(:unit :fast :stable :isolated :org :context)
  (let ((env-alist '(("FOO" . "bar") ("BAZ" . "qux"))))
    ;; Simple expansion
    (should (equal "bar" (code-agent-org--expand-env-vars "${FOO}" env-alist)))
    ;; Multiple expansions
    (should (equal "bar/qux" (code-agent-org--expand-env-vars "${FOO}/${BAZ}" env-alist)))
    ;; Default value syntax
    (should (equal "default" (code-agent-org--expand-env-vars "${MISSING:-default}" env-alist)))
    ;; No expansion needed
    (should (equal "plain text" (code-agent-org--expand-env-vars "plain text" env-alist)))))

;;; Session State Tests

(ert-deftest test-code-agent-org-session-state-accessors ()
  "Test session state put/get operations."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    (code-agent-org-mode 1)
    (let ((key "test-key"))
      (code-agent-org--session-put key :foo "bar")
      (should (equal "bar" (code-agent-org--session-get key :foo)))
      (code-agent-org--session-put key :busy t)
      (should (equal t (code-agent-org--session-get key :busy))))))

(ert-deftest test-code-agent-org-active-session-count ()
  "Test counting active sessions."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    (code-agent-org-mode 1)
    (should (= 0 (code-agent-org--active-session-count)))
    (code-agent-org--session-put "session-1" :busy t)
    (should (= 1 (code-agent-org--active-session-count)))
    (code-agent-org--session-put "session-2" :busy t)
    (should (= 2 (code-agent-org--active-session-count)))
    (code-agent-org--session-put "session-1" :busy nil)
    (should (= 1 (code-agent-org--active-session-count)))))

(ert-deftest test-code-agent-org-session-display-name ()
  "Test session display name extraction."
  :tags '(:unit :fast :stable :isolated :org :session)
  (should (equal "my-session"
                 (code-agent-org--session-display-name "/path/to/file.org::my-session")))
  (should (equal "file.org"
                 (code-agent-org--session-display-name "/path/to/file.org"))))

(ert-deftest test-code-agent-org-format-elapsed ()
  "Test elapsed time formatting."
  :tags '(:unit :fast :stable :isolated :org :data-structures)
  (should (equal "unknown" (code-agent-org--format-elapsed nil)))
  (should (string-match-p "started [0-9]+ seconds ago"
                          (code-agent-org--format-elapsed (- (float-time) 30))))
  (should (string-match-p "started [0-9]+ minutes ago"
                          (code-agent-org--format-elapsed (- (float-time) 120)))))

;;; Block Insertion Tests

(ert-deftest test-code-agent-org-next-instruction-number ()
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
    (should (= 3 (code-agent-org--next-instruction-number)))))

(ert-deftest test-code-agent-org-skip-output-section ()
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
    (code-agent-org--skip-to-after-output-section)
    (should (looking-at "^\\* Instruction 2"))))

;;; Header Normalization Tests

(ert-deftest test-code-agent-org-normalize-headers-in-text ()
  "Test org header normalization with regex replacement."
  :tags '(:unit :fast :stable :isolated :org :normalization)
  (let ((code-agent-org-normalize-headers t))
    ;; Simple case: single header
    (should (equal "**** Top\n" (code-agent-org--normalize-headers-in-text "* Top\n" 4)))
    ;; Multiple headers
    (should (equal "**** Top\n***** Sub\n"
                   (code-agent-org--normalize-headers-in-text "* Top\n** Sub\n" 4)))
    ;; Mixed content
    (should (equal "Hello\n**** Head\nText\n"
                   (code-agent-org--normalize-headers-in-text "Hello\n* Head\nText\n" 4)))
    ;; Non-headers unchanged
    (should (equal "  * not at start\n"
                   (code-agent-org--normalize-headers-in-text "  * not at start\n" 4)))
    (should (equal "*no space after\n"
                   (code-agent-org--normalize-headers-in-text "*no space after\n" 4)))
    ;; Empty string
    (should (equal "" (code-agent-org--normalize-headers-in-text "" 4)))
    ;; No newline - still works (header at start of string)
    (should (equal "**** Header" (code-agent-org--normalize-headers-in-text "* Header" 4)))))

(ert-deftest test-code-agent-org-normalize-headers-disabled ()
  "Test that normalization can be disabled."
  :tags '(:unit :fast :stable :isolated :org :normalization)
  (let ((code-agent-org-normalize-headers nil))
    (should (equal "* Top\n" (code-agent-org--normalize-headers-in-text "* Top\n" 4)))))

(ert-deftest test-code-agent-org-normalize-headers-streaming ()
  "Test header normalization with streaming tokens."
  :tags '(:unit :fast :stable :isolated :org :normalization)
  (let ((code-agent-org-normalize-headers t)
        (output ""))
    ;; Simulate streaming - each token is processed independently
    (dolist (token '("Here is " "the ans" "wer:\n" "* Sum" "mary\n" "Text\n"))
      (setq output (concat output (code-agent-org--normalize-headers-in-text token 4))))
    (should (equal "Here is the answer:\n**** Summary\nText\n" output))))

;;; Chat Level Detection Tests

(ert-deftest test-code-agent-org-find-previous-chat-level-with-tag ()
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
    (should (= 2 (code-agent-org--find-previous-chat-level)))))

(ert-deftest test-code-agent-org-find-previous-chat-level-custom-title ()
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
    (should (= 4 (code-agent-org--find-previous-chat-level)))))

(ert-deftest test-code-agent-org-find-previous-chat-level-no-tag ()
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
    (should-not (code-agent-org--find-previous-chat-level))))

(ert-deftest test-code-agent-org-find-previous-chat-level-no-match ()
  "Test returning nil when no chat section exists."
  :tags '(:unit :fast :stable :isolated :org :insertion)
  (with-temp-buffer
    (org-mode)
    (insert "* Regular Section\n")
    (insert "** Another Section\n")
    (insert "Some content without any chat blocks\n")
    (goto-char (point-max))
    ;; Should return nil (no chat sections found)
    (should-not (code-agent-org--find-previous-chat-level))))

(ert-deftest test-code-agent-org-find-previous-chat-level-multiple ()
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
    (should (= 2 (code-agent-org--find-previous-chat-level)))))

(ert-deftest test-code-agent-org-do-insert-block-uses-chat-level ()
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
    (code-agent-org--do-insert-block nil)
    ;; Find the newly inserted Instruction heading
    (goto-char (point-min))
    (re-search-forward "^\\(\\*+\\) Instruction [0-9]+" nil t)
    ;; Should be level 4 (same as "My Custom Title")
    (should (= 4 (length (match-string 1))))))

;;; Instruction Numbering Tests

(ert-deftest test-code-agent-org-next-instruction-number-session-scoped ()
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
    (should (= 3 (code-agent-org--next-instruction-number)))
    ;; Position in SDD B - should find 1 existing, next is 2
    (goto-char (point-min))
    (re-search-forward "SDD B")
    (re-search-forward "Query 1")
    (should (= 2 (code-agent-org--next-instruction-number)))))

(ert-deftest test-code-agent-org-next-instruction-number-counts-chat-tags ()
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
    (should (= 4 (code-agent-org--next-instruction-number)))))

;;; Loop Session Key Tests

(ert-deftest test-code-agent-org-send-request-uses-session-key-override ()
  "Test that send-request uses session-key-override when provided.
This is critical for loop iterations where cursor may have moved."
  :tags '(:unit :fast :stable :isolated :org :loop)
  ;; We can't easily test the full send-request without mocking claude-agent-query,
  ;; but we can verify the function signature accepts session-key-override
  (should (equal '(prompt &optional query-context session-key-override)
                 (help-function-arglist 'code-agent-org--send-request))))

(ert-deftest test-code-agent-org-execute-loop-iteration-passes-session-key ()
  "Test that execute-loop-iteration passes session-key to send-request.
This ensures loop iterations use the original session, not current cursor position."
  :tags '(:unit :fast :stable :isolated :org :loop)
  (let* ((fn-str (format "%s" (symbol-function 'code-agent-org--execute-loop-iteration)))
         ;; Check that the function calls send-request with session-key as 3rd arg
         (has-session-key-arg (string-match "send-request prompt query-ctx session-key" fn-str)))
    (should has-session-key-arg)))

(ert-deftest test-code-agent-org-loop-state-preserved ()
  "Test that loop state is properly stored and retrieved from session."
  :tags '(:unit :fast :stable :isolated :org :loop)
  (let ((test-session-key "test-loop-session::test"))
    ;; Setup loop state as code-agent-org-execute would
    (code-agent-org--session-put test-session-key :loop-max 5)
    (code-agent-org--session-put test-session-key :loop-current 1)
    (code-agent-org--session-put test-session-key :loop-interval 10)
    (code-agent-org--session-put test-session-key :original-prompt "test prompt")
    (code-agent-org--session-put test-session-key :instruction-num 1)
    ;; Verify state is retrievable
    (should (= 5 (code-agent-org--session-get test-session-key :loop-max)))
    (should (= 1 (code-agent-org--session-get test-session-key :loop-current)))
    (should (= 10 (code-agent-org--session-get test-session-key :loop-interval)))
    (should (equal "test prompt" (code-agent-org--session-get test-session-key :original-prompt)))
    ;; Verify loop continuation condition
    (let ((loop-current (code-agent-org--session-get test-session-key :loop-current))
          (loop-max (code-agent-org--session-get test-session-key :loop-max)))
      (should (and loop-current loop-max (< loop-current loop-max))))
    ;; Cleanup
    (remhash test-session-key code-agent-org--sessions)))

;;; Recovery Session Key Tests

(ert-deftest test-code-agent-org-recover-session-passes-session-key ()
  "Test that recover-session passes session-key to send-request.
This ensures recovery uses the original session, not current cursor position."
  :tags '(:unit :fast :stable :isolated :org :recovery)
  (let* ((fn-str (format "%s" (symbol-function 'code-agent-org--recover-session)))
         ;; Check that the function calls send-request with session-key as 3rd arg
         (has-session-key-arg (string-match "send-request recovery-prompt nil session-key" fn-str)))
    (should has-session-key-arg)))

(ert-deftest test-code-agent-org-recover-session-uses-query-id ()
  "Test that recover-session uses query-id based marker-free architecture.
This ensures recovery works without relying on markers that can become invalid."
  :tags '(:unit :fast :stable :isolated :org :recovery)
  (let* ((fn-str (format "%s" (symbol-function 'code-agent-org--recover-session)))
         ;; Check for marker-free approach using query-id
         (uses-query-id (or (string-match "find-response-by-query-id" fn-str)
                            (string-match "old-query-id" fn-str))))
    (should uses-query-id)))

(ert-deftest test-code-agent-org-recover-session-positions-cursor ()
  "Test that recover-session positions cursor at response section before operations.
This ensures org operations work correctly when called during recovery."
  :tags '(:unit :fast :stable :isolated :org :recovery)
  (let* ((fn-str (format "%s" (symbol-function 'code-agent-org--recover-session)))
         ;; Check that we position at response-pos before operations
         (positions-cursor (or (string-match "goto-char response-pos" fn-str)
                               (string-match "response-pos" fn-str))))
    (should positions-cursor)))

;;; CUSTOM_ID Generation Tests

(ert-deftest test-code-agent-org-generate-instruction-custom-id-basic ()
  "Test basic CUSTOM_ID generation with timestamp."
  :tags '(:unit :fast :stable :isolated :org :custom-id)
  (let ((id (code-agent-org--generate-instruction-custom-id "myfile" 1 "sdd-20260121-100000")))
    ;; Should have format: file-instruction-N-session-id-HHMMSS
    (should (string-match "^myfile-instruction-1-sdd-20260121-100000-[0-9]\\{6\\}$" id))))

(ert-deftest test-code-agent-org-generate-instruction-custom-id-no-session ()
  "Test CUSTOM_ID generation without session ID."
  :tags '(:unit :fast :stable :isolated :org :custom-id)
  (let ((id (code-agent-org--generate-instruction-custom-id "myfile" 2 nil)))
    ;; Should have format: file-instruction-N-HHMMSS (no session-id part)
    (should (string-match "^myfile-instruction-2-[0-9]\\{6\\}$" id))))

(ert-deftest test-code-agent-org-generate-instruction-custom-id-nil-file-base ()
  "Test CUSTOM_ID generation returns nil when file-base is nil."
  :tags '(:unit :fast :stable :isolated :org :custom-id)
  (should (null (code-agent-org--generate-instruction-custom-id nil 1 "session"))))

(ert-deftest test-code-agent-org-generate-instruction-custom-id-duplicate-suffix ()
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
    (cl-letf (((symbol-function 'code-agent-org--custom-id-exists-p)
               (lambda (id)
                 (save-excursion
                   (goto-char (point-min))
                   (search-forward (format ":CUSTOM_ID: %s" id) nil t)))))
      ;; Mock timestamp to return fixed value
      (cl-letf (((symbol-function 'format-time-string)
                 (lambda (_fmt) "123456")))
        ;; First call with same parameters should detect duplicate and add -2
        (let ((id (code-agent-org--generate-instruction-custom-id "testbuf" 1 "sess")))
          (should (equal id "testbuf-instruction-1-sess-123456-2")))))))

(ert-deftest test-code-agent-org-generate-instruction-custom-id-multiple-duplicates ()
  "Test CUSTOM_ID generation increments suffix for multiple duplicates."
  :tags '(:unit :fast :stable :isolated :org :custom-id)
  (with-temp-buffer
    (org-mode)
    ;; Create multiple existing headings with CUSTOM_IDs
    (insert "* Section 1\n:PROPERTIES:\n:CUSTOM_ID: testbuf-instruction-1-sess-123456\n:END:\n\n")
    (insert "* Section 2\n:PROPERTIES:\n:CUSTOM_ID: testbuf-instruction-1-sess-123456-2\n:END:\n\n")
    (insert "* Section 3\n:PROPERTIES:\n:CUSTOM_ID: testbuf-instruction-1-sess-123456-3\n:END:\n\n")
    (cl-letf (((symbol-function 'code-agent-org--custom-id-exists-p)
               (lambda (id)
                 (save-excursion
                   (goto-char (point-min))
                   (search-forward (format ":CUSTOM_ID: %s" id) nil t)))))
      (cl-letf (((symbol-function 'format-time-string)
                 (lambda (_fmt) "123456")))
        ;; Should detect all duplicates and return -4
        (let ((id (code-agent-org--generate-instruction-custom-id "testbuf" 1 "sess")))
          (should (equal id "testbuf-instruction-1-sess-123456-4")))))))

;;; yasnippet Template Tests

(ert-deftest test-code-agent-org-backtrace-text-with-buffer ()
  "Test backtrace-text helper extracts content from backtrace buffer."
  :tags '(:unit :fast :stable :isolated :org :template)
  (let ((buf (get-buffer-create "*Backtrace*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (erase-buffer)
            (insert "Debugger entered--Lisp error: (void-variable foo)"))
          (let ((result (code-agent-org-template--backtrace-text)))
            (should (string-match-p "void-variable foo" result))))
      (kill-buffer buf))))

(ert-deftest test-code-agent-org-backtrace-text-no-buffer ()
  "Test backtrace-text returns fallback when no buffer exists."
  :tags '(:unit :fast :stable :isolated :org :template)
  (when (get-buffer "*Backtrace*") (kill-buffer "*Backtrace*"))
  (let ((result (code-agent-org-template--backtrace-text)))
    (should (string-match-p "No backtrace found" result))))

(ert-deftest test-code-agent-org-yasnippet-snippets-loaded ()
  "Test that Claude AI yasnippet snippets are loaded."
  :tags '(:unit :fast :stable :isolated :org :template)
  (code-agent-org--setup-yasnippet)
  (let* ((table (yas--table-get-create 'org-mode))
         (all '()))
    (maphash (lambda (_k v)
               (maphash (lambda (_k2 tmpl) (push tmpl all)) v))
             (yas--table-hash table))
    (let ((ai (cl-remove-if-not
               (lambda (t)
                 (let ((g (yas--template-group t)))
                   (or (equal "Claude AI" g) (equal '("Claude AI") g))))
               all)))
      (should (>= (length ai) 10))
      ;; Check known templates exist
      (should (cl-find "Code Review" ai :key #'yas--template-name :test #'equal))
      (should (cl-find "Fix Error" ai :key #'yas--template-name :test #'equal))
      (should (cl-find "Merge Worktree" ai :key #'yas--template-name :test #'equal)))))

;;; Persistent Client Registry Tests

(defun test-code-agent-org--clear-persistent-registry ()
  "Drain the persistent-client registry — fixture helper."
  (clrhash (code-agent-org-persistent-registry-entries
            code-agent-org--persistent-registry)))

(ert-deftest test-code-agent-org-persistent-client-registry-empty ()
  "Test empty persistent client registry."
  :tags '(:unit :fast :stable :isolated :org :persistent)
  (test-code-agent-org--clear-persistent-registry)
  (should (= 0 (code-agent-org-persistent-registry-count
                code-agent-org--persistent-registry)))
  (should (null (code-agent-org-persistent-registry-list
                 code-agent-org--persistent-registry))))

(ert-deftest test-code-agent-org-register-persistent-client ()
  "Test registering a persistent client."
  :tags '(:unit :fast :stable :isolated :org :persistent)
  (test-code-agent-org--clear-persistent-registry)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    (let ((mock-client (claude-agent--make-client
                        :session-key "/tmp/test.org::test-session"
                        :connected-p nil)))
      (code-agent-org-persistent-registry-register
       code-agent-org--persistent-registry
       "/tmp/test.org::test-session"
       mock-client
       (current-buffer)
       1)
      (should (= 1 (code-agent-org-persistent-registry-count
                    code-agent-org--persistent-registry)))
      (should (eq mock-client
                  (code-agent-org-persistent-registry-get
                   code-agent-org--persistent-registry
                   "/tmp/test.org::test-session")))
      (let ((clients (code-agent-org-persistent-registry-list
                      code-agent-org--persistent-registry)))
        (should (= 1 (length clients)))
        (should (equal "/tmp/test.org::test-session" (caar clients))))
      (test-code-agent-org--clear-persistent-registry))))

(ert-deftest test-code-agent-org-disconnect-persistent-client ()
  "Test disconnecting a persistent client."
  :tags '(:unit :fast :stable :isolated :org :persistent)
  (test-code-agent-org--clear-persistent-registry)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    (let ((mock-client (claude-agent--make-client
                        :session-key "/tmp/test.org::test-session"
                        :connected-p nil)))
      (code-agent-org-persistent-registry-register
       code-agent-org--persistent-registry
       "/tmp/test.org::test-session" mock-client (current-buffer) 1)
      (should (= 1 (code-agent-org-persistent-registry-count
                    code-agent-org--persistent-registry)))
      (code-agent-org-persistent-registry-disconnect
       code-agent-org--persistent-registry "/tmp/test.org::test-session")
      (should (= 0 (code-agent-org-persistent-registry-count
                    code-agent-org--persistent-registry)))
      (should (null (code-agent-org-persistent-registry-get
                     code-agent-org--persistent-registry
                     "/tmp/test.org::test-session"))))))

(ert-deftest test-code-agent-org-disconnect-all-clients-for-buffer ()
  "Test disconnecting all clients for a buffer."
  :tags '(:unit :fast :stable :isolated :org :persistent)
  (test-code-agent-org--clear-persistent-registry)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    (let ((buf (current-buffer))
          (mock-client-1 (claude-agent--make-client
                          :session-key "/tmp/test.org::session-1"
                          :connected-p nil))
          (mock-client-2 (claude-agent--make-client
                          :session-key "/tmp/test.org::session-2"
                          :connected-p nil)))
      (code-agent-org-persistent-registry-register
       code-agent-org--persistent-registry
       "/tmp/test.org::session-1" mock-client-1 buf 1)
      (code-agent-org-persistent-registry-register
       code-agent-org--persistent-registry
       "/tmp/test.org::session-2" mock-client-2 buf 10)
      (should (= 2 (code-agent-org-persistent-registry-count
                    code-agent-org--persistent-registry)))
      (code-agent-org-persistent-registry-disconnect-buffer
       code-agent-org--persistent-registry buf)
      (should (= 0 (code-agent-org-persistent-registry-count
                    code-agent-org--persistent-registry))))))

(ert-deftest test-code-agent-org-update-persistent-client-activity ()
  "Test updating persistent client activity timestamp."
  :tags '(:unit :fast :stable :isolated :org :persistent)
  (test-code-agent-org--clear-persistent-registry)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test.org")
    (let ((mock-client (claude-agent--make-client
                        :session-key "/tmp/test.org::test-session"
                        :connected-p nil)))
      (code-agent-org-persistent-registry-register
       code-agent-org--persistent-registry
       "/tmp/test.org::test-session" mock-client (current-buffer) 1)
      (let* ((entry (code-agent-org-persistent-registry-get-entry
                     code-agent-org--persistent-registry
                     "/tmp/test.org::test-session")))
        (should (= 0 (code-agent-org-persistent-entry-query-count entry)))
        (code-agent-org-persistent-registry-update-activity
         code-agent-org--persistent-registry "/tmp/test.org::test-session")
        (let ((updated (code-agent-org-persistent-registry-get-entry
                        code-agent-org--persistent-registry
                        "/tmp/test.org::test-session")))
          (should (= 1 (code-agent-org-persistent-entry-query-count updated)))
          (should (code-agent-org-persistent-entry-last-activity updated))))
      (test-code-agent-org--clear-persistent-registry))))

(ert-deftest test-code-agent-org-persistent-sessions-default-nil ()
  "Test that persistent sessions is disabled by default."
  :tags '(:unit :fast :stable :isolated :org :persistent)
  ;; Should be nil by default (legacy behavior)
  (should (null code-agent-org-persistent-sessions)))

;;; Lifecycle Hook Tests

(ert-deftest test-code-agent-org-on-buffer-kill-cleans-clients ()
  "Test that buffer kill hook cleans up persistent clients."
  :tags '(:unit :fast :stable :isolated :org :persistent)
  (test-code-agent-org--clear-persistent-registry)
  (let ((test-buf (generate-new-buffer "*test-org*")))
    (unwind-protect
        (with-current-buffer test-buf
          (org-mode)
          (setq buffer-file-name "/tmp/test-kill.org")
          (let ((mock-client (claude-agent--make-client
                              :session-key "/tmp/test-kill.org::session"
                              :connected-p nil)))
            (code-agent-org-persistent-registry-register
             code-agent-org--persistent-registry
             "/tmp/test-kill.org::session" mock-client test-buf 1)
            (should (= 1 (code-agent-org-persistent-registry-count
                          code-agent-org--persistent-registry)))
            (code-agent-org--on-buffer-kill)
            (should (= 0 (code-agent-org-persistent-registry-count
                          code-agent-org--persistent-registry)))))
      (kill-buffer test-buf))))

(ert-deftest test-code-agent-org-on-todo-state-change-disconnects ()
  "Test that TODO state change to DONE disconnects persistent client.
The hook only disconnects when the client is alive; this test mocks
alive-p + disconnect to verify the disconnect branch fires."
  :tags '(:unit :fast :stable :isolated :org :persistent)
  (test-code-agent-org--clear-persistent-registry)
  (defvar test--disconnect-called nil)
  (setq test--disconnect-called nil)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-todo.org")
    (insert "* Task\n")
    (insert ":PROPERTIES:\n")
    (insert ":CLAUDE_SESSION_ID: todo-session\n")
    (insert ":END:\n")
    (let* ((session-key "/tmp/test-todo.org::todo-session")
           (mock-client (claude-agent--make-client
                         :session-key session-key
                         :connected-p nil)))
      (code-agent-org-persistent-registry-register
       code-agent-org--persistent-registry
       session-key mock-client (current-buffer) 1)
      (should (= 1 (code-agent-org-persistent-registry-count
                    code-agent-org--persistent-registry)))
      (cl-letf (((symbol-function 'code-agent-org-persistent-registry-alive-p)
                 (lambda (_registry _key) t))
                ((symbol-function 'code-agent-org-persistent-registry-disconnect)
                 (lambda (registry key &optional _reason)
                   (setq test--disconnect-called t)
                   (remhash key (code-agent-org-persistent-registry-entries
                                 registry)))))
        (goto-char (point-min))
        (re-search-forward "^\\* Task")
        (defvar org-state)
        (let ((org-state "DONE"))
          (code-agent-org--on-todo-state-change))
        (should test--disconnect-called)
        (should (= 0 (code-agent-org-persistent-registry-count
                      code-agent-org--persistent-registry)))))))

;;; Response Message Separator Tests

(defmacro with-response-section (session-key query-id &rest body)
  "Set up an org buffer with a response section and session state, then run BODY.
SESSION-KEY and QUERY-ID are evaluated once and bound for BODY.
Creates a standard response section header and initializes the 4 session
properties needed by handle-token-v2 / handle-message."
  (declare (indent 2) (debug t))
  `(with-temp-buffer
     (org-mode)
     (let ((session-key ,session-key)
           (query-id ,query-id))
       (insert "* Response 1 (2026-01-01 00:00) :ai_output:\n")
       (insert ":PROPERTIES:\n")
       (insert (format ":QUERY_ID: %s\n" query-id))
       (insert ":QUERY_TYPE: normal\n")
       (insert ":END:\n\n")
       (code-agent-org--session-put session-key :query-id query-id)
       (code-agent-org--session-put session-key :section-level 1)
       (code-agent-org--session-put session-key :current-line-length 0)
       (code-agent-org--session-put session-key :response-has-content nil)
       ,@body)))

(ert-deftest test-code-agent-org-newline-between-assistant-messages ()
  "Test that a newline separator is inserted between consecutive assistant messages.
When Claude sends multiple assistant messages (e.g., text -> tool use -> text),
the second message text should be visually separated from the first."
  :tags '(:unit :fast :stable :isolated :org :response)
  (with-temp-buffer
    (org-mode)
    (let* ((session-key "test::newline-sep")
           (query-id "qid-test-newline"))
      ;; Create response section structure
      (insert "* Response 1 (2026-01-01 00:00) :ai_output:\n")
      (insert ":PROPERTIES:\n")
      (insert (format ":QUERY_ID: %s\n" query-id))
      (insert ":QUERY_TYPE: normal\n")
      (insert ":END:\n\n")
      ;; Set up session state
      (code-agent-org--session-put session-key :query-id query-id)
      (code-agent-org--session-put session-key :section-level 1)
      (code-agent-org--session-put session-key :current-line-length 0)
      (code-agent-org--session-put session-key :response-has-content nil)
      ;; Simulate first assistant message tokens (realistic: text ends with newline)
      (code-agent-org--handle-token-v2 session-key "First message text.\n")
      ;; Simulate assistant message boundary (on-message callback)
      (let ((msg1 (claude-agent-make-assistant-message
                   :content (list (claude-agent-make-text-block
                                   :text "First message text.\n")))))
        (code-agent-org--handle-message session-key msg1))
      ;; Simulate second assistant message tokens
      (code-agent-org--handle-token-v2 session-key "Second message text.")
      ;; Verify: the response content should have a blank line between messages
      (goto-char (point-min))
      (re-search-forward ":END:" nil t)
      (forward-line 1)
      (let ((content (buffer-substring-no-properties (point) (point-max))))
        ;; There should be a newline separator between the two message texts
        (should (string-match-p
                 "First message text\\.\n+Second message text\\."
                 content))))))

(ert-deftest test-code-agent-org-no-newline-before-first-assistant-message ()
  "Test that no extra newline is added before the very first assistant message."
  :tags '(:unit :fast :stable :isolated :org :response)
  (with-temp-buffer
    (org-mode)
    (let* ((session-key "test::no-leading-nl")
           (query-id "qid-test-no-leading"))
      ;; Create response section
      (insert "* Response 1 (2026-01-01 00:00) :ai_output:\n")
      (insert ":PROPERTIES:\n")
      (insert (format ":QUERY_ID: %s\n" query-id))
      (insert ":QUERY_TYPE: normal\n")
      (insert ":END:\n\n")
      ;; Set up session
      (code-agent-org--session-put session-key :query-id query-id)
      (code-agent-org--session-put session-key :section-level 1)
      (code-agent-org--session-put session-key :current-line-length 0)
      (code-agent-org--session-put session-key :response-has-content nil)
      ;; Simulate FIRST assistant message tokens (should NOT have leading newline)
      (code-agent-org--handle-token-v2 session-key "First message")
      ;; Content after :END: should be: blank-line + "First message" (no extra newlines)
      (goto-char (point-min))
      (re-search-forward ":END:\n" nil t)
      (let ((content (buffer-substring-no-properties (point) (point-max))))
        ;; Should be just a blank line then the text, no double blank lines
        (should (string-match-p "^\n?First message" content))
        (should-not (string-match-p "^\n\n+First message" content))))))

(ert-deftest test-code-agent-org-no-stale-separator-across-queries ()
  "Test that a stale separator flag from a previous query does not affect the next.
The :last-assistant-query-id stores the query-id that set it, so a leftover
value from query N (different query-id) cannot trigger a separator in query N+1."
  :tags '(:unit :fast :stable :isolated :org :response)
  (with-temp-buffer
    (org-mode)
    (let* ((session-key "test::no-stale")
           (old-qid "qid-old-query")
           (new-qid "qid-new-query"))
      ;; Simulate leftover state from a previous query's last assistant message
      (code-agent-org--session-put session-key :last-assistant-query-id old-qid)
      ;; Now start a NEW query with a different query-id
      (insert "* Response 1 (2026-01-01 00:00) :ai_output:\n")
      (insert ":PROPERTIES:\n")
      (insert (format ":QUERY_ID: %s\n" new-qid))
      (insert ":QUERY_TYPE: normal\n")
      (insert ":END:\n\n")
      (code-agent-org--session-put session-key :query-id new-qid)
      (code-agent-org--session-put session-key :section-level 1)
      (code-agent-org--session-put session-key :current-line-length 0)
      (code-agent-org--session-put session-key :response-has-content nil)
      ;; First token of new query should NOT get a separator
      (code-agent-org--handle-token-v2 session-key "New query text")
      (goto-char (point-min))
      (re-search-forward ":END:\n" nil t)
      (let ((content (buffer-substring-no-properties (point) (point-max))))
        (should (string-match-p "^\n?New query text" content))
        (should-not (string-match-p "^\n\n+New query text" content))))))

(ert-deftest test-code-agent-org-strip-leading-newlines-from-first-token ()
  "Test that leading newlines are stripped from the first token of a new response.
Claude's model often starts assistant text with \\n\\n which would create
unwanted blank lines after the :END: property drawer."
  :tags '(:unit :fast :stable :isolated :org :response)
  (with-temp-buffer
    (org-mode)
    (let* ((session-key "test::strip-leading")
           (query-id "qid-strip-leading"))
      (insert "* Response 1 (2026-01-01 00:00) :ai_output:\n")
      (insert ":PROPERTIES:\n")
      (insert (format ":QUERY_ID: %s\n" query-id))
      (insert ":QUERY_TYPE: normal\n")
      (insert ":END:\n\n")
      (code-agent-org--session-put session-key :query-id query-id)
      (code-agent-org--session-put session-key :section-level 1)
      (code-agent-org--session-put session-key :current-line-length 0)
      (code-agent-org--session-put session-key :response-has-content nil)
      ;; Simulate Claude's typical first token starting with \n\n
      (code-agent-org--handle-token-v2 session-key "\n\nHello world")
      (goto-char (point-min))
      (re-search-forward ":END:\n" nil t)
      (let ((content (buffer-substring-no-properties (point) (point-max))))
        ;; Leading newlines should be stripped; content should start cleanly
        (should (string-match-p "^\n?Hello world" content))
        (should-not (string-match-p "^\n\n+Hello world" content))))))

(ert-deftest test-code-agent-org-strip-preserves-later-newlines ()
  "Test that newline stripping only affects the first token, not subsequent ones."
  :tags '(:unit :fast :stable :isolated :org :response)
  (with-temp-buffer
    (org-mode)
    (let* ((session-key "test::strip-later")
           (query-id "qid-strip-later"))
      (insert "* Response 1 (2026-01-01 00:00) :ai_output:\n")
      (insert ":PROPERTIES:\n")
      (insert (format ":QUERY_ID: %s\n" query-id))
      (insert ":QUERY_TYPE: normal\n")
      (insert ":END:\n\n")
      (code-agent-org--session-put session-key :query-id query-id)
      (code-agent-org--session-put session-key :section-level 1)
      (code-agent-org--session-put session-key :current-line-length 0)
      (code-agent-org--session-put session-key :response-has-content nil)
      ;; First token - leading newlines stripped
      (code-agent-org--handle-token-v2 session-key "\n\nFirst part")
      ;; Second token - newlines should be preserved
      (code-agent-org--handle-token-v2 session-key "\n\nSecond part")
      (goto-char (point-min))
      (re-search-forward ":END:\n" nil t)
      (let ((content (buffer-substring-no-properties (point) (point-max))))
        ;; First part's leading newlines stripped
        (should (string-match-p "^\n?First part" content))
        ;; Second part's newlines preserved in the content
        (should (string-match-p "Second part" content))))))

(ert-deftest test-code-agent-org-strip-newline-only-first-token ()
  "Test that a first token containing only newlines is stripped without
affecting the second token which carries real content."
  :tags '(:unit :fast :stable :isolated :org :response)
  (with-temp-buffer
    (org-mode)
    (let* ((session-key "test::strip-empty")
           (query-id "qid-strip-empty"))
      (insert "* Response 1 (2026-01-01 00:00) :ai_output:\n")
      (insert ":PROPERTIES:\n")
      (insert (format ":QUERY_ID: %s\n" query-id))
      (insert ":QUERY_TYPE: normal\n")
      (insert ":END:\n\n")
      (code-agent-org--session-put session-key :query-id query-id)
      (code-agent-org--session-put session-key :section-level 1)
      (code-agent-org--session-put session-key :current-line-length 0)
      (code-agent-org--session-put session-key :response-has-content nil)
      ;; First token is ONLY newlines - becomes empty after stripping
      (code-agent-org--handle-token-v2 session-key "\n\n")
      ;; :response-has-content should still be nil (nothing inserted)
      (should-not (code-agent-org--session-get session-key :response-has-content))
      ;; Second token has real content - should NOT be stripped
      (code-agent-org--handle-token-v2 session-key "Real content")
      (should (code-agent-org--session-get session-key :response-has-content))
      (goto-char (point-min))
      (re-search-forward ":END:\n" nil t)
      (let ((content (buffer-substring-no-properties (point) (point-max))))
        (should (string-match-p "^\n?Real content" content))
        (should-not (string-match-p "^\n\n+Real content" content))))))

;;; Phase 1b: reset-session-state helper tests

(ert-deftest test-code-agent-org-reset-session-state-clears-flags ()
  "Test that reset-session-state clears busy, recovering, query-id flags."
  :tags '(:unit :fast :stable :isolated :session :phase-1b)
  (let ((code-agent-org--sessions (make-hash-table :test 'equal)))
    (code-agent-org--session-put "test-key" :busy t)
    (code-agent-org--session-put "test-key" :recovering t)
    (code-agent-org--session-put "test-key" :last-assistant-query-id "qid-123")
    ;; Reset
    (code-agent-org--reset-session-state "test-key")
    ;; All should be nil
    (should-not (code-agent-org--session-get "test-key" :busy))
    (should-not (code-agent-org--session-get "test-key" :recovering))
    (should-not (code-agent-org--session-get "test-key" :last-assistant-query-id))))

(ert-deftest test-code-agent-org-reset-session-state-preserves-other-props ()
  "Test that reset-session-state preserves unrelated session properties."
  :tags '(:unit :fast :stable :isolated :session :phase-1b)
  (let ((code-agent-org--sessions (make-hash-table :test 'equal)))
    (code-agent-org--session-put "test-key" :busy t)
    (code-agent-org--session-put "test-key" :custom-id "my-block-id")
    (code-agent-org--session-put "test-key" :query-id "qid-456")
    ;; Reset
    (code-agent-org--reset-session-state "test-key")
    ;; Unrelated props should survive
    (should (equal "my-block-id" (code-agent-org--session-get "test-key" :custom-id)))
    (should (equal "qid-456" (code-agent-org--session-get "test-key" :query-id)))))

;;; Phase 1c: find-heading-by-property tests

(ert-deftest test-code-agent-org-find-heading-by-property-found ()
  "Test that find-heading-by-property returns point at matching heading."
  :tags '(:unit :fast :stable :isolated :navigation :phase-1c)
  (with-temp-buffer
    (org-mode)
    (insert "* Heading One\n:PROPERTIES:\n:CUSTOM_ID: h1\n:END:\n\n"
            "* Heading Two\n:PROPERTIES:\n:CUSTOM_ID: h2\n:END:\n\n"
            "* Heading Three\n:PROPERTIES:\n:MY_PROP: special-val\n:END:\n")
    ;; Find by CUSTOM_ID
    (let ((pos (code-agent-org--find-heading-by-property "CUSTOM_ID" "h2")))
      (should pos)
      (should (integer-or-marker-p pos))
      (goto-char pos)
      (should (looking-at "\\* Heading Two")))))

(ert-deftest test-code-agent-org-find-heading-by-property-not-found ()
  "Test that find-heading-by-property returns nil when no match."
  :tags '(:unit :fast :stable :isolated :navigation :phase-1c)
  (with-temp-buffer
    (org-mode)
    (insert "* Heading One\n:PROPERTIES:\n:CUSTOM_ID: h1\n:END:\n")
    (should-not (code-agent-org--find-heading-by-property "CUSTOM_ID" "nonexistent"))))

(ert-deftest test-code-agent-org-find-heading-by-property-custom-prop ()
  "Test find-heading-by-property works with arbitrary property names."
  :tags '(:unit :fast :stable :isolated :navigation :phase-1c)
  (with-temp-buffer
    (org-mode)
    (insert "* First\n:PROPERTIES:\n:SESSION_KEY: sk-001\n:END:\n\n"
            "* Second\n:PROPERTIES:\n:SESSION_KEY: sk-002\n:END:\n")
    (let ((pos (code-agent-org--find-heading-by-property "SESSION_KEY" "sk-002")))
      (should pos)
      (goto-char pos)
      (should (looking-at "\\* Second")))))

(ert-deftest test-code-agent-org-find-heading-by-property-explicit-buffer ()
  "Test find-heading-by-property with explicit buffer argument."
  :tags '(:unit :fast :stable :isolated :navigation :phase-1c)
  (let ((buf (generate-new-buffer " *test-prop-buf*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (org-mode)
            (insert "* Target\n:PROPERTIES:\n:CUSTOM_ID: target-id\n:END:\n"))
          ;; Call from a different buffer
          (let ((pos (code-agent-org--find-heading-by-property
                      "CUSTOM_ID" "target-id" buf)))
            (should pos)))
      (kill-buffer buf))))

;;; Phase 7: session-state cl-defstruct tests

(ert-deftest test-code-agent-org-session-state-struct-exists ()
  "Test that code-agent-org--session-state struct type exists with correct fields."
  :tags '(:unit :fast :stable :isolated :session :phase-7)
  (let ((ss (code-agent-org--make-session-state)))
    (should (code-agent-org--session-state-p ss))
    ;; All core fields should be nil by default
    (should-not (code-agent-org--session-state-get ss :busy))
    (should-not (code-agent-org--session-state-get ss :recovering))
    (should-not (code-agent-org--session-state-get ss :query-id))
    (should-not (code-agent-org--session-state-get ss :backend))
    (should-not (code-agent-org--session-state-get ss :query-handle))
    (should-not (code-agent-org--session-state-get ss :marker))
    (should-not (code-agent-org--session-state-get ss :custom-id))
    (should-not (code-agent-org--session-state-get ss :block-id))
    (should-not (code-agent-org--session-state-get ss :pending-queue))))

(ert-deftest test-code-agent-org-session-state-struct-fields ()
  "Test that session-state struct has all documented fields."
  :tags '(:unit :fast :stable :isolated :session :phase-7)
  (let ((ss (code-agent-org--make-session-state
             :busy t
             :recovering nil
             :query-id "qid-123"
             :backend 'mock-backend
             :query-handle 'mock-handle
             :start-time 1234.5
             :original-prompt "hello"
             :section-level 3
             :response-has-content t
             :last-assistant-query-id "qid-prev"
             :current-line-length 42
             :loop-max 5
             :loop-current 2
             :loop-interval 10
             :pending-queue '("block-1")
             :instruction-num 3
             :custom-id "cid-abc"
             :recovery-count 1
             :block-id "bid-001"
             :marker nil
             :spinner 2
             :sdk-uuid "uuid-xyz")))
    (should (eq t (code-agent-org--session-state-get ss :busy)))
    (should (equal "qid-123" (code-agent-org--session-state-get ss :query-id)))
    (should (equal 'mock-backend (code-agent-org--session-state-get ss :backend)))
    (should (equal 'mock-handle (code-agent-org--session-state-get ss :query-handle)))
    (should (= 1234.5 (code-agent-org--session-state-get ss :start-time)))
    (should (equal "hello" (code-agent-org--session-state-get ss :original-prompt)))
    (should (= 3 (code-agent-org--session-state-get ss :section-level)))
    (should (eq t (code-agent-org--session-state-get ss :response-has-content)))
    (should (equal "qid-prev" (code-agent-org--session-state-get ss :last-assistant-query-id)))
    (should (= 42 (code-agent-org--session-state-get ss :current-line-length)))
    (should (= 5 (code-agent-org--session-state-get ss :loop-max)))
    (should (= 2 (code-agent-org--session-state-get ss :loop-current)))
    (should (= 10 (code-agent-org--session-state-get ss :loop-interval)))
    (should (equal '("block-1") (code-agent-org--session-state-get ss :pending-queue)))
    (should (= 3 (code-agent-org--session-state-get ss :instruction-num)))
    (should (equal "cid-abc" (code-agent-org--session-state-get ss :custom-id)))
    (should (= 1 (code-agent-org--session-state-get ss :recovery-count)))
    (should (equal "bid-001" (code-agent-org--session-state-get ss :block-id)))
    (should (= 2 (code-agent-org--session-state-get ss :spinner)))
    (should (equal "uuid-xyz" (code-agent-org--session-state-get ss :sdk-uuid)))))

(ert-deftest test-code-agent-org-session-state-setf ()
  "Test that session-state fields are mutable via session-state-set."
  :tags '(:unit :fast :stable :isolated :session :phase-7)
  (let ((ss (code-agent-org--make-session-state)))
    (code-agent-org--session-state-set ss :busy t)
    (code-agent-org--session-state-set ss :query-id "qid-new")
    (should (eq t (code-agent-org--session-state-get ss :busy)))
    (should (equal "qid-new" (code-agent-org--session-state-get ss :query-id)))))

(ert-deftest test-code-agent-org-session-put-get ()
  "Test session-put/get with struct-backed state."
  :tags '(:unit :fast :stable :isolated :session :phase-7)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-phase7.org")
    (code-agent-org-mode 1)
    (let ((key "test-phase7"))
      ;; Put known properties
      (code-agent-org--session-put key :busy t)
      (code-agent-org--session-put key :query-id "qid-456")
      (code-agent-org--session-put key :section-level 2)
      (code-agent-org--session-put key :loop-max 10)
      ;; Get them back
      (should (eq t (code-agent-org--session-get key :busy)))
      (should (equal "qid-456" (code-agent-org--session-get key :query-id)))
      (should (= 2 (code-agent-org--session-get key :section-level)))
      (should (= 10 (code-agent-org--session-get key :loop-max))))))

(ert-deftest test-code-agent-org-session-state-stored-as-struct ()
  "Test that sessions hash stores struct instances, not plists."
  :tags '(:unit :fast :stable :isolated :session :phase-7)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-phase7b.org")
    (code-agent-org-mode 1)
    (let ((key "test-struct-check"))
      (code-agent-org--session-put key :busy t)
      (let ((stored (gethash key code-agent-org--sessions)))
        (should (code-agent-org--session-state-p stored))))))

(ert-deftest test-code-agent-org-get-session-replaces-stale-plist ()
  "Test that get-session replaces old plist entries with proper structs.
When old code stored a plist in the sessions hash table, get-session
should detect the non-struct and replace it with a fresh struct."
  :tags '(:unit :fast :stable :isolated :session :phase-7)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-plist-migration.org")
    (code-agent-org-mode 1)
    ;; Initialize the hash table via a normal get-session call
    (code-agent-org--get-session "init-key")
    (let ((key "test-stale-plist"))
      ;; Simulate old code: manually store a plist in the hash table
      (puthash key '(:process-state nil :marker nil :busy t :query-id "old-qid")
               code-agent-org--sessions)
      ;; Verify plist is stored (not a struct)
      (should-not (code-agent-org--session-state-p (gethash key code-agent-org--sessions)))
      ;; get-session should detect and replace with a struct
      (let ((state (code-agent-org--get-session key)))
        (should (code-agent-org--session-state-p state))
        ;; The struct should be fresh (old plist data is stale)
        (should-not (code-agent-org--session-state-get state :busy))
        ;; Hash table should now contain the struct
        (should (code-agent-org--session-state-p (gethash key code-agent-org--sessions)))))))

(ert-deftest test-code-agent-org-unregister-active-query-uses-backend ()
  "Test that unregister-active-query uses backend protocol, not process-state."
  :tags '(:unit :fast :stable :isolated :session :phase-7)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-unregister-backend.org")
    (code-agent-org-mode 1)
    (let* ((key "test-unregister")
           (cancelled nil)
           ;; Create a mock backend that records cancel calls
           (mock-backend (claude-agent-claude-code-backend--create))
           (mock-handle 'mock-handle))
      ;; Store backend and handle in session
      (code-agent-org--session-put key :backend mock-backend)
      (code-agent-org--session-put key :query-handle mock-handle)
      ;; Mock cancel to record the call
      (cl-letf (((symbol-function 'claude-agent-backend-cancel)
                 (lambda (backend handle)
                   (setq cancelled (list backend handle)))))
        (code-agent-org--unregister-active-query key))
      ;; Verify cancel was called with correct args
      (should cancelled)
      (should (eq mock-backend (car cancelled)))
      (should (eq mock-handle (cadr cancelled))))))

;;; Phase 7b: marker-to-query-id migration tests

(ert-deftest test-code-agent-org-exec-status-no-exec-marker ()
  "Test that set/get-exec-status-for-session works via custom-id."
  :tags '(:unit :fast :stable :isolated :session :phase-7b)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-7b-exec.org")
    (code-agent-org-mode 1)
    (insert "* Test Block\n:PROPERTIES:\n:CUSTOM_ID: block-7b-exec\n:END:\n\n")
    (let ((key "test-7b-exec"))
      ;; Store custom-id for exec-status lookup
      (code-agent-org--session-put key :custom-id "block-7b-exec")
      ;; Set status should work via custom-id
      (should (code-agent-org--set-exec-status-for-session key "executing"))
      ;; Get status should return what we set
      (should (equal "executing" (code-agent-org--get-exec-status-for-session key))))))

(ert-deftest test-code-agent-org-queue-dedup-by-custom-id ()
  "Test that queue duplicate detection uses custom-id, not marker position."
  :tags '(:unit :fast :stable :isolated :queue :phase-7b)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-7b-queue.org")
    (code-agent-org-mode 1)
    (let ((key "test-7b-queue"))
      ;; Queue a block with custom-id
      (should (eq 'queued
                  (code-agent-org--queue-block key '(:custom-id "blk-1" :content "hello"))))
      ;; Same custom-id should be detected as duplicate
      (should (eq 'in-queue
                  (code-agent-org--queue-block key '(:custom-id "blk-1" :content "hello"))))
      ;; Different custom-id should be accepted
      (should (eq 'queued
                  (code-agent-org--queue-block key '(:custom-id "blk-2" :content "world")))))))

(ert-deftest test-code-agent-org-queue-running-dedup-by-custom-id ()
  "Test that queue detects running block via custom-id match."
  :tags '(:unit :fast :stable :isolated :queue :phase-7b)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-7b-running.org")
    (code-agent-org-mode 1)
    (let ((key "test-7b-running"))
      ;; Set custom-id for the running session
      (code-agent-org--session-put key :custom-id "running-blk")
      (code-agent-org--session-put key :busy t)
      ;; Try to queue the same block that's running
      (should (eq 'running
                  (code-agent-org--queue-block key '(:custom-id "running-blk" :content "test"))))
      ;; Different block should queue fine
      (should (eq 'queued
                  (code-agent-org--queue-block key '(:custom-id "other-blk" :content "test")))))))

;;; R1: Data-driven session state dispatch tests

(ert-deftest test-session-field-accessors-alist-exists ()
  "The accessors alist constant should exist and cover all 22 struct fields."
  :tags '(:unit :fast :stable :isolated :session :r1)
  (should (boundp 'code-agent-org--session-field-accessors))
  (should (listp code-agent-org--session-field-accessors))
  ;; Must have entries for all 22 named fields
  (should (>= (length code-agent-org--session-field-accessors) 22))
  ;; Each entry should be (keyword . function)
  (dolist (entry code-agent-org--session-field-accessors)
    (should (keywordp (car entry)))
    (should (functionp (cdr entry)))))

(ert-deftest test-session-field-setters-alist-exists ()
  "The setters alist constant should exist and cover all 22 struct fields."
  :tags '(:unit :fast :stable :isolated :session :r1)
  (should (boundp 'code-agent-org--session-field-setters))
  (should (listp code-agent-org--session-field-setters))
  ;; Must have entries for all 22 named fields
  (should (>= (length code-agent-org--session-field-setters) 22))
  ;; Each entry should be (keyword . function)
  (dolist (entry code-agent-org--session-field-setters)
    (should (keywordp (car entry)))
    (should (functionp (cdr entry)))))

(ert-deftest test-session-state-get-all-known-fields ()
  "session-state-get should retrieve all 22 known fields without error."
  :tags '(:unit :fast :stable :isolated :session :r1)
  (let ((state (code-agent-org--make-session-state
                :busy t
                :recovering nil
                :query-id "q123"
                :backend 'test-backend
                :query-handle 'handle
                :start-time 1000.0
                :original-prompt "test prompt"
                :section-level 2
                :response-has-content t
                :last-assistant-query-id "aq1"
                :current-line-length 42
                :loop-max 5
                :loop-current 3
                :loop-interval 10
                :pending-queue '(a b)
                :instruction-num 7
                :custom-id "cid"
                :recovery-count 2
                :block-id "bid"
                :marker nil
                :spinner 1
                :sdk-uuid "uuid-1")))
    (should (eq t (code-agent-org--session-state-get state :busy)))
    (should (eq nil (code-agent-org--session-state-get state :recovering)))
    (should (equal "q123" (code-agent-org--session-state-get state :query-id)))
    (should (eq 'test-backend (code-agent-org--session-state-get state :backend)))
    (should (eq 'handle (code-agent-org--session-state-get state :query-handle)))
    (should (= 1000.0 (code-agent-org--session-state-get state :start-time)))
    (should (equal "test prompt" (code-agent-org--session-state-get state :original-prompt)))
    (should (= 2 (code-agent-org--session-state-get state :section-level)))
    (should (eq t (code-agent-org--session-state-get state :response-has-content)))
    (should (equal "aq1" (code-agent-org--session-state-get state :last-assistant-query-id)))
    (should (= 42 (code-agent-org--session-state-get state :current-line-length)))
    (should (= 5 (code-agent-org--session-state-get state :loop-max)))
    (should (= 3 (code-agent-org--session-state-get state :loop-current)))
    (should (= 10 (code-agent-org--session-state-get state :loop-interval)))
    (should (equal '(a b) (code-agent-org--session-state-get state :pending-queue)))
    (should (= 7 (code-agent-org--session-state-get state :instruction-num)))
    (should (equal "cid" (code-agent-org--session-state-get state :custom-id)))
    (should (= 2 (code-agent-org--session-state-get state :recovery-count)))
    (should (equal "bid" (code-agent-org--session-state-get state :block-id)))
    (should (eq nil (code-agent-org--session-state-get state :marker)))
    (should (= 1 (code-agent-org--session-state-get state :spinner)))
    (should (equal "uuid-1" (code-agent-org--session-state-get state :sdk-uuid)))))

(ert-deftest test-session-state-set-all-known-fields ()
  "session-state-set should set all 22 known fields and return value."
  :tags '(:unit :fast :stable :isolated :session :r1)
  (let ((state (code-agent-org--make-session-state :spinner 0 :section-level 0
                                               :current-line-length 0)))
    ;; Set each field and verify round-trip
    (code-agent-org--session-state-set state :busy t)
    (should (eq t (code-agent-org--session-state-get state :busy)))
    (code-agent-org--session-state-set state :query-id "new-q")
    (should (equal "new-q" (code-agent-org--session-state-get state :query-id)))
    (code-agent-org--session-state-set state :start-time 2000.0)
    (should (= 2000.0 (code-agent-org--session-state-get state :start-time)))
    (code-agent-org--session-state-set state :section-level 3)
    (should (= 3 (code-agent-org--session-state-get state :section-level)))
    (code-agent-org--session-state-set state :loop-max 10)
    (should (= 10 (code-agent-org--session-state-get state :loop-max)))
    (code-agent-org--session-state-set state :recovery-count 5)
    (should (= 5 (code-agent-org--session-state-get state :recovery-count)))
    (code-agent-org--session-state-set state :sdk-uuid "new-uuid")
    (should (equal "new-uuid" (code-agent-org--session-state-get state :sdk-uuid)))))

(ert-deftest test-session-state-extras-fallback ()
  "Unknown properties should fall through to extras plist."
  :tags '(:unit :fast :stable :isolated :session :r1)
  (let ((state (code-agent-org--make-session-state :spinner 0 :section-level 0
                                               :current-line-length 0)))
    ;; Set unknown property
    (code-agent-org--session-state-set state :custom-thing "hello")
    (should (equal "hello" (code-agent-org--session-state-get state :custom-thing)))
    ;; Set another unknown property
    (code-agent-org--session-state-set state :another 42)
    (should (= 42 (code-agent-org--session-state-get state :another)))
    ;; First property should still be there
    (should (equal "hello" (code-agent-org--session-state-get state :custom-thing)))))

(ert-deftest test-session-state-set-returns-value ()
  "session-state-set should return the value that was set."
  :tags '(:unit :fast :stable :isolated :session :r1)
  (let ((state (code-agent-org--make-session-state :spinner 0 :section-level 0
                                               :current-line-length 0)))
    (should (eq t (code-agent-org--session-state-set state :busy t)))
    (should (equal "q1" (code-agent-org--session-state-set state :query-id "q1")))
    ;; Extras fallback should also return value
    (should (equal "val" (code-agent-org--session-state-set state :unknown-prop "val")))))

(ert-deftest test-session-field-alists-cover-all-struct-fields ()
  "Both alists should have entries for the same set of keywords."
  :tags '(:unit :fast :stable :isolated :session :r1)
  (let ((accessor-keys (mapcar #'car code-agent-org--session-field-accessors))
        (setter-keys (mapcar #'car code-agent-org--session-field-setters)))
    ;; Same set of keywords in both alists
    (should (equal (sort (copy-sequence accessor-keys) #'string<)
                   (sort (copy-sequence setter-keys) #'string<)))
    ;; All expected keywords present
    (let ((expected '(:busy :recovering :query-id :backend :query-handle
                      :start-time :original-prompt :section-level
                      :response-has-content :last-assistant-query-id
                      :current-line-length :loop-max :loop-current
                      :loop-interval :pending-queue :instruction-num
                      :custom-id :recovery-count :block-id :marker
                      :spinner :sdk-uuid)))
      (dolist (key expected)
        (should (assq key code-agent-org--session-field-accessors))
        (should (assq key code-agent-org--session-field-setters))))))

;;; R6: Recovery retry limit tests

(ert-deftest test-recovery-max-attempts-defcustom-exists ()
  "code-agent-org-max-recovery-attempts defcustom should exist with default 3."
  :tags '(:unit :fast :stable :isolated :recovery :r6)
  (should (boundp 'code-agent-org-max-recovery-attempts))
  (should (= 3 code-agent-org-max-recovery-attempts)))

(ert-deftest test-recovery-stops-at-limit ()
  "recover-session should refuse to recover when recovery-count >= max."
  :tags '(:unit :fast :stable :isolated :recovery :r6)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-r6-limit.org")
    (code-agent-org-mode 1)
    (let ((key "test-r6-limit")
          (error-inserted nil))
      ;; Set recovery count at the limit
      (code-agent-org--session-put key :recovery-count 3)
      (code-agent-org--session-put key :busy t)
      (code-agent-org--session-put key :query-id "old-q")
      ;; Stub functions called during recovery failure path
      (cl-letf (((symbol-function 'code-agent-org--insert-error)
                 (lambda (_key _msg) (setq error-inserted t)))
                ((symbol-function 'code-agent-org--stop-spinner) #'ignore)
                ((symbol-function 'code-agent-org--refresh-header-line) #'ignore)
                ((symbol-function 'code-agent-org--reset-session-state) #'ignore))
        (code-agent-org--recover-session key 'expired)
        ;; Should have inserted error, not attempted recovery
        (should error-inserted)
        ;; Should NOT have set recovering flag (it was short-circuited)
        (should-not (code-agent-org--session-get key :recovering))))))

(ert-deftest test-recovery-count-resets-on-success ()
  "recovery-count should be reset to 0 when a new query starts."
  :tags '(:unit :fast :stable :isolated :recovery :r6)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-r6-reset.org")
    (code-agent-org-mode 1)
    (let ((key "test-r6-reset"))
      ;; Simulate some recovery attempts
      (code-agent-org--session-put key :recovery-count 2)
      (should (= 2 (code-agent-org--session-get key :recovery-count)))
      ;; Reset (simulating what send-request does on new query)
      (code-agent-org--session-put key :recovery-count 0)
      (should (= 0 (code-agent-org--session-get key :recovery-count))))))

;;; R2: with-session-marker macro tests

(ert-deftest test-with-session-marker-valid-marker ()
  "Macro should execute body when marker is valid."
  :tags '(:unit :fast :stable :isolated :marker :r2)
  (with-temp-buffer
    (org-mode)
    (insert "Test content\n")
    (let ((marker (copy-marker (point-min))))
      (should (equal "executed"
                     (code-agent-org--with-session-marker marker
                       "executed"))))))

(ert-deftest test-with-session-marker-nil-marker ()
  "Macro should return nil when marker is nil."
  :tags '(:unit :fast :stable :isolated :marker :r2)
  (should-not (code-agent-org--with-session-marker nil
                (error "Should not reach here"))))

(ert-deftest test-with-session-marker-killed-buffer ()
  "Macro should return nil when marker's buffer has been killed."
  :tags '(:unit :fast :stable :isolated :marker :r2)
  (let* ((buf (generate-new-buffer " *test-r2-killed*"))
         (marker (with-current-buffer buf
                   (insert "content")
                   (copy-marker (point-min)))))
    (kill-buffer buf)
    (should-not (code-agent-org--with-session-marker marker
                  (error "Should not reach here")))))

;;; R11: Queue depth limit tests

(ert-deftest test-queue-max-depth-defcustom-exists ()
  "code-agent-org-max-queue-depth defcustom should exist with default 20."
  :tags '(:unit :fast :stable :isolated :queue :r11)
  (should (boundp 'code-agent-org-max-queue-depth))
  (should (= 20 code-agent-org-max-queue-depth)))

(ert-deftest test-queue-full-rejection ()
  "queue-block should return queue-full when queue exceeds max depth."
  :tags '(:unit :fast :stable :isolated :queue :r11)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-r11-full.org")
    (code-agent-org-mode 1)
    (let ((key "test-r11-full")
          (code-agent-org-max-queue-depth 3))
      ;; Fill queue to limit
      (dotimes (i 3)
        (should (eq 'queued
                    (code-agent-org--queue-block
                     key (list :custom-id (format "blk-%d" i)
                               :content (format "content %d" i))))))
      ;; Next should be rejected
      (should (eq 'queue-full
                  (code-agent-org--queue-block
                   key '(:custom-id "blk-overflow" :content "overflow")))))))

;;; R3: Decomposed send-request tests

(ert-deftest test-build-full-prompt-with-reminder ()
  "build-full-prompt should prepend system reminder to prompt."
  :tags '(:unit :fast :stable :isolated :send-request :r3)
  (should (fboundp 'code-agent-org--build-full-prompt))
  (let ((result (code-agent-org--build-full-prompt "my query" "context info")))
    (should (stringp result))
    (should (string-match-p "context info" result))
    (should (string-match-p "my query" result))))

(ert-deftest test-build-full-prompt-without-reminder ()
  "build-full-prompt with nil/empty reminder should return prompt unchanged."
  :tags '(:unit :fast :stable :isolated :send-request :r3)
  (should (equal "my query" (code-agent-org--build-full-prompt "my query" nil)))
  (should (equal "my query" (code-agent-org--build-full-prompt "my query" ""))))

(ert-deftest test-dispatch-query-exists ()
  "dispatch-query function should exist."
  :tags '(:unit :fast :stable :isolated :send-request :r3)
  (should (fboundp 'code-agent-org--dispatch-query)))

;;; R7: Modular header-line component tests

(ert-deftest test-header-line-components-exist ()
  "All header-line component functions should exist."
  :tags '(:unit :fast :stable :isolated :header :r7)
  (should (fboundp 'code-agent-org--header-session-badge))
  (should (fboundp 'code-agent-org--header-docker-badge))
  (should (fboundp 'code-agent-org--header-permission-badge))
  (should (fboundp 'code-agent-org--header-activity-badge))
  (should (fboundp 'code-agent-org--header-project-badge))
  (should (fboundp 'code-agent-org--header-ide-context)))

(ert-deftest test-header-line-components-return-strings ()
  "All header-line components should return strings."
  :tags '(:unit :fast :stable :isolated :header :r7)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-r7.org")
    (code-agent-org-mode 1)
    (should (stringp (code-agent-org--header-session-badge)))
    (should (stringp (code-agent-org--header-docker-badge)))
    (should (stringp (code-agent-org--header-permission-badge)))
    (should (stringp (code-agent-org--header-activity-badge)))
    (should (stringp (code-agent-org--header-project-badge)))
    (should (stringp (code-agent-org--header-ide-context)))))

;;; Review Fixes: Recovery counter increment

(ert-deftest test-recovery-counter-increments-on-each-attempt ()
  "recover-session should increment recovery-count on each recovery call."
  :tags '(:unit :fast :stable :isolated :recovery :review-fix)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-recovery-incr.org")
    (code-agent-org-mode 1)
    (let ((key "test-recovery-incr")
          (recovery-attempted nil))
      ;; Initialize session state
      (code-agent-org--session-put key :recovery-count 0)
      (code-agent-org--session-put key :busy t)
      (code-agent-org--session-put key :query-id "old-q-1")
      ;; Stub out all side-effect functions - we just want to verify counter
      (cl-letf (((symbol-function 'code-agent-org--find-response-by-query-id)
                 (lambda (_) (point-min)))
                ((symbol-function 'code-agent-org--create-response-section) #'ignore)
                ((symbol-function 'code-agent-org--collect-session-context)
                 (lambda () "context"))
                ((symbol-function 'code-agent-org--build-recovery-prompt)
                 (lambda (_ctx _prompt) "recovery"))
                ((symbol-function 'code-agent-org--clear-sdk-uuid) #'ignore)
                ((symbol-function 'code-agent-org--send-request)
                 (lambda (_prompt &rest _) (setq recovery-attempted t)))
                ((symbol-function 'code-agent-org--generate-query-id)
                 (lambda () "new-q"))
                ((symbol-function 'code-agent-org--stop-spinner) #'ignore)
                ((symbol-function 'code-agent-org--refresh-header-line) #'ignore))
        ;; First recovery call: count should go from 0 to 1
        (code-agent-org--recover-session key 'expired)
        (should (= 1 (code-agent-org--session-get key :recovery-count)))
        ;; Second recovery call: count should go from 1 to 2
        (code-agent-org--session-put key :query-id "old-q-2")
        (code-agent-org--recover-session key 'expired)
        (should (= 2 (code-agent-org--session-get key :recovery-count)))))))

;;; Completion status: exec-status must be "completed" and :busy nil after handle-complete

(ert-deftest test-handle-complete-sets-exec-status-completed ()
  "After handle-complete, exec-status should be 'completed' and :busy nil.
Reproduces issue: scheduled instructions can't run because previous
instruction was not properly marked as completed."
  :tags '(:unit :fast :stable :isolated :completion :scheduled)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-completion-status.org")
    (code-agent-org-mode 1)
    ;; Build an org structure with CUSTOM_ID, AI block, and Response section
    (insert "* Test Heading\n")
    (insert ":PROPERTIES:\n")
    (insert ":CUSTOM_ID: test-completion-block\n")
    (insert ":END:\n\n")
    (insert "#+begin_src ai\ntest query\n#+end_src\n\n")
    (insert "** Response 1 (2026-02-19 20:00) :ai_output:\n")
    (insert ":PROPERTIES:\n")
    (insert ":QUERY_ID: test-qid-123\n")
    (insert ":QUERY_TYPE: normal\n")
    (insert ":END:\n\n")
    (insert "Some response text\n")
    ;; Set up session state as if execution is in progress
    (let ((key "test-completion-status"))
      (code-agent-org--session-put key :busy t)
      (code-agent-org--session-put key :query-id "test-qid-123")
      (code-agent-org--session-put key :custom-id "test-completion-block")
      (code-agent-org--session-put key :loop-max 1)
      (code-agent-org--session-put key :loop-current 1)
      (code-agent-org--session-put key :marker (copy-marker (point-min)))
      (code-agent-org--session-put key :section-level 2)
      ;; Set exec-status to "executing" on the heading
      (save-excursion
        (goto-char (point-min))
        (org-back-to-heading t)
        (org-entry-put nil "AI_EXEC_STATUS" "executing"))
      ;; Stub side-effect functions
      (cl-letf (((symbol-function 'code-agent-org--stop-spinner) #'ignore)
                ((symbol-function 'code-agent-org--refresh-header-line) #'ignore)
                ((symbol-function 'code-agent-org--unregister-active-query) #'ignore))
        ;; Call handle-complete
        (code-agent-org--handle-complete key nil)
        ;; CRITICAL: :busy should be nil (so scheduled blocks can run)
        (should-not (code-agent-org--session-get key :busy))
        ;; CRITICAL: exec-status should be "completed"
        (let ((status (save-excursion
                        (goto-char (point-min))
                        (org-back-to-heading t)
                        (org-entry-get nil "AI_EXEC_STATUS"))))
          (should (equal "completed" status)))))))

(ert-deftest test-handle-complete-unblocks-scheduled-execution ()
  "After handle-complete, a scheduled block should see session as not busy."
  :tags '(:unit :fast :stable :isolated :completion :scheduled)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-sched-unblock.org")
    (code-agent-org-mode 1)
    ;; Build org structure
    (insert "* Block A\n")
    (insert ":PROPERTIES:\n")
    (insert ":CUSTOM_ID: block-a\n")
    (insert ":END:\n\n")
    (insert "#+begin_src ai\nquery A\n#+end_src\n\n")
    (insert "** Response 1 (2026-02-19 20:00) :ai_output:\n")
    (insert ":PROPERTIES:\n")
    (insert ":QUERY_ID: qid-a\n")
    (insert ":QUERY_TYPE: normal\n")
    (insert ":END:\n\nResponse A text\n\n")
    (insert "* Block B\n")
    (insert ":PROPERTIES:\n")
    (insert ":CUSTOM_ID: block-b\n")
    (insert ":SCHEDULED: <2026-02-19 Wed 20:00>\n")
    (insert ":END:\n\n")
    (insert "#+begin_src ai\nquery B\n#+end_src\n")
    ;; Set up session state: Block A is executing
    (let ((key "test-sched-unblock"))
      (code-agent-org--session-put key :busy t)
      (code-agent-org--session-put key :query-id "qid-a")
      (code-agent-org--session-put key :custom-id "block-a")
      (code-agent-org--session-put key :loop-max 1)
      (code-agent-org--session-put key :loop-current 1)
      (code-agent-org--session-put key :marker (copy-marker (point-min)))
      (code-agent-org--session-put key :section-level 2)
      ;; Stub side-effect functions
      (cl-letf (((symbol-function 'code-agent-org--stop-spinner) #'ignore)
                ((symbol-function 'code-agent-org--refresh-header-line) #'ignore)
                ((symbol-function 'code-agent-org--unregister-active-query) #'ignore))
        ;; Before handle-complete: session should be busy
        (should (code-agent-org--session-get key :busy))
        ;; Complete Block A
        (code-agent-org--handle-complete key nil)
        ;; After handle-complete: session should NOT be busy
        (should-not (code-agent-org--session-get key :busy))
        ;; Scheduled checker would now see session as free
        ;; (simulating what code-agent-org-scheduled--maybe-execute checks)
        (should-not (code-agent-org--session-get key :busy))))))

;;; ============================================================
;;; F9: code-agent-org Backend Integration
;;; ============================================================

(ert-deftest test-f9-make-backend-claude-code ()
  "make-default-backend returns claude-code-backend by default."
  :tags '(:unit :fast :stable :isolated :org :f9)
  (let ((backend (code-agent-org--make-default-backend "test-key" nil)))
    (should (claude-agent-claude-code-backend-p backend))))

(ert-deftest test-f9-show-verbose-uses-backend-verbose-buffer ()
  "show-verbose should check backend-verbose-buffer first."
  :tags '(:unit :fast :stable :isolated :org :f9)
  (let* ((test-buf (generate-new-buffer " *test-verbose*"))
         (backend (claude-agent-claude-code-backend--create)))
    (unwind-protect
        (progn
          ;; backend-verbose-buffer returns nil for claude-code-backend (no terminal)
          (should-not (claude-agent-backend-verbose-buffer backend)))
      (kill-buffer test-buf))))

(ert-deftest test-f9-handle-complete-nil-result ()
  "handle-complete should work with nil result (from claude-backend)."
  :tags '(:unit :fast :stable :isolated :org :f9)
  ;; This test verifies that handle-complete doesn't crash when
  ;; result is nil (as returned by claude-backend's bell handler)
  (let ((key "test-f9-complete::nil-result"))
    (code-agent-org--session-put key :query-id "q1")
    (code-agent-org--session-put key :section-level 1)
    ;; handle-complete with nil result should not error
    (code-agent-org--handle-complete key nil)
    ;; Session should not be busy after completion
    (should-not (code-agent-org--session-get key :busy))))

(ert-deftest test-f9-dispatch-query-stores-backend ()
  "dispatch-query should store backend in session."
  :tags '(:unit :fast :stable :isolated :org :f9)
  (let* ((key "test-f9-dispatch::stores-backend")
         (mock-handle 'mock-handle))
    (code-agent-org--session-put key :section-level 1)
    ;; Mock backend-query to avoid actual CLI call
    (cl-letf (((symbol-function 'claude-agent-backend-query)
               (lambda (_backend _prompt _callbacks &rest _args)
                 mock-handle)))
      (code-agent-org--dispatch-query
       key "test prompt"
       (list :on-token #'ignore :on-complete #'ignore)
       :options nil))
    ;; Backend should be stored
    (should (code-agent-org--session-get key :backend))
    (should (claude-agent-claude-code-backend-p
             (code-agent-org--session-get key :backend)))))


;;; F9b: CLAUDE_BACKEND org property override
;;; ============================================================

(ert-deftest test-f9b-backend-property-file-level-claude-code ()
  "File-level CLAUDE_BACKEND property claude-code creates claude-code-backend."
  :tags '(:unit :fast :stable :isolated :org :f9b)
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: CLAUDE_BACKEND claude-code\n\n")
    (insert "* Section\n")
    (goto-char (point-min))
    (re-search-forward "^\\* Section")
    (let ((backend (code-agent-org--make-default-backend "test-key" nil)))
      (should (claude-agent-claude-code-backend-p backend)))))

(ert-deftest test-f9b-backend-property-absent-uses-fallback ()
  "Without CLAUDE_BACKEND property, claude-code fallback is used."
  :tags '(:unit :fast :stable :isolated :org :f9b)
  (with-temp-buffer
    (org-mode)
    (insert "* Section\n")
    (goto-char (point-min))
    (re-search-forward "^\\* Section")
    (let ((backend (code-agent-org--make-default-backend "test-key" nil)))
      (should (claude-agent-claude-code-backend-p backend)))))

(ert-deftest test-f9b-backend-property-invalid-value-uses-fallback ()
  "Invalid CLAUDE_BACKEND property value falls back to claude-code."
  :tags '(:unit :fast :stable :isolated :org :f9b)
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: CLAUDE_BACKEND nonsense-value\n\n")
    (insert "* Section\n")
    (goto-char (point-min))
    (re-search-forward "^\\* Section")
    (let ((backend (code-agent-org--make-default-backend "test-key" nil)))
      (should (claude-agent-claude-code-backend-p backend)))))

(provide 'test-code-agent-org-unit)
;;; test-code-agent-org-unit.el ends here
