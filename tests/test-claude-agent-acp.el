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
    (unless (featurep 'claude-agent-jsonrpc)
      (literate-elisp-load (expand-file-name "claude-agent-jsonrpc.org" root)))
    (unless (featurep 'claude-agent-acp)
      (literate-elisp-load (expand-file-name "claude-agent-acp.org" root)))
    (unless (featurep 'claude-agent-acp-opencode)
      (literate-elisp-load (expand-file-name "claude-agent-acp-opencode.org" root)))
    (unless (featurep 'claude-agent-acp-gemini)
      (literate-elisp-load (expand-file-name "claude-agent-acp-gemini.org" root)))
    (unless (featurep 'claude-agent-acp-codex)
      (literate-elisp-load (expand-file-name "claude-agent-acp-codex.org" root)))))

(require 'claude-agent-backend)
(require 'claude-agent-jsonrpc)
(require 'claude-agent-acp)
(require 'claude-agent-acp-opencode)
(require 'claude-agent-acp-gemini)
(require 'claude-agent-acp-codex)

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
  (claude-agent-jsonrpc--route
   client `((jsonrpc . "2.0") (id . ,id) (result . ,result))))

(defun test-acp--inject-error (client id code message)
  "Simulate an incoming JSON-RPC error response."
  (claude-agent-jsonrpc--route
   client `((jsonrpc . "2.0") (id . ,id)
            (error . ((code . ,code) (message . ,message))))))

(defun test-acp--inject-notification (client method params)
  "Simulate an incoming JSON-RPC notification."
  (claude-agent-jsonrpc--route
   client `((jsonrpc . "2.0") (method . ,method) (params . ,params))))

;;; Tests: Struct creation

(ert-deftest test-acp-backend-struct-creation ()
  "Test basic struct creation."
  (let ((backend (claude-agent-acp-backend--create
                  :session-key "test"
                  :cwd "/tmp")))
    (should (claude-agent-acp-backend-p backend))
    (should (eq (claude-agent-backend-type backend) :acp))
    (should (equal (claude-agent-acp-backend-session-key backend) "test"))
    (should (equal (claude-agent-acp-backend-cwd backend) "/tmp"))
    (should-not (claude-agent-acp-backend-client backend))
    (should-not (claude-agent-acp-backend-initialized backend))
    (should-not (claude-agent-acp-backend-active-query backend))))

(ert-deftest test-acp-opencode-constructor-sets-defaults ()
  "Opencode constructor presets agent-name, spawn-args, and no-auth."
  (let ((backend (claude-agent-acp-opencode-create
                  :session-key "oc" :cwd "/tmp")))
    (should (equal (claude-agent-acp-backend-agent-name backend) "opencode"))
    (should (equal (claude-agent-acp-backend-spawn-args backend)
                   '("opencode" "acp")))
    (should-not (claude-agent-acp-backend-needs-authenticate backend))
    (should-not (claude-agent-acp-backend-auth-request-maker backend))))

(ert-deftest test-acp-gemini-constructor-sets-defaults ()
  "Gemini constructor presets command, auth-method, and needs-auth."
  (let ((backend (claude-agent-acp-gemini-create
                  :session-key "gm" :cwd "/tmp")))
    (should (equal (claude-agent-acp-backend-agent-name backend) "gemini"))
    (should (equal (claude-agent-acp-backend-spawn-args backend)
                   '("gemini" "--experimental-acp")))
    (should (claude-agent-acp-backend-needs-authenticate backend))
    (should (functionp
             (claude-agent-acp-backend-auth-request-maker backend)))))

(ert-deftest test-acp-gemini-auth-request-uses-configured-method ()
  "Gemini auth-request-maker returns the configured methodId.
The per-profile `--auth-request' defuns were replaced in 2026-05 by a
shared `claude-agent-acp--make-profile-backend' helper that installs
a closure as the backend's `auth-request-maker'; we drive the
closure off a created backend instance."
  (dolist (method '(vertex-ai oauth-personal gemini-api-key))
    (let* ((claude-agent-acp-gemini-auth-method method)
           (backend (claude-agent-acp-gemini-create
                     :session-key "gm" :cwd "/tmp"))
           (maker (claude-agent-acp-backend-auth-request-maker backend)))
      (should (equal (map-elt (funcall maker) 'methodId)
                     (symbol-name method))))))

(ert-deftest test-acp-codex-constructor-sets-defaults ()
  "Codex constructor presets command, auth-method, and needs-auth."
  (let ((backend (claude-agent-acp-codex-create
                  :session-key "cx" :cwd "/tmp")))
    (should (equal (claude-agent-acp-backend-agent-name backend) "codex"))
    (should (equal (claude-agent-acp-backend-spawn-args backend)
                   '("codex-acp")))
    (should (claude-agent-acp-backend-needs-authenticate backend))
    (should (functionp
             (claude-agent-acp-backend-auth-request-maker backend)))))

(ert-deftest test-acp-codex-auth-request-uses-configured-method ()
  "Codex auth-request-maker returns the configured methodId.
The per-profile `--auth-request' defuns were replaced in 2026-05 by a
shared `claude-agent-acp--make-profile-backend' helper that installs
a closure as the backend's `auth-request-maker'; we drive the
closure off a created backend instance."
  (dolist (method '(openai-api-key codex-api-key chatgpt))
    (let* ((claude-agent-acp-codex-auth-method method)
           (backend (claude-agent-acp-codex-create
                     :session-key "cx" :cwd "/tmp"))
           (maker (claude-agent-acp-backend-auth-request-maker backend)))
      (should (equal (map-elt (funcall maker) 'methodId)
                     (symbol-name method))))))

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
  "When `claude-agent-acp-auto-approve' is t, handler picks the first option."
  (let* ((tokens nil)
         (backend (claude-agent-acp-backend--create))
         (claude-agent-acp-auto-approve t))
    (setf (claude-agent-acp-backend-callbacks backend)
          (list :on-token (lambda (text) (push text tokens))))
    (let* ((sent-data nil)
           (proc (start-process "test-acp-perm" nil "sleep" "10"))
           (client (claude-agent-jsonrpc-make-client proc)))
      (advice-add 'process-send-string :before
                  (lambda (_proc data) (push data sent-data))
                  '((name . test-acp-capture)))
      (unwind-protect
          (progn
            (setf (claude-agent-acp-backend-client backend) client)
            (claude-agent-acp--handle-request
             backend
             `((method . "session/request_permission")
               (id . 99)
               (params (toolCall (title . "Write output.txt")
                                 (toolCallId . "tc-5"))
                       (options . [((id . "allow-once") (label . "Allow once"))
                                   ((id . "deny") (label . "Deny"))]))))
            (should (>= (length sent-data) 1))
            (let* ((resp-json (json-read-from-string (car sent-data)))
                   (result (map-elt resp-json 'result))
                   (outcome (map-elt result 'outcome)))
              (should (equal (map-elt outcome 'outcome) "selected"))
              (should (equal (map-elt outcome 'optionId) "allow-once")))
            (should (= (length tokens) 1))
            (should (string-match-p "Permission.*Write output.txt" (car tokens))))
        (advice-remove 'process-send-string 'test-acp-capture)
        (delete-process proc)))))

(ert-deftest test-acp-permission-handler-prompts-user-by-default ()
  "With `claude-agent-acp-auto-approve' nil (default), prompts via completing-read."
  (let* ((backend (claude-agent-acp-backend--create))
         (claude-agent-acp-auto-approve nil)
         (prompt-seen nil))
    (setf (claude-agent-acp-backend-callbacks backend) nil)
    (let* ((sent-data nil)
           (proc (start-process "test-acp-perm-prompt" nil "sleep" "10"))
           (client (claude-agent-jsonrpc-make-client proc)))
      (advice-add 'process-send-string :before
                  (lambda (_proc data) (push data sent-data))
                  '((name . test-acp-capture-prompt)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt _coll &rest _)
                   (setq prompt-seen prompt)
                   "Deny")))
        (unwind-protect
            (progn
              (setf (claude-agent-acp-backend-client backend) client)
              (claude-agent-acp--handle-request
               backend
               `((method . "session/request_permission")
                 (id . 101)
                 (params (toolCall (title . "rm -rf /")
                                   (toolCallId . "tc-x"))
                         (options . [((id . "allow") (label . "Allow"))
                                     ((id . "deny") (label . "Deny"))]))))
              (should (stringp prompt-seen))
              (should (string-match-p "rm -rf" prompt-seen))
              (should (>= (length sent-data) 1))
              (let* ((resp-json (json-read-from-string (car sent-data)))
                     (result (map-elt resp-json 'result))
                     (outcome (map-elt result 'outcome)))
                (should (equal (map-elt outcome 'outcome) "selected"))
                (should (equal (map-elt outcome 'optionId) "deny"))))
          (advice-remove 'process-send-string 'test-acp-capture-prompt)
          (delete-process proc))))))

(ert-deftest test-acp-permission-handler-user-cancels ()
  "C-g at the permission prompt sends a cancelled outcome."
  (let* ((backend (claude-agent-acp-backend--create))
         (claude-agent-acp-auto-approve nil))
    (let* ((sent-data nil)
           (proc (start-process "test-acp-perm-quit" nil "sleep" "10"))
           (client (claude-agent-jsonrpc-make-client proc)))
      (advice-add 'process-send-string :before
                  (lambda (_proc data) (push data sent-data))
                  '((name . test-acp-capture-quit)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (signal 'quit nil))))
        (unwind-protect
            (progn
              (setf (claude-agent-acp-backend-client backend) client)
              (claude-agent-acp--handle-request
               backend
               `((method . "session/request_permission")
                 (id . 102)
                 (params (toolCall (title . "Read ~/.ssh/id_rsa"))
                         (options . [((id . "allow") (label . "Allow"))
                                     ((id . "deny") (label . "Deny"))]))))
              (should (>= (length sent-data) 1))
              (let* ((resp-json (json-read-from-string (car sent-data)))
                     (result (map-elt resp-json 'result))
                     (outcome (map-elt result 'outcome)))
                (should (equal (map-elt outcome 'outcome) "cancelled"))))
          (advice-remove 'process-send-string 'test-acp-capture-quit)
          (delete-process proc))))))

;;; Tests: Handshake via route-message

(ert-deftest test-acp-backend-handshake-and-prompt ()
  "Test handshake + prompt using injected responses via route-message."
  (let* ((tokens nil)
         (completed nil)
         (backend (claude-agent-acp-opencode-create :cwd "/tmp"))
         ;; Create a fake client
         (proc (start-process "test-acp-hs" nil "sleep" "10"))
         (client (claude-agent-jsonrpc-make-client proc)))
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
         (backend (claude-agent-acp-opencode-create :cwd "/tmp"))
         (proc (start-process "test-acp-tc" nil "sleep" "10"))
         (client (claude-agent-jsonrpc-make-client proc)))
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

;;; Tests: Verbose buffer integration

(ert-deftest test-acp-backend-verbose-buffer-returns-nil ()
  "ACP backend verbose-buffer method returns nil (uses shared system)."
  (let ((backend (claude-agent-acp-backend--create :session-key "test")))
    (should-not (claude-agent-backend-verbose-buffer backend))))

(ert-deftest test-acp-verbose-log-writes-to-shared-buffer ()
  "verbose-log writes timestamped entries to shared verbose buffer."
  (let* ((sk "/tmp/test::verbose-test")
         (backend (claude-agent-acp-backend--create :session-key sk)))
    ;; Create the shared verbose buffer
    (claude-agent--get-session-verbose-buffer sk)
    (unwind-protect
        (progn
          (claude-agent-acp--verbose-log backend "initialize OK")
          (let ((content (with-current-buffer
                             (gethash sk claude-agent--session-verbose-buffers)
                           (buffer-string))))
            ;; Should contain the log message
            (should (string-match-p "initialize OK" content))
            ;; Should contain a timestamp
            (should (string-match-p "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]" content))))
      ;; Cleanup
      (when-let* ((buf (gethash sk claude-agent--session-verbose-buffers)))
        (kill-buffer buf))
      (remhash sk claude-agent--session-verbose-buffers))))

(ert-deftest test-acp-notification-writes-to-verbose-buffer ()
  "Notification handler writes streaming text to verbose buffer."
  (let* ((sk "/tmp/test::verbose-notify")
         (backend (claude-agent-acp-backend--create :session-key sk))
         (tokens nil))
    (setf (claude-agent-acp-backend-callbacks backend)
          (list :on-token (lambda (text) (push text tokens))))
    (claude-agent--get-session-verbose-buffer sk)
    (unwind-protect
        (progn
          ;; agent_message_chunk
          (claude-agent-acp--handle-notification
           backend
           '((jsonrpc . "2.0") (method . "session/update")
             (params (update (sessionUpdate . "agent_message_chunk")
                             (content (text . "verbose test text"))))))
          (let ((content (with-current-buffer
                             (gethash sk claude-agent--session-verbose-buffers)
                           (buffer-string))))
            (should (string-match-p "verbose test text" content)))
          ;; tool_call
          (claude-agent-acp--handle-notification
           backend
           '((jsonrpc . "2.0") (method . "session/update")
             (params (update (sessionUpdate . "tool_call")
                             (title . "Bash ls")
                             (status . "running")))))
          (let ((content (with-current-buffer
                             (gethash sk claude-agent--session-verbose-buffers)
                           (buffer-string))))
            (should (string-match-p "Tool:" content))
            (should (string-match-p "Bash ls" content)))
          ;; tool_call_update completed
          (claude-agent-acp--handle-notification
           backend
           `((jsonrpc . "2.0") (method . "session/update")
             (params (update (sessionUpdate . "tool_call_update")
                             (title . "Bash ls")
                             (status . "completed")
                             (content . [((type . "text")
                                          (text . "file1.txt"))])))))
          (let ((content (with-current-buffer
                             (gethash sk claude-agent--session-verbose-buffers)
                           (buffer-string))))
            (should (string-match-p "Result:" content))
            (should (string-match-p "file1.txt" content))))
      (when-let* ((buf (gethash sk claude-agent--session-verbose-buffers)))
        (kill-buffer buf))
      (remhash sk claude-agent--session-verbose-buffers))))

(ert-deftest test-acp-verbose-completion-writes-duration ()
  "Completion writes elapsed duration to verbose buffer."
  (let* ((sk "/tmp/test::verbose-complete")
         (backend (claude-agent-acp-backend--create :session-key sk)))
    (claude-agent--get-session-verbose-buffer sk)
    (setf (claude-agent-acp-backend-prompt-start-time backend)
          (- (float-time) 2.5))  ;; 2.5 seconds ago
    (unwind-protect
        (progn
          (claude-agent-acp--verbose-completion backend)
          (let ((content (with-current-buffer
                             (gethash sk claude-agent--session-verbose-buffers)
                           (buffer-string))))
            (should (string-match-p "Complete:" content))
            (should (string-match-p "[0-9]+\\.[0-9]s" content)))
          ;; prompt-start-time should be cleared
          (should-not (claude-agent-acp-backend-prompt-start-time backend)))
      (when-let* ((buf (gethash sk claude-agent--session-verbose-buffers)))
        (kill-buffer buf))
      (remhash sk claude-agent--session-verbose-buffers))))

(ert-deftest test-acp-usage-update-stores-tokens ()
  "usage_update notification stores token counts in backend slots."
  (let* ((sk "/tmp/test::usage-tokens")
         (backend (claude-agent-acp-backend--create :session-key sk)))
    (claude-agent--get-session-verbose-buffer sk)
    (unwind-protect
        (progn
          (claude-agent-acp--handle-notification
           backend
           '((jsonrpc . "2.0") (method . "session/update")
             (params (update (sessionUpdate . "usage_update")
                             (usage (inputTokens . 1500)
                                    (outputTokens . 300))))))
          (should (= (claude-agent-acp-backend-input-tokens backend) 1500))
          (should (= (claude-agent-acp-backend-output-tokens backend) 300)))
      (when-let* ((buf (gethash sk claude-agent--session-verbose-buffers)))
        (kill-buffer buf))
      (remhash sk claude-agent--session-verbose-buffers))))

(ert-deftest test-acp-usage-update-stores-cost ()
  "usage_update notification stores cost data in backend slots."
  (let* ((sk "/tmp/test::usage-cost")
         (backend (claude-agent-acp-backend--create :session-key sk)))
    (claude-agent--get-session-verbose-buffer sk)
    (unwind-protect
        (progn
          (claude-agent-acp--handle-notification
           backend
           '((jsonrpc . "2.0") (method . "session/update")
             (params (update (sessionUpdate . "usage_update")
                             (cost (amount . 0.0042)
                                   (currency . "USD"))
                             (used . 28000)
                             (size . 200000)))))
          (should (= (claude-agent-acp-backend-cost-amount backend) 0.0042))
          (should (equal (claude-agent-acp-backend-cost-currency backend) "USD"))
          (should (= (claude-agent-acp-backend-context-used backend) 28000))
          (should (= (claude-agent-acp-backend-context-size backend) 200000)))
      (when-let* ((buf (gethash sk claude-agent--session-verbose-buffers)))
        (kill-buffer buf))
      (remhash sk claude-agent--session-verbose-buffers))))

(ert-deftest test-acp-verbose-completion-shows-cost-and-tokens ()
  "Completion line includes cost and token counts when available."
  (let* ((sk "/tmp/test::verbose-cost")
         (backend (claude-agent-acp-backend--create :session-key sk)))
    (claude-agent--get-session-verbose-buffer sk)
    (setf (claude-agent-acp-backend-prompt-start-time backend)
          (- (float-time) 3.0))
    (setf (claude-agent-acp-backend-cost-amount backend) 0.0042)
    (setf (claude-agent-acp-backend-cost-currency backend) "USD")
    (setf (claude-agent-acp-backend-input-tokens backend) 1200)
    (setf (claude-agent-acp-backend-output-tokens backend) 340)
    (unwind-protect
        (progn
          (claude-agent-acp--verbose-completion backend)
          (let ((content (with-current-buffer
                             (gethash sk claude-agent--session-verbose-buffers)
                           (buffer-string))))
            ;; Should contain elapsed time
            (should (string-match-p "[0-9]+\\.[0-9]s" content))
            ;; Should contain cost
            (should (string-match-p "\\$0\\.0042" content))
            ;; Should contain token counts
            (should (string-match-p "1\\.2k in" content))
            (should (string-match-p "340 out" content))))
      (when-let* ((buf (gethash sk claude-agent--session-verbose-buffers)))
        (kill-buffer buf))
      (remhash sk claude-agent--session-verbose-buffers))))

;;; Tests: fs/read_text_file + fs/write_text_file handlers

(ert-deftest test-acp-fs-read-returns-file-content ()
  "fs/read_text_file should read the file and respond with {content: ...}."
  (let* ((backend (claude-agent-acp-backend--create))
         (tmp (make-temp-file "acp-fs-read-" nil ".txt" "hello world\n")))
    (unwind-protect
        (let* ((sent-data nil)
               (proc (start-process "test-acp-fs-r" nil "sleep" "10"))
               (client (claude-agent-jsonrpc-make-client proc)))
          (advice-add 'process-send-string :before
                      (lambda (_proc data) (push data sent-data))
                      '((name . test-acp-fs-read-capture)))
          (unwind-protect
              (progn
                (setf (claude-agent-acp-backend-client backend) client)
                (claude-agent-acp--handle-request
                 backend
                 `((method . "fs/read_text_file")
                   (id . 11)
                   (params . ((path . ,tmp)))))
                (should (>= (length sent-data) 1))
                (let* ((resp (json-read-from-string (car sent-data)))
                       (result (map-elt resp 'result)))
                  (should result)
                  (should (equal (map-elt result 'content) "hello world\n"))))
            (advice-remove 'process-send-string 'test-acp-fs-read-capture)
            (delete-process proc)))
      (delete-file tmp))))

(ert-deftest test-acp-fs-read-missing-file-returns-error ()
  "Reading a missing file returns a JSON-RPC error, not a result."
  (let* ((backend (claude-agent-acp-backend--create))
         (sent-data nil)
         (proc (start-process "test-acp-fs-r2" nil "sleep" "10"))
         (client (claude-agent-jsonrpc-make-client proc)))
    (advice-add 'process-send-string :before
                (lambda (_proc data) (push data sent-data))
                '((name . test-acp-fs-read-miss)))
    (unwind-protect
        (progn
          (setf (claude-agent-acp-backend-client backend) client)
          (claude-agent-acp--handle-request
           backend
           `((method . "fs/read_text_file")
             (id . 12)
             (params . ((path . "/nonexistent/path/xyz")))))
          (should (>= (length sent-data) 1))
          (let* ((resp (json-read-from-string (car sent-data)))
                 (err (map-elt resp 'error)))
            (should err)
            (should (numberp (map-elt err 'code)))))
      (advice-remove 'process-send-string 'test-acp-fs-read-miss)
      (delete-process proc))))

(ert-deftest test-acp-fs-write-creates-file ()
  "fs/write_text_file should write the content and acknowledge."
  (let* ((backend (claude-agent-acp-backend--create))
         (tmp (make-temp-file "acp-fs-write-" nil ".txt"))
         (claude-agent-acp-fs-write-root nil))
    (delete-file tmp)  ;; start clean
    (unwind-protect
        (let* ((sent-data nil)
               (proc (start-process "test-acp-fs-w" nil "sleep" "10"))
               (client (claude-agent-jsonrpc-make-client proc)))
          (advice-add 'process-send-string :before
                      (lambda (_proc data) (push data sent-data))
                      '((name . test-acp-fs-write-capture)))
          (unwind-protect
              (progn
                (setf (claude-agent-acp-backend-client backend) client)
                (claude-agent-acp--handle-request
                 backend
                 `((method . "fs/write_text_file")
                   (id . 21)
                   (params . ((path . ,tmp)
                              (content . "new content\n")))))
                (should (>= (length sent-data) 1))
                (let* ((resp (json-read-from-string (car sent-data))))
                  (should (map-contains-key resp 'result)))
                (should (file-exists-p tmp))
                (with-temp-buffer
                  (insert-file-contents tmp)
                  (should (equal (buffer-string) "new content\n"))))
            (advice-remove 'process-send-string 'test-acp-fs-write-capture)
            (delete-process proc)))
      (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest test-acp-fs-write-respects-root-sandbox ()
  "With `claude-agent-acp-fs-write-root' set, writes outside it are rejected."
  (let* ((backend (claude-agent-acp-backend--create))
         (sandbox (make-temp-file "acp-sandbox-" t))
         (outside (make-temp-file "acp-outside-" nil ".txt"))
         (claude-agent-acp-fs-write-root sandbox))
    (delete-file outside)
    (unwind-protect
        (let* ((sent-data nil)
               (proc (start-process "test-acp-fs-sbox" nil "sleep" "10"))
               (client (claude-agent-jsonrpc-make-client proc)))
          (advice-add 'process-send-string :before
                      (lambda (_proc data) (push data sent-data))
                      '((name . test-acp-fs-sbox-capture)))
          (unwind-protect
              (progn
                (setf (claude-agent-acp-backend-client backend) client)
                (claude-agent-acp--handle-request
                 backend
                 `((method . "fs/write_text_file")
                   (id . 22)
                   (params . ((path . ,outside)
                              (content . "should-not-write")))))
                (should (>= (length sent-data) 1))
                (let* ((resp (json-read-from-string (car sent-data)))
                       (err (map-elt resp 'error)))
                  (should err)
                  (should (string-match-p "Refusing"
                                          (map-elt err 'message))))
                (should-not (file-exists-p outside)))
            (advice-remove 'process-send-string 'test-acp-fs-sbox-capture)
            (delete-process proc)))
      (when (file-exists-p outside) (delete-file outside))
      (when (file-directory-p sandbox) (delete-directory sandbox t)))))

;;; Tests: Session persistence slots

(ert-deftest test-acp-backend-persistence-slots ()
  "The backend exposes initial-session-id and save-session-id-fn slots."
  (let* ((saved nil)
         (save-fn (lambda (sid) (setq saved sid)))
         (backend (claude-agent-acp-opencode-create
                   :session-key "test"
                   :cwd "/tmp"
                   :initial-session-id "prior-sid-123"
                   :save-session-id-fn save-fn)))
    (should (equal (claude-agent-acp-backend-initial-session-id backend)
                   "prior-sid-123"))
    (should (functionp (claude-agent-acp-backend-save-session-id-fn backend)))
    (funcall (claude-agent-acp-backend-save-session-id-fn backend) "new-sid")
    (should (equal saved "new-sid"))))

;;; Tests: Re-entrancy guard (prevents callback overwrite)

(ert-deftest test-acp-query-rejects-while-busy ()
  "A second query while one is in-flight is rejected via on-error/on-complete.
Before the fix, the second query silently overwrote the first query's
callbacks, losing its completion/error notification forever."
  (let* ((backend (claude-agent-acp-backend--create))
         (sentinel-cb (list :on-error (lambda (_) nil)))
         (errors-2 nil)
         (complete-2 nil))
    (setf (claude-agent-acp-backend-active-query backend) t)
    (setf (claude-agent-acp-backend-callbacks backend) sentinel-cb)
    (unwind-protect
        (progn
          (claude-agent-backend-query
           backend "second"
           (list :on-error (lambda (e) (push e errors-2))
                 :on-complete (lambda (_) (setq complete-2 t))))
          ;; First query's callbacks must be untouched (identity check).
          (should (eq (claude-agent-acp-backend-callbacks backend)
                      sentinel-cb))
          ;; Second query's on-error fired with a "busy" message.
          (should (= 1 (length errors-2)))
          (should (string-match-p "busy" (car errors-2)))
          (should complete-2))
      (setf (claude-agent-acp-backend-active-query backend) nil))))

;;; Tests: session/load fallback to session/new

(ert-deftest test-acp-resume-or-new-falls-back-to-new ()
  "When session/load errors, we transparently call session/new."
  (let* ((saved-ids nil)
         (backend (claude-agent-acp-opencode-create
                   :session-key "resume-test"
                   :cwd "/tmp"
                   :initial-session-id "stale-sid"
                   :save-session-id-fn (lambda (sid) (push sid saved-ids))))
         (load-called nil)
         (new-called nil)
         (ready-called nil))
    (claude-agent--get-session-verbose-buffer "resume-test")
    (cl-letf (((symbol-function 'claude-agent-acp--load-session)
               (lambda (_b _sid _on-ok on-err)
                 (setq load-called t)
                 (funcall on-err "session not found")))
              ((symbol-function 'claude-agent-acp--new-session)
               (lambda (backend on-ok _on-err)
                 (setq new-called t)
                 (setf (claude-agent-acp-backend-session-id backend) "fresh-sid")
                 (funcall on-ok))))
      (unwind-protect
          (progn
            (claude-agent-acp--resume-or-new
             backend
             (lambda () (setq ready-called t))
             (lambda (err) (error "unexpected on-error: %s" err)))
            (should load-called)
            (should new-called)
            (should ready-called)
            (should (equal saved-ids '("fresh-sid"))))
        (when-let* ((buf (gethash "resume-test"
                                  claude-agent--session-verbose-buffers)))
          (kill-buffer buf))
        (remhash "resume-test" claude-agent--session-verbose-buffers)))))

;;; Tests: permission title sanitization (spoofing defence)

(ert-deftest test-acp-sanitize-agent-string-strips-controls ()
  "Control characters and escape sequences are removed."
  (should (equal (claude-agent-acp--sanitize-agent-string
                  "Read \x1b[2Jfile")
                 "Read [2Jfile"))
  (should (equal (claude-agent-acp--sanitize-agent-string "foo\nbar\tbaz")
                 "foobarbaz"))
  (should (equal (claude-agent-acp--sanitize-agent-string nil) "")))

(ert-deftest test-acp-sanitize-agent-string-truncates ()
  "Long titles are truncated to `claude-agent-acp-permission-title-max'."
  (let* ((claude-agent-acp-permission-title-max 20)
         (input (make-string 100 ?x))
         (out (claude-agent-acp--sanitize-agent-string input)))
    (should (= (length out) 21))  ;; 20 chars + ellipsis
    (should (string-suffix-p "…" out))))

;;; Tests: fs-write-root symlink sandbox

(ert-deftest test-acp-fs-write-path-inside-p-respects-symlinks ()
  "A symlink pointing outside the sandbox must be rejected."
  (let* ((sandbox (make-temp-file "acp-sandbox-" t))
         (outside-target (make-temp-file "acp-real-" nil ".txt"))
         ;; Symlink inside sandbox → outside.
         (link (expand-file-name "escape" sandbox)))
    (unwind-protect
        (progn
          (make-symbolic-link outside-target link)
          ;; The link path, when resolved, should NOT be considered inside
          ;; the sandbox.
          (should-not (claude-agent-acp--path-inside-p link sandbox))
          ;; A non-symlinked path inside the sandbox IS inside.
          (let ((legit (expand-file-name "file.txt" sandbox)))
            (should (claude-agent-acp--path-inside-p legit sandbox))))
      (when (file-exists-p link) (delete-file link))
      (when (file-exists-p outside-target) (delete-file outside-target))
      (when (file-directory-p sandbox) (delete-directory sandbox t)))))

(ert-deftest test-acp-fs-write-root-trailing-slash-normalization ()
  "/home/user/p must NOT match /home/user/project."
  (let* ((base (make-temp-file "acp-base-" t))
         (sibling-name (concat (file-name-nondirectory base) "evil"))
         (sibling (expand-file-name sibling-name
                                    (file-name-directory base))))
    (unwind-protect
        (progn
          (make-directory sibling)
          (let ((victim (expand-file-name "pwn.txt" sibling)))
            (should-not (claude-agent-acp--path-inside-p victim base))))
      (when (file-directory-p sibling) (delete-directory sibling t))
      (when (file-directory-p base) (delete-directory base t)))))

;;; Tests: fs-read sandbox

(ert-deftest test-acp-fs-read-sandbox-denies-outside-roots ()
  "With `claude-agent-acp-fs-read-roots' set, reads outside are blocked."
  (let* ((sandbox (make-temp-file "acp-read-sbox-" t))
         (inside-file (expand-file-name "ok.txt" sandbox))
         (outside-file (make-temp-file "acp-read-out-" nil ".txt" "secret"))
         (claude-agent-acp-fs-read-roots (list sandbox)))
    (unwind-protect
        (progn
          (with-temp-file inside-file (insert "ok content"))
          (should (claude-agent-acp--read-allowed-p inside-file))
          (should-not (claude-agent-acp--read-allowed-p outside-file)))
      (when (file-exists-p inside-file) (delete-file inside-file))
      (when (file-exists-p outside-file) (delete-file outside-file))
      (when (file-directory-p sandbox) (delete-directory sandbox t)))))

(ert-deftest test-acp-fs-read-sandbox-nil-allows-all ()
  "Nil `claude-agent-acp-fs-read-roots' permits reading any readable file."
  (let* ((tmp (make-temp-file "acp-read-all-" nil ".txt" "x"))
         (claude-agent-acp-fs-read-roots nil))
    (unwind-protect
        (should (claude-agent-acp--read-allowed-p tmp))
      (delete-file tmp))))

;;; Tests: Unknown request method returns -32601 instead of hanging

(ert-deftest test-acp-unknown-request-returns-method-not-found ()
  "Unknown server-to-client requests respond with -32601 (not silent drop)."
  (let* ((backend (claude-agent-acp-backend--create))
         (sent-data nil)
         (proc (start-process "test-acp-unknown" nil "sleep" "10"))
         (client (claude-agent-jsonrpc-make-client proc)))
    (advice-add 'process-send-string :before
                (lambda (_proc data) (push data sent-data))
                '((name . test-acp-unknown-capture)))
    (unwind-protect
        (progn
          (setf (claude-agent-acp-backend-client backend) client)
          (claude-agent-acp--handle-request
           backend
           '((method . "some/future/method") (id . 77) (params . nil)))
          (should (>= (length sent-data) 1))
          (let* ((resp (json-read-from-string (car sent-data)))
                 (err (map-elt resp 'error)))
            (should err)
            (should (= (map-elt err 'code) -32601))))
      (advice-remove 'process-send-string 'test-acp-unknown-capture)
      (delete-process proc))))

(ert-deftest test-acp-format-tokens-compact ()
  "Token formatter produces compact strings with k/m suffixes."
  (should (equal (claude-agent-acp--format-tokens-compact 500) "500"))
  (should (equal (claude-agent-acp--format-tokens-compact 1200) "1.2k"))
  (should (equal (claude-agent-acp--format-tokens-compact 15000) "15.0k"))
  (should (equal (claude-agent-acp--format-tokens-compact 1500000) "2m")))

(provide 'test-claude-agent-acp)
;;; test-claude-agent-acp.el ends here
