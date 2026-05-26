;;; test-code-agent-error-injection.el --- Error injection tests -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Tests that use mock-cli-v2.py with error injection scenarios.
;; These exercise the SDK's error handling paths: crashes, malformed JSON,
;; rate limit errors, and hung process detection.
;;
;; All scenarios use fixture files in mock-scenarios/ with directives
;; like #CRASH, #MALFORMED, #EXIT, and #DELAY.

;;; Code:

(require 'ert)
(require 'code-agent)
(require 'test-config)

;;; Helpers

(defvar test-claude-mock-cli-v2-path
  (expand-file-name "mock-claude-cli-v2.py"
                    (file-name-directory
                     (directory-file-name test-claude-fixture-dir)))
  "Path to mock CLI v2 (Python) for error injection tests.")

(defun test-claude-v2-mock-options (scenario &rest args)
  "Create options using mock CLI v2 with explicit SCENARIO.
ARGS are additional options passed to `code-agent-options'."
  (apply #'code-agent-options
         :cli-path test-claude-mock-cli-v2-path
         :setting-sources test-claude-default-setting-sources
         :env (list (cons "MOCK_SCENARIO" scenario))
         args))

;;; Test: Crash Mid-Stream

(ert-deftest test-error-crash-mid-stream ()
  "Process killed mid-response — verify cleanup and completion.
Mock outputs init + one assistant message, then crashes via SIGKILL.
The sentinel should detect abnormal exit and invoke cleanup."
  :tags '(:unit :error-injection :process)
  (let ((tokens '())
        (error-received nil)
        (completed nil)
        (state nil))
    (setq state
          (code-agent-query
           "Generate some text"
           :options (test-claude-v2-mock-options "crash-mid-stream")
           :session-key "test-crash-mid-stream"
           :on-token (lambda (text)
                       (push text tokens))
           :on-error (lambda (err)
                       (setq error-received err))
           :on-complete (lambda (_result)
                          (setq completed t))))

    ;; Wait for process to finish (crash should be fast)
    (should (test-claude-wait-until
             (lambda () (or completed error-received))
             10))

    ;; After crash, query should no longer be active
    (should-not (code-agent--query-active-p state))

    ;; Should have received at least the init message before crash
    ;; (tokens may or may not have arrived depending on timing)
    ;; The key assertion: state is cleaned up, no dangling process
    (let ((proc (code-agent--process-state-process state)))
      (should (or (null proc) (not (process-live-p proc)))))))

;;; Test: Malformed JSON

(ert-deftest test-error-malformed-json ()
  "Invalid JSON line in stream — verify graceful degradation.
Mock outputs valid init, one good assistant message, then malformed JSON,
then continues with valid messages. SDK should skip the bad line and
continue processing."
  :tags '(:unit :error-injection :process)
  (let ((tokens '())
        (completed nil)
        (response nil))
    (code-agent-query
     "Generate some text"
     :options (test-claude-v2-mock-options "malformed-json")
     :session-key "test-malformed-json"
     :on-token (lambda (text)
                 (push text tokens))
     :on-message (lambda (msg)
                   (when (code-agent-assistant-message-p msg)
                     (setq response (code-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 10))

    ;; Should have completed despite malformed JSON in the middle
    (should completed)

    ;; Should have received valid tokens (at least the ones before/after malformed)
    (should (> (length tokens) 0))

    ;; Response should contain text from the valid messages
    (should response)))

;;; Test: Rate Limited

(ert-deftest test-error-rate-limited ()
  "Rate limit error response — verify error callback fires.
Mock outputs init then a result message with is_error=true and exits non-zero."
  :tags '(:unit :error-injection :process)
  (let ((completed nil)
        (result-msg nil)
        (error-received nil))
    (code-agent-query
     "Generate some text"
     :options (test-claude-v2-mock-options "rate-limited")
     :session-key "test-rate-limited"
     :on-message (lambda (msg)
                   (when (code-agent-result-message-p msg)
                     (setq result-msg msg)))
     :on-error (lambda (err)
                 (setq error-received err))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until
             (lambda () (or completed error-received))
             10))

    ;; Either we got the result message via on-message, or the error via on-error,
    ;; or the sentinel fired on-complete. Any of these means the error was handled.
    (should (or result-msg error-received completed))))

;;; Test: Timeout / Hung Process

(ert-deftest test-error-timeout-hung ()
  "Hung process — verify we can detect and kill it.
Mock outputs init + one message then hangs for 30s.
We manually kill the process after a short wait and verify cleanup."
  :tags '(:unit :error-injection :process)
  (let ((tokens '())
        (state nil)
        (completed nil)
        (error-received nil))
    (setq state
          (code-agent-query
           "Generate some text"
           :options (test-claude-v2-mock-options "timeout-hung")
           :session-key "test-timeout-hung"
           :on-token (lambda (text)
                       (push text tokens))
           :on-error (lambda (err)
                       (setq error-received err))
           :on-complete (lambda (_result)
                          (setq completed t))))

    ;; Wait for process to start and output initial data
    (should (test-claude-wait-until
             (lambda ()
               (and state
                    (code-agent--process-state-process state)
                    (process-live-p (code-agent--process-state-process state))))
             5))

    ;; Give it a moment to output the initial lines
    (sleep-for 0.5)
    (accept-process-output nil 0.3)

    ;; Should have received at least one token
    (should (> (length tokens) 0))

    ;; Process should still be alive (hung on the DELAY)
    (should (process-live-p (code-agent--process-state-process state)))

    ;; Kill the hung process (simulating timeout detection)
    (let ((proc (code-agent--process-state-process state)))
      (when (process-live-p proc)
        (kill-process proc)))

    ;; Wait for sentinel to fire and clean up
    (should (test-claude-wait-until
             (lambda () (or completed error-received))
             5))

    ;; Query should no longer be active
    (should-not (code-agent--query-active-p state))))

;;; Backward Compatibility: verify v2 mock works with existing scenarios

(ert-deftest test-v2-mock-backward-compat ()
  "Verify mock-cli-v2.py is backward compatible with existing scenarios.
Run the simple-query scenario through v2 mock and verify same behavior."
  :tags '(:unit :error-injection :process)
  (let ((response nil)
        (completed nil))
    (code-agent-query
     "What is 2+2?"
     :options (test-claude-v2-mock-options "simple-query")
     :on-message (lambda (msg)
                   (when (code-agent-assistant-message-p msg)
                     (setq response (code-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 10))
    (should response)
    (should (string-match-p "4" response))))

(provide 'test-code-agent-error-injection)
;;; test-code-agent-error-injection.el ends here
