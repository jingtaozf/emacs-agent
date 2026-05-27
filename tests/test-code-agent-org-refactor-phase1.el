;;; test-code-agent-org-refactor-phase1.el --- Phase 1 refactoring tests -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; TDD tests for Phase 1 architecture refactoring:
;; F1: ensure-positive-level helper
;; F2: Unify token handler (handle-token removed, handle-token-v2 only)
;; F3: execute-core extraction
;; F4: merge duplicate .env parsers

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)

;; Source modules loaded by batch command (literate-elisp-load from Makefile)
(require 'code-agent)
(require 'code-agent-org)

;;; ===========================================================================
;;; F1: ensure-positive-level helper
;;; ===========================================================================

(ert-deftest test-ensure-positive-level-nil-returns-1 ()
  "nil input should default to 1."
  :tags '(:unit :fast :stable :isolated :refactor :f1)
  (should (= 1 (code-agent-org--ensure-positive-level nil))))

(ert-deftest test-ensure-positive-level-zero-returns-1 ()
  "0 input should default to 1."
  :tags '(:unit :fast :stable :isolated :refactor :f1)
  (should (= 1 (code-agent-org--ensure-positive-level 0))))

(ert-deftest test-ensure-positive-level-negative-returns-1 ()
  "Negative input should default to 1."
  :tags '(:unit :fast :stable :isolated :refactor :f1)
  (should (= 1 (code-agent-org--ensure-positive-level -5))))

(ert-deftest test-ensure-positive-level-positive-passthrough ()
  "Positive input should pass through unchanged."
  :tags '(:unit :fast :stable :isolated :refactor :f1)
  (should (= 3 (code-agent-org--ensure-positive-level 3)))
  (should (= 1 (code-agent-org--ensure-positive-level 1)))
  (should (= 7 (code-agent-org--ensure-positive-level 7))))

(ert-deftest test-effective-section-level-from-session ()
  "effective-section-level reads from session and applies guard."
  :tags '(:unit :fast :stable :isolated :refactor :f1)
  (let ((test-buffer (generate-new-buffer "*test-eff-level*")))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (insert "* Top\n** Sub\n")
          (setq buffer-file-name "/tmp/test-eff-level.org")
          (let ((session-key (code-agent-org-current-session-key)))
            ;; Set section-level to 4
            (code-agent-org-session-put session-key :section-level 4)
            (should (= 4 (code-agent-org--effective-section-level session-key)))
            ;; Set to nil — should fall back to 1
            (code-agent-org-session-put session-key :section-level nil)
            (should (= 1 (code-agent-org--effective-section-level session-key)))
            ;; Set to 0 — should fall back to 1
            (code-agent-org-session-put session-key :section-level 0)
            (should (= 1 (code-agent-org--effective-section-level session-key)))))
      (kill-buffer test-buffer))))

(ert-deftest test-create-response-section-uses-ensure-positive-level ()
  "create-response-section should use the ensure-positive-level helper,
producing valid headings even when session section-level is nil."
  :tags '(:unit :fast :stable :isolated :refactor :f1)
  (let ((test-buffer (generate-new-buffer "*test-crs-helper*")))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (insert "* Development\n** Story\n*** Task\n")
          (insert "#+begin_src ai\nquery\n#+end_src\n\n")
          (setq buffer-file-name "/tmp/test-crs-helper.org")
          (let* ((session-key (code-agent-org-current-session-key))
                 (query-id "test-crs-001"))
            (code-agent-org-session-put session-key :query-id query-id)
            ;; Leave section-level as nil (not set)
            (code-agent-org-session-put session-key :section-level nil)
            ;; Create response section — should not error, should produce valid heading
            (goto-char (point-max))
            (let ((pos (code-agent-org--create-response-section
                        session-key query-id 'normal)))
              (should pos)
              ;; Verify a heading with stars was created
              (goto-char (point-min))
              (should (re-search-forward "^\\*+ Response .* :ai_output:" nil t)))))
      (kill-buffer test-buffer))))

;;; ===========================================================================
;;; F2: Unify token handler — handle-token removed
;;; ===========================================================================

(ert-deftest test-handle-token-v1-removed ()
  "The old handle-token (marker-based) should no longer exist."
  :tags '(:unit :fast :stable :isolated :refactor :f2)
  (should-not (fboundp 'code-agent-org--handle-token)))

(ert-deftest test-handle-token-v2-normalizes-headers ()
  "handle-token-v2 should normalize headers in streamed text."
  :tags '(:unit :fast :stable :isolated :refactor :f2)
  (let ((test-buffer (generate-new-buffer "*test-htv2-norm*")))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (insert "* Top\n** Sub\n*** Task\n")
          (insert "#+begin_src ai\nquery\n#+end_src\n\n")
          (setq buffer-file-name "/tmp/test-htv2-norm.org")
          (let* ((session-key (code-agent-org-current-session-key))
                 (query-id "test-htv2-001"))
            (code-agent-org-session-put session-key :query-id query-id)
            (code-agent-org-session-put session-key :section-level 3)
            (code-agent-org-session-put session-key :response-has-content nil)
            ;; Create response section to have a valid insertion target
            (goto-char (point-max))
            (code-agent-org--create-response-section session-key query-id 'normal)
            ;; Send a token with a "* Heading" — should be normalized to level 4+
            (code-agent-org--handle-token-v2 session-key "* My Heading\nSome content\n")
            ;; The heading should NOT be at level 1 in the buffer
            ;; It should be at target-level = section-level + 1 = 4
            (goto-char (point-min))
            (should (re-search-forward "^\\*\\*\\*\\* My Heading" nil t))))
      (kill-buffer test-buffer))))

(ert-deftest test-handle-token-v2-strips-leading-newlines ()
  "handle-token-v2 strips leading newlines from first token."
  :tags '(:unit :fast :stable :isolated :refactor :f2)
  (let ((test-buffer (generate-new-buffer "*test-htv2-strip*")))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (insert "* Top\n")
          (insert "#+begin_src ai\nquery\n#+end_src\n\n")
          (setq buffer-file-name "/tmp/test-htv2-strip.org")
          (let* ((session-key (code-agent-org-current-session-key))
                 (query-id "test-htv2-002"))
            (code-agent-org-session-put session-key :query-id query-id)
            (code-agent-org-session-put session-key :section-level 1)
            (code-agent-org-session-put session-key :response-has-content nil)
            (goto-char (point-max))
            (code-agent-org--create-response-section session-key query-id 'normal)
            ;; First token with leading newlines
            (code-agent-org--handle-token-v2 session-key "\n\nHello world")
            ;; Should not have leading blank lines before "Hello world"
            (goto-char (point-min))
            (re-search-forward ":END:" nil t)
            (forward-line 1)
            ;; Skip one blank line (standard separator after :END:)
            (when (looking-at "^$") (forward-line 1))
            ;; Content should start without extra blank lines
            (should (looking-at "Hello world"))))
      (kill-buffer test-buffer))))

(ert-deftest test-with-session-marker-still-exists ()
  "with-session-marker macro should still exist (used by insert-error)."
  :tags '(:unit :fast :stable :isolated :refactor :f2)
  ;; The macro is still needed for error insertion — just handle-token is removed
  (should (fboundp 'code-agent-org--with-session-marker)))

;;; ===========================================================================
;;; F3: execute-core extraction — verify shared logic
;;; ===========================================================================

(ert-deftest test-execute-command-class-exists ()
  "The execute-command class and its run generic should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f3)
  (should (fboundp 'code-agent-org-execute-command--create))
  (should (fboundp 'code-agent-org-execute-command-run))
  (should (fboundp 'code-agent-org-execute-command-from-block-info)))

(ert-deftest test-execute-command-run-sets-session-state ()
  "Running an execute-command should populate all required session slots."
  :tags '(:unit :fast :stable :isolated :refactor :f3)
  (let ((test-buffer (generate-new-buffer "*test-exec-core*")))
    (unwind-protect
        (with-current-buffer test-buffer
          (org-mode)
          (insert "* Top\n** Story\n*** Task\n")
          (insert "#+begin_src ai\ntest query\n#+end_src\n\n")
          (setq buffer-file-name "/tmp/test-exec-core.org")
          (let* ((session-key (code-agent-org-current-session-key))
                 (content "test query")
                 (section-level 3)
                 (query-id "test-exec-001")
                 (custom-id "test-custom-001"))
            (goto-char (point-min))
            (re-search-forward "test query")
            (cl-letf (((symbol-function 'code-agent-org--send-request)
                       (lambda (&rest _args) nil))
                      ((symbol-function 'code-agent-org--generate-query-id)
                       (lambda () query-id))
                      ((symbol-function 'code-agent-org--start-spinner)
                       (lambda (&rest _) nil))
                      ((symbol-function 'code-agent-org--maybe-auto-generate-title)
                       (lambda (&rest _) nil))
                      ((symbol-function 'code-agent-org--find-response-insert-point)
                       (lambda () (point-max)))
                      ((symbol-function 'code-agent-org--find-instruction-number)
                       (lambda () 1))
                      ((symbol-function 'code-agent-org--set-exec-status)
                       (lambda (&rest _) nil)))
              (code-agent-org-execute-command-run
               (code-agent-org-execute-command--create
                :session-key session-key
                :content content
                :section-level section-level
                :custom-id custom-id
                :loop-max 1
                :loop-interval 0))
              (should (equal query-id (code-agent-org-session-get session-key :query-id)))
              (should (equal content (code-agent-org-session-get session-key :original-prompt)))
              (should (= section-level (code-agent-org-session-get session-key :section-level)))
              (should (code-agent-org-session-get session-key :busy))
              (should (= 1 (code-agent-org-session-get session-key :loop-max)))
              (should (= 1 (code-agent-org-session-get session-key :loop-current)))
              (should (= 0 (code-agent-org-session-get session-key :loop-interval)))
              (should (equal custom-id (code-agent-org-session-get session-key :custom-id))))))
      (kill-buffer test-buffer))))

;;; ===========================================================================
;;; F4: Merge .env parsers
;;; ===========================================================================

(ert-deftest test-parse-env-from-file ()
  "Unified parser should handle file path input."
  :tags '(:unit :fast :stable :isolated :refactor :f4)
  (let ((temp-file (make-temp-file "test-env-" nil ".env")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "FOO=bar\nBAZ=\"hello world\"\n# comment\nexport KEY=value\n"))
          (let ((result (code-agent-org--parse-env temp-file)))
            (should (assoc "FOO" result))
            (should (equal "bar" (cdr (assoc "FOO" result))))
            (should (equal "hello world" (cdr (assoc "BAZ" result))))
            (should (equal "value" (cdr (assoc "KEY" result))))))
      (delete-file temp-file))))

(ert-deftest test-parse-env-from-string ()
  "Unified parser should handle string input via :from-string."
  :tags '(:unit :fast :stable :isolated :refactor :f4)
  (let ((content "APP=myapp\nDEBUG='true'\n# skip me\n"))
    (let ((result (code-agent-org--parse-env content :from-string t)))
      (should (assoc "APP" result))
      (should (equal "myapp" (cdr (assoc "APP" result))))
      (should (equal "true" (cdr (assoc "DEBUG" result)))))))

(ert-deftest test-parse-env-strips-quotes ()
  "Parser should strip both single and double quotes."
  :tags '(:unit :fast :stable :isolated :refactor :f4)
  (let ((content "A=\"double quoted\"\nB='single quoted'\nC=unquoted\n"))
    (let ((result (code-agent-org--parse-env content :from-string t)))
      (should (equal "double quoted" (cdr (assoc "A" result))))
      (should (equal "single quoted" (cdr (assoc "B" result))))
      (should (equal "unquoted" (cdr (assoc "C" result)))))))

(ert-deftest test-parse-env-handles-export ()
  "Parser should handle 'export' prefix."
  :tags '(:unit :fast :stable :isolated :refactor :f4)
  (let ((content "export MY_VAR=hello\n"))
    (let ((result (code-agent-org--parse-env content :from-string t)))
      (should (equal "hello" (cdr (assoc "MY_VAR" result)))))))

(ert-deftest test-parse-env-skips-comments-and-blanks ()
  "Parser should skip comments and blank lines."
  :tags '(:unit :fast :stable :isolated :refactor :f4)
  (let ((content "# comment\n\nKEY=val\n\n# another comment\n"))
    (let ((result (code-agent-org--parse-env content :from-string t)))
      (should (= 1 (length result)))
      (should (equal "val" (cdr (assoc "KEY" result)))))))

(ert-deftest test-parse-env-value-with-equals ()
  "Parser should handle values containing = signs."
  :tags '(:unit :fast :stable :isolated :refactor :f4)
  (let ((content "URL=http://host?a=1&b=2\n"))
    (let ((result (code-agent-org--parse-env content :from-string t)))
      (should (equal "http://host?a=1&b=2" (cdr (assoc "URL" result)))))))

(ert-deftest test-parse-env-nonexistent-file ()
  "Parser should return nil for nonexistent file."
  :tags '(:unit :fast :stable :isolated :refactor :f4)
  (should (null (code-agent-org--parse-env "/tmp/nonexistent-env-file-xyz.env"))))

(ert-deftest test-parse-env-compat-aliases-removed ()
  "Deprecated compat aliases (`-parse-env-file', `-parse-env-file-safe',
`-parse-env-safe') were removed per the project's no-backward-compat
rule.  Callers use `code-agent-org--parse-env' directly."
  :tags '(:unit :fast :stable :isolated :refactor :f4)
  (should-not (fboundp 'code-agent-org--parse-env-file))
  (should-not (fboundp 'code-agent-org--parse-env-file-safe))
  (should-not (fboundp 'code-agent-org--parse-env-safe)))

(ert-deftest test-static-no-handle-token-v1-references ()
  "No references to the removed handle-token v1 should remain in source."
  :tags '(:unit :fast :stable :isolated :refactor :static)
  (let ((source-files '("code-agent-org.org" "code-agent.org")))
    (dolist (file source-files)
      (let ((path (expand-file-name file
                    (file-name-directory (or load-file-name
                                             (locate-library "test-code-agent-org-refactor-phase1")
                                             default-directory)))))
        (when (file-exists-p path)
          (with-temp-buffer
            (insert-file-contents path)
            ;; Should not find handle-token that is NOT handle-token-v2
            ;; Pattern: handle-token followed by non-"-v2" or end of word
            (goto-char (point-min))
            (let ((found-v1 nil))
              (while (re-search-forward "code-agent-org--handle-token\\b" nil t)
                (unless (looking-at "-v2")
                  ;; Skip the defun line in case it's in a comment
                  (unless (save-excursion
                            (beginning-of-line)
                            (looking-at ".*;;"))
                    (setq found-v1 t))))
              (should-not found-v1))))))))

(provide 'test-code-agent-org-refactor-phase1)
;;; test-code-agent-org-refactor-phase1.el ends here
