;;; test-workspace-bridge-response.el --- Tests for workspace bridge response insertion -*- lexical-binding: t -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Tests for `code-agent-org-workspace-bridge-insert-response' covering:
;; - Single response section per instruction (idempotent heading creation)
;; - Chronological ordering of appended content
;; - Correct creation of new response sections
;;
;; Uses real org buffers backed by temp files (not with-temp-buffer) because
;; the function under test calls `save-buffer'.

;;; Code:

(require 'ert)
(require 'org)
(require 'cl-lib)

;; Load project source
(let ((project-root (file-name-directory
                     (directory-file-name
                      (file-name-directory
                       (or load-file-name buffer-file-name))))))
  (require 'literate-elisp)
  (literate-elisp-load (expand-file-name "code-agent-trace.org" project-root))
  (literate-elisp-load (expand-file-name "code-agent.org" project-root))
  (literate-elisp-load (expand-file-name "code-agent-backend.org" project-root))
  (literate-elisp-load (expand-file-name "code-agent-org.org" project-root)))

;;; ============================================================================
;;; Test Fixtures
;;; ============================================================================

(defconst test-workspace-response--org-template
  "* Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-session
:END:
** Workflow :sdd:
:PROPERTIES:
:CUSTOM_ID: test-workflow
:END:
*** Instruction 1 :claude_chat:
:PROPERTIES:
:CUSTOM_ID: test-instr-1
:END:

#+begin_src ai
test query
#+end_src

*** Instruction 2 :claude_chat:
:PROPERTIES:
:CUSTOM_ID: test-instr-2
:END:

#+begin_src ai
second query
#+end_src
"
  "Org buffer template for response insertion tests.")

(defun test-workspace-response--setup ()
  "Create a temp file with the org template and return (buffer . file-path).
Caller must clean up with `test-workspace-response--cleanup'."
  (let* ((tmp-file (make-temp-file "test-workspace-response-" nil ".org"))
         (buf (find-file-noselect tmp-file)))
    (with-current-buffer buf
      (erase-buffer)
      (insert test-workspace-response--org-template)
      (save-buffer))
    (cons buf tmp-file)))

(defun test-workspace-response--cleanup (buf file)
  "Kill BUF and delete FILE."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (set-buffer-modified-p nil))
    (kill-buffer buf))
  (when (file-exists-p file)
    (delete-file file)))

(defun test-workspace-response--count-headings (buf pattern)
  "Count headings matching PATTERN in BUF."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (let ((count 0))
        (while (re-search-forward pattern nil t)
          (setq count (1+ count)))
        count))))

(defun test-workspace-response--buffer-text (buf)
  "Return full text of BUF."
  (with-current-buffer buf
    (buffer-substring-no-properties (point-min) (point-max))))

(defmacro test-workspace-response--with-fixture (&rest body)
  "Execute BODY with a temp org buffer.
Binds `buf' and `file' for use in BODY.  Automatically cleans up on exit."
  (declare (indent 0) (debug t))
  `(let* ((setup (test-workspace-response--setup))
          (buf (car setup))
          (file (cdr setup)))
     (unwind-protect
         (progn ,@body)
       (test-workspace-response--cleanup buf file))))

;;; ============================================================================
;;; Test: Single response section per instruction
;;; ============================================================================

(ert-deftest test-workspace-response/duplicate-insert-single-heading ()
  "Calling insert-response twice for the same instruction must produce only ONE
response heading. The second call should append to the existing response section,
not create a duplicate."
  :tags '(:unit :stable)
  (test-workspace-response--with-fixture
    ;; First insertion
    (code-agent-org-workspace-bridge-insert-response file "test-session"
                                            "First response content." "test-instr-1")
    ;; Second insertion for the SAME instruction
    (code-agent-org-workspace-bridge-insert-response file "test-session"
                                            "Second response content." "test-instr-1")
    (with-current-buffer buf (revert-buffer t t t))
    ;; There must be exactly ONE :ai_output: heading for Instruction 1
    (should (= 1 (test-workspace-response--count-headings
                   buf "^\\*\\*\\* Response .+:ai_output:")))
    ;; Both pieces of content must be present
    (let ((text (test-workspace-response--buffer-text buf)))
      (should (string-match-p "First response content\\." text))
      (should (string-match-p "Second response content\\." text)))))

;;; ============================================================================
;;; Test: Chronological ordering of appended content
;;; ============================================================================

(ert-deftest test-workspace-response/chronological-order ()
  "When multiple responses are inserted for the same instruction, content must
appear in oldest-first order (first inserted content before later content)."
  :tags '(:unit :stable)
  (test-workspace-response--with-fixture
    (code-agent-org-workspace-bridge-insert-response file "test-session"
                                            "ALPHA response." "test-instr-1")
    (code-agent-org-workspace-bridge-insert-response file "test-session"
                                            "BRAVO response." "test-instr-1")
    (code-agent-org-workspace-bridge-insert-response file "test-session"
                                            "CHARLIE response." "test-instr-1")
    (with-current-buffer buf (revert-buffer t t t))
    (let ((text (test-workspace-response--buffer-text buf)))
      ;; ALPHA must appear before BRAVO, and BRAVO before CHARLIE
      (let ((pos-a (string-match "ALPHA response\\." text))
            (pos-b (string-match "BRAVO response\\." text))
            (pos-c (string-match "CHARLIE response\\." text)))
        (should pos-a)
        (should pos-b)
        (should pos-c)
        (should (< pos-a pos-b))
        (should (< pos-b pos-c))))))

;;; ============================================================================
;;; Test: New response section created correctly
;;; ============================================================================

(ert-deftest test-workspace-response/new-section-created ()
  "When no response exists yet, insert-response must create a new
\"Response N :ai_output:\" heading after the instruction and before the next
instruction."
  :tags '(:unit :stable)
  (test-workspace-response--with-fixture
    (code-agent-org-workspace-bridge-insert-response file "test-session"
                                            "New response text." "test-instr-1")
    (with-current-buffer buf (revert-buffer t t t))
    (let ((text (test-workspace-response--buffer-text buf)))
      ;; A Response heading with :ai_output: tag must exist
      (should (string-match-p "^\\*\\*\\* Response 1 .+:ai_output:" text))
      ;; The response content must be present
      (should (string-match-p "New response text\\." text))
      ;; The response heading must appear AFTER "Instruction 1"
      ;; and BEFORE "Instruction 2"
      (let ((instr1-pos (string-match "Instruction 1" text))
            (response-pos (string-match "Response 1" text))
            (instr2-pos (string-match "Instruction 2" text)))
        (should instr1-pos)
        (should response-pos)
        (should instr2-pos)
        (should (< instr1-pos response-pos))
        (should (< response-pos instr2-pos))))))

;;; ============================================================================
;;; Test: Second instruction gets its own response section
;;; ============================================================================

(ert-deftest test-workspace-response/separate-responses-per-instruction ()
  "Each instruction should get its own response section. Inserting responses for
both Instruction 1 and Instruction 2 should produce two separate :ai_output:
headings in the correct positions."
  :tags '(:unit :stable)
  (test-workspace-response--with-fixture
    (code-agent-org-workspace-bridge-insert-response file "test-session"
                                            "Response for instr 1." "test-instr-1")
    (code-agent-org-workspace-bridge-insert-response file "test-session"
                                            "Response for instr 2." "test-instr-2")
    (with-current-buffer buf (revert-buffer t t t))
    ;; Two separate :ai_output: headings
    (should (= 2 (test-workspace-response--count-headings
                   buf "^\\*\\*\\* Response .+:ai_output:")))
    ;; Verify ordering: instr1 < response1 < instr2 < response2
    (let ((text (test-workspace-response--buffer-text buf)))
      (let ((instr1-pos (string-match "Instruction 1" text))
            (resp1-pos (string-match "Response for instr 1\\." text))
            (instr2-pos (string-match "Instruction 2" text))
            (resp2-pos (string-match "Response for instr 2\\." text)))
        (should instr1-pos)
        (should resp1-pos)
        (should instr2-pos)
        (should resp2-pos)
        (should (< instr1-pos resp1-pos))
        (should (< resp1-pos instr2-pos))
        (should (< instr2-pos resp2-pos))))))

;;; ============================================================================
;;; Test: Response section has correct properties
;;; ============================================================================

(ert-deftest test-workspace-response/response-has-properties ()
  "A newly created response section must have a PROPERTIES drawer with
QUERY_TYPE set to terminal."
  :tags '(:unit :stable)
  (test-workspace-response--with-fixture
    (code-agent-org-workspace-bridge-insert-response file "test-session"
                                            "Some output." "test-instr-1")
    (with-current-buffer buf
      (revert-buffer t t t)
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\*\\* Response .+:ai_output:" nil t))
      (should (string= "terminal" (org-entry-get nil "QUERY_TYPE"))))))

(provide 'test-workspace-bridge-response)

;;; test-workspace-bridge-response.el ends here
