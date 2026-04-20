;;; test-claude-agent-acp.el --- Tests for ACP backend -*- lexical-binding: t; -*-

;;; Commentary:
;; Unit tests for claude-agent-acp.org using our own JSON-RPC transport.
;; No external acp.el dependency.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'map)

;; Load dependencies
(when (boundp 'test-claude-agent-project-root)
  (let ((root test-claude-agent-project-root))
    (unless (featurep 'claude-agent-backend)
      (literate-elisp-load (expand-file-name "claude-agent-backend.org" root)))
    (unless (featurep 'claude-agent-acp)
      (literate-elisp-load (expand-file-name "claude-agent-acp.org" root)))))

(require 'claude-agent-backend)
(require 'claude-agent-acp)

;;; Test helpers

(defun test-acp--make-fake-client (&optional response-alist)
  "Create a fake JSON-RPC client plist for testing.
RESPONSE-ALIST maps method names to result values (or error alists).
The fake process captures sent data but doesn't actually communicate."
  (let* ((sent-messages nil)
         (proc (start-process "test-acp-fake" nil "true"))
         (client (list :process proc
                       :pending (make-hash-table :test 'equal)
                       :notification-handlers nil
                       :request-handlers nil
                       :stderr-buffer nil
                       :partial-line ""
                       ;; Test-only: track sent messages and response map
                       :sent-messages nil
                       :response-alist response-alist)))
    ;; Override process-send-string by intercepting at the request level
    client))

(defun test-acp--inject-response (client id result)
  "Simulate an incoming JSON-RPC response with ID and RESULT."
  (claude-agent-acp--route-message
   client `((jsonrpc . "2.0") (id . ,id) (result . ,result))))

(defun test-acp--inject-error (client id code message)
  "Simulate an incoming JSON-RPC error response."
  (claude-agent-acp--route-message
   client `((jsonrpc . "2.0") (id . ,id)
            (error . ((code . ,code) (message . ,message))))))

(defun test-acp--inject-notification (client method params)
  "Simulate an incoming JSON-RPC notification."
  (claude-agent-acp--route-message
   client `((jsonrpc . "2.0") (method . ,method) (params . ,params))))

;;; Tests: Struct creation

(ert-deftest test-acp-backend-struct-creation ()
  "Test basic struct creation."
  (let ((backend (claude-agent-acp-backend--create
                  :session-key "test"
                  :cwd "/tmp")))
    (should (claude-agent-acp-backend-p backend))
    (should (eq (claude-agent-backend-type backend) :opencode-acp))
    (should (equal (claude-agent-acp-backend-session-key backend) "test"))
    (should (equal (claude-agent-acp-backend-cwd backend) "/tmp"))
    (should-not (claude-agent-acp-backend-client backend))
    (should-not (claude-agent-acp-backend-initialized backend))
    (should-not (claude-agent-acp-backend-active-query backend))))

;;; Tests: Capabilities

(ert-deftest test-acp-backend-supports-p ()
  "Test capability declarations."
  (let ((backend (claude-agent-acp-backend--create)))
    (should (claude-agent-backend-supports-p backend :streaming-tokens))
    (should (claude-agent-backend-supports-p backend :tool-use))
    (should (claude-agent-backend-supports-p backend :persistent-client))
    (should-not (claude-agent-backend-supports-p backend :structured-messages))
    (should-not (claude-agent-backend-supports-p backend :session-resume))))

;;; Tests: Ready and active state

(ert-deftest test-acp-backend-ready-p ()
  "Test ready-p reflects active query state."
  (let ((backend (claude-agent-acp-backend--create)))
    (should (claude-agent-backend-ready-p backend))
    (setf (claude-agent-acp-backend-active-query backend) t)
    (should-not (claude-agent-backend-ready-p backend))))

;;; Tests: Error classification

(ert-deftest test-acp-backend-classify-error ()
  "Test error classification."
  (let ((backend (claude-agent-acp-backend--create)))
    (should (eq (claude-agent-backend-classify-error backend "auth failed")
                'auth))
    (should (eq (claude-agent-backend-classify-error backend "session expired")
                'session-expired))
    (should (eq (claude-agent-backend-classify-error backend "ECONNREFUSED")
                'network))
    (should (eq (claude-agent-backend-classify-error backend "something else")
                'unknown))
    (should (eq (claude-agent-backend-classify-error backend nil)
                'unknown))))

;;; Tests: Notification handler dispatch

(ert-deftest test-acp-notification-handler-agent-message ()
  "Test direct notification dispatch for agent_message_chunk."
  (let* ((tokens nil)
         (backend (claude-agent-acp-backend--create)))
    (setf (claude-agent-acp-backend-callbacks backend)
          (list :on-token (lambda (text) (push text tokens))))
    (claude-agent-acp--handle-notification
     backend
     '((jsonrpc . "2.0") (method . "session/update")
       (params (update (sessionUpdate . "agent_message_chunk")
                       (content (text . "test chunk"))))))
    (should (equal tokens '("test chunk")))))

(ert-deftest test-acp-notification-handler-tool-call ()
  "Test direct notification dispatch for tool_call."
  (let* ((tokens nil)
         (backend (claude-agent-acp-backend--create)))
    (setf (claude-agent-acp-backend-callbacks backend)
          (list :on-token (lambda (text) (push text tokens))))
    (claude-agent-acp--handle-notification
     backend
     '((jsonrpc . "2.0") (method . "session/update")
       (params (update (sessionUpdate . "tool_call")
                       (toolCallId . "tc-1")
                       (title . "Bash ls")
                       (status . "running")))))
    (should (= (length tokens) 1))
    (should (string-match-p "Tool:.*Bash ls" (car tokens)))))

(ert-deftest test-acp-notification-handler-ignores-unknown ()
  "Test that unknown event types are silently ignored."
  (let* ((tokens nil)
         (backend (claude-agent-acp-backend--create)))
    (setf (claude-agent-acp-backend-callbacks backend)
          (list :on-token (lambda (text) (push text tokens))))
    (claude-agent-acp--handle-notification
     backend
     '((jsonrpc . "2.0") (method . "session/update")
       (params (update (sessionUpdate . "unknown_event")))))
    (should-not tokens)))

;;; Tests: Content extraction

(ert-deftest test-acp-extract-content-text ()
  "Test content text extraction from ACP content items."
  ;; Vector of content objects
  (should (equal (claude-agent-acp--extract-content-text
                  [((type . "text") (text . "line 1"))
                   ((type . "text") (text . "line 2"))])
                 "line 1\nline 2"))
  ;; Empty
  (should-not (claude-agent-acp--extract-content-text nil))
  (should-not (claude-agent-acp--extract-content-text [])))

;;; Tests: Permission handler

(ert-deftest test-acp-permission-handler-auto-approve ()
  "Test permission auto-approval sends response with first option."
  (let* ((tokens nil)
         (sent-responses nil)
         (backend (claude-agent-acp-backend--create)))
    (setf (claude-agent-acp-backend-callbacks backend)
          (list :on-token (lambda (text) (push text tokens))))
    ;; Create a minimal client with a process that captures sent strings
    (let* ((sent-data nil)
           (proc (start-process "test-acp-perm" nil "sleep" "10"))
           (client (claude-agent-acp--make-jsonrpc-client proc)))
      ;; Override process-send-string to capture output
      (advice-add 'process-send-string :before
                  (lambda (_proc data) (push data sent-data))
                  '((name . test-acp-capture)))
      (unwind-protect
          (progn
            (setf (claude-agent-acp-backend-client backend) client)
            ;; Send permission request
            (claude-agent-acp--handle-request
             backend
             `((method . "session/request_permission")
               (id . 99)
               (params (toolCall (title . "Write output.txt")
                                 (toolCallId . "tc-5"))
                       (options . [((id . "allow-once") (label . "Allow once"))
                                   ((id . "deny") (label . "Deny"))]))))
            ;; Should have sent a response via process
            (should (>= (length sent-data) 1))
            ;; Verify the response contains optionId
            (let* ((resp-json (json-read-from-string (car sent-data)))
                   (result (map-elt resp-json 'result)))
              (should (equal (map-elt result 'optionId) "allow-once")))
            ;; Should have notified user
            (should (= (length tokens) 1))
            (should (string-match-p "Approved.*Write output.txt" (car tokens))))
        (advice-remove 'process-send-string 'test-acp-capture)
        (delete-process proc)))))

;;; Tests: Handshake via route-message

(ert-deftest test-acp-backend-handshake-and-prompt ()
  "Test handshake + prompt using injected responses via route-message."
  (let* ((tokens nil)
         (completed nil)
         (backend (claude-agent-acp-backend--create :cwd "/tmp"))
         ;; Create a fake client
         (proc (start-process "test-acp-hs" nil "sleep" "10"))
         (client (claude-agent-acp--make-jsonrpc-client proc)))
    (setf (claude-agent-acp-backend-client backend) client)
    (setf (claude-agent-acp-backend-initialized backend) t)
    (setf (claude-agent-acp-backend-session-id backend) "test-session-42")
    (claude-agent-acp--subscribe backend)
    ;; Intercept sends to auto-respond
    (advice-add 'process-send-string :after
                (lambda (_proc data)
                  (ignore-errors
                    (let* ((msg (json-read-from-string
                                 (string-trim data)))
                           (id (map-elt msg 'id))
                           (method (map-elt msg 'method)))
                      (when (equal method "session/prompt")
                        ;; Inject a text chunk notification
                        (test-acp--inject-notification
                         client "session/update"
                         '((update (sessionUpdate . "agent_message_chunk")
                                   (content (text . "Hello from OpenCode!")))))
                        ;; Inject prompt completion
                        (test-acp--inject-response
                         client id '((stopReason . "end_turn")))))))
                '((name . test-acp-auto-respond)))
    (unwind-protect
        (progn
          (claude-agent-backend-query
           backend "hello"
           (list :on-token (lambda (text) (push text tokens))
                 :on-complete (lambda (_) (setq completed t))))
          ;; Should complete synchronously (fake)
          (should completed)
          ;; Verify token received
          (should (member "Hello from OpenCode!" tokens))
          ;; Verify no longer active
          (should-not (claude-agent-acp-backend-active-query backend)))
      (advice-remove 'process-send-string 'test-acp-auto-respond)
      (delete-process proc))))

;;; Tests: Tool call notifications

(ert-deftest test-acp-backend-tool-call-notifications ()
  "Test tool_call and tool_call_update mapped to on-token."
  (let* ((tokens nil)
         (completed nil)
         (backend (claude-agent-acp-backend--create :cwd "/tmp"))
         (proc (start-process "test-acp-tc" nil "sleep" "10"))
         (client (claude-agent-acp--make-jsonrpc-client proc)))
    (setf (claude-agent-acp-backend-client backend) client)
    (setf (claude-agent-acp-backend-initialized backend) t)
    (setf (claude-agent-acp-backend-session-id backend) "test-session-42")
    (claude-agent-acp--subscribe backend)
    (advice-add 'process-send-string :after
                (lambda (_proc data)
                  (ignore-errors
                    (let* ((msg (json-read-from-string
                                 (string-trim data)))
                           (id (map-elt msg 'id))
                           (method (map-elt msg 'method)))
                      (when (equal method "session/prompt")
                        ;; tool_call
                        (test-acp--inject-notification
                         client "session/update"
                         '((update (sessionUpdate . "tool_call")
                                   (title . "Read file.py")
                                   (status . "running"))))
                        ;; tool_call_update completed
                        (test-acp--inject-notification
                         client "session/update"
                         `((update (sessionUpdate . "tool_call_update")
                                   (title . "Read file.py")
                                   (status . "completed")
                                   (content . [((type . "text")
                                                (text . "file contents here"))]))))
                        ;; agent message
                        (test-acp--inject-notification
                         client "session/update"
                         '((update (sessionUpdate . "agent_message_chunk")
                                   (content (text . "I read the file.")))))
                        ;; done
                        (test-acp--inject-response
                         client id '((stopReason . "end_turn")))))))
                '((name . test-acp-tc-respond)))
    (unwind-protect
        (progn
          (claude-agent-backend-query
           backend "read file.py"
           (list :on-token (lambda (text) (push text tokens))
                 :on-complete (lambda (_) (setq completed t))))
          (should completed)
          (let ((all-text (string-join (nreverse tokens) "")))
            (should (string-match-p "Tool:.*Read file.py" all-text))
            (should (string-match-p "file contents here" all-text))
            (should (string-match-p "I read the file" all-text))))
      (advice-remove 'process-send-string 'test-acp-tc-respond)
      (delete-process proc))))

;;; Tests: Cleanup

(ert-deftest test-acp-backend-cleanup ()
  "Test cleanup releases resources."
  (let ((backend (claude-agent-acp-backend--create
                  :session-key "test")))
    (setf (claude-agent-acp-backend-session-id backend) "sid")
    (setf (claude-agent-acp-backend-initialized backend) t)
    (setf (claude-agent-acp-backend-active-query backend) t)
    ;; No real client to shut down — cleanup should not error
    (claude-agent-backend-cleanup backend)
    (should-not (claude-agent-acp-backend-client backend))
    (should-not (claude-agent-acp-backend-session-id backend))
    (should-not (claude-agent-acp-backend-initialized backend))
    (should-not (claude-agent-acp-backend-active-query backend))))

(provide 'test-claude-agent-acp)
;;; test-claude-agent-acp.el ends here
