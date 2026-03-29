;;; test-permission-round-trip.el --- Permission control_request round-trip tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for the permission round-trip: control_request (can_use_tool)
;; arrives from CLI → handle-control-request dispatches to permission
;; functions → send-control-response sends back → pending tracking lifecycle.
;;
;; Tests verify:
;; - Tracking lifecycle (tracked on receive, untracked on response)
;; - Permission allow/deny behavior
;; - Permission function error → deny response
;; - hook_callback subtype handling
;; - Unsupported subtype → error response
;; - Dead process handling (response dropped, still untracked)

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-agent)

;;; Helpers

(defvar test-perm--sent-data nil
  "Accumulates data sent to mock process via process-send-string.")

(defun test-perm--make-mock-process (&optional request-id session-key)
  "Create a mock process with attached process-state.
REQUEST-ID is the owning query's request ID (default \"req-test\").
SESSION-KEY is the session key (default \"test-perm-session\")."
  (let* ((req-id (or request-id "req-test"))
         (sess-key (or session-key "test-perm-session"))
         (state (claude-agent--make-process-state
                 :request-id req-id
                 :session-key sess-key
                 :ready t))
         (process (start-process "test-perm-mock" nil "true")))
    (process-put process 'claude-agent-state state)
    (process-put process 'claude-agent-trace-ctx nil)
    process))

(defmacro test-perm--with-clean-state (&rest body)
  "Execute BODY with clean pending-control-requests table.
Restores original table after execution."
  (declare (indent 0))
  `(let ((claude-agent--pending-control-requests (make-hash-table :test 'equal)))
     ,@body))

(defun test-perm--make-can-use-tool-request (request-id tool-name &optional tool-input)
  "Build a can_use_tool control_request plist.
REQUEST-ID: string ID for the request.
TOOL-NAME: string like \"Read\", \"Bash\".
TOOL-INPUT: optional plist of tool arguments."
  (list :type "control_request"
        :request_id request-id
        :request (list :subtype "can_use_tool"
                       :tool_name tool-name
                       :input (or tool-input (list :file_path "/tmp/test.txt"))
                       :permission_suggestions nil)))

(defun test-perm--make-hook-callback-request (request-id)
  "Build a hook_callback control_request plist."
  (list :type "control_request"
        :request_id request-id
        :request (list :subtype "hook_callback")))

(defun test-perm--make-unsupported-request (request-id subtype)
  "Build a control_request with unsupported SUBTYPE."
  (list :type "control_request"
        :request_id request-id
        :request (list :subtype subtype)))

;;; Tests: can_use_tool Allow Round-trip

(ert-deftest test-perm-allow-round-trip ()
  "can_use_tool with allow: request tracked, permission runs, response sent, untracked."
  :tags '(:unit :permission :protocol)
  (test-perm--with-clean-state
    (let* ((permission-called nil)
           (permission-tool nil)
           (permission-input nil)
           (sent-json nil)
           (process (test-perm--make-mock-process))
           (request (test-perm--make-can-use-tool-request "ctrl-001" "Read"
                      (list :file_path "/home/user/file.txt")))
           (claude-agent-permission-functions
            (list (lambda (tool-name tool-input _ctx)
                    (setq permission-called t
                          permission-tool tool-name
                          permission-input tool-input)
                    '(:behavior "allow")))))
      (unwind-protect
          (progn
            ;; Mock process-send-string to capture output
            (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'process-send-string)
                       (lambda (_proc data) (setq sent-json data)))
                      ((symbol-function 'claude-agent--drain-output) #'ignore))
              (claude-agent--handle-control-request process request))

            ;; Permission function was called with correct arguments
            (should permission-called)
            (should (equal permission-tool "Read"))
            (should (equal (plist-get permission-input :file_path) "/home/user/file.txt"))

            ;; Response was sent as JSON
            (should sent-json)
            (let* ((json-object-type 'plist)
                   (json-key-type 'keyword)
                   (parsed (json-read-from-string (string-trim sent-json))))
              (should (equal (plist-get parsed :type) "control_response"))
              (let ((resp (plist-get parsed :response)))
                (should (equal (plist-get resp :subtype) "success"))
                (should (equal (plist-get resp :request_id) "ctrl-001"))
                (let ((resp-data (plist-get resp :response)))
                  (should (equal (plist-get resp-data :behavior) "allow")))))

            ;; Request was untracked (no longer pending)
            (should-not (gethash "ctrl-001" claude-agent--pending-control-requests)))
        (ignore-errors (delete-process process))))))

;;; Tests: can_use_tool Deny Round-trip

(ert-deftest test-perm-deny-round-trip ()
  "can_use_tool with deny: response contains deny behavior and message."
  :tags '(:unit :permission :protocol)
  (test-perm--with-clean-state
    (let* ((sent-json nil)
           (process (test-perm--make-mock-process))
           (request (test-perm--make-can-use-tool-request "ctrl-002" "Bash"
                      (list :command "rm -rf /")))
           (claude-agent-permission-functions
            (list (lambda (_tool _input _ctx)
                    '(:behavior "deny" :message "Dangerous command blocked")))))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'process-send-string)
                       (lambda (_proc data) (setq sent-json data)))
                      ((symbol-function 'claude-agent--drain-output) #'ignore))
              (claude-agent--handle-control-request process request))

            ;; Response has deny behavior
            (should sent-json)
            (let* ((json-object-type 'plist)
                   (json-key-type 'keyword)
                   (parsed (json-read-from-string (string-trim sent-json))))
              (let* ((resp (plist-get parsed :response))
                     (resp-data (plist-get resp :response)))
                (should (equal (plist-get resp-data :behavior) "deny"))
                (should (equal (plist-get resp-data :message) "Dangerous command blocked"))))

            ;; Request untracked
            (should-not (gethash "ctrl-002" claude-agent--pending-control-requests)))
        (ignore-errors (delete-process process))))))

;;; Tests: Permission Function Error

(ert-deftest test-perm-error-sends-deny ()
  "Permission function error: SECURITY — deny on error, not allow."
  :tags '(:unit :permission :protocol :security)
  (test-perm--with-clean-state
    (let* ((sent-json nil)
           (process (test-perm--make-mock-process))
           (request (test-perm--make-can-use-tool-request "ctrl-003" "Write"))
           (claude-agent-permission-functions
            (list (lambda (_tool _input _ctx)
                    (error "Permission database offline")))))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'process-send-string)
                       (lambda (_proc data) (setq sent-json data)))
                      ((symbol-function 'claude-agent--drain-output) #'ignore))
              (claude-agent--handle-control-request process request))

            ;; Response has deny behavior (security: deny on error)
            (should sent-json)
            (let* ((json-object-type 'plist)
                   (json-key-type 'keyword)
                   (parsed (json-read-from-string (string-trim sent-json))))
              (let* ((resp (plist-get parsed :response))
                     (resp-data (plist-get resp :response)))
                (should (equal (plist-get resp-data :behavior) "deny"))))

            ;; Still untracked
            (should-not (gethash "ctrl-003" claude-agent--pending-control-requests)))
        (ignore-errors (delete-process process))))))

;;; Tests: Tracking Lifecycle

(ert-deftest test-perm-tracking-lifecycle ()
  "Request is tracked BEFORE permission runs and untracked AFTER response sent."
  :tags '(:unit :permission :protocol :lifecycle)
  (test-perm--with-clean-state
    (let* ((tracked-during-permission nil)
           (process (test-perm--make-mock-process))
           (request (test-perm--make-can-use-tool-request "ctrl-004" "Grep"))
           (claude-agent-permission-functions
            (list (lambda (_tool _input _ctx)
                    ;; Observe: request should be tracked at this point
                    (setq tracked-during-permission
                          (gethash "ctrl-004" claude-agent--pending-control-requests))
                    '(:behavior "allow")))))
      (unwind-protect
          (progn
            ;; Before: not tracked
            (should-not (gethash "ctrl-004" claude-agent--pending-control-requests))

            (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'process-send-string) #'ignore)
                      ((symbol-function 'claude-agent--drain-output) #'ignore))
              (claude-agent--handle-control-request process request))

            ;; During: was tracked when permission function ran
            (should tracked-during-permission)
            ;; Owner should be the request-id from the process state
            (should (equal tracked-during-permission "req-test"))

            ;; After: untracked
            (should-not (gethash "ctrl-004" claude-agent--pending-control-requests)))
        (ignore-errors (delete-process process))))))

;;; Tests: hook_callback Subtype

(ert-deftest test-perm-hook-callback-success ()
  "hook_callback subtype returns success response."
  :tags '(:unit :permission :protocol)
  (test-perm--with-clean-state
    (let* ((sent-json nil)
           (process (test-perm--make-mock-process))
           (request (test-perm--make-hook-callback-request "ctrl-005")))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'process-send-string)
                       (lambda (_proc data) (setq sent-json data)))
                      ((symbol-function 'claude-agent--drain-output) #'ignore))
              (claude-agent--handle-control-request process request))

            ;; Response sent with success subtype
            (should sent-json)
            (let* ((json-object-type 'plist)
                   (json-key-type 'keyword)
                   (parsed (json-read-from-string (string-trim sent-json))))
              (let ((resp (plist-get parsed :response)))
                (should (equal (plist-get resp :subtype) "success"))
                (should (equal (plist-get resp :request_id) "ctrl-005"))))

            ;; Untracked
            (should-not (gethash "ctrl-005" claude-agent--pending-control-requests)))
        (ignore-errors (delete-process process))))))

;;; Tests: Unsupported Subtype

(ert-deftest test-perm-unsupported-subtype-error ()
  "Unsupported subtype sends error response."
  :tags '(:unit :permission :protocol)
  (test-perm--with-clean-state
    (let* ((sent-json nil)
           (process (test-perm--make-mock-process))
           (request (test-perm--make-unsupported-request "ctrl-006" "unknown_thing")))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'process-send-string)
                       (lambda (_proc data) (setq sent-json data)))
                      ((symbol-function 'claude-agent--drain-output) #'ignore))
              (claude-agent--handle-control-request process request))

            ;; Response sent with error subtype
            (should sent-json)
            (let* ((json-object-type 'plist)
                   (json-key-type 'keyword)
                   (parsed (json-read-from-string (string-trim sent-json))))
              (let ((resp (plist-get parsed :response)))
                (should (equal (plist-get resp :subtype) "error"))
                (should (equal (plist-get resp :request_id) "ctrl-006"))
                ;; Error message should mention the unsupported subtype
                (let ((resp-data (plist-get resp :response)))
                  (should (stringp (plist-get resp-data :error)))
                  (should (string-match-p "unknown_thing"
                                          (plist-get resp-data :error))))))

            ;; Still untracked after error response
            (should-not (gethash "ctrl-006" claude-agent--pending-control-requests)))
        (ignore-errors (delete-process process))))))

;;; Tests: Dead Process

(ert-deftest test-perm-dead-process-drops-response ()
  "When process dies before response can be sent, response is dropped but tracking cleaned up."
  :tags '(:unit :permission :protocol :regression)
  (test-perm--with-clean-state
    (let* ((send-called nil)
           (process (test-perm--make-mock-process))
           (request (test-perm--make-can-use-tool-request "ctrl-007" "Read"))
           (claude-agent-permission-functions
            (list (lambda (_tool _input _ctx) '(:behavior "allow")))))
      (unwind-protect
          (progn
            ;; Process is dead — process-send-string should NOT be called
            (cl-letf (((symbol-function 'process-live-p) (lambda (_) nil))
                      ((symbol-function 'process-send-string)
                       (lambda (_proc _data) (setq send-called t)))
                      ((symbol-function 'claude-agent--drain-output) #'ignore))
              (claude-agent--handle-control-request process request))

            ;; Response was NOT sent (process was dead)
            (should-not send-called)

            ;; But request was still untracked (no leak)
            (should-not (gethash "ctrl-007" claude-agent--pending-control-requests)))
        (ignore-errors (delete-process process))))))

;;; Tests: Context Propagation

(ert-deftest test-perm-context-includes-session-and-suggestions ()
  "Permission functions receive session-id and permission_suggestions in context."
  :tags '(:unit :permission :protocol)
  (test-perm--with-clean-state
    (let* ((received-ctx nil)
           (process (test-perm--make-mock-process))
           (request (list :type "control_request"
                          :request_id "ctrl-008"
                          :request (list :subtype "can_use_tool"
                                        :tool_name "Bash"
                                        :input (list :command "ls")
                                        :permission_suggestions
                                        (list (list :type "allow_once")))))
           (claude-agent-permission-functions
            (list (lambda (_tool _input ctx)
                    (setq received-ctx ctx)
                    '(:behavior "allow")))))
      ;; Set process properties that handle-control-request reads
      (process-put process :session-id "sess-abc-123")
      (process-put process :context-label "test-context")
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'process-send-string) #'ignore)
                      ((symbol-function 'claude-agent--drain-output) #'ignore))
              (claude-agent--handle-control-request process request))

            ;; Context should include session-id
            (should received-ctx)
            (should (equal (plist-get received-ctx :session-id) "sess-abc-123"))
            (should (equal (plist-get received-ctx :context-label) "test-context"))
            ;; Suggestions passed through
            (should (plist-get received-ctx :suggestions)))
        (ignore-errors (delete-process process))))))

;;; Tests: Updated Input Pass-Through

(ert-deftest test-perm-updated-input-forwarded ()
  "Permission function can modify tool input via :updated-input."
  :tags '(:unit :permission :protocol)
  (test-perm--with-clean-state
    (let* ((sent-json nil)
           (process (test-perm--make-mock-process))
           (request (test-perm--make-can-use-tool-request "ctrl-009" "Write"
                      (list :file_path "/etc/passwd" :content "hacked")))
           (claude-agent-permission-functions
            (list (lambda (_tool _input _ctx)
                    '(:behavior "allow"
                      :updated-input (:file_path "/tmp/safe.txt" :content "safe"))))))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'process-send-string)
                       (lambda (_proc data) (setq sent-json data)))
                      ((symbol-function 'claude-agent--drain-output) #'ignore))
              (claude-agent--handle-control-request process request))

            ;; Response should contain updatedInput from permission result
            (should sent-json)
            (let* ((json-object-type 'plist)
                   (json-key-type 'keyword)
                   (parsed (json-read-from-string (string-trim sent-json))))
              (let* ((resp (plist-get parsed :response))
                     (resp-data (plist-get resp :response)))
                (should (equal (plist-get resp-data :behavior) "allow"))
                ;; updatedInput should have the modified path
                (let ((updated (plist-get resp-data :updatedInput)))
                  (should updated)
                  (should (equal (plist-get updated :file_path) "/tmp/safe.txt"))))))
        (ignore-errors (delete-process process))))))

;;; Tests: Multiple Concurrent Requests

(ert-deftest test-perm-concurrent-requests-independent ()
  "Multiple pending control requests tracked independently."
  :tags '(:unit :permission :protocol)
  (test-perm--with-clean-state
    (let* ((process-a (test-perm--make-mock-process "req-A" "session-A"))
           (process-b (test-perm--make-mock-process "req-B" "session-B"))
           (request-a (test-perm--make-can-use-tool-request "ctrl-A1" "Read"))
           (request-b (test-perm--make-can-use-tool-request "ctrl-B1" "Write"))
           (claude-agent-permission-functions
            (list (lambda (_tool _input _ctx) '(:behavior "allow")))))
      (unwind-protect
          (progn
            ;; Track request A but don't respond yet (simulate slow permission)
            (claude-agent--track-control-request "ctrl-A1" "req-A")
            (should (gethash "ctrl-A1" claude-agent--pending-control-requests))

            ;; Handle request B fully — should not affect A's tracking
            (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'process-send-string) #'ignore)
                      ((symbol-function 'claude-agent--drain-output) #'ignore))
              (claude-agent--handle-control-request process-b request-b))

            ;; B is untracked
            (should-not (gethash "ctrl-B1" claude-agent--pending-control-requests))
            ;; A is still tracked (independent)
            (should (gethash "ctrl-A1" claude-agent--pending-control-requests))
            ;; A's owner is correct
            (should (equal "req-A" (gethash "ctrl-A1" claude-agent--pending-control-requests)))

            ;; Clean up A
            (claude-agent--untrack-control-request "ctrl-A1")
            (should-not (claude-agent--has-pending-control-requests-p)))
        (ignore-errors (delete-process process-a))
        (ignore-errors (delete-process process-b))))))

(provide 'test-permission-round-trip)
;;; test-permission-round-trip.el ends here
