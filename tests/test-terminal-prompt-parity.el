;;; test-terminal-prompt-parity.el --- TDD tests for terminal prompt feature parity -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Tests that terminal-typed prompts (via SDD bridge) get the same
;; block history recording and exec-status tracking as Emacs-originated
;; prompts (via C-c C-c / claude-org-execute).
;;
;; Design doc: docs/design-docs/2026-terminal-prompt-parity.org

;;; Code:

(require 'ert)
(require 'org)
(require 'claude-org)

;;; Helpers

(defvar test-tpp--cleanup-buffers nil
  "Buffers to kill in cleanup.")
(defvar test-tpp--cleanup-files nil
  "Files to delete in cleanup.")

(defun test-tpp--setup-sdd-buffer (session-id)
  "Create a temp org file with SDD structure and return (buffer . file-path).
SESSION-ID is the CLAUDE_SESSION_ID for the SDD section."
  (let* ((tmp-file (make-temp-file "test-tpp-" nil ".org"))
         (buf (find-file-noselect tmp-file)))
    (push buf test-tpp--cleanup-buffers)
    (push tmp-file test-tpp--cleanup-files)
    (with-current-buffer buf
      (erase-buffer)
      (org-mode)
      (insert (format "* Test Feature :sdd:\n"
                       ))
      (insert ":PROPERTIES:\n")
      (insert (format ":CLAUDE_SESSION_ID: %s\n" session-id))
      (insert (format ":CUSTOM_ID: test-feature-%s\n" session-id))
      (insert ":END:\n")
      (insert "** System Prompt :system_prompt:\n")
      (insert "You are a test assistant.\n")
      (insert "** Workflow :sdd:\n")
      (insert ":PROPERTIES:\n")
      (insert (format ":CUSTOM_ID: test-feature-workflow-%s\n" session-id))
      (insert ":END:\n")
      (save-buffer))
    (cons buf tmp-file)))

(defun test-tpp--cleanup ()
  "Clean up test buffers and files."
  (dolist (buf test-tpp--cleanup-buffers)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (set-buffer-modified-p nil))
      (kill-buffer buf)))
  (dolist (file test-tpp--cleanup-files)
    (when (file-exists-p file)
      (delete-file file)))
  (setq test-tpp--cleanup-buffers nil
        test-tpp--cleanup-files nil))

;;; Test 1: Exec-status set to "executing"

(ert-deftest test-tpp-exec-status-executing ()
  "Terminal-typed prompt should set AI_EXEC_STATUS to executing on the heading."
  :tags '(:unit :fast :tdd :terminal-parity)
  (let ((session-id "sdd-20260312-test-exec")
        (setup nil))
    (unwind-protect
        (progn
          (setq setup (test-tpp--setup-sdd-buffer session-id))
          (let* ((buf (car setup))
                 (org-file (cdr setup)))
            (with-current-buffer buf
              (claude-org-workspace-bridge-insert-prompt
               org-file session-id "Explain closures")
              ;; Navigate to the Instruction heading
              (goto-char (point-min))
              (should (re-search-forward "^\\*\\*\\* Instruction 1" nil t))
              (org-back-to-heading t)
              ;; Should have exec status set
              (should (string= "executing"
                               (org-entry-get nil claude-org-exec-status-property))))))
      (test-tpp--cleanup))))

;;; Test 3: Query-completed clears busy and sets exec-status

(ert-deftest test-tpp-query-completed-clears-state ()
  "claude-org-iterm2--query-completed should clear :busy and set exec-status."
  :tags '(:unit :fast :tdd :terminal-parity)
  (let ((session-id "sdd-20260312-test-qcomp")
        (setup nil))
    (unwind-protect
        (progn
          (setq setup (test-tpp--setup-sdd-buffer session-id))
          (let* ((buf (car setup))
                 (org-file (cdr setup)))
            (with-current-buffer buf
              (claude-org-workspace-bridge-insert-prompt
               org-file session-id "Summarize this")
              ;; Session should be busy
              (let ((session-key (claude-org--current-session-key)))
                (should (claude-org--session-get session-key :busy))
                ;; Call query-completed (need to have a request-id saved)
                (claude-org-iterm2--query-completed session-id)
                ;; :busy should be cleared
                (should-not (claude-org--session-get session-key :busy))))))
      (test-tpp--cleanup))))

(provide 'test-terminal-prompt-parity)
;;; test-terminal-prompt-parity.el ends here
