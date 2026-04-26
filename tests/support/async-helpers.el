;;; async-helpers.el --- Async test helpers with adaptive backoff -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Async test helpers with adaptive backoff for more efficient waiting.
;; Replaces naive polling with intelligent exponential backoff.

;;; Code:

(require 'cl-lib)

;;; Adaptive Waiting

(defconst test-claude-default-timeout 60
  "Default timeout in seconds for async wait operations.")

(cl-defun test-claude-wait-until (predicate
                                   &key
                                   (timeout test-claude-default-timeout)
                                   (initial-interval 0.05)
                                   (max-interval 0.5)
                                   (backoff-factor 1.5)
                                   (description "condition"))
  "Wait for PREDICATE with adaptive backoff.
Returns predicate result on success, nil on timeout.

TIMEOUT: Maximum seconds to wait (default `test-claude-default-timeout').
INITIAL-INTERVAL: Starting poll interval in seconds (default 50ms).
MAX-INTERVAL: Maximum poll interval in seconds (default 500ms).
BACKOFF-FACTOR: Multiplier for increasing interval (default 1.5).
DESCRIPTION: Description for timeout message."
  (let ((start (float-time))
        (interval initial-interval)
        (result nil)
        (iterations 0))
    (while (and (not result)
                (< (- (float-time) start) timeout))
      (setq result (funcall predicate))
      (unless result
        (sleep-for interval)
        (accept-process-output nil interval)
        (cl-incf iterations)
        ;; Adaptive backoff
        (setq interval (min max-interval (* interval backoff-factor)))))
    (unless result
      (message "Timeout after %.2fs waiting for %s (%d iterations)"
               (- (float-time) start)
               description
               iterations))
    result))

(defun test-claude-wait-for-completion (session-key &optional timeout)
  "Wait for SESSION-KEY to complete with optimized polling.
Uses adaptive backoff for efficiency.
TIMEOUT defaults to `test-claude-default-timeout'."
  (test-claude-wait-until
   (lambda () (not (code-agent-org--session-get session-key :busy)))
   :timeout (or timeout test-claude-default-timeout)
   :initial-interval 0.05  ;; Start fast (50ms)
   :max-interval 0.3       ;; Cap at 300ms for session checks
   :description (format "session '%s' completion" session-key)))

(defun test-claude-wait-for-response (response-var &optional timeout)
  "Wait for RESPONSE-VAR (symbol) to be set.
Optimized for fast responses with quick initial polling.
TIMEOUT defaults to `test-claude-default-timeout'."
  (test-claude-wait-until
   (lambda () (symbol-value response-var))
   :timeout (or timeout test-claude-default-timeout)
   :initial-interval 0.01  ;; Very fast start (10ms)
   :max-interval 0.1       ;; Cap at 100ms for responses
   :backoff-factor 2.0     ;; Faster backoff
   :description (format "variable '%s' to be set" response-var)))

(defun test-claude-wait-for-process-start (process &optional timeout)
  "Wait for PROCESS to start running.
Returns t if process started, nil if timeout."
  (test-claude-wait-until
   (lambda () (and (processp process) (process-live-p process)))
   :timeout (or timeout 5)
   :initial-interval 0.01
   :max-interval 0.1
   :description (format "process '%s' to start"
                       (if (processp process)
                           (process-name process)
                         "unknown"))))

(provide 'async-helpers)
;;; async-helpers.el ends here
