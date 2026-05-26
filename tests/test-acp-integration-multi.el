;;; test-acp-integration-multi.el --- E2E tests for all ACP profiles -*- lexical-binding: t; -*-

;;; Commentary:

;; Local E2E tests that exercise the generic ACP backend against each
;; agent profile (opencode, gemini, codex).  Tests skip when the
;; corresponding CLI or API key is unavailable, so this file is safe to
;; run unconditionally — only the reachable agents execute.
;;
;; Run with: make test-acp-multi-local

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; Wait helper

(defun test-acp-multi--wait-until (pred &optional timeout)
  "Wait until PRED returns non-nil, polling every 0.2s.  TIMEOUT defaults to 45s."
  (let ((deadline (+ (float-time) (or timeout 45))))
    (while (and (not (funcall pred))
                (< (float-time) deadline))
      (accept-process-output nil 0.2))
    (funcall pred)))

;;; Skip helpers

(defun test-acp-multi--skip-unless (binary env-var &optional alt-msg)
  "Skip if BINARY is not on PATH or if ENV-VAR (when non-nil) is unset."
  (unless (executable-find binary)
    (ert-skip (or alt-msg (format "%s CLI not found" binary))))
  (when (and env-var (not (getenv env-var)))
    (ert-skip (format "env var %s not set" env-var))))

;;; Gemini E2E

(ert-deftest test-acp-multi-gemini-basic-prompt ()
  "Gemini ACP: initialize → authenticate → session/new → session/prompt → result."
  :tags '(:local-e2e :acp :gemini :slow)
  (test-acp-multi--skip-unless "gemini" "GEMINI_API_KEY")
  (let* ((tokens nil)
         (completed nil)
         (error-msg nil)
         (code-agent-acp-gemini-auth-method 'gemini-api-key)
         (code-agent-acp-gemini-environment
          (list (format "GEMINI_API_KEY=%s" (getenv "GEMINI_API_KEY"))))
         (backend (code-agent-acp-gemini-create
                   :cwd (expand-file-name "."))))
    (unwind-protect
        (progn
          (code-agent-backend-query
           backend
           "Reply with exactly the single word: hello"
           (list :on-token (lambda (tok) (push tok tokens))
                 :on-complete (lambda (_) (setq completed t))
                 :on-error (lambda (err) (setq error-msg err))))
          (should (test-acp-multi--wait-until
                   (lambda () (or completed error-msg)) 60))
          (should-not error-msg)
          (should completed)
          (let ((full-text (downcase (string-join (nreverse tokens) ""))))
            (should (> (length full-text) 0))
            (should (string-match-p "hello" full-text))))
      (ignore-errors (code-agent-backend-cleanup backend)))))

;;; Codex E2E

(ert-deftest test-acp-multi-codex-basic-prompt ()
  "Codex ACP: requires the codex-acp shim binary on PATH."
  :tags '(:local-e2e :acp :codex :slow)
  (test-acp-multi--skip-unless "codex-acp" "OPENAI_API_KEY"
                               "codex-acp shim not installed")
  (let* ((tokens nil)
         (completed nil)
         (error-msg nil)
         (code-agent-acp-codex-auth-method 'openai-api-key)
         (code-agent-acp-codex-environment
          (list (format "OPENAI_API_KEY=%s" (getenv "OPENAI_API_KEY"))))
         (backend (code-agent-acp-codex-create
                   :cwd (expand-file-name "."))))
    (unwind-protect
        (progn
          (code-agent-backend-query
           backend
           "Reply with exactly the single word: hello"
           (list :on-token (lambda (tok) (push tok tokens))
                 :on-complete (lambda (_) (setq completed t))
                 :on-error (lambda (err) (setq error-msg err))))
          (should (test-acp-multi--wait-until
                   (lambda () (or completed error-msg)) 60))
          (should-not error-msg)
          (should completed)
          (let ((full-text (downcase (string-join (nreverse tokens) ""))))
            (should (string-match-p "hello" full-text))))
      (ignore-errors (code-agent-backend-cleanup backend)))))

(provide 'test-acp-integration-multi)
;;; test-acp-integration-multi.el ends here
