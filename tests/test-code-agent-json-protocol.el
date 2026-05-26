;;; test-code-agent-json-protocol.el --- TDD Tests for JSON Protocol Handling -*- lexical-binding: t; -*-

;; TDD tests for JSON streaming and error recovery
;; These tests define expected behavior BEFORE implementation
;; Tag: :tdd - written test-first

(require 'ert)
(require 'cl-lib)

;; Note: code-agent.org is loaded via Makefile

;;; JSON Validation Tests

(ert-deftest test-json-validate-message-valid-types ()
  "TDD: Valid message types should pass validation."
  :tags '(:unit :fast :stable :isolated :json :tdd)
  ;; assistant message
  (let ((msg '(:type "assistant" :message (:content "hello"))))
    (should (code-agent--validate-json-message msg)))
  ;; user message
  (let ((msg '(:type "user" :message (:content "test"))))
    (should (code-agent--validate-json-message msg)))
  ;; result message
  (let ((msg '(:type "result" :result "success")))
    (should (code-agent--validate-json-message msg)))
  ;; system message
  (let ((msg '(:type "system" :message "initialized")))
    (should (code-agent--validate-json-message msg)))
  ;; control_request message
  (let ((msg '(:type "control_request" :request_id "123")))
    (should (code-agent--validate-json-message msg))))

(ert-deftest test-json-validate-message-missing-type ()
  "TDD: Messages without :type should fail validation."
  :tags '(:unit :fast :stable :isolated :json :tdd)
  (let ((msg '(:message "hello" :content "test")))
    (should-not (code-agent--validate-json-message msg))))

(ert-deftest test-json-validate-message-invalid-type ()
  "TDD: Messages with non-string :type should fail validation."
  :tags '(:unit :fast :stable :isolated :json :tdd)
  ;; Symbol instead of string
  (let ((msg '(:type assistant :message "hello")))
    (should-not (code-agent--validate-json-message msg)))
  ;; Number instead of string
  (let ((msg '(:type 123 :message "hello")))
    (should-not (code-agent--validate-json-message msg)))
  ;; Empty type
  (let ((msg '(:type "" :message "hello")))
    (should-not (code-agent--validate-json-message msg))))

(ert-deftest test-json-validate-message-unknown-type ()
  "TDD: Unknown message types should still pass basic validation.
The caller decides how to handle unknown types."
  :tags '(:unit :fast :stable :isolated :json :tdd)
  ;; Unknown but well-formed type should pass basic validation
  (let ((msg '(:type "unknown_future_type" :data "something")))
    (should (code-agent--validate-json-message msg))))

;;; JSON Parse Error Recovery Tests

(ert-deftest test-json-parse-error-is-logged ()
  "TDD: JSON parse errors should be logged with context."
  :tags '(:unit :fast :stable :isolated :json :tdd)
  (let ((logged-errors nil))
    (cl-letf (((symbol-function 'code-agent--debug-log)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-errors))))
      ;; Create mock process state using correct constructor
      (let* ((state (code-agent--make-process-state
                     :json-buffer "not valid json\n"
                     :ready t))
             (process (start-process "test" nil "true")))
        (unwind-protect
            (progn
              (process-put process 'code-agent-state state)
              (code-agent--process-json-buffer process))
          (delete-process process))))
    ;; Should have logged the parse error
    (should (cl-some (lambda (msg)
                       (or (string-match-p "Non-JSON" msg)
                           (string-match-p "JSON" msg)))
                     logged-errors))))

(ert-deftest test-json-parse-error-calls-error-callback ()
  "TDD: JSON parse errors should invoke error callback with details."
  :tags '(:unit :fast :stable :isolated :json :tdd)
  (let ((error-received nil))
    (let* ((state (code-agent--make-process-state
                   :json-buffer "{invalid json}\n"
                   :ready t
                   :error-callback (lambda (err) (setq error-received err))))
           (process (start-process "test" nil "true")))
      (unwind-protect
          (progn
            (process-put process 'code-agent-state state)
            (code-agent--process-json-buffer process))
        (delete-process process)))
    ;; Error callback should have been called
    (should error-received)
    ;; Error should contain the problematic input
    (should (plist-get (cdr error-received) :message))))

(ert-deftest test-json-multiline-string-preserved ()
  "TDD: JSON with embedded newlines in strings should be handled.
Note: Current implementation assumes newline-delimited JSON."
  :tags '(:unit :fast :stable :isolated :json :tdd)
  ;; This test documents expected behavior: embedded \n in JSON strings
  ;; must be escaped as \\n in the wire format
  (let* ((json-str "{\"type\":\"assistant\",\"content\":\"line1\\nline2\"}\n")
         (state (code-agent--make-process-state
                 :json-buffer json-str
                 :ready t
                 :callback (lambda (msg) nil)))
         (process (start-process "test" nil "true")))
    (unwind-protect
        (progn
          (process-put process 'code-agent-state state)
          ;; Should parse without error
          (should-not (condition-case err
                          (progn
                            (code-agent--process-json-buffer process)
                            nil)
                        (error err))))
      (delete-process process))))

;;; JSON Buffer Handling Tests

(ert-deftest test-json-buffer-incomplete-json-preserved ()
  "TDD: Incomplete JSON (no trailing newline) should be preserved in buffer."
  :tags '(:unit :fast :stable :isolated :json :tdd)
  (let* ((state (code-agent--make-process-state
                 :json-buffer "{\"type\":\"assistant\""  ; incomplete, no newline
                 :ready t))
         (process (start-process "test" nil "true")))
    (unwind-protect
        (progn
          (process-put process 'code-agent-state state)
          (code-agent--process-json-buffer process)
          ;; Buffer should still contain the incomplete JSON
          (should (string= (code-agent--process-state-json-buffer state)
                          "{\"type\":\"assistant\"")))
      (delete-process process))))

(ert-deftest test-json-buffer-multiple-messages ()
  "TDD: Multiple JSON messages in buffer should all be processed."
  :tags '(:unit :fast :stable :isolated :json :tdd)
  (let ((messages-received nil))
    (let* ((json-str (concat "{\"type\":\"system\",\"message\":\"init\"}\n"
                             "{\"type\":\"assistant\",\"message\":{}}\n"
                             "{\"type\":\"result\",\"result\":\"done\"}\n"))
           (state (code-agent--make-process-state
                   :json-buffer json-str
                   :ready t
                   :callback (lambda (msg)
                              (push (plist-get msg :type) messages-received))))
           (process (start-process "test" nil "true")))
      (unwind-protect
          (progn
            (process-put process 'code-agent-state state)
            (code-agent--process-json-buffer process))
        (delete-process process)))
    ;; Should have received all 3 messages
    (should (= 3 (length messages-received)))))

(ert-deftest test-json-buffer-empty-lines-skipped ()
  "TDD: Empty lines between JSON messages should be skipped."
  :tags '(:unit :fast :stable :isolated :json :tdd)
  (let ((messages-received nil))
    (let* ((json-str (concat "{\"type\":\"assistant\",\"message\":{}}\n"
                             "\n"  ; empty line
                             "   \n"  ; whitespace-only line
                             "{\"type\":\"result\",\"result\":\"ok\"}\n"))
           (state (code-agent--make-process-state
                   :json-buffer json-str
                   :ready t
                   :callback (lambda (msg)
                              (push msg messages-received))))
           (process (start-process "test" nil "true")))
      (unwind-protect
          (progn
            (process-put process 'code-agent-state state)
            (code-agent--process-json-buffer process))
        (delete-process process)))
    ;; Should have received 2 messages (empty lines skipped)
    (should (= 2 (length messages-received)))))

;;; JSON Error Distinguishing Tests

(ert-deftest test-json-distinguish-cli-text-from-malformed ()
  "TDD: Should distinguish CLI text output from malformed JSON.
CLI text (like startup messages) should be handled differently from
actually malformed JSON that was supposed to be valid."
  :tags '(:unit :fast :stable :isolated :json :tdd)
  ;; Plain text from CLI (not JSON at all)
  (should (code-agent--is-cli-text-output-p "Welcome to Claude CLI"))
  (should (code-agent--is-cli-text-output-p "Error: Connection failed"))
  (should (code-agent--is-cli-text-output-p ""))
  ;; Clearly attempted JSON (has braces)
  (should-not (code-agent--is-cli-text-output-p "{broken"))
  (should-not (code-agent--is-cli-text-output-p "{\"type\":"))
  (should-not (code-agent--is-cli-text-output-p "[1, 2, 3")))

;;; JSON Type Coercion Tests

(ert-deftest test-json-type-settings-applied ()
  "TDD: JSON parsing should use correct type settings."
  :tags '(:unit :fast :stable :isolated :json :tdd)
  ;; This test verifies our JSON parsing settings are correct
  (let* ((json-object-type 'plist)
         (json-array-type 'list)
         (json-key-type 'keyword)
         (parsed (json-read-from-string "{\"type\":\"test\",\"items\":[1,2,3]}")))
    ;; Should be plist
    (should (plistp parsed))
    ;; Keys should be keywords
    (should (eq (car parsed) :type))
    ;; Arrays should be lists
    (should (listp (plist-get parsed :items)))))

(provide 'test-code-agent-json-protocol)
;;; test-code-agent-json-protocol.el ends here
