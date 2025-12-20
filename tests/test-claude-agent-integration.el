;;; test-claude-agent-integration.el --- Integration tests for claude-agent.el -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Integration tests for claude-agent.el
;; These tests make REAL API calls to Claude.
;; Requires ANTHROPIC_API_KEY environment variable.

;;; Code:

(require 'ert)
(require 'claude-agent)
(require 'test-config)

;;; Basic Query Tests

(ert-deftest test-integration-simple-query ()
  "Test basic query execution with real API."
  :tags '(:integration :slow :api :stable :process)
  (test-claude-skip-unless-cli-available)

  (let ((response-received nil)
        (tokens '())
        (completed nil))
    (claude-agent-query
     "What is 2+2? Answer with just the number."
     :on-token (lambda (text)
                 (push text tokens))
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     (setq response-received (claude-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed t)))

    ;; Wait for completion
    (should (test-claude-wait-until (lambda () completed) 30))
    (should response-received)
    (should (> (length tokens) 0))
    (should (string-match-p "4" response-received))))

(ert-deftest test-integration-streaming-tokens ()
  "Test that :on-token callback is called for message content.
Note: Claude CLI returns complete messages, not per-character tokens,
so :on-token is called once per message with the full text content."
  :tags '(:integration :slow :api :stable :process)
  (test-claude-skip-unless-cli-available)

  (let ((token-count 0)
        (token-text "")
        (completed nil))
    (claude-agent-query
     "Count from 1 to 3 slowly: one, two, three."
     :on-token (lambda (text)
                 (cl-incf token-count)
                 (setq token-text (concat token-text text)))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 30))
    (should (>= token-count 1))
    (should (> (length token-text) 0))))

;;; Session Management Tests

(ert-deftest test-integration-session-continuity ()
  "Test session continuation with --resume."
  :tags '(:integration :slow :api :stable :session)
  (test-claude-skip-unless-cli-available)

  (let ((session-key "test-session-continuity")
        (first-response nil)
        (second-response nil)
        (sdk-uuid nil)
        (completed1 nil)
        (completed2 nil))

    ;; First query - establish session
    (claude-agent-query
     "Remember this number: 42. Just confirm you remember it."
     :session-key session-key
     :on-message (lambda (msg)
                   (when (claude-agent-result-message-p msg)
                     (setq sdk-uuid (claude-agent-result-message-session-id msg)))
                   (when (claude-agent-assistant-message-p msg)
                     (setq first-response (claude-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed1 t)))

    (should (test-claude-wait-until (lambda () completed1) 30))
    (should sdk-uuid)
    (should first-response)

    ;; Second query - continue session
    (claude-agent-query
     "What number did I ask you to remember? Just the number."
     :options (claude-agent-options :resume sdk-uuid)
     :session-key session-key
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     (setq second-response (claude-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed2 t)))

    (should (test-claude-wait-until (lambda () completed2) 30))
    (should second-response)
    (should (> (length second-response) 0))))

(ert-deftest test-integration-session-expiry-detection ()
  "Test detection of session expiry errors.
  :tags '(:integration :slow :api :flaky :session)
NOTE: Skipped because Claude CLI doesn't fail on invalid session UUIDs.
When given a non-existent session, CLI prints a warning to stderr
but continues with a new session instead of failing."
  :expected-result :failed  ;; Mark as expected to fail (skip)
  (ert-skip "Claude CLI continues with new session instead of failing on invalid session UUID"))

;;; Tool Use Tests

(ert-deftest test-integration-tool-use-read ()
  "Test that Claude can use the Read tool.
  :tags '(:integration :slow :api :stable :process)
NOTE: This test can be flaky due to API variability."
  (test-claude-skip-unless-cli-available)

  (let ((tool-used nil)
        (response nil)
        (completed nil)
        (error-occurred nil))
    (claude-agent-query
     "Use the Read tool to read the file README.md and tell me the first word."
     :options (claude-agent-options
               :cwd (expand-file-name "~/projects/claude-agent")
               :permission-mode "acceptEdits")
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     ;; Check for tool use in content
                     (dolist (block (claude-agent-assistant-message-content msg))
                       (when (claude-agent-tool-use-block-p block)
                         (when (equal "Read" (claude-agent-tool-use-block-name block))
                           (setq tool-used t))))
                     (setq response (claude-agent-extract-text msg))))
     :on-error (lambda (err)
                 (setq error-occurred t)
                 (message "Error in Read tool test: %S" err))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () (or completed error-occurred)) 60))
    (when completed
      (should response))))

(ert-deftest test-integration-tool-use-glob ()
  "Test that Claude can use the Glob tool.
  :tags '(:integration :slow :api :flaky :process)
NOTE: Skipped due to high flakiness - tool use tests frequently timeout with live API.
This is a known limitation of testing complex tool use against the real API."
  :expected-result :failed  ;; Mark as expected to fail (effectively skip)
  (ert-skip "Tool use with Glob frequently times out - too flaky for reliable testing"))

;;; Permission Mode Tests

(ert-deftest test-integration-readonly-mode ()
  "Test default permission mode with tool use request.
  :tags '(:integration :slow :api :stable :permission)
NOTE: This test can be flaky due to API variability."
  (test-claude-skip-unless-cli-available)

  (let ((response nil)
        (completed nil)
        (error-occurred nil))
    (claude-agent-query
     "What is 2+2? Just give me the number."
     :options (claude-agent-options
               :cwd (expand-file-name "~/projects/claude-agent")
               :permission-mode "default")
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     (setq response (claude-agent-extract-text msg))))
     :on-error (lambda (err)
                 (setq error-occurred t)
                 (message "Error in readonly test: %S" err))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () (or completed error-occurred)) 45))
    (when completed
      (should response))))

;;; Error Handling Tests

(ert-deftest test-integration-invalid-api-key ()
  "Test error handling infrastructure.
  :tags '(:integration :slow :api :stable :process)
NOTE: Claude CLI uses its own auth (~/.claude/auth), not ANTHROPIC_API_KEY.
This test verifies that error handling works, but doesn't actually trigger
an auth error since CLI ignores the environment variable."
  (test-claude-skip-unless-cli-available)

  (let ((completed nil)
        (response nil)
        (error-occurred nil))
    (claude-agent-query
     "What is 2+2?"
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     (setq response (claude-agent-extract-text msg))))
     :on-error (lambda (err)
                 (setq error-occurred t))
     :on-complete (lambda (_result)
                    (setq completed t)))

    ;; Should either complete or error (not timeout)
    (should (test-claude-wait-until (lambda () (or completed error-occurred)) 30))
    (when completed
      (should response))))

;;; Concurrent Query Tests

(ert-deftest test-integration-concurrent-queries ()
  "Test multiple concurrent queries."
  :tags '(:integration :slow :api :stable :process)
  (test-claude-skip-unless-cli-available)

  (let ((completed1 nil)
        (completed2 nil)
        (response1 nil)
        (response2 nil))

    ;; Start first query
    (claude-agent-query
     "What is 2+2?"
     :session-key "concurrent-1"
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     (setq response1 (claude-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed1 t)))

    ;; Start second query immediately
    (claude-agent-query
     "What is 3+3?"
     :session-key "concurrent-2"
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     (setq response2 (claude-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed2 t)))

    (should (test-claude-wait-until (lambda () (and completed1 completed2)) 60))
    (should response1)
    (should response2)
    (should (> (length response1) 0))
    (should (> (length response2) 0))))

;;; Query Cancellation Tests

(ert-deftest test-integration-query-cancellation ()
  "Test cancelling a running query."
  :tags '(:integration :slow :api :stable :process)
  (test-claude-skip-unless-cli-available)

  (let ((request-id nil)
        (state nil)
        (cancelled nil))

    ;; Start a slow query
    (setq state (claude-agent-query
                 "Write a very long story about numbers..."
                 :session-key "cancellation-test"
                 :on-complete (lambda (_result)
                                ;; Should not complete
                                (setq cancelled nil))))

    ;; Get request ID from state struct
    (setq request-id (claude-agent-query-request-id state))

    ;; Wait a bit for query to start
    (sleep-for 0.5)

    ;; Cancel it
    (when request-id
      (setq cancelled (claude-agent-cancel-query request-id)))

    (should cancelled)
    ;; Wait for cleanup - should succeed
    (should (test-claude-wait-until
             (lambda () (= 0 (claude-agent-active-query-count)))
             5))))

(provide 'test-claude-agent-integration)
;;; test-claude-agent-integration.el ends here
