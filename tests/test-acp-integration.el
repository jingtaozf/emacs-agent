;;; test-acp-integration.el --- Integration tests for ACP backend -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Local E2E tests for the OpenCode ACP backend.
;; Requires `opencode` CLI installed and authenticated.
;; Run with: make test-acp-local

;;; Code:

(require 'ert)

;;; Helpers

(defun test-acp-skip-unless-opencode ()
  "Skip test if opencode CLI is not available."
  (unless (executable-find "opencode")
    (ert-skip "opencode CLI not found")))

(defun test-acp-wait-until (pred &optional timeout)
  "Wait until PRED returns non-nil, checking every 0.2s.
TIMEOUT defaults to 30 seconds.  Returns non-nil if PRED succeeded."
  (let ((deadline (+ (float-time) (or timeout 30))))
    (while (and (not (funcall pred))
                (< (float-time) deadline))
      (accept-process-output nil 0.2))
    (funcall pred)))

;;; Test: Backend struct creation

(ert-deftest test-acp-backend-create ()
  "Test that the ACP backend struct can be created."
  :tags '(:local-e2e :acp)
  (let ((backend (claude-agent-acp-opencode-create
                  :session-key "test-key"
                  :cwd "/tmp")))
    (should (claude-agent-acp-backend-p backend))
    (should (equal (claude-agent-acp-backend-session-key backend) "test-key"))
    (should (equal (claude-agent-acp-backend-cwd backend) "/tmp"))
    (should (equal (claude-agent-acp-backend-agent-name backend) "opencode"))
    (should-not (claude-agent-acp-backend-initialized backend))
    (should-not (claude-agent-acp-backend-active-query backend))))

;;; Test: Full handshake and prompt

(ert-deftest test-acp-handshake-and-prompt ()
  "Test initialize -> session/new -> session/prompt with real OpenCode."
  :tags '(:local-e2e :acp :slow)
  (test-acp-skip-unless-opencode)

  (let ((tokens nil)
        (completed nil)
        (error-msg nil)
        (backend (claude-agent-acp-opencode-create
                  :cwd (expand-file-name "."))))
    (unwind-protect
        (progn
          (claude-agent-backend-query
           backend
           "What is 1+1? Reply with ONLY the number."
           (list :on-token (lambda (tok) (push tok tokens))
                 :on-complete (lambda (_) (setq completed t))
                 :on-error (lambda (err) (setq error-msg err))))

          ;; Wait for completion (handshake + prompt response)
          (should (test-acp-wait-until (lambda () (or completed error-msg)) 30))
          (should-not error-msg)
          (should completed)

          ;; Verify we got the answer
          (let ((full-text (string-join (nreverse tokens) "")))
            (should (> (length full-text) 0))
            (should (string-match-p "2" full-text)))

          ;; Verify backend state
          (should (claude-agent-acp-backend-initialized backend))
          (should (claude-agent-acp-backend-session-id backend))
          (should-not (claude-agent-acp-backend-active-query backend)))
      ;; Cleanup
      (ignore-errors (claude-agent-backend-cleanup backend)))))

;;; Test: Backend reuse (second prompt on same session)

(ert-deftest test-acp-session-reuse ()
  "Test that a second prompt reuses the existing ACP session."
  :tags '(:local-e2e :acp :slow)
  (test-acp-skip-unless-opencode)

  (let ((completed-1 nil)
        (completed-2 nil)
        (error-msg nil)
        (tokens-1 nil)
        (tokens-2 nil)
        (backend (claude-agent-acp-opencode-create
                  :cwd (expand-file-name "."))))
    (unwind-protect
        (progn
          ;; First prompt
          (claude-agent-backend-query
           backend
           "Say only: first"
           (list :on-token (lambda (tok) (push tok tokens-1))
                 :on-complete (lambda (_) (setq completed-1 t))
                 :on-error (lambda (err) (setq error-msg err))))

          (should (test-acp-wait-until (lambda () (or completed-1 error-msg)) 30))
          (should-not error-msg)
          (should completed-1)

          (let ((session-id (claude-agent-acp-backend-session-id backend)))
            (should session-id)

            ;; Second prompt -- should reuse session
            (claude-agent-backend-query
             backend
             "Say only: second"
             (list :on-token (lambda (tok) (push tok tokens-2))
                   :on-complete (lambda (_) (setq completed-2 t))
                   :on-error (lambda (err) (setq error-msg err))))

            (should (test-acp-wait-until (lambda () (or completed-2 error-msg)) 30))
            (should-not error-msg)
            (should completed-2)

            ;; Same session ID
            (should (equal session-id
                          (claude-agent-acp-backend-session-id backend)))))
      ;; Cleanup
      (ignore-errors (claude-agent-backend-cleanup backend)))))

;;; Test: Cleanup releases resources

(ert-deftest test-acp-cleanup ()
  "Test that cleanup kills the process and clears state."
  :tags '(:local-e2e :acp)
  (test-acp-skip-unless-opencode)

  (let ((completed nil)
        (backend (claude-agent-acp-opencode-create
                  :cwd (expand-file-name "."))))
    ;; Connect by sending a prompt
    (claude-agent-backend-query
     backend
     "Say only: cleanup-test"
     (list :on-complete (lambda (_) (setq completed t))))

    (test-acp-wait-until (lambda () completed) 30)

    ;; Verify process is alive
    (let ((client (claude-agent-acp-backend-client backend)))
      (should client)
      (should (process-live-p (plist-get client :process)))

      ;; Cleanup
      (claude-agent-backend-cleanup backend)

      ;; All state should be cleared
      (should-not (claude-agent-acp-backend-client backend))
      (should-not (claude-agent-acp-backend-session-id backend))
      (should-not (claude-agent-acp-backend-initialized backend)))))

(provide 'test-acp-integration)
;;; test-acp-integration.el ends here
