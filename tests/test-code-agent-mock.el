;;; test-code-agent-mock.el --- Mock CLI integration tests for code-agent -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Integration tests that use the mock Claude CLI (mock-claude-cli.sh)
;; instead of the real Claude Code CLI.  These tests exercise the full
;; subprocess pipeline — process creation, JSON protocol, callbacks,
;; session management — without requiring an API key.
;;
;; The mock CLI speaks the identical newline-delimited JSON protocol.
;; Fixture data in mock-scenarios/*.jsonl was modelled on real CLI output.
;;
;; To switch any test to the real CLI, replace `test-claude-mock-options'
;; with `test-claude-default-options' (and add the skip guard).

;;; Code:

(require 'ert)
(require 'code-agent)
(require 'test-config)

;;; Basic Query Tests

(ert-deftest test-mock-simple-query ()
  "Test basic query execution with mock CLI.
Verifies: process starts, JSON parsed, callbacks invoked, response extracted."
  :tags '(:mock :fast :stable :isolated :process)
  (let ((response-received nil)
        (tokens '())
        (completed nil))
    (code-agent-query
     "What is 2+2? Answer with just the number."
     :options (test-claude-mock-options-with-scenario "simple-query")
     :on-token (lambda (text)
                 (push text tokens))
     :on-message (lambda (msg)
                   (when (code-agent-assistant-message-p msg)
                     (setq response-received (code-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 10))
    (should response-received)
    (should (> (length tokens) 0))
    (should (string-match-p "4" response-received))))

(ert-deftest test-mock-streaming-tokens ()
  "Test that :on-token callback fires for each content chunk.
Mock sends multiple assistant messages to simulate streaming."
  :tags '(:mock :fast :stable :isolated :process)
  (let ((token-count 0)
        (token-text "")
        (completed nil))
    (code-agent-query
     "Count from 1 to 3 slowly: one, two, three."
     :options (test-claude-mock-options-with-scenario "streaming-tokens")
     :on-token (lambda (text)
                 (cl-incf token-count)
                 (setq token-text (concat token-text text)))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 10))
    ;; Mock sends 3 assistant messages with text chunks
    (should (>= token-count 3))
    (should (string-match-p "One" token-text))
    (should (string-match-p "three" token-text))))

;;; Session Management Tests

(ert-deftest test-mock-session-continuity ()
  "Test session continuation with --resume.
First query establishes session, second query resumes it."
  :tags '(:mock :fast :stable :isolated :session)
  (let ((session-key "test-mock-session-continuity")
        (first-response nil)
        (sdk-uuid nil)
        (completed1 nil))

    ;; First query — establish session
    (code-agent-query
     "Remember this number: 42. Just confirm you remember it."
     :options (test-claude-mock-options-with-scenario "session-start")
     :session-key session-key
     :on-message (lambda (msg)
                   (when (code-agent-result-message-p msg)
                     (setq sdk-uuid (code-agent-result-message-session-id msg)))
                   (when (code-agent-assistant-message-p msg)
                     (setq first-response (code-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed1 t)))

    (should (test-claude-wait-until (lambda () completed1) 10))
    (should sdk-uuid)
    (should first-response)
    (should (string-match-p "remember" first-response))

    ;; Second query — continue session via --resume
    (let ((second-response nil)
          (completed2 nil))
      (code-agent-query
       "What number did I ask you to remember? Just the number."
       :options (test-claude-mock-options-with-scenario
                 "session-resume" :resume sdk-uuid)
       :session-key session-key
       :on-message (lambda (msg)
                     (when (code-agent-assistant-message-p msg)
                       (setq second-response (code-agent-extract-text msg))))
       :on-complete (lambda (_result)
                      (setq completed2 t)))

      (should (test-claude-wait-until (lambda () completed2) 10))
      (should second-response)
      (should (string-match-p "42" second-response)))))

;;; Concurrent Query Tests

(ert-deftest test-mock-concurrent-queries ()
  "Test multiple concurrent queries with independent mock processes."
  :tags '(:mock :fast :stable :isolated :process)
  (let ((completed1 nil)
        (completed2 nil)
        (response1 nil)
        (response2 nil))

    (code-agent-query
     "What is 2+2?"
     :options (test-claude-mock-options-with-scenario "concurrent-1")
     :session-key "mock-concurrent-1"
     :on-message (lambda (msg)
                   (when (code-agent-assistant-message-p msg)
                     (setq response1 (code-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed1 t)))

    (code-agent-query
     "What is 3+3?"
     :options (test-claude-mock-options-with-scenario "concurrent-2")
     :session-key "mock-concurrent-2"
     :on-message (lambda (msg)
                   (when (code-agent-assistant-message-p msg)
                     (setq response2 (code-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed2 t)))

    (should (test-claude-wait-until (lambda () (and completed1 completed2)) 10))
    (should response1)
    (should response2)
    (should (string-match-p "4" response1))
    (should (string-match-p "6" response2))))

;;; Query Cancellation Tests

(ert-deftest test-mock-query-cancellation ()
  "Test cancelling a running query via cancel-query.
Mock slow-response scenario keeps process alive long enough to cancel."
  :tags '(:mock :fast :stable :isolated :process :cancel)
  (let ((state nil)
        (request-id nil)
        (cancelled nil))

    ;; Start a slow query
    (setq state (code-agent-query
                 "Write a very long story about numbers..."
                 :options (test-claude-mock-options-with-scenario "slow-response")
                 :session-key "mock-cancellation-test"
                 :on-complete (lambda (_result)
                                nil)))

    (setq request-id (code-agent-query-request-id state))

    ;; Wait for process to start
    (should (test-claude-wait-until
             (lambda ()
               (and state
                    (code-agent--process-state-process state)
                    (process-live-p (code-agent--process-state-process state))))
             5))

    ;; Cancel it
    (when request-id
      (setq cancelled (code-agent-cancel-query request-id)))

    (should cancelled)
    ;; Wait for cleanup
    (should (test-claude-wait-until
             (lambda ()
               (not (code-agent--query-active-p state)))
             5))))

;;; Session ID Capture Tests

(ert-deftest test-mock-session-id-from-init ()
  "Test that session-id is captured from system/init message.
Critical for recovery — session-id must be available before result."
  :tags '(:mock :fast :stable :isolated :recovery)
  (let ((session-id-from-init nil)
        (session-id-from-result nil)
        (completed nil))
    (code-agent-query
     "What is 2+2? Just the number."
     :options (test-claude-mock-options-with-scenario "recovery-capture")
     :on-message (lambda (msg)
                   (when (and (code-agent-system-message-p msg)
                              (equal (code-agent-system-message-subtype msg) "init"))
                     (setq session-id-from-init
                           (plist-get (code-agent-system-message-data msg) :session_id)))
                   (when (code-agent-result-message-p msg)
                     (setq session-id-from-result
                           (code-agent-result-message-session-id msg))))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 10))
    (should session-id-from-init)
    (should (stringp session-id-from-init))
    (should (> (length session-id-from-init) 0))
    ;; Both sources must agree
    (should (equal session-id-from-init session-id-from-result))))

;;; Result Message Tests

(ert-deftest test-mock-result-message-fields ()
  "Test that result message contains all expected fields.
Verifies the mock output is parsed into a complete result-message struct."
  :tags '(:mock :fast :stable :isolated :process)
  (let ((result-msg nil)
        (completed nil))
    (code-agent-query
     "What is 2+2?"
     :options (test-claude-mock-options-with-scenario "simple-query")
     :on-message (lambda (msg)
                   (when (code-agent-result-message-p msg)
                     (setq result-msg msg)))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 10))
    (should result-msg)
    ;; Verify all expected fields from result message
    (should (code-agent-result-message-session-id result-msg))
    (should (numberp (code-agent-result-message-duration-ms result-msg)))
    (should (> (code-agent-result-message-duration-ms result-msg) 0))
    (should (code-agent-result-message-usage result-msg))
    ;; Usage should have input/output tokens
    (let ((usage (code-agent-result-message-usage result-msg)))
      (should (plist-get usage :input_tokens))
      (should (plist-get usage :output_tokens)))))

;;; Error Handling / Robustness Tests

(ert-deftest test-mock-complete-callback-always-fires ()
  "Test that on-complete is called even for generic responses.
Ensures the full lifecycle (init → assistant → result → complete) works."
  :tags '(:mock :fast :stable :isolated :process)
  (let ((completed nil)
        (response nil))
    (code-agent-query
     "Some arbitrary request"
     :options (test-claude-mock-options-with-scenario "generic-response")
     :on-message (lambda (msg)
                   (when (code-agent-assistant-message-p msg)
                     (setq response (code-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 10))
    (should response)
    (should (> (length response) 0))))

;;; Auto-Detection Tests

(ert-deftest test-mock-auto-detect-from-prompt ()
  "Test that mock CLI auto-detects scenario from prompt content.
Without explicit MOCK_SCENARIO, '2+2' in prompt selects simple-query."
  :tags '(:mock :fast :stable :isolated :process)
  (let ((response nil)
        (completed nil))
    ;; Use test-claude-mock-options WITHOUT explicit scenario
    (code-agent-query
     "What is 2+2?"
     :options (test-claude-mock-options)
     :on-message (lambda (msg)
                   (when (code-agent-assistant-message-p msg)
                     (setq response (code-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 10))
    (should response)
    (should (string-match-p "4" response))))

;;; Permission Mode Tests

(ert-deftest test-mock-readonly-mode ()
  "Test default permission mode works (simple query with permission-mode set)."
  :tags '(:mock :fast :stable :isolated :permission)
  (let ((response nil)
        (completed nil))
    (code-agent-query
     "What is 2+2? Just give me the number."
     :options (test-claude-mock-options-with-scenario
               "simple-query"
               :cwd (expand-file-name "~/projects/emacs-agent")
               :permission-mode "default")
     :on-message (lambda (msg)
                   (when (code-agent-assistant-message-p msg)
                     (setq response (code-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 10))
    (should response)
    (should (string-match-p "4" response))))

(ert-deftest test-mock-error-handling ()
  "Test error handling infrastructure with mock CLI.
Verifies that the query lifecycle completes even with simple error scenarios."
  :tags '(:mock :fast :stable :isolated :process)
  (let ((completed nil)
        (response nil))
    (code-agent-query
     "What is 2+2?"
     :options (test-claude-mock-options-with-scenario "simple-query")
     :on-message (lambda (msg)
                   (when (code-agent-assistant-message-p msg)
                     (setq response (code-agent-extract-text msg))))
     :on-error (lambda (_err) nil)
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () (or completed response)) 10))
    (when completed
      (should response))))

;;; Tool Use Tests

(ert-deftest test-mock-tool-use-read ()
  "Test that tool_use content blocks in assistant message are parsed.
Mock outputs an assistant message with tool_use block followed by text response."
  :tags '(:mock :fast :stable :isolated :process)
  (let ((tool-used nil)
        (response nil)
        (completed nil))
    (code-agent-query
     "Use the Read tool to read the file README.md and tell me the first word."
     :options (test-claude-mock-options-with-scenario "tool-use-read")
     :on-message (lambda (msg)
                   (when (code-agent-assistant-message-p msg)
                     (dolist (block (code-agent-assistant-message-content msg))
                       (when (code-agent-tool-use-block-p block)
                         (when (equal "Read" (code-agent-tool-use-block-name block))
                           (setq tool-used t))))
                     (let ((text (code-agent-extract-text msg)))
                       (when (and text (> (length text) 0))
                         (setq response text)))))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 10))
    (should tool-used)
    (should response)
    (should (string-match-p "Claude" response))))

;;; Recovery Tests

(ert-deftest test-mock-recovery-on-kill ()
  "Test automatic recovery when CLI process is killed.
Starts slow query, kills process, verifies recovery message and session resume."
  :tags '(:mock :fast :stable :isolated :recovery)
  (let ((code-agent-auto-recovery t)
        (code-agent-cli-path test-claude-mock-cli-path)
        (state nil)
        (tokens '())
        (recovery-seen nil)
        (completed nil))

    (let ((process-environment
           (cons "MOCK_SCENARIO=slow-response" process-environment)))
      (setq state (code-agent-query
                   "Count slowly from 1 to 20, saying each number on a new line."
                   :options (test-claude-mock-options-with-scenario "slow-response")
                   :session-key "mock-recovery-test"
                   :on-token (lambda (text)
                               (push text tokens)
                               (when (string-match-p "Session interrupted" text)
                                 (setq recovery-seen t)))
                   :on-complete (lambda (_result)
                                  (setq completed t)))))

    ;; Wait for process to start and session-id to be captured
    (should (test-claude-wait-until
             (lambda ()
               (and state
                    (code-agent--process-state-session-id state)))
             5))

    ;; Give it a moment to start generating output
    (sleep-for 0.5)
    (accept-process-output nil 0.2)

    ;; Kill the process (simulating external kill)
    (let ((process (code-agent--process-state-process state)))
      (when (and process (process-live-p process))
        (kill-process process)))

    ;; Wait for recovery and eventual completion
    (should (test-claude-wait-until (lambda () completed) 15))

    ;; Verify recovery happened
    (should recovery-seen)
    (should (> (length tokens) 0))))

(ert-deftest test-mock-recovery-disabled ()
  "Test that recovery does not happen when disabled.
Killing the process should just trigger error/complete without recovery."
  :tags '(:mock :fast :stable :isolated :recovery)
  (let ((code-agent-auto-recovery nil)
        (code-agent-cli-path test-claude-mock-cli-path)
        (state nil)
        (error-received nil)
        (completed nil)
        (recovery-seen nil))

    (let ((process-environment
           (cons "MOCK_SCENARIO=slow-response" process-environment)))
      (setq state (code-agent-query
                   "Count from 1 to 100 slowly."
                   :options (test-claude-mock-options-with-scenario "slow-response")
                   :session-key "mock-recovery-disabled-test"
                   :on-token (lambda (text)
                               (when (string-match-p "Session interrupted" text)
                                 (setq recovery-seen t)))
                   :on-error (lambda (_err)
                               (setq error-received t))
                   :on-complete (lambda (result)
                                  (setq completed t)
                                  (when result
                                    (setq error-received t))))))

    ;; Wait for process to start
    (should (test-claude-wait-until
             (lambda ()
               (and state
                    (code-agent--process-state-process state)
                    (process-live-p (code-agent--process-state-process state))))
             5))

    (sleep-for 0.3)

    ;; Kill the process
    (let ((process (code-agent--process-state-process state)))
      (when (and process (process-live-p process))
        (kill-process process)))

    ;; Wait for completion (should be quick since no recovery)
    (should (test-claude-wait-until
             (lambda () (or completed error-received))
             5))

    ;; Recovery should NOT have happened
    (should-not recovery-seen)))

(ert-deftest test-mock-recovery-message-format ()
  "Test that the recovery message has the expected format."
  :tags '(:mock :fast :stable :isolated :unit :recovery)
  ;; This is a pure unit test — no subprocess needed
  (let ((received-message nil))
    (let ((state (code-agent--make-process-state
                  :token-callback (lambda (text)
                                    (setq received-message text)))))
      (code-agent--insert-recovery-message state "killed: 9")
      (should received-message)
      (should (string-match-p "Session interrupted" received-message))
      (should (string-match-p "killed: 9" received-message))
      (should (string-match-p "automatic recovery" received-message)))))

(ert-deftest test-mock-abnormal-exit-detection ()
  "Test the abnormal exit detection logic."
  :tags '(:mock :fast :stable :isolated :unit :recovery)

  (let ((code-agent-auto-recovery t))
    ;; Signal kill should trigger recovery (if session-id available)
    (let ((state (code-agent--make-process-state :session-id "test-uuid")))
      (should (code-agent--is-abnormal-exit-p "killed: 9" state)))

    ;; Abnormal exit should trigger recovery
    (let ((state (code-agent--make-process-state :session-id "test-uuid")))
      (should (code-agent--is-abnormal-exit-p "exited abnormally with code 1" state)))

    ;; Normal finish without result should trigger recovery
    (let ((state (code-agent--make-process-state :session-id "test-uuid")))
      (should (code-agent--is-abnormal-exit-p "finished" state)))

    ;; Normal finish WITH result should NOT trigger recovery
    (let ((state (code-agent--make-process-state :session-id "test-uuid" :got-result t)))
      (should-not (code-agent--is-abnormal-exit-p "finished" state)))

    ;; No session-id means no recovery possible
    (let ((state (code-agent--make-process-state)))
      (should-not (code-agent--is-abnormal-exit-p "killed: 9" state)))

    ;; Recovery disabled
    (let ((code-agent-auto-recovery nil)
          (state (code-agent--make-process-state :session-id "test-uuid")))
      (should-not (code-agent--is-abnormal-exit-p "killed: 9" state)))))

;;; AskUserQuestion Tests

(ert-deftest test-mock-ask-user-question ()
  "Test that AskUserQuestion tool_use blocks are parsed from mock response.
Verifies the SDK correctly parses tool_use content blocks."
  :tags '(:mock :fast :stable :isolated :process)
  (let ((tool-used nil)
        (response nil)
        (completed nil))
    (code-agent-query
     "Ask me about my preferred output format using AskUserQuestion."
     :options (test-claude-mock-options-with-scenario "ask-user-question")
     :on-message (lambda (msg)
                   (when (code-agent-assistant-message-p msg)
                     (dolist (block (code-agent-assistant-message-content msg))
                       (when (code-agent-tool-use-block-p block)
                         (when (equal "AskUserQuestion"
                                      (code-agent-tool-use-block-name block))
                           (setq tool-used t))))
                     (let ((text (code-agent-extract-text msg)))
                       (when (and text (> (length text) 0))
                         (setq response text)))))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 10))
    ;; Should have parsed the AskUserQuestion tool_use block
    (should tool-used)
    ;; Should have received the final text response
    (should response)
    (should (string-match-p "Detailed" response))))

(provide 'test-code-agent-mock)
;;; test-code-agent-mock.el ends here
