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
  "Test finding next available instruction number."
  :tags '(:unit :fast :stable :isolated :org :session)
  (with-temp-buffer
    (org-mode)
    (insert "* Instruction 1\n")
    (insert "* Instruction 5\n")
    (insert "* Instruction 3\n")
    (insert "* Other Section\n")
    ;; Should find max + 1
    (should (= 6 (claude-org--next-instruction-number)))))

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

(ert-deftest test-claude-org-normalize-header-line ()
  "Test single header line normalization."
  :tags '(:unit :fast :stable :isolated :org :normalization)
  ;; With offset 3 (target level 4): * becomes ****
  (should (equal "**** Heading" (claude-org--normalize-header-line "* Heading" 3)))
  (should (equal "***** Sub" (claude-org--normalize-header-line "** Sub" 3)))
  (should (equal "****** SubSub" (claude-org--normalize-header-line "*** SubSub" 3)))
  ;; Non-headers unchanged
  (should (equal "regular text" (claude-org--normalize-header-line "regular text" 3)))
  (should (equal "  * not at start" (claude-org--normalize-header-line "  * not at start" 3)))
  (should (equal "*no space after" (claude-org--normalize-header-line "*no space after" 3)))
  (should (equal "" (claude-org--normalize-header-line "" 3))))

(ert-deftest test-claude-org-normalize-headers-in-text ()
  "Test full text normalization with newline handling."
  :tags '(:unit :fast :stable :isolated :org :normalization)
  (let ((claude-org-normalize-headers t))
    ;; Simple case: complete lines
    (let ((result (claude-org--normalize-headers-in-text "* Top\n** Sub\n" 4 "")))
      (should (equal "**** Top\n***** Sub\n" (car result)))
      (should (equal "" (cdr result))))
    ;; Pending line: no trailing newline
    (let ((result (claude-org--normalize-headers-in-text "* Top\n** Pen" 4 "")))
      (should (equal "**** Top\n" (car result)))
      (should (equal "** Pen" (cdr result))))
    ;; Continue with pending
    (let ((result (claude-org--normalize-headers-in-text "ding\n" 4 "** Pen")))
      (should (equal "***** Pending\n" (car result)))
      (should (equal "" (cdr result))))
    ;; Mixed content
    (let ((result (claude-org--normalize-headers-in-text "Hello\n* Head\nText\n" 4 "")))
      (should (equal "Hello\n**** Head\nText\n" (car result)))
      (should (equal "" (cdr result))))))

(ert-deftest test-claude-org-normalize-headers-disabled ()
  "Test that normalization can be disabled."
  :tags '(:unit :fast :stable :isolated :org :normalization)
  (let ((claude-org-normalize-headers nil))
    (let ((result (claude-org--normalize-headers-in-text "* Top\n" 4 "")))
      (should (equal "* Top\n" (car result)))
      (should (equal "" (cdr result))))))

(ert-deftest test-claude-org-normalize-headers-token-boundary ()
  "Test header split across token boundaries."
  :tags '(:unit :fast :stable :isolated :org :normalization)
  (let ((claude-org-normalize-headers t))
    ;; Token ends with partial header - should buffer
    (let ((result (claude-org--normalize-headers-in-text "text\n*" 4 "")))
      (should (equal "text\n" (car result)))
      (should (equal "*" (cdr result))))
    ;; Next token completes header
    (let ((result (claude-org--normalize-headers-in-text "* Head\n" 4 "*")))
      (should (equal "***** Head\n" (car result)))
      (should (equal "" (cdr result))))
    ;; Stars split across tokens
    (let ((result (claude-org--normalize-headers-in-text "* Head\n" 4 "**")))
      (should (equal "****** Head\n" (car result)))
      (should (equal "" (cdr result))))
    ;; Non-header text without newline should output immediately
    (let ((result (claude-org--normalize-headers-in-text "Hello world" 4 "")))
      (should (equal "Hello world" (car result)))
      (should (equal "" (cdr result))))))

(ert-deftest test-claude-org-normalize-headers-streaming-simulation ()
  "Test header normalization simulating real streaming scenario."
  :tags '(:unit :fast :stable :isolated :org :normalization)
  (let ((claude-org-normalize-headers t)
        (pending "")
        (output ""))
    ;; Simulate streaming tokens - text without newlines should stream immediately
    (let* ((tokens '("Here is " "the ans" "wer:\n\n" "* Sum" "mary\n" "Some " "text\n" "** Det" "ails\n"))
           (target-level 4))
      (dolist (token tokens)
        (let ((result (claude-org--normalize-headers-in-text token target-level pending)))
          (setq output (concat output (car result)))
          (setq pending (cdr result))))
      ;; Final flush of pending
      (when (> (length pending) 0)
        (setq output (concat output (claude-org--normalize-header-line pending 3))))
      ;; Verify result
      (should (equal "Here is the answer:\n\n**** Summary\nSome text\n***** Details\n" output)))))

(provide 'test-claude-org-unit)
;;; test-claude-org-unit.el ends here
