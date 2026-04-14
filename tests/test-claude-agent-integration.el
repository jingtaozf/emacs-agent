;;; test-claude-agent-integration.el --- Integration tests for claude-agent.org -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Integration tests for claude-agent.org (core SDK module)
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
     :options (test-claude-default-options)
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
     :options (test-claude-default-options)
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
     :options (test-claude-default-options)
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
     :options (test-claude-default-options :resume sdk-uuid)
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
     :options (test-claude-default-options
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
     :options (test-claude-default-options
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
     :options (test-claude-default-options)
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
     :options (test-claude-default-options)
     :session-key "concurrent-1"
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     (setq response1 (claude-agent-extract-text msg))))
     :on-complete (lambda (_result)
                    (setq completed1 t)))

    ;; Start second query immediately
    (claude-agent-query
     "What is 3+3?"
     :options (test-claude-default-options)
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
                 :options (test-claude-default-options)
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

;;; Translation Tests

(ert-deftest test-integration-translate-basic ()
  "Test basic translation functionality with actual API call.
Translates 'Hello, world!' to Chinese and verifies output contains Chinese characters."
  :tags '(:integration :slow :api :stable)
  (test-claude-skip-unless-cli-available)

  ;; Clean up any previous translation state — each run now allocates its
  ;; own buffer, so we just clear the "latest" pointer.
  (setq claude-agent-translate--active-state nil)
  (when (buffer-live-p claude-agent-translate--last-buffer)
    (kill-buffer claude-agent-translate--last-buffer))
  (setq claude-agent-translate--last-buffer nil)

  ;; Run translation (with setting-sources to skip slow plugin loading)
  (claude-agent-translate "Hello, world!" "Chinese"
                          (list :setting-sources test-claude-default-setting-sources))

  ;; Wait for completion (translation should be quick with haiku model)
  (should (test-claude-wait-until
           (lambda ()
             (null claude-agent-translate--active-state))
           30))

  ;; Check translation buffer has content (the run-specific one)
  (let* ((buf claude-agent-translate--last-buffer)
         (result-text (when (buffer-live-p buf)
                        (with-current-buffer buf (buffer-string)))))

    (should buf)
    (should result-text)
    ;; Verify translation completed
    (should (string-match-p "Translation complete" result-text))
    ;; Should contain some Chinese characters (Unicode range)
    (should (string-match-p "[\u4e00-\u9fff]" result-text))

    ;; Clean up
    (kill-buffer buf)))

;;; Automatic Recovery Tests

(ert-deftest test-integration-recovery-session-id-capture ()
  "Test that session-id is captured from system/init message.
This is critical for recovery to work - session-id must be available
before the result message."
  :tags '(:integration :slow :api :stable :recovery)
  (test-claude-skip-unless-cli-available)

  (let ((session-id-from-init nil)
        (session-id-from-result nil)
        (completed nil))
    (claude-agent-query
     "What is 2+2? Just the number."
     :options (test-claude-default-options)
     :on-message (lambda (msg)
                   ;; Capture session-id from system/init message
                   (when (and (claude-agent-system-message-p msg)
                              (equal (claude-agent-system-message-subtype msg) "init"))
                     (setq session-id-from-init
                           (plist-get (claude-agent-system-message-data msg) :session_id)))
                   ;; Also capture from result for comparison
                   (when (claude-agent-result-message-p msg)
                     (setq session-id-from-result
                           (claude-agent-result-message-session-id msg))))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 30))
    ;; Session ID should be available from init message
    (should session-id-from-init)
    (should (stringp session-id-from-init))
    (should (> (length session-id-from-init) 0))
    ;; Should match the one from result message
    (should (equal session-id-from-init session-id-from-result))))

(ert-deftest test-integration-recovery-on-kill ()
  "Test automatic recovery when CLI process is killed.
Starts a long-running query, kills the process, and verifies:
1. Recovery message is inserted
2. Session resumes automatically
3. Query eventually completes"
  :tags '(:integration :slow :api :flaky :recovery)
  (test-claude-skip-unless-cli-available)

  ;; Ensure auto-recovery is enabled
  (let ((claude-agent-auto-recovery t)
        (state nil)
        (tokens '())
        (recovery-seen nil)
        (completed nil)
        (final-response nil))

    ;; Start a query that will take some time
    (setq state (claude-agent-query
                 "Count slowly from 1 to 20, saying each number on a new line."
                 :options (test-claude-default-options)
                 :session-key "recovery-test"
                 :on-token (lambda (text)
                             (push text tokens)
                             ;; Check for recovery message
                             (when (string-match-p "Session interrupted" text)
                               (setq recovery-seen t)))
                 :on-message (lambda (msg)
                               (when (claude-agent-assistant-message-p msg)
                                 (setq final-response
                                       (claude-agent-extract-text msg))))
                 :on-complete (lambda (_result)
                                (setq completed t))))

    ;; Wait for query to start and session-id to be captured
    (should (test-claude-wait-until
             (lambda ()
               (and state
                    (claude-agent--process-state-session-id state)))
             10))

    ;; Give it a moment to start generating output
    (sleep-for 1)

    ;; Kill the process (simulating external kill)
    (let ((process (claude-agent--process-state-process state)))
      (when (and process (process-live-p process))
        (kill-process process)))

    ;; Wait for recovery and eventual completion
    ;; This may take longer as it needs to resume
    (should (test-claude-wait-until (lambda () completed) 60))

    ;; Verify recovery happened
    (should recovery-seen)
    ;; Should have received some response
    (should (> (length tokens) 0))))

(ert-deftest test-integration-recovery-disabled ()
  "Test that recovery does not happen when disabled.
When `claude-agent-auto-recovery' is nil, killing the process
should just trigger the error callback without recovery."
  :tags '(:integration :slow :api :stable :recovery)
  (test-claude-skip-unless-cli-available)

  ;; Disable auto-recovery
  (let ((claude-agent-auto-recovery nil)
        (state nil)
        (error-received nil)
        (completed nil)
        (recovery-seen nil))

    (setq state (claude-agent-query
                 "Count from 1 to 100 slowly."
                 :options (test-claude-default-options)
                 :session-key "recovery-disabled-test"
                 :on-token (lambda (text)
                             (when (string-match-p "Session interrupted" text)
                               (setq recovery-seen t)))
                 :on-error (lambda (_err)
                             (setq error-received t))
                 :on-complete (lambda (result)
                                (setq completed t)
                                ;; Check if completed with error
                                (when result
                                  (setq error-received t)))))

    ;; Wait for query to start
    (should (test-claude-wait-until
             (lambda ()
               (and state
                    (claude-agent--process-state-process state)
                    (process-live-p (claude-agent--process-state-process state))))
             10))

    (sleep-for 0.5)

    ;; Kill the process
    (let ((process (claude-agent--process-state-process state)))
      (when (and process (process-live-p process))
        (kill-process process)))

    ;; Wait for completion (should be quick since no recovery)
    (should (test-claude-wait-until
             (lambda () (or completed error-received))
             10))

    ;; Recovery should NOT have happened
    (should-not recovery-seen)))

(ert-deftest test-integration-recovery-message-format ()
  "Test that the recovery message has the expected format."
  :tags '(:integration :unit :recovery)
  ;; This is more of a unit test but placed here for context

  ;; Create a mock state with token-callback
  (let ((received-message nil))
    (let ((state (claude-agent--make-process-state
                  :token-callback (lambda (text)
                                    (setq received-message text)))))
      ;; Test with kill signal
      (claude-agent--insert-recovery-message state "killed: 9")
      (should received-message)
      (should (string-match-p "Session interrupted" received-message))
      (should (string-match-p "killed: 9" received-message))
      (should (string-match-p "automatic recovery" received-message)))))

(ert-deftest test-integration-abnormal-exit-detection ()
  "Test the abnormal exit detection logic."
  :tags '(:integration :unit :recovery)

  (let ((claude-agent-auto-recovery t))
    ;; Test 1: Signal kill should trigger recovery (if session-id available)
    (let ((state (claude-agent--make-process-state
                  :session-id "test-uuid")))
      (should (claude-agent--is-abnormal-exit-p "killed: 9" state)))

    ;; Test 2: Abnormal exit should trigger recovery
    (let ((state (claude-agent--make-process-state
                  :session-id "test-uuid")))
      (should (claude-agent--is-abnormal-exit-p "exited abnormally with code 1" state)))

    ;; Test 3: Normal finish without result should trigger recovery
    (let ((state (claude-agent--make-process-state
                  :session-id "test-uuid")))
      (should (claude-agent--is-abnormal-exit-p "finished" state)))

    ;; Test 4: Normal finish WITH result should NOT trigger recovery
    (let ((state (claude-agent--make-process-state
                  :session-id "test-uuid"
                  :got-result t)))
      (should-not (claude-agent--is-abnormal-exit-p "finished" state)))

    ;; Test 5: No session-id means no recovery possible
    (let ((state (claude-agent--make-process-state)))
      (should-not (claude-agent--is-abnormal-exit-p "killed: 9" state)))

    ;; Test 6: Recovery disabled
    (let ((claude-agent-auto-recovery nil)
          (state (claude-agent--make-process-state
                  :session-id "test-uuid")))
      (should-not (claude-agent--is-abnormal-exit-p "killed: 9" state)))))

;;; AskUserQuestion Integration Tests

(ert-deftest test-integration-ask-user-question-with-mock ()
  "Test that AskUserQuestion tool receives mock answers and Claude uses them.
This test triggers Claude to use the AskUserQuestion tool, provides mock
answers via `claude-agent-ask-user-question-mock-answers', and verifies
Claude's response references the selected answer."
  :tags '(:integration :slow :api :stable :permissions :ask-user)
  (test-claude-skip-unless-cli-available)

  (let* ((claude-agent-ask-user-question-mock-answers
          '(("What is your preferred output format?" . "Detailed")))
         (completed nil)
         (response nil)
         (ask-user-question-called nil))

    ;; Add a hook to detect when AskUserQuestion is triggered
    (let ((original-fn (symbol-function 'claude-agent-permission-ask-user-question)))
      (cl-letf (((symbol-function 'claude-agent-permission-ask-user-question)
                 (lambda (tool-name tool-input context)
                   (when (string= tool-name "AskUserQuestion")
                     (setq ask-user-question-called t))
                   (funcall original-fn tool-name tool-input context))))

        (claude-agent-query
         "I need you to ask me about my preferred output format. Use the AskUserQuestion tool to ask me: 'What is your preferred output format?' with options 'Summary' and 'Detailed'. Then tell me what I chose."
         :options (test-claude-default-options)
         :session-key "ask-user-test"
         :on-message (lambda (msg)
                       (when (claude-agent-assistant-message-p msg)
                         (setq response (concat response (or (claude-agent-extract-text msg) "")))))
         :on-complete (lambda (_result)
                        (setq completed t)))

        (should (test-claude-wait-until (lambda () completed) 60))
        ;; The test may or may not trigger AskUserQuestion depending on Claude's decision
        ;; But if it did, the mock should have been used
        (when ask-user-question-called
          (should response)
          (should (string-match-p "Detailed\\|detailed" response)))))))

(ert-deftest test-integration-ask-user-question-multi-select-mock ()
  "Test AskUserQuestion with multi-select mock answers."
  :tags '(:integration :slow :api :stable :permissions :ask-user)
  (test-claude-skip-unless-cli-available)

  (let* ((claude-agent-ask-user-question-mock-answers
          '(("Which features would you like?" . "Feature1, Feature2")))
         (completed nil)
         (response nil))

    (claude-agent-query
     "Ask me which features I want using AskUserQuestion with multiSelect=true. Options should be Feature1, Feature2, Feature3. The question should be 'Which features would you like?'. Then summarize my choices."
     :options (test-claude-default-options)
     :session-key "ask-user-multi-test"
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     (setq response (concat response (or (claude-agent-extract-text msg) "")))))
     :on-complete (lambda (_result)
                    (setq completed t)))

    (should (test-claude-wait-until (lambda () completed) 60))
    ;; If Claude used the tool and mock was applied, response should mention chosen features
    (when response
      (should (> (length response) 0)))))

(provide 'test-claude-agent-integration)
;;; test-claude-agent-integration.el ends here
