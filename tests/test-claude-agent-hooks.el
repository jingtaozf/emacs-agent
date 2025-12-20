;;; test-claude-agent-hooks.el --- Tests for Claude Agent Hook System -*- lexical-binding: t; -*-

;; Test the Emacs-native hook integration with Claude's control protocol

(require 'ert)
(require 'cl-lib)

;; Note: claude-agent.org is loaded via Makefile before this file is loaded

;;; Helper Functions

(defun test-claude-skip-unless-cli-available ()
  "Skip test if Claude CLI is not available."
  (unless (executable-find "claude")
    (ert-skip "Claude CLI not found - skipping integration test")))

;;; Unit Tests - Hook Infrastructure

(ert-deftest test-hook-variables-exist ()
  "Test that hook variables are defined."
  :tags '(:unit :fast :stable :isolated :hooks)
  (should (boundp 'claude-agent-pre-tool-use-hook))
  (should (boundp 'claude-agent-post-tool-use-hook))
  (should (boundp 'claude-agent-user-prompt-submit-hook))
  (should (boundp 'claude-agent-session-start-hook)))

(ert-deftest test-hook-event-name-conversion ()
  "Test conversion of event names to hook symbols."
  :tags '(:unit :fast :stable :isolated :hooks)
  (should (eq (claude-agent--hook-event-name-to-symbol "PreToolUse")
              'claude-agent-pre-tool-use-hook))
  (should (eq (claude-agent--hook-event-name-to-symbol "PostToolUse")
              'claude-agent-post-tool-use-hook))
  (should (eq (claude-agent--hook-event-name-to-symbol "UserPromptSubmit")
              'claude-agent-user-prompt-submit-hook))
  (should (eq (claude-agent--hook-event-name-to-symbol "SessionStart")
              'claude-agent-session-start-hook)))

(ert-deftest test-hook-invocation-no-hooks ()
  "Test hook invocation when no hooks are registered."
  :tags '(:unit :fast :stable :isolated :hooks)
  (let ((claude-agent-pre-tool-use-hook nil))
    (let ((result (claude-agent--run-hooks-for-event
                   'claude-agent-pre-tool-use-hook
                   (list :tool_name "Bash" :tool_input (list :command "echo test"))
                   nil
                   (list :signal nil))))
      (should (null result)))))

(ert-deftest test-hook-invocation-allow ()
  "Test hook that allows tool execution."
  :tags '(:unit :fast :stable :isolated :hooks)
  (let ((claude-agent-pre-tool-use-hook nil))
    (add-hook 'claude-agent-pre-tool-use-hook
              (lambda (input-data tool-use-id context)
                nil))  ; Return nil = allow
    (let ((result (claude-agent--run-hooks-for-event
                   'claude-agent-pre-tool-use-hook
                   (list :tool_name "Bash" :tool_input (list :command "echo test"))
                   nil
                   (list :signal nil))))
      (should (null result)))
    (setq claude-agent-pre-tool-use-hook nil)))

(ert-deftest test-hook-invocation-deny ()
  "Test hook that denies tool execution."
  :tags '(:unit :fast :stable :isolated :hooks)
  (let ((claude-agent-pre-tool-use-hook nil))
    (add-hook 'claude-agent-pre-tool-use-hook
              (lambda (input-data tool-use-id context)
                (list :reason "Test deny"
                      :systemMessage "Denied by test"
                      :hookSpecificOutput
                      (list :hookEventName "PreToolUse"
                            :permissionDecision "deny"
                            :permissionDecisionReason "Test policy"))))
    (let ((result (claude-agent--run-hooks-for-event
                   'claude-agent-pre-tool-use-hook
                   (list :tool_name "Bash" :tool_input (list :command "echo test"))
                   nil
                   (list :signal nil))))
      (should (not (null result)))
      (should (equal (plist-get result :reason) "Test deny"))
      (should (equal (plist-get result :systemMessage) "Denied by test"))
      (let ((hook-output (plist-get result :hookSpecificOutput)))
        (should (equal (plist-get hook-output :permissionDecision) "deny"))))
    (setq claude-agent-pre-tool-use-hook nil)))

(ert-deftest test-hook-invocation-multiple-hooks ()
  "Test multiple hooks with first deny winning."
  :tags '(:unit :fast :stable :isolated :hooks)
  (let ((claude-agent-pre-tool-use-hook nil)
        (hook1-called nil)
        (hook2-called nil))
    ;; Hook 1: Allows
    (add-hook 'claude-agent-pre-tool-use-hook
              (lambda (input-data tool-use-id context)
                (setq hook1-called t)
                nil))
    ;; Hook 2: Denies
    (add-hook 'claude-agent-pre-tool-use-hook
              (lambda (input-data tool-use-id context)
                (setq hook2-called t)
                (list :reason "Denied by hook 2"
                      :hookSpecificOutput
                      (list :permissionDecision "deny"))))
    (let ((result (claude-agent--run-hooks-for-event
                   'claude-agent-pre-tool-use-hook
                   (list :tool_name "Bash" :tool_input (list :command "test"))
                   nil
                   (list :signal nil))))
      (should hook1-called)
      (should hook2-called)
      (should (not (null result)))
      (should (equal (plist-get result :reason) "Denied by hook 2")))
    (setq claude-agent-pre-tool-use-hook nil)))

(ert-deftest test-hook-error-handling ()
  "Test that hook errors don't break processing."
  :tags '(:unit :fast :stable :isolated :hooks)
  (let ((claude-agent-pre-tool-use-hook nil)
        (hook2-called nil))
    ;; Hook 1: Throws error
    (add-hook 'claude-agent-pre-tool-use-hook
              (lambda (input-data tool-use-id context)
                (error "Test error in hook")))
    ;; Hook 2: Should still run
    (add-hook 'claude-agent-pre-tool-use-hook
              (lambda (input-data tool-use-id context)
                (setq hook2-called t)
                nil))
    (let ((result (claude-agent--run-hooks-for-event
                   'claude-agent-pre-tool-use-hook
                   (list :tool_name "Bash" :tool_input (list :command "test"))
                   nil
                   (list :signal nil))))
      (should hook2-called))
    (setq claude-agent-pre-tool-use-hook nil)))

;;; Integration Tests - Real Claude CLI

(ert-deftest test-integration-hook-blocks-bash-command ()
  "Test that PreToolUse hook can block bash commands."
  :tags '(:integration :slow :api :stable :hooks :process)
  (test-claude-skip-unless-cli-available)

  (let ((hook-called nil)
        (blocked nil)
        (claude-agent-pre-tool-use-hook nil))

    ;; Register hook to block rm commands
    (add-hook 'claude-agent-pre-tool-use-hook
              (lambda (input-data tool-use-id context)
                (setq hook-called t)
                (let ((tool-name (plist-get input-data :tool_name))
                      (tool-input (plist-get input-data :tool_input)))
                  (when (and (equal tool-name "Bash")
                             (string-match-p "rm" (plist-get tool-input :command)))
                    (setq blocked t)
                    (list :reason "rm commands are blocked for safety"
                          :systemMessage "🚫 rm commands are not allowed"
                          :hookSpecificOutput
                          (list :hookEventName "PreToolUse"
                                :permissionDecision "deny"
                                :permissionDecisionReason "Security policy blocks rm"))))))

    (let ((response-received nil)
          (error-received nil))
      (claude-agent-query
       "Run this bash command: rm test.txt"
       :options (claude-agent-options :allowed-tools '("Bash"))
       :on-message (lambda (msg) (setq response-received t))
       :on-error (lambda (err) (setq error-received t))
       :on-complete (lambda () (message "Query complete")))

      ;; Wait for completion
      (let ((timeout (+ (float-time) 30)))
        (while (and (not response-received)
                    (not error-received)
                    (< (float-time) timeout))
          (sleep-for 0.1)
          (accept-process-output nil 0.1)))

      (should (or response-received error-received))
      (should hook-called)
      (should blocked))

    ;; Cleanup
    (setq claude-agent-pre-tool-use-hook nil)))

(ert-deftest test-integration-hook-allows-safe-command ()
  "Test that PreToolUse hook allows safe commands."
  :tags '(:integration :slow :api :stable :hooks :process)
  (test-claude-skip-unless-cli-available)

  (let ((hook-called nil)
        (denied nil)
        (claude-agent-pre-tool-use-hook nil))

    ;; Register hook that only blocks dangerous commands
    (add-hook 'claude-agent-pre-tool-use-hook
              (lambda (input-data tool-use-id context)
                (setq hook-called t)
                (let ((tool-name (plist-get input-data :tool_name))
                      (tool-input (plist-get input-data :tool_input)))
                  (when (and (equal tool-name "Bash")
                             (string-match-p "rm -rf" (plist-get tool-input :command)))
                    (setq denied t)
                    (list :hookSpecificOutput
                          (list :permissionDecision "deny"))))))

    (let ((response-received nil))
      (claude-agent-query
       "Run this bash command: echo 'Hello from hooks test'"
       :options (claude-agent-options :allowed-tools '("Bash"))
       :on-message (lambda (msg) (setq response-received t))
       :on-complete (lambda () (message "Query complete")))

      ;; Wait for completion
      (let ((timeout (+ (float-time) 30)))
        (while (and (not response-received)
                    (< (float-time) timeout))
          (sleep-for 0.1)
          (accept-process-output nil 0.1)))

      (should response-received)
      (should hook-called)
      (should-not denied))

    ;; Cleanup
    (setq claude-agent-pre-tool-use-hook nil)))

(ert-deftest test-integration-buffer-local-hooks ()
  "Test that hooks can be buffer-local."
  :tags '(:integration :slow :api :stable :hooks :buffer-local)
  (test-claude-skip-unless-cli-available)

  (let ((buffer1 (generate-new-buffer "*test-hooks-1*"))
        (buffer2 (generate-new-buffer "*test-hooks-2*"))
        (hook1-called nil)
        (hook2-called nil))

    (unwind-protect
        (progn
          ;; Buffer 1: Add buffer-local hook
          (with-current-buffer buffer1
            (make-local-variable 'claude-agent-pre-tool-use-hook)
            (add-hook 'claude-agent-pre-tool-use-hook
                      (lambda (input-data tool-use-id context)
                        (setq hook1-called t)
                        nil)
                      nil t))

          ;; Buffer 2: Add different buffer-local hook
          (with-current-buffer buffer2
            (make-local-variable 'claude-agent-pre-tool-use-hook)
            (add-hook 'claude-agent-pre-tool-use-hook
                      (lambda (input-data tool-use-id context)
                        (setq hook2-called t)
                        nil)
                      nil t))

          ;; Run query in buffer 1
          (with-current-buffer buffer1
            (let ((response-received nil))
              (claude-agent-query
               "Run: echo 'test 1'"
               :options (claude-agent-options :allowed-tools '("Bash"))
               :on-message (lambda (msg) (setq response-received t))
               :on-complete (lambda () (message "Complete")))

              (let ((timeout (+ (float-time) 30)))
                (while (and (not response-received)
                            (< (float-time) timeout))
                  (sleep-for 0.1)
                  (accept-process-output nil 0.1)))))

          ;; Check that only buffer 1's hook was called
          (should hook1-called)
          (should-not hook2-called))

      ;; Cleanup
      (kill-buffer buffer1)
      (kill-buffer buffer2))))

;;; Performance Tests

(ert-deftest test-hook-performance ()
  "Test that hook invocation is fast."
  :tags '(:unit :fast :stable :performance :hooks)
  (let ((claude-agent-pre-tool-use-hook nil))
    ;; Add 10 simple hooks
    (dotimes (i 10)
      (add-hook 'claude-agent-pre-tool-use-hook
                (lambda (input-data tool-use-id context) nil)))

    (let ((start (float-time)))
      ;; Run hooks 100 times
      (dotimes (i 100)
        (claude-agent--run-hooks-for-event
         'claude-agent-pre-tool-use-hook
         (list :tool_name "Bash" :tool_input (list :command "test"))
         nil
         (list :signal nil)))
      (let ((elapsed (- (float-time) start)))
        ;; Should complete in under 1 second
        (should (< elapsed 1.0))))

    (setq claude-agent-pre-tool-use-hook nil)))

;;; Org File Protection Tests

;; These tests require claude-org.org to be loaded
;; Run with: make test-org-hooks

(ert-deftest test-org-protection-hook-blocks-edit ()
  "Test that org protection hook blocks Edit on .org files."
  :tags '(:unit :fast :stable :isolated :hooks :org)
  ;; Skip if claude-org not loaded
  (unless (fboundp 'claude-org--protect-org-files)
    (ert-skip "claude-org not loaded - run make test-org-hooks"))

  (let ((input-data (list :tool_name "Edit"
                          :tool_input (list :file_path "/path/to/file.org"))))
    (let ((result (claude-org--protect-org-files input-data nil nil)))
      (should (not (null result)))
      (should (equal (plist-get result :reason)
                     "Org files require Emacs MCP tools for proper structure handling"))
      (let ((hook-output (plist-get result :hookSpecificOutput)))
        (should (equal (plist-get hook-output :permissionDecision) "deny"))))))

(ert-deftest test-org-protection-hook-blocks-write ()
  "Test that org protection hook blocks Write on .org files."
  :tags '(:unit :fast :stable :isolated :hooks :org)
  (unless (fboundp 'claude-org--protect-org-files)
    (ert-skip "claude-org not loaded - run make test-org-hooks"))

  (let ((input-data (list :tool_name "Write"
                          :tool_input (list :file_path "/some/path/notes.org"))))
    (let ((result (claude-org--protect-org-files input-data nil nil)))
      (should (not (null result)))
      (let ((hook-output (plist-get result :hookSpecificOutput)))
        (should (equal (plist-get hook-output :permissionDecision) "deny"))))))

(ert-deftest test-org-protection-hook-allows-non-org ()
  "Test that org protection hook allows Edit/Write on non-.org files."
  :tags '(:unit :fast :stable :isolated :hooks :org)
  (unless (fboundp 'claude-org--protect-org-files)
    (ert-skip "claude-org not loaded - run make test-org-hooks"))

  ;; Test .el file
  (let ((input-data (list :tool_name "Edit"
                          :tool_input (list :file_path "/path/to/file.el"))))
    (should (null (claude-org--protect-org-files input-data nil nil))))

  ;; Test .py file
  (let ((input-data (list :tool_name "Write"
                          :tool_input (list :file_path "/path/to/script.py"))))
    (should (null (claude-org--protect-org-files input-data nil nil))))

  ;; Test .txt file
  (let ((input-data (list :tool_name "Edit"
                          :tool_input (list :file_path "/path/to/notes.txt"))))
    (should (null (claude-org--protect-org-files input-data nil nil)))))

(ert-deftest test-org-protection-hook-allows-other-tools ()
  "Test that org protection hook allows non-Edit/Write tools on .org files."
  :tags '(:unit :fast :stable :isolated :hooks :org)
  (unless (fboundp 'claude-org--protect-org-files)
    (ert-skip "claude-org not loaded - run make test-org-hooks"))

  ;; Read tool should be allowed
  (let ((input-data (list :tool_name "Read"
                          :tool_input (list :file_path "/path/to/file.org"))))
    (should (null (claude-org--protect-org-files input-data nil nil))))

  ;; Grep tool should be allowed
  (let ((input-data (list :tool_name "Grep"
                          :tool_input (list :path "/path/to/file.org"))))
    (should (null (claude-org--protect-org-files input-data nil nil))))

  ;; Bash tool should be allowed
  (let ((input-data (list :tool_name "Bash"
                          :tool_input (list :command "cat file.org"))))
    (should (null (claude-org--protect-org-files input-data nil nil)))))

(provide 'test-claude-agent-hooks)
;;; test-claude-agent-hooks.el ends here
