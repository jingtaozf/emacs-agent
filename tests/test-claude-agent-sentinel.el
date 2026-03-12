;;; test-claude-agent-sentinel.el --- Process sentinel tests -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Tests that exercise process sentinel callbacks.
;; These verify that the SDK properly handles all process exit scenarios:
;; normal exit, crash exit, OOM kill, and filter errors.
;;
;; Uses mock-cli-v2.py for scenarios that require specific exit behaviors.

;;; Code:

(require 'ert)
(require 'claude-agent)
(require 'test-config)

;;; Helpers

(defvar test-sentinel-mock-cli-v2-path
  (expand-file-name "mock-claude-cli-v2.py"
                    (file-name-directory
                     (directory-file-name test-claude-fixture-dir)))
  "Path to mock CLI v2 (Python) for sentinel tests.")

(defun test-sentinel-mock-options (scenario &rest args)
  "Create options using mock CLI v2 with explicit SCENARIO.
ARGS are additional options passed to `claude-agent-options'."
  (apply #'claude-agent-options
         :cli-path test-sentinel-mock-cli-v2-path
         :setting-sources test-claude-default-setting-sources
         :env (list (cons "MOCK_SCENARIO" scenario))
         args))

;;; Test: Normal Exit

(ert-deftest test-sentinel-normal-exit ()
  "Mock process exits 0 — verify session state idle, markers freed.
After normal completion, the process state should be closed,
the process should not be live, and on-complete should have fired."
  :tags '(:unit :sentinel)
  (let ((completed nil)
        (result-msg nil)
        (state nil))
    (setq state
          (claude-agent-query
           "What is 2+2?"
           :options (test-sentinel-mock-options "simple-query")
           :session-key "test-sentinel-normal"
           :on-message (lambda (msg)
                         (when (claude-agent-result-message-p msg)
                           (setq result-msg msg)))
           :on-complete (lambda (_result)
                          (setq completed t))))

    (should (test-claude-wait-until (lambda () completed) 10))

    ;; on-complete must have fired
    (should completed)

    ;; Result message received
    (should result-msg)

    ;; Process state should be closed
    (should (claude-agent--process-state-closed state))

    ;; got-result flag should be set
    (should (claude-agent--process-state-got-result state))

    ;; Process should no longer be live
    (let ((proc (claude-agent--process-state-process state)))
      (should (or (null proc) (not (process-live-p proc)))))

    ;; Query should not be active
    (should-not (claude-agent--query-active-p state))))

;;; Test: Crash Exit

(ert-deftest test-sentinel-crash-exit ()
  "Mock process exits non-zero — verify error callback, state cleanup.
Uses crash-mid-stream scenario: process is killed mid-response.
Sentinel should detect abnormal exit and clean up state."
  :tags '(:unit :sentinel)
  (let ((claude-agent-auto-recovery nil)  ; disable recovery for clean test
        (completed nil)
        (error-received nil)
        (state nil))
    (setq state
          (claude-agent-query
           "Generate text then crash"
           :options (test-sentinel-mock-options "crash-mid-stream")
           :session-key "test-sentinel-crash"
           :on-error (lambda (err)
                       (setq error-received err))
           :on-complete (lambda (_result)
                          (setq completed t))))

    ;; Wait for sentinel to fire
    (should (test-claude-wait-until
             (lambda () (or completed error-received))
             10))

    ;; Process state should be closed after sentinel runs
    (should (claude-agent--process-state-closed state))

    ;; got-result should NOT be set (crashed before result)
    (should-not (claude-agent--process-state-got-result state))

    ;; Process should no longer be live
    (let ((proc (claude-agent--process-state-process state)))
      (should (or (null proc) (not (process-live-p proc)))))

    ;; Query should not be active
    (should-not (claude-agent--query-active-p state))))

;;; Test: OOM Kill (Signal 9)

(ert-deftest test-sentinel-oom-kill ()
  "Signal 9 exit — verify cleanup.
Starts a slow query, then sends SIGKILL to simulate OOM kill.
Sentinel should handle signal death gracefully."
  :tags '(:unit :sentinel)
  (let ((claude-agent-auto-recovery nil)
        (state nil)
        (completed nil)
        (error-received nil))
    (setq state
          (claude-agent-query
           "Write a very long story..."
           :options (test-sentinel-mock-options "slow-response")
           :session-key "test-sentinel-oom"
           :on-error (lambda (err)
                       (setq error-received err))
           :on-complete (lambda (_result)
                          (setq completed t))))

    ;; Wait for process to start
    (should (test-claude-wait-until
             (lambda ()
               (and state
                    (claude-agent--process-state-process state)
                    (process-live-p (claude-agent--process-state-process state))))
             5))

    ;; Give it time to start outputting
    (sleep-for 0.3)
    (accept-process-output nil 0.2)

    ;; Send SIGKILL (simulating OOM killer)
    (let ((proc (claude-agent--process-state-process state)))
      (when (process-live-p proc)
        (signal-process proc 9)))

    ;; Wait for sentinel to fire
    (should (test-claude-wait-until
             (lambda () (or completed error-received))
             5))

    ;; State should be fully cleaned up
    (should (claude-agent--process-state-closed state))
    (should-not (claude-agent--query-active-p state))

    ;; Process must not be live
    (let ((proc (claude-agent--process-state-process state)))
      (should (or (null proc) (not (process-live-p proc)))))))

;;; Test: Filter Error Recovery

(ert-deftest test-sentinel-filter-error-recovery ()
  "Error in filter — verify sentinel compensates.
Uses malformed JSON scenario which may trigger filter errors.
Even if the filter encounters bad data, sentinel should still
clean up properly when the process exits."
  :tags '(:unit :sentinel)
  (let ((completed nil)
        (state nil))
    (setq state
          (claude-agent-query
           "Generate text with malformed data"
           :options (test-sentinel-mock-options "malformed-json")
           :session-key "test-sentinel-filter-error"
           :on-complete (lambda (_result)
                          (setq completed t))))

    ;; Should complete despite malformed JSON in stream
    (should (test-claude-wait-until (lambda () completed) 10))

    ;; State must be fully cleaned up by sentinel
    (should (claude-agent--process-state-closed state))
    (should-not (claude-agent--query-active-p state))

    ;; Process should not be live
    (let ((proc (claude-agent--process-state-process state)))
      (should (or (null proc) (not (process-live-p proc)))))))

;;; Test: Rate Limit Exit Code

(ert-deftest test-sentinel-error-exit-code ()
  "Non-zero exit with error result — verify sentinel handles gracefully.
Uses rate-limited scenario: exits with code 1 after error result message."
  :tags '(:unit :sentinel)
  (let ((completed nil)
        (error-received nil)
        (state nil))
    (setq state
          (claude-agent-query
           "Generate text"
           :options (test-sentinel-mock-options "rate-limited")
           :session-key "test-sentinel-error-exit"
           :on-error (lambda (err)
                       (setq error-received err))
           :on-complete (lambda (_result)
                          (setq completed t))))

    ;; Wait for full cleanup (closed state), not just callbacks
    (should (test-claude-wait-until
             (lambda () (and state (claude-agent--process-state-closed state)))
             10))

    ;; State should be cleaned up
    (should-not (claude-agent--query-active-p state))
    ;; At least one of the callbacks should have fired
    (should (or completed error-received))))

(provide 'test-claude-agent-sentinel)
;;; test-claude-agent-sentinel.el ends here
