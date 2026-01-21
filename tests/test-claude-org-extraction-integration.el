;;; test-claude-org-extraction-integration.el --- Integration tests for knowledge extraction -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Integration tests for knowledge extraction feature (skills and rules).
;; These tests require a running Claude API connection.
;; Run with: make test-integration
;;
;; To run just these tests:
;;   (ert-run-tests-interactively "test-claude-org-extraction-")

;;; Code:

(require 'ert)
(require 'claude-org)

;;; Test Utilities

(defvar test-claude-org-extraction--timeout 120
  "Timeout in seconds for integration tests.")

(defmacro test-claude-org-extraction--with-temp-org-file (&rest body)
  "Execute BODY with a temporary org file and claude-org-mode enabled."
  (declare (indent 0) (debug t))
  `(let ((temp-file (make-temp-file "test-extraction-" nil ".org"))
         ;; Disable MCP server auto-start to avoid port conflicts in tests
         (claude-org-auto-start-mcp-server nil))
     (unwind-protect
         (progn
           (find-file temp-file)
           (claude-org-mode 1)
           ,@body)
       (when (get-file-buffer temp-file)
         (kill-buffer (get-file-buffer temp-file)))
       (delete-file temp-file))))

(defun test-claude-org-extraction--wait-for-completion (session-key &optional timeout)
  "Wait for SESSION-KEY to complete execution.
TIMEOUT defaults to `test-claude-org-extraction--timeout'."
  (let ((timeout (or timeout test-claude-org-extraction--timeout))
        (start-time (float-time)))
    (while (and (claude-org--session-get session-key :busy)
                (< (- (float-time) start-time) timeout))
      (sleep-for 0.5))
    (not (claude-org--session-get session-key :busy))))

(defun test-claude-org-extraction--wait-for-extraction (buffer &optional timeout)
  "Wait for extraction to complete in BUFFER.
Waits for 'Skill/Rule Extraction' section and some content after it.
TIMEOUT defaults to `test-claude-org-extraction--timeout'."
  (let ((timeout (or timeout test-claude-org-extraction--timeout))
        (start-time (float-time)))
    (with-current-buffer buffer
      ;; Wait for extraction section to appear and have some content
      (while (and (< (- (float-time) start-time) timeout)
                  (save-excursion
                    (goto-char (point-min))
                    (not (and (search-forward "Skill/Rule Extraction" nil t)
                              ;; Wait for at least some content after the header
                              (progn (forward-line 2)
                                     (not (looking-at-p "^$")))))))
        (sleep-for 0.5)
        (accept-process-output nil 0.1))
      ;; Return t if extraction section found with content
      (save-excursion
        (goto-char (point-min))
        (search-forward "Skill/Rule Extraction" nil t)))))

;;; Integration Tests

(ert-deftest test-claude-org-extraction-hook-registered ()
  "Test that extraction hook can be registered."
  :tags '(:unit :extraction)
  (let ((claude-org-complete-hook nil))
    (add-hook 'claude-org-complete-hook #'claude-org-extract-knowledge)
    (should (member #'claude-org-extract-knowledge claude-org-complete-hook))))

(ert-deftest test-claude-org-extraction-timing-after-all ()
  "Test that extraction timing 'after-all' works correctly for loops."
  :tags '(:unit :extraction)
  (let ((claude-org-loop-extraction-timing 'after-all))
    ;; Non-loop should extract
    (cl-letf (((symbol-function 'claude-org--session-get)
               (lambda (key prop)
                 (pcase prop
                   (:loop-max 1)
                   (:loop-current 1)))))
      (should (claude-org--should-extract-now-p "test-session")))
    ;; Loop not at end should NOT extract
    (cl-letf (((symbol-function 'claude-org--session-get)
               (lambda (key prop)
                 (pcase prop
                   (:loop-max 3)
                   (:loop-current 1)))))
      (should-not (claude-org--should-extract-now-p "test-session")))
    ;; Loop at end SHOULD extract
    (cl-letf (((symbol-function 'claude-org--session-get)
               (lambda (key prop)
                 (pcase prop
                   (:loop-max 3)
                   (:loop-current 3)))))
      (should (claude-org--should-extract-now-p "test-session")))))

(ert-deftest test-claude-org-extraction-timing-after-each ()
  "Test that extraction timing 'after-each' extracts every iteration."
  :tags '(:unit :extraction)
  (let ((claude-org-loop-extraction-timing 'after-each))
    ;; Should extract for any iteration
    (cl-letf (((symbol-function 'claude-org--session-get)
               (lambda (key prop)
                 (pcase prop
                   (:loop-max 3)
                   (:loop-current 1)))))
      (should (claude-org--should-extract-now-p "test-session")))
    (cl-letf (((symbol-function 'claude-org--session-get)
               (lambda (key prop)
                 (pcase prop
                   (:loop-max 3)
                   (:loop-current 2)))))
      (should (claude-org--should-extract-now-p "test-session")))))

(ert-deftest test-claude-org-extraction-prompt-file-exists ()
  "Test that the claudeception prompt file exists."
  :tags '(:unit :extraction)
  (let ((prompt-file (expand-file-name "skills/claudeception.org"
                                       claude-org-prompts-directory)))
    (should (file-exists-p prompt-file))))

(ert-deftest test-claude-org-extraction-prompt-loads ()
  "Test that the claudeception prompt can be loaded."
  :tags '(:unit :extraction)
  (let* ((prompt-file (expand-file-name "skills/claudeception.org"
                                        claude-org-prompts-directory))
         (content (claude-org--load-prompt-file prompt-file)))
    (should content)
    (should (stringp content))
    (should (> (length content) 100))
    ;; Check for key sections
    (should (string-match-p "Skills" content))
    (should (string-match-p "Rules" content))
    (should (string-match-p "Summary" content))
    (should (string-match-p "emacs-agent" content))))

(ert-deftest test-claude-org-extraction-hook-skips-on-error ()
  "Test that extraction is skipped when execution status is error."
  :tags '(:unit :extraction)
  (let ((extraction-ran nil))
    (cl-letf (((symbol-function 'claude-org--run-knowledge-extraction)
               (lambda (key) (setq extraction-ran t))))
      ;; Should NOT run on error status
      (claude-org-extract-knowledge "test-session" "some error" 'error)
      (should-not extraction-ran)
      ;; SHOULD run on completed status
      (cl-letf (((symbol-function 'claude-org--should-extract-now-p)
                 (lambda (key) t)))
        (claude-org-extract-knowledge "test-session" nil 'completed)
        (should extraction-ran)))))

(ert-deftest test-claude-org-extraction-single-execution-integration ()
  "Integration test: extraction runs after single AI block execution.
This test requires a running Claude API connection."
  :tags '(:integration :extraction)
  (skip-unless (executable-find "claude"))
  (test-claude-org-extraction--with-temp-org-file
    (let ((extraction-ran nil)
          (claude-org-complete-hook nil))
      ;; Add our test hook before the extraction hook
      (add-hook 'claude-org-complete-hook
                (lambda (session-key result status)
                  (when (eq status 'completed)
                    (setq extraction-ran t))))
      (add-hook 'claude-org-complete-hook #'claude-org-extract-knowledge)
      ;; Insert a simple AI block
      (insert "* Test Instruction :claude_chat:\n\n")
      (insert "#+begin_src ai\n")
      (insert "Say 'hello' and nothing else.\n")
      (insert "#+end_src\n")
      ;; Position cursor in block
      (search-backward "Say 'hello'")
      ;; Execute
      (claude-org-execute)
      ;; Wait for completion
      (let ((session-key (claude-org--current-session-key)))
        (should (test-claude-org-extraction--wait-for-completion session-key))
        ;; Verify hook ran
        (should extraction-ran)
        ;; Check buffer has extraction section
        (goto-char (point-min))
        (should (search-forward "Skill/Rule Extraction" nil t))))))

(ert-deftest test-claude-org-extraction-continue-conversation ()
  "Integration test: extraction uses same session for context.
This test requires a running Claude API connection."
  :tags '(:integration :extraction)
  (skip-unless (executable-find "claude"))
  (test-claude-org-extraction--with-temp-org-file
    (let ((claude-org-complete-hook nil))
      (add-hook 'claude-org-complete-hook #'claude-org-extract-knowledge)
      ;; Insert AI block with context to remember
      (insert "* Test :claude_chat:\n\n")
      (insert "#+begin_src ai\n")
      (insert "Remember: The magic word is XYZZY123. Reply with just 'OK'.\n")
      (insert "#+end_src\n")
      (search-backward "Remember:")
      (claude-org-execute)
      (let ((session-key (claude-org--current-session-key)))
        (should (test-claude-org-extraction--wait-for-completion session-key 180))
        ;; The extraction should have access to the same session context
        ;; (we can't easily verify :continue-conversation but we verify
        ;; the extraction section was added, implying the query completed)
        (goto-char (point-min))
        (should (search-forward "Skill/Rule Extraction" nil t))))))

(ert-deftest test-claude-org-extraction-output-format ()
  "Integration test: extraction output contains expected sections.
This test requires a running Claude API connection."
  :tags '(:integration :extraction)
  (skip-unless (executable-find "claude"))
  (test-claude-org-extraction--with-temp-org-file
    (let ((claude-org-complete-hook nil)
          (buf (current-buffer)))
      (add-hook 'claude-org-complete-hook #'claude-org-extract-knowledge)
      ;; Insert a trivial task (likely no extraction)
      (insert "* Simple Task :claude_chat:\n\n")
      (insert "#+begin_src ai\n")
      (insert "What is 2+2? Just reply with the number.\n")
      (insert "#+end_src\n")
      (search-backward "What is")
      (claude-org-execute)
      (let ((session-key (claude-org--current-session-key)))
        (should (test-claude-org-extraction--wait-for-completion session-key))
        ;; Wait for extraction to complete (it's a second async query)
        (should (test-claude-org-extraction--wait-for-extraction buf 60))
        ;; Check extraction section exists with content
        (goto-char (point-min))
        (should (search-forward "Skill/Rule Extraction" nil t))
        ;; For a trivial task, Claude should indicate no extraction needed
        ;; Accept various phrasings: "No new skills", "no skills", "none", "Summary"
        (goto-char (point-min))
        (should (or (search-forward "No new skills" nil t)
                    (search-forward "no skills" nil t)
                    (search-forward "nothing to extract" nil t)
                    (search-forward "none" nil t)
                    (search-forward "Summary" nil t)))))))

(ert-deftest test-claude-org-extraction-loop-after-all ()
  "Integration test: extraction runs only after final loop iteration.
This test requires a running Claude API connection."
  :tags '(:integration :extraction :slow)
  (skip-unless (executable-find "claude"))
  (test-claude-org-extraction--with-temp-org-file
    (let ((claude-org-complete-hook nil)
          (claude-org-loop-extraction-timing 'after-all)
          (extraction-count 0)
          (buf (current-buffer)))
      ;; Track extraction calls via advice (more reliable than cl-letf for async)
      (let ((advice-fn (lambda (orig-fn session-key)
                         (setq extraction-count (1+ extraction-count))
                         (funcall orig-fn session-key))))
        (advice-add 'claude-org--run-knowledge-extraction :around advice-fn)
        (unwind-protect
            (progn
              (add-hook 'claude-org-complete-hook #'claude-org-extract-knowledge)
              ;; Insert loop AI block
              (insert "* Loop Test :claude_chat:\n\n")
              (insert "#+begin_src ai :loop 2 :interval 1\n")
              (insert "Say 'iteration' and nothing else.\n")
              (insert "#+end_src\n")
              (search-backward "Say 'iteration'")
              (claude-org-execute)
              (let ((session-key (claude-org--current-session-key)))
                ;; Wait for all iterations to complete
                (should (test-claude-org-extraction--wait-for-completion session-key 300))
                ;; Wait for extraction to actually run and complete
                (should (test-claude-org-extraction--wait-for-extraction buf 120))
                ;; With after-all, extraction should run only once (after final iteration)
                (should (= extraction-count 1))))
          (advice-remove 'claude-org--run-knowledge-extraction advice-fn))))))

(provide 'test-claude-org-extraction-integration)
;;; test-claude-org-extraction-integration.el ends here
