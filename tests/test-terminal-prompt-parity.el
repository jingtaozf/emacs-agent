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

;;; Test 1: Block history recorded for terminal prompt

(ert-deftest test-tpp-block-history-recorded ()
  "Terminal-typed prompt via SDD bridge should record block history entry.
After `claude-org-sdd-bridge-insert-prompt', `claude-org--block-history'
should contain an entry with the generated CUSTOM_ID."
  :tags '(:unit :fast :tdd :terminal-parity)
  (let ((session-id "sdd-20260312-test-hist")
        (setup nil))
    (unwind-protect
        (progn
          (setq setup (test-tpp--setup-sdd-buffer session-id))
          (let* ((buf (car setup))
                 (org-file (cdr setup)))
            (with-current-buffer buf
              ;; Clear any existing history
              (setq-local claude-org--block-history nil)
              ;; Insert a terminal prompt
              (let ((custom-id (claude-org-sdd-bridge-insert-prompt
                                org-file session-id "What is 2+2?")))
                ;; Should have returned a custom-id
                (should custom-id)
                (should (stringp custom-id))
                ;; Block history should now have an entry
                (should claude-org--block-history)
                (should (= 1 (length claude-org--block-history)))
                ;; Entry should have the correct custom-id
                (let* ((entry (car claude-org--block-history))
                       (props (cdr entry)))
                  (should (string= custom-id (plist-get props :custom-id)))
                  (should (eq 'in-progress (plist-get props :status)))
                  (should (numberp (plist-get props :timestamp))))))))
      (test-tpp--cleanup))))

;;; Test 2: Session :block-id populated

(ert-deftest test-tpp-session-block-id-set ()
  "Terminal-typed prompt should store :block-id in session state.
This is needed for `claude-org--update-block-status' to find the entry
on completion."
  :tags '(:unit :fast :tdd :terminal-parity)
  (let ((session-id "sdd-20260312-test-blkid")
        (setup nil))
    (unwind-protect
        (progn
          (setq setup (test-tpp--setup-sdd-buffer session-id))
          (let* ((buf (car setup))
                 (org-file (cdr setup)))
            (with-current-buffer buf
              (setq-local claude-org--block-history nil)
              (claude-org-sdd-bridge-insert-prompt
               org-file session-id "Tell me a joke")
              ;; Session should have :block-id set
              (let* ((session-key (claude-org--current-session-key))
                     (block-id (claude-org--session-get session-key :block-id)))
                (should session-key)
                (should block-id)
                (should (stringp block-id))))))
      (test-tpp--cleanup))))

;;; Test 3: Exec-status set to "executing"

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
              (claude-org-sdd-bridge-insert-prompt
               org-file session-id "Explain closures")
              ;; Navigate to the Instruction heading
              (goto-char (point-min))
              (should (re-search-forward "^\\*\\*\\* Instruction 1" nil t))
              (org-back-to-heading t)
              ;; Should have exec status set
              (should (string= "executing"
                               (org-entry-get nil claude-org-exec-status-property))))))
      (test-tpp--cleanup))))

;;; Test 4: Completion updates block history status

(ert-deftest test-tpp-completion-updates-history ()
  "Firing `claude-org-complete-hook' should update block history to completed.
Simulates what Python handle_response does via MCP."
  :tags '(:unit :fast :tdd :terminal-parity)
  (let ((session-id "sdd-20260312-test-comp")
        (setup nil))
    (unwind-protect
        (progn
          (setq setup (test-tpp--setup-sdd-buffer session-id))
          (let* ((buf (car setup))
                 (org-file (cdr setup)))
            (with-current-buffer buf
              (setq-local claude-org--block-history nil)
              (claude-org-sdd-bridge-insert-prompt
               org-file session-id "Fix this bug")
              ;; Verify in-progress
              (should (= 1 (length claude-org--block-history)))
              (should (eq 'in-progress
                          (plist-get (cdar claude-org--block-history) :status)))
              ;; Simulate completion (same as Python does via MCP)
              (let ((session-key (claude-org--current-session-key)))
                (run-hook-with-args 'claude-org-complete-hook
                                    session-key nil 'completed))
              ;; Block history should now show completed
              (should (eq 'completed
                          (plist-get (cdar claude-org--block-history) :status))))))
      (test-tpp--cleanup))))

;;; Test 5: Query-completed clears busy and sets exec-status

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
              (claude-org-sdd-bridge-insert-prompt
               org-file session-id "Summarize this")
              ;; Session should be busy
              (let ((session-key (claude-org--current-session-key)))
                (should (claude-org--session-get session-key :busy))
                ;; Call query-completed (need to have a request-id saved)
                (claude-org-iterm2--query-completed session-id)
                ;; :busy should be cleared
                (should-not (claude-org--session-get session-key :busy))))))
      (test-tpp--cleanup))))

;;; Test 6: Multiple terminal prompts create separate history entries

(ert-deftest test-tpp-multiple-prompts-history ()
  "Two terminal prompts should create two distinct block history entries."
  :tags '(:unit :fast :tdd :terminal-parity)
  (let ((session-id "sdd-20260312-test-multi")
        (setup nil))
    (unwind-protect
        (progn
          (setq setup (test-tpp--setup-sdd-buffer session-id))
          (let* ((buf (car setup))
                 (org-file (cdr setup)))
            (with-current-buffer buf
              (setq-local claude-org--block-history nil)
              (let ((cid1 (claude-org-sdd-bridge-insert-prompt
                           org-file session-id "First question"))
                    (cid2 (claude-org-sdd-bridge-insert-prompt
                           org-file session-id "Second question")))
                ;; Two distinct custom IDs
                (should-not (string= cid1 cid2))
                ;; Two history entries
                (should (= 2 (length claude-org--block-history)))
                ;; Most recent is first (stack order)
                (should (string= cid2
                                 (plist-get (cdar claude-org--block-history) :custom-id)))))))
      (test-tpp--cleanup))))

(provide 'test-terminal-prompt-parity)
;;; test-terminal-prompt-parity.el ends here
