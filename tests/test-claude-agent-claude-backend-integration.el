;;; test-claude-agent-claude-backend-integration.el --- F10: Integration Tests -*- lexical-binding: t; -*-

;; End-to-end integration tests for the Claude CLI terminal backend.
;; These tests verify the full pipeline by mocking eat functions and
;; simulating bell/exit events.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-agent)

;;; Helpers

(defun test-f10--make-mock-eat-buffer ()
  "Create a buffer simulating an eat terminal."
  (let ((buf (generate-new-buffer " *test-eat-integration*")))
    (with-current-buffer buf
      (set (make-local-variable 'eat-terminal) 'mock-terminal))
    buf))

(defmacro test-f10--with-mock-eat (&rest body)
  "Execute BODY with eat functions mocked.
Provides mock-buf and eat-sends for tracking."
  (declare (indent 0))
  `(let ((mock-buf (test-f10--make-mock-eat-buffer))
         (eat-sends nil)
         (input-events nil))
     (unwind-protect
         (let ((featurep-orig (symbol-function 'featurep)))
           (cl-letf (((symbol-function 'eat-make)
                      (lambda (&rest _) mock-buf))
                     ((symbol-function 'featurep)
                      (lambda (f &rest args)
                        (if (eq f 'eat) t
                          (apply featurep-orig f args))))
                     ((symbol-function 'eat-term-send-string-as-yank)
                      (lambda (_term args) (push args eat-sends)))
                     ((symbol-function 'eat-term-input-event)
                      (lambda (_term &rest args) (push args input-events))))
             ,@body))
       (when (buffer-live-p mock-buf)
         (kill-buffer mock-buf)))))

;;; ============================================================
;;; F10: End-to-End Integration Tests
;;; ============================================================

(ert-deftest test-f10-full-lifecycle-query-bell-complete ()
  "Full lifecycle: query → insert text → bell → :on-token → :on-complete."
  :tags '(:integration :claude-backend :f10)
  (test-f10--with-mock-eat
    (let* ((token-results nil)
           (complete-result 'not-called)
           (backend (claude-agent-claude-backend--create :cwd "/tmp"))
           (callbacks (list :on-token (lambda (text)
                                        (push text token-results))
                            :on-complete (lambda (result)
                                           (setq complete-result result)))))
      ;; 1. Query sends prompt
      (claude-agent-backend-query backend "Hello Claude" callbacks)
      (should (claude-agent-claude-backend-active backend))
      (should (= 1 (claude-agent-claude-backend-query-count backend)))
      ;; Prompt was sent via yank
      (should (equal '("Hello Claude") (car eat-sends)))

      ;; 2. Simulate Claude's response appearing in the buffer
      (with-current-buffer mock-buf
        (goto-char (point-max))
        (insert "Here is my response.\nSecond line."))

      ;; 3. Simulate bell (Claude finished)
      (claude-agent-claude-backend--on-bell backend)

      ;; 4. Verify callbacks
      (should (= 2 (length token-results)))
      (should (member "Here is my response." token-results))
      (should (member "Second line." token-results))
      (should-not complete-result)  ; nil = success
      (should-not (claude-agent-claude-backend-active backend)))))

(ert-deftest test-f10-second-query-reuses-terminal ()
  "Second query should reuse terminal, increment query-count."
  :tags '(:integration :claude-backend :f10)
  (test-f10--with-mock-eat
    (let* ((backend (claude-agent-claude-backend--create :cwd "/tmp"))
           (callbacks (list :on-token #'ignore :on-complete #'ignore)))
      ;; First query
      (claude-agent-backend-query backend "first" callbacks)
      (should (= 1 (claude-agent-claude-backend-query-count backend)))
      ;; Complete first query
      (claude-agent-claude-backend--on-bell backend)
      (should-not (claude-agent-claude-backend-active backend))
      ;; Second query — should reuse same buffer
      (let ((buf-before (claude-agent-claude-backend-buffer backend)))
        (claude-agent-backend-query backend "second" callbacks)
        (should (= 2 (claude-agent-claude-backend-query-count backend)))
        (should (eq buf-before (claude-agent-claude-backend-buffer backend)))
        ;; Cleanup
        (claude-agent-claude-backend--on-bell backend)))))

(ert-deftest test-f10-cancel-sends-esc ()
  "Cancel should send ESC and allow on-bell to fire."
  :tags '(:integration :claude-backend :f10)
  (test-f10--with-mock-eat
    (let* ((esc-sent nil)
           (backend (claude-agent-claude-backend--create :cwd "/tmp"))
           (callbacks (list :on-token #'ignore :on-complete #'ignore)))
      ;; Mock eat-term-send-string for cancel
      (cl-letf (((symbol-function 'eat-term-send-string)
                 (lambda (_term str) (when (equal str "\e") (setq esc-sent t)))))
        (claude-agent-backend-query backend "test" callbacks)
        (should (claude-agent-claude-backend-active backend))
        ;; Cancel
        (claude-agent-backend-cancel backend backend)
        (should esc-sent)))))

(ert-deftest test-f10-verbose-buffer-is-eat-buffer ()
  "Verbose buffer should be the eat terminal buffer."
  :tags '(:integration :claude-backend :f10)
  (test-f10--with-mock-eat
    (let ((backend (claude-agent-claude-backend--create :cwd "/tmp")))
      (claude-agent-backend-query backend "test"
                                  (list :on-token #'ignore :on-complete #'ignore))
      (should (eq mock-buf
                  (claude-agent-backend-verbose-buffer backend)))
      ;; Cleanup
      (claude-agent-claude-backend--on-bell backend))))

(ert-deftest test-f10-cleanup-kills-process-frees-marker ()
  "Backend cleanup should kill buffer and free all fields."
  :tags '(:integration :claude-backend :f10)
  (test-f10--with-mock-eat
    (let ((backend (claude-agent-claude-backend--create :cwd "/tmp")))
      (claude-agent-backend-query backend "test"
                                  (list :on-token #'ignore :on-complete #'ignore))
      (should (buffer-live-p (claude-agent-claude-backend-buffer backend)))
      (let ((marker (claude-agent-claude-backend-output-start-pos backend)))
        ;; Cleanup
        (claude-agent-backend-cleanup backend)
        ;; Everything nil'd
        (should-not (claude-agent-claude-backend-buffer backend))
        (should-not (claude-agent-claude-backend-process backend))
        (should-not (claude-agent-claude-backend-active backend))
        (should-not (claude-agent-claude-backend-output-start-pos backend))
        (should-not (claude-agent-claude-backend-callbacks backend))
        ;; Marker freed
        (should-not (marker-buffer marker))))))

(ert-deftest test-f10-hook-handler-pretooluse-roundtrip ()
  "Hook handler: JSON input → handler → JSON output roundtrip."
  :tags '(:integration :claude-backend :f10)
  (let ((claude-agent-permission-functions
         (list (lambda (_tool _input _ctx) '(:behavior "allow")))))
    ;; Simulate what the shell wrapper would do
    (let* ((json-input "{\"hook_event_name\": \"PreToolUse\", \"tool_name\": \"Read\", \"tool_input\": {\"file_path\": \"/tmp/foo\"}}")
           (parsed (claude-agent-claude-backend--parse-hook-input json-input))
           (event-type (alist-get 'hook_event_name parsed))
           (result (claude-agent-claude-backend--handle-hook event-type parsed))
           (json-output (claude-agent-claude-backend--format-hook-response result))
           ;; Parse output back to verify roundtrip
           (output-parsed (json-read-from-string json-output))
           (hso (alist-get 'hookSpecificOutput output-parsed)))
      (should (equal "PreToolUse" (alist-get 'hookEventName hso)))
      (should (equal "allow" (alist-get 'permissionDecision hso))))))

(ert-deftest test-f10-hook-handler-deny-roundtrip ()
  "Hook handler: deny permission → JSON deny output roundtrip."
  :tags '(:integration :claude-backend :f10)
  (let ((claude-agent-permission-functions
         (list (lambda (_tool _input _ctx)
                 '(:behavior "deny" :message "Blocked by test")))))
    (let* ((json-input "{\"hook_event_name\": \"PreToolUse\", \"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"rm -rf /\"}}")
           (parsed (claude-agent-claude-backend--parse-hook-input json-input))
           (result (claude-agent-claude-backend--handle-hook "PreToolUse" parsed))
           (json-output (claude-agent-claude-backend--format-hook-response result))
           (output-parsed (json-read-from-string json-output))
           (hso (alist-get 'hookSpecificOutput output-parsed)))
      (should (equal "deny" (alist-get 'permissionDecision hso)))
      (should (equal "Blocked by test"
                     (alist-get 'permissionDecisionReason hso))))))

(ert-deftest test-f10-backend-type-creates-correct-backend ()
  "claude-org-backend-type dispatches correctly."
  :tags '(:integration :claude-backend :f10)
  ;; json-stream
  (let ((claude-org-backend-type 'json-stream))
    (let ((backend (claude-org--make-default-backend "key" nil)))
      (should (claude-agent-json-backend-p backend))))
  ;; claude-cli (with mock eat)
  (let ((claude-org-backend-type 'claude-cli))
    (let ((featurep-orig (symbol-function 'featurep)))
      (cl-letf (((symbol-function 'featurep)
                 (lambda (f &rest args)
                   (if (eq f 'eat) t (apply featurep-orig f args)))))
        (let ((backend (claude-org--make-default-backend "key" nil)))
          (should (claude-agent-claude-backend-p backend)))))))

(ert-deftest test-f10-error-in-bell-handler-resets-state ()
  "Error during bell handler should call :on-error, reset state, not propagate."
  :tags '(:integration :claude-backend :f10)
  (let* ((error-received nil)
         (complete-received nil)
         (backend (claude-agent-claude-backend--create
                   :active t
                   :callbacks (list :on-token (lambda (_text)
                                                (error "Callback crashed"))
                                    :on-error (lambda (msg)
                                                (setq error-received msg))
                                    :on-complete (lambda (result)
                                                   (setq complete-received result))))))
    (with-temp-buffer
      (insert "some response")
      (let ((marker (copy-marker (point-min))))
        (setf (claude-agent-claude-backend-buffer backend) (current-buffer))
        (setf (claude-agent-claude-backend-output-start-pos backend) marker)
        (set (make-local-variable 'eat-terminal) 'mock-terminal)
        ;; Bell should NOT propagate the error (condition-case inside)
        (claude-agent-claude-backend--on-bell backend)
        ;; :on-error was called
        (should error-received)
        (should (string-match-p "crashed" error-received))
        ;; :on-complete was called with error info
        (should (plist-get complete-received :error))
        ;; State should be reset
        (should-not (claude-agent-claude-backend-active backend))))))

(ert-deftest test-f10-double-bell-second-ignored ()
  "Rapid double bell: second bell when not active is ignored."
  :tags '(:integration :claude-backend :f10)
  (test-f10--with-mock-eat
    (let* ((complete-count 0)
           (backend (claude-agent-claude-backend--create :cwd "/tmp"))
           (callbacks (list :on-token #'ignore
                            :on-complete (lambda (_r)
                                           (cl-incf complete-count)))))
      (claude-agent-backend-query backend "test" callbacks)
      ;; First bell
      (claude-agent-claude-backend--on-bell backend)
      (should (= 1 complete-count))
      ;; Second bell (spurious) — backend is no longer active
      (claude-agent-claude-backend--on-bell backend)
      ;; Should still be 1, second bell was no-op
      (should (= 1 complete-count)))))

(provide 'test-claude-agent-claude-backend-integration)
;;; test-claude-agent-claude-backend-integration.el ends here
