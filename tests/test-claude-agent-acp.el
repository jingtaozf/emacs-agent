;;; test-claude-agent-acp.el --- Tests for ACP backend -*- lexical-binding: t; -*-

;;; Commentary:
;; Unit tests for claude-agent-acp.org using acp-fakes.

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

(require 'acp)
(require 'acp-fakes)
(require 'claude-agent-backend)
(require 'claude-agent-acp)

;;; Test helpers

(defun test-acp--make-messages-no-auth ()
  "Create fake ACP message traffic for a full handshake (no auth) + prompt.
Returns a list of messages suitable for `acp-fakes-make-client'."
  (list
   ;; Request 1: initialize (outgoing marker)
   `((:direction . outgoing) (:kind . request)
     (:object (jsonrpc . "2.0") (method . "initialize") (id . 1)
              (params (protocolVersion . 1))))
   ;; Response 1: initialize result (no auth methods)
   `((:direction . incoming) (:kind . response)
     (:object (jsonrpc . "2.0") (id . 1)
              (result (protocolVersion . 1)
                      (authMethods . [])
                      (agentCapabilities (loadSession . :false)))))
   ;; Request 2: session/new
   `((:direction . outgoing) (:kind . request)
     (:object (jsonrpc . "2.0") (method . "session/new") (id . 2)
              (params (cwd . "/tmp"))))
   ;; Response 2: session/new result
   `((:direction . incoming) (:kind . response)
     (:object (jsonrpc . "2.0") (id . 2)
              (result (sessionId . "test-session-42"))))
   ;; Request 3: session/prompt
   `((:direction . outgoing) (:kind . request)
     (:object (jsonrpc . "2.0") (method . "session/prompt") (id . 3)
              (params (sessionId . "test-session-42"))))
   ;; Notification: agent_message_chunk
   `((:direction . incoming) (:kind . notification)
     (:object (jsonrpc . "2.0") (method . "session/update")
              (params (update (sessionUpdate . "agent_message_chunk")
                              (content (text . "Hello from OpenCode!"))))))
   ;; Response 3: prompt complete
   `((:direction . incoming) (:kind . response)
     (:object (jsonrpc . "2.0") (id . 3)
              (result (stopReason . "end_turn"))))))

(defun test-acp--make-messages-with-tool-call ()
  "Create messages with a tool call notification."
  (list
   ;; Handshake (reuse same pattern)
   `((:direction . outgoing) (:kind . request)
     (:object (jsonrpc . "2.0") (method . "initialize") (id . 1)))
   `((:direction . incoming) (:kind . response)
     (:object (jsonrpc . "2.0") (id . 1)
              (result (protocolVersion . 1) (authMethods . []))))
   `((:direction . outgoing) (:kind . request)
     (:object (jsonrpc . "2.0") (method . "session/new") (id . 2)))
   `((:direction . incoming) (:kind . response)
     (:object (jsonrpc . "2.0") (id . 2)
              (result (sessionId . "test-session-42"))))
   ;; Prompt with tool call
   `((:direction . outgoing) (:kind . request)
     (:object (jsonrpc . "2.0") (method . "session/prompt") (id . 3)))
   ;; tool_call notification
   `((:direction . incoming) (:kind . notification)
     (:object (jsonrpc . "2.0") (method . "session/update")
              (params (update (sessionUpdate . "tool_call")
                              (toolCallId . "tc-1")
                              (title . "Read file.py")
                              (status . "running")
                              (kind . "tool_use")))))
   ;; tool_call_update notification (completed)
   `((:direction . incoming) (:kind . notification)
     (:object (jsonrpc . "2.0") (method . "session/update")
              (params (update (sessionUpdate . "tool_call_update")
                              (toolCallId . "tc-1")
                              (title . "Read file.py")
                              (status . "completed")
                              (content . [((type . "text") (text . "file contents here"))])))))
   ;; agent response
   `((:direction . incoming) (:kind . notification)
     (:object (jsonrpc . "2.0") (method . "session/update")
              (params (update (sessionUpdate . "agent_message_chunk")
                              (content (text . "I read the file."))))))
   ;; Done
   `((:direction . incoming) (:kind . response)
     (:object (jsonrpc . "2.0") (id . 3)
              (result (stopReason . "end_turn"))))))

(defun test-acp--make-backend-with-fake (messages)
  "Create an ACP backend pre-loaded with a fake client using MESSAGES."
  (let ((backend (claude-agent-acp-backend--create
                  :cwd "/tmp"
                  :session-key "test-key")))
    (let ((client (acp-fakes-make-client messages)))
      ;; acp-fakes request-sender doesn't accept :buffer — wrap it
      (let ((orig-sender (map-elt client :request-sender)))
        (setf (map-elt client :request-sender)
              (cl-function
               (lambda (&key client request on-success on-failure _sync _buffer)
                 (funcall orig-sender
                          :client client
                          :request request
                          :on-success on-success
                          :on-failure on-failure)))))
      (setf (claude-agent-acp-backend-client backend) client))
    backend))

;;; Tests

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

(ert-deftest test-acp-backend-supports-p ()
  "Test capability declarations."
  (let ((backend (claude-agent-acp-backend--create)))
    (should (claude-agent-backend-supports-p backend :streaming-tokens))
    (should (claude-agent-backend-supports-p backend :tool-use))
    (should-not (claude-agent-backend-supports-p backend :structured-messages))
    (should-not (claude-agent-backend-supports-p backend :session-resume))
    (should-not (claude-agent-backend-supports-p backend :persistent-client))))

(ert-deftest test-acp-backend-ready-p ()
  "Test ready-p reflects active query state."
  (let ((backend (claude-agent-acp-backend--create)))
    (should (claude-agent-backend-ready-p backend))
    (setf (claude-agent-acp-backend-active-query backend) t)
    (should-not (claude-agent-backend-ready-p backend))))

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

(ert-deftest test-acp-backend-handshake-and-prompt ()
  "Test full flow: handshake + prompt with streaming token."
  (let* ((tokens nil)
         (completed nil)
         (backend (test-acp--make-backend-with-fake
                   (test-acp--make-messages-no-auth)))
         (callbacks (list :on-token (lambda (text) (push text tokens))
                          :on-complete (lambda (_) (setq completed t)))))
    ;; Send query — should complete synchronously with fake client
    (claude-agent-backend-query backend "hello" callbacks)
    ;; Verify handshake completed
    (should (claude-agent-acp-backend-initialized backend))
    (should (equal (claude-agent-acp-backend-session-id backend)
                   "test-session-42"))
    ;; Verify token received
    (should (member "Hello from OpenCode!" tokens))
    ;; Verify completion
    (should completed)
    ;; Verify no longer active
    (should-not (claude-agent-acp-backend-active-query backend))))

(ert-deftest test-acp-backend-tool-call-notifications ()
  "Test tool_call and tool_call_update mapped to on-token."
  (let* ((tokens nil)
         (completed nil)
         (backend (test-acp--make-backend-with-fake
                   (test-acp--make-messages-with-tool-call)))
         (callbacks (list :on-token (lambda (text) (push text tokens))
                          :on-complete (lambda (_) (setq completed t)))))
    (claude-agent-backend-query backend "read file.py" callbacks)
    (should completed)
    ;; Should have tool_call, tool_call_update result, and agent message
    (let ((all-text (string-join (nreverse tokens) "")))
      (should (string-match-p "Tool:.*Read file.py" all-text))
      (should (string-match-p "file contents here" all-text))
      (should (string-match-p "I read the file" all-text)))))

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

(ert-deftest test-acp-permission-handler-auto-approve ()
  "Test permission auto-approval sends response with first option."
  (let* ((tokens nil)
         (responses nil)
         (backend (claude-agent-acp-backend--create)))
    (setf (claude-agent-acp-backend-callbacks backend)
          (list :on-token (lambda (text) (push text tokens))))
    ;; Create a fake client with a response-sender that captures calls
    (let ((fake-client (acp-fakes-make-client nil)))
      (setf (map-elt fake-client :response-sender)
            (lambda (&rest args) (push args responses)))
      (setf (claude-agent-acp-backend-client backend) fake-client))
    ;; Send permission request
    (claude-agent-acp--handle-request
     backend
     `((method . "session/request_permission")
       (id . 99)
       (params (toolCall (title . "Write output.txt")
                         (toolCallId . "tc-5"))
               (options . [((id . "allow-once") (label . "Allow once"))
                           ((id . "deny") (label . "Deny"))]))))
    ;; Should have sent a response
    (should (= (length responses) 1))
    ;; Should have notified user
    (should (= (length tokens) 1))
    (should (string-match-p "Approved.*Write output.txt" (car tokens)))))

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
