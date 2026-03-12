;;; test-claude-agent-chat.el --- Tests for claude-agent-chat mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Tests for `claude-agent-chat', `claude-agent-chat-mode',
;; `claude-agent-chat-interrupt', and `claude-agent-chat-clear'.
;; These tests mock the CLI and backend to avoid real API calls.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-agent)

;;; Helpers

(defvar test-chat--original-find-cli nil
  "Saved original `claude-agent--find-cli' for restore.")

(defun test-chat--setup ()
  "Set up chat test environment. Returns buffer to clean up."
  ;; Mock CLI discovery so chat can start without real CLI
  (setq test-chat--original-find-cli (symbol-function 'claude-agent--find-cli))
  (fset 'claude-agent--find-cli (lambda () "/usr/bin/true"))
  ;; Kill any existing chat buffer
  (when-let ((buf (get-buffer claude-agent-chat-buffer-name)))
    (kill-buffer buf))
  nil)

(defun test-chat--cleanup ()
  "Clean up chat test environment."
  ;; Restore original find-cli
  (when test-chat--original-find-cli
    (fset 'claude-agent--find-cli test-chat--original-find-cli)
    (setq test-chat--original-find-cli nil))
  ;; Kill chat buffer
  (when-let ((buf (get-buffer claude-agent-chat-buffer-name)))
    (let ((proc (get-buffer-process buf)))
      (when proc
        (set-process-query-on-exit-flag proc nil)
        (delete-process proc)))
    (kill-buffer buf)))

;;; Tests

(ert-deftest test-chat-creates-buffer ()
  "Verify `claude-agent-chat' creates the chat buffer."
  :tags '(:unit :fast :stable :isolated :chat)
  (test-chat--setup)
  (unwind-protect
      (progn
        (claude-agent-chat)
        (should (get-buffer claude-agent-chat-buffer-name)))
    (test-chat--cleanup)))

(ert-deftest test-chat-mode-enabled ()
  "Verify chat-mode is active in the chat buffer."
  :tags '(:unit :fast :stable :isolated :chat)
  (test-chat--setup)
  (unwind-protect
      (progn
        (claude-agent-chat)
        (with-current-buffer claude-agent-chat-buffer-name
          (should (eq major-mode 'claude-agent-chat-mode))))
    (test-chat--cleanup)))

(ert-deftest test-chat-send-starts-process ()
  "Verify sending input creates a backend and initiates a query.
We mock the backend query to verify it gets called."
  :tags '(:unit :fast :stable :isolated :chat)
  (test-chat--setup)
  (let ((query-called nil))
    (unwind-protect
        (progn
          (claude-agent-chat)
          (with-current-buffer claude-agent-chat-buffer-name
            ;; Mock backend-query to capture the call
            (cl-letf (((symbol-function 'claude-agent-backend-query)
                       (lambda (_backend _prompt _callbacks &rest _opts)
                         (setq query-called t)
                         ;; Return a dummy handle
                         'mock-handle)))
              ;; Inject a pre-created backend
              (setq claude-agent-chat--backend
                    (claude-agent-json-backend--create :persistent-p nil))
              (claude-agent-chat--send-input "Hello Claude")
              (should query-called))))
      (test-chat--cleanup))))

(ert-deftest test-chat-interrupt-kills-process ()
  "Verify `claude-agent-chat-interrupt' cancels the active query."
  :tags '(:unit :fast :stable :isolated :chat)
  (test-chat--setup)
  (let ((cancel-called nil))
    (unwind-protect
        (progn
          (claude-agent-chat)
          (with-current-buffer claude-agent-chat-buffer-name
            ;; Mock backend and query handle
            (setq claude-agent-chat--backend
                  (claude-agent-json-backend--create :persistent-p nil))
            (setq claude-agent-chat--query-handle 'mock-handle)
            (setq claude-agent-chat--waiting t)
            ;; Mock cancel
            (cl-letf (((symbol-function 'claude-agent-backend-cancel)
                       (lambda (_backend _handle)
                         (setq cancel-called t))))
              (claude-agent-chat-interrupt)
              (should cancel-called)
              ;; Should reset waiting state
              (should-not claude-agent-chat--waiting))))
      (test-chat--cleanup))))

(ert-deftest test-chat-quit-cleans-up ()
  "Verify killing the chat buffer cleans up the backend."
  :tags '(:unit :fast :stable :isolated :chat)
  (test-chat--setup)
  (let ((cleanup-called nil))
    (unwind-protect
        (progn
          (claude-agent-chat)
          (with-current-buffer claude-agent-chat-buffer-name
            ;; Set a backend
            (setq claude-agent-chat--backend
                  (claude-agent-json-backend--create :persistent-p nil))
            ;; Mock cleanup
            (cl-letf (((symbol-function 'claude-agent-backend-cleanup)
                       (lambda (_backend) (setq cleanup-called t))))
              ;; Kill buffer triggers kill-buffer-hook
              (let ((proc (get-buffer-process (current-buffer))))
                (when proc
                  (set-process-query-on-exit-flag proc nil)
                  (delete-process proc)))
              (kill-buffer (current-buffer))
              (should cleanup-called))))
      (test-chat--cleanup))))

(provide 'test-claude-agent-chat)
;;; test-claude-agent-chat.el ends here
