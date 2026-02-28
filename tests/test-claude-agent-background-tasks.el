;;; test-claude-agent-background-tasks.el --- Tests for background task tracking -*- lexical-binding: t; -*-

;;; Commentary:
;; Unit tests for the background task tracking feature.
;; Tests use actual data patterns from historical Claude Code logs.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Load the module being tested
(require 'claude-agent nil t)
(unless (featurep 'claude-agent)
  (load-file (expand-file-name "../claude-agent.el"
                               (file-name-directory load-file-name))))

(defmacro test-bg--with-mock-stdin (&rest body)
  "Execute BODY with mock process-live-p/process-send-eof.
Binds `closed' to track whether stdin was closed."
  (declare (indent 0) (debug t))
  `(let ((closed nil))
     (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
               ((symbol-function 'process-send-eof) (lambda (_) (setq closed t))))
       ,@body)))

;;; Test: Background Task Tracker

(ert-deftest test-background-task-tracker-launch ()
  "Test async task launch detection from PostToolUse hook."
  (clrhash claude-agent--pending-background-tasks)
  (claude-agent--background-task-tracker
   "toolu_01CDqrV8" nil nil
   '(:isAsync t :status "async_launched" :agentId "a0ea616"
     :description "Research Ralph workflow"
     :outputFile "/tmp/claude/-workspace/tasks/a0ea616.output")
   nil)
  (should (gethash "a0ea616" claude-agent--pending-background-tasks)))

(ert-deftest test-background-task-tracker-multiple-launches ()
  "Test tracking multiple async task launches."
  (clrhash claude-agent--pending-background-tasks)
  ;; Launch first task
  (claude-agent--background-task-tracker
   "toolu_01" nil nil
   '(:isAsync t :agentId "task1")
   nil)
  ;; Launch second task
  (claude-agent--background-task-tracker
   "toolu_02" nil nil
   '(:isAsync t :agentId "task2")
   nil)
  (should (= 2 (hash-table-count claude-agent--pending-background-tasks)))
  (should (gethash "task1" claude-agent--pending-background-tasks))
  (should (gethash "task2" claude-agent--pending-background-tasks)))

(ert-deftest test-background-task-tracker-running ()
  "Test task running state doesn't remove from tracking."
  (clrhash claude-agent--pending-background-tasks)
  (puthash "a0ea616" t claude-agent--pending-background-tasks)
  ;; TaskOutput with status=running
  (claude-agent--background-task-tracker
   "toolu_018Mp1Nq" nil nil
   '(:retrieval_status "timeout"
     :task (:task_id "a0ea616" :task_type "local_agent" :status "running"))
   nil)
  ;; Should still be tracked
  (should (gethash "a0ea616" claude-agent--pending-background-tasks)))

(ert-deftest test-background-task-tracker-completed ()
  "Test task completion removes from tracking."
  (clrhash claude-agent--pending-background-tasks)
  (puthash "a7febb9" t claude-agent--pending-background-tasks)
  ;; TaskOutput with status=completed
  (claude-agent--background-task-tracker
   "toolu_01G6f9Y8" nil nil
   '(:retrieval_status "success"
     :task (:task_id "a7febb9" :task_type "local_agent" :status "completed"))
   nil)
  ;; Should be removed
  (should-not (gethash "a7febb9" claude-agent--pending-background-tasks)))

(ert-deftest test-background-task-tracker-nil-result ()
  "Test tracker handles nil tool-use-result gracefully."
  (clrhash claude-agent--pending-background-tasks)
  ;; Should not error
  (claude-agent--background-task-tracker "toolu_123" nil nil nil nil)
  (should (= 0 (hash-table-count claude-agent--pending-background-tasks))))

(ert-deftest test-background-task-tracker-non-async ()
  "Test non-async results don't add to tracking."
  (clrhash claude-agent--pending-background-tasks)
  ;; Regular tool result without isAsync
  (claude-agent--background-task-tracker
   "toolu_123" "some result" nil
   '(:filenames ("/workspace/file.el") :durationMs 50)
   nil)
  (should (= 0 (hash-table-count claude-agent--pending-background-tasks))))

;;; Test: Bash Background Task Tracking (NEW - using actual event data)

(ert-deftest test-background-task-tracker-bash-launch ()
  "Test Bash background task launch detection.
Uses actual event data from verbose buffer session sdd-20260124-180353."
  (clrhash claude-agent--pending-background-tasks)
  ;; Actual Bash background launch result (from verbose buffer)
  (claude-agent--background-task-tracker
   "toolu_019K8M7SZr24P17tDHmxcbe1" nil nil
   '(:stdout "" :stderr "" :interrupted nil :isImage nil :backgroundTaskId "b8406fe")
   nil)
  (should (gethash "b8406fe" claude-agent--pending-background-tasks))
  (should (= 1 (hash-table-count claude-agent--pending-background-tasks))))

(ert-deftest test-background-task-tracker-bash-completion ()
  "Test Bash background task completion removes from tracking.
Uses actual TaskOutput result pattern."
  (clrhash claude-agent--pending-background-tasks)
  (puthash "b8406fe" t claude-agent--pending-background-tasks)
  ;; TaskOutput with status=completed for Bash task
  (claude-agent--background-task-tracker
   "toolu_01RPJxtBAeJ4VhmA92XnL7hm" nil nil
   '(:retrieval_status "success"
     :task (:task_id "b8406fe" :task_type "local_bash" :status "completed"
            :description "Run real LLM test with sample turns"))
   nil)
  ;; Should be removed
  (should-not (gethash "b8406fe" claude-agent--pending-background-tasks)))

(ert-deftest test-background-task-tracker-bash-running ()
  "Test Bash task running state doesn't remove from tracking.
Uses actual timeout pattern from verbose buffer."
  (clrhash claude-agent--pending-background-tasks)
  (puthash "b8406fe" t claude-agent--pending-background-tasks)
  ;; TaskOutput with status=running (timeout case)
  (claude-agent--background-task-tracker
   "toolu_019K8M7SZr24P17tDHmxcbe1" nil nil
   '(:retrieval_status "timeout"
     :task (:task_id "b8406fe" :task_type "local_bash" :status "running"
            :description "Run real LLM test with sample turns"))
   nil)
  ;; Should still be tracked
  (should (gethash "b8406fe" claude-agent--pending-background-tasks)))

(ert-deftest test-background-task-tracker-mixed-task-and-bash ()
  "Test tracking both Task subagent and Bash background simultaneously.
Uses actual event data from verbose buffer."
  (clrhash claude-agent--pending-background-tasks)
  ;; Launch Task subagent (actual data from session)
  (claude-agent--background-task-tracker
   "toolu_01LzRMXCp9YFivQQwHzC2ayK" nil nil
   '(:isAsync t :status "async_launched" :agentId "a4b3ecf"
     :description "Explore mega_code source"
     :prompt "Explore the mega_code source code structure...")
   nil)
  ;; Launch Bash background (actual data from session)
  (claude-agent--background-task-tracker
   "toolu_019K8M7SZr24P17tDHmxcbe1" nil nil
   '(:stdout "" :stderr "" :interrupted nil :isImage nil :backgroundTaskId "b8406fe")
   nil)
  ;; Both should be tracked
  (should (= 2 (hash-table-count claude-agent--pending-background-tasks)))
  (should (gethash "a4b3ecf" claude-agent--pending-background-tasks))
  (should (gethash "b8406fe" claude-agent--pending-background-tasks))

  ;; Complete Task subagent
  (claude-agent--background-task-tracker
   "toolu_01NJeYeAJ9iE3ep58dzQkzc8" nil nil
   '(:retrieval_status "success"
     :task (:task_id "a4b3ecf" :task_type "local_agent" :status "completed"))
   nil)
  (should (= 1 (hash-table-count claude-agent--pending-background-tasks)))
  (should-not (gethash "a4b3ecf" claude-agent--pending-background-tasks))
  (should (gethash "b8406fe" claude-agent--pending-background-tasks))

  ;; Complete Bash task
  (claude-agent--background-task-tracker
   "toolu_01RPJxtBAeJ4VhmA92XnL7hm" nil nil
   '(:retrieval_status "success"
     :task (:task_id "b8406fe" :task_type "local_bash" :status "completed"))
   nil)
  (should (= 0 (hash-table-count claude-agent--pending-background-tasks))))

(ert-deftest test-stdin-not-closed-with-pending-bash ()
  "Test stdin not closed when Bash background task is pending.
This is the critical fix - Bash tasks must prevent early exit."
  (clrhash claude-agent--pending-background-tasks)
  ;; Launch Bash background task
  (claude-agent--background-task-tracker
   "toolu_bg" nil nil
   '(:stdout "" :stderr "" :backgroundTaskId "b8406fe")
   nil)
  ;; Result message arrives - stdin should NOT close
  (test-bg--with-mock-stdin
    (claude-agent--maybe-close-stdin 'mock-process '(:type "result"))
    (should-not closed)))

;;; Test: Has Pending Background Tasks

(ert-deftest test-has-pending-background-tasks-empty ()
  "Test has-pending returns nil when no tasks."
  (clrhash claude-agent--pending-background-tasks)
  (should-not (claude-agent--has-pending-background-tasks-p)))

(ert-deftest test-has-pending-background-tasks-with-tasks ()
  "Test has-pending returns t when tasks exist."
  (clrhash claude-agent--pending-background-tasks)
  (puthash "task1" t claude-agent--pending-background-tasks)
  (should (claude-agent--has-pending-background-tasks-p)))

;;; Test: Maybe Close Stdin

(ert-deftest test-maybe-close-stdin-with-pending ()
  "Test stdin not closed when background tasks pending."
  (clrhash claude-agent--pending-background-tasks)
  (puthash "task1" t claude-agent--pending-background-tasks)
  (test-bg--with-mock-stdin
    (claude-agent--maybe-close-stdin 'mock-process '(:type "result"))
    (should-not closed)))

(ert-deftest test-maybe-close-stdin-no-pending ()
  "Test stdin closed when no background tasks pending."
  (clrhash claude-agent--pending-background-tasks)
  (let ((claude-agent-stdin-close-delay 0))  ; Immediate close for testing
    (test-bg--with-mock-stdin
      (claude-agent--maybe-close-stdin 'mock-process '(:type "result"))
      (should closed))))

(ert-deftest test-maybe-close-stdin-non-result ()
  "Test non-result messages don't trigger close."
  (clrhash claude-agent--pending-background-tasks)
  (test-bg--with-mock-stdin
    (claude-agent--maybe-close-stdin 'mock-process '(:type "assistant"))
    (claude-agent--maybe-close-stdin 'mock-process '(:type "user"))
    (should-not closed)))

;;; Test: Dispatch Functions

(ert-deftest test-dispatch-pre-tool-use ()
  "Test dispatch-pre-tool-use calls hook with correct args."
  (let ((hook-calls nil))
    (cl-letf (((symbol-function 'run-hook-with-args)
               (lambda (&rest args) (push args hook-calls))))
      (claude-agent--dispatch-pre-tool-use
       '(:type "assistant"
         :message (:content ((:type "tool_use"
                              :name "Read"
                              :input (:file_path "/test.el")
                              :id "toolu_123"))))
       'mock-state))
    (should (= 1 (length hook-calls)))
    (let ((call (car hook-calls)))
      (should (eq (nth 0 call) 'claude-agent-pre-tool-use-functions))
      (should (equal (nth 1 call) "Read"))
      (should (equal (nth 2 call) '(:file_path "/test.el")))
      (should (equal (nth 3 call) "toolu_123"))
      (should (eq (nth 4 call) 'mock-state)))))

(ert-deftest test-dispatch-pre-tool-use-multiple-tools ()
  "Test dispatch-pre-tool-use handles multiple tool_use blocks."
  (let ((hook-calls nil))
    (cl-letf (((symbol-function 'run-hook-with-args)
               (lambda (&rest args) (push args hook-calls))))
      (claude-agent--dispatch-pre-tool-use
       '(:type "assistant"
         :message (:content ((:type "tool_use" :name "Read" :id "t1")
                             (:type "text" :text "Some text")
                             (:type "tool_use" :name "Write" :id "t2"))))
       'mock-state))
    ;; Should call hook twice (once per tool_use)
    (should (= 2 (length hook-calls)))))

(ert-deftest test-dispatch-pre-tool-use-no-tool-use ()
  "Test dispatch-pre-tool-use handles messages without tool_use."
  (let ((hook-calls nil))
    (cl-letf (((symbol-function 'run-hook-with-args)
               (lambda (&rest args) (push args hook-calls))))
      (claude-agent--dispatch-pre-tool-use
       '(:type "assistant"
         :message (:content "plain text response"))
       'mock-state))
    ;; Should not call hook
    (should (= 0 (length hook-calls)))))

(ert-deftest test-dispatch-post-tool-use ()
  "Test dispatch-post-tool-use calls hook with correct args.
Uses :tool_use_result (snake_case) matching actual JSON from CLI."
  (let ((hook-calls nil))
    (cl-letf (((symbol-function 'run-hook-with-args)
               (lambda (&rest args) (push args hook-calls))))
      (claude-agent--dispatch-post-tool-use
       '(:type "user"
         :message (:content ((:type "tool_result"
                              :tool_use_id "toolu_123"
                              :content "file contents"
                              :is_error nil)))
         :tool_use_result (:isAsync t :agentId "abc"))
       'mock-state))
    (should (= 1 (length hook-calls)))
    (let ((call (car hook-calls)))
      (should (eq (nth 0 call) 'claude-agent-post-tool-use-functions))
      (should (equal (nth 1 call) "toolu_123"))
      (should (equal (nth 2 call) "file contents"))
      (should (eq (nth 3 call) nil))  ; is_error
      (should (equal (nth 4 call) '(:isAsync t :agentId "abc")))
      (should (eq (nth 5 call) 'mock-state)))))

(ert-deftest test-dispatch-post-tool-use-no-tool-result ()
  "Test dispatch-post-tool-use handles messages without tool_result."
  (let ((hook-calls nil))
    (cl-letf (((symbol-function 'run-hook-with-args)
               (lambda (&rest args) (push args hook-calls))))
      (claude-agent--dispatch-post-tool-use
       '(:type "user"
         :message (:content "plain text"))
       'mock-state))
    ;; Should not call hook
    (should (= 0 (length hook-calls)))))

;;; Test: JSON Key Name Fix (tool_use_result vs toolUseResult)
;;;
;;; The bug: dispatch-post-tool-use was looking for :toolUseResult (camelCase)
;;; but json-read-from-string with json-key-type 'keyword converts
;;; "tool_use_result" to :tool_use_result (snake_case).

(ert-deftest test-dispatch-post-tool-use-json-key-format ()
  "Test that dispatch uses :tool_use_result (snake_case) matching JSON parsing.
This is the critical fix - JSON key names use underscores, not camelCase."
  (let ((hook-calls nil))
    (cl-letf (((symbol-function 'run-hook-with-args)
               (lambda (&rest args) (push args hook-calls))))
      ;; Simulate parsed JSON from actual CLI output
      ;; JSON: {\"tool_use_result\": {\"backgroundTaskId\": \"bee9495\"}}
      ;; After json-read: (:tool_use_result (:backgroundTaskId "bee9495"))
      (claude-agent--dispatch-post-tool-use
       '(:type "user"
         :message (:content ((:type "tool_result"
                              :tool_use_id "toolu_01Test"
                              :content "Command running in background"
                              :is_error nil)))
         :tool_use_result (:stdout "" :stderr "" :interrupted nil
                           :isImage nil :backgroundTaskId "bee9495"))
       'mock-state))
    ;; Hook should be called with the tool_use_result data
    (should (= 1 (length hook-calls)))
    (let* ((call (car hook-calls))
           (tool-use-result (nth 4 call)))
      ;; Verify backgroundTaskId is passed through correctly
      (should (equal (plist-get tool-use-result :backgroundTaskId) "bee9495")))))

(ert-deftest test-json-parsing-produces-snake-case-keys ()
  "Verify that json-read-from-string produces :snake_case keywords.
This confirms the fix is correct for the actual JSON format."
  (let* ((json-object-type 'plist)
         (json-array-type 'list)
         (json-key-type 'keyword)
         ;; Actual JSON from Claude CLI verbose buffer
         (json-str "{\"type\":\"user\",\"tool_use_result\":{\"backgroundTaskId\":\"test123\"}}")
         (parsed (json-read-from-string json-str)))
    ;; Key should be :tool_use_result NOT :toolUseResult
    (should (plist-get parsed :tool_use_result))
    (should-not (plist-get parsed :toolUseResult))
    ;; Nested key backgroundTaskId uses camelCase in original JSON
    (let ((result (plist-get parsed :tool_use_result)))
      (should (equal (plist-get result :backgroundTaskId) "test123")))))

;;; Test: Pending Control Request Tracking
;;;
;;; Control requests (permission prompts) must be tracked to prevent
;;; premature stdin close while awaiting control_response.

(ert-deftest test-control-request-tracking-basic ()
  "Test basic control request tracking functions."
  (claude-agent--clear-pending-control-requests)
  ;; Initially empty
  (should-not (claude-agent--has-pending-control-requests-p))

  ;; Track a request
  (claude-agent--track-control-request "req-001")
  (should (claude-agent--has-pending-control-requests-p))

  ;; Track another
  (claude-agent--track-control-request "req-002")
  (should (= 2 (hash-table-count claude-agent--pending-control-requests)))

  ;; Untrack one
  (claude-agent--untrack-control-request "req-001")
  (should (claude-agent--has-pending-control-requests-p))

  ;; Untrack the other
  (claude-agent--untrack-control-request "req-002")
  (should-not (claude-agent--has-pending-control-requests-p)))

(ert-deftest test-control-request-clear ()
  "Test clearing all pending control requests."
  (claude-agent--clear-pending-control-requests)
  (claude-agent--track-control-request "req-001")
  (claude-agent--track-control-request "req-002")
  (should (= 2 (hash-table-count claude-agent--pending-control-requests)))

  (claude-agent--clear-pending-control-requests)
  (should-not (claude-agent--has-pending-control-requests-p))
  (should (= 0 (hash-table-count claude-agent--pending-control-requests))))

(ert-deftest test-stdin-not-closed-with-pending-control-request ()
  "Test stdin not closed when control request is pending response.
This is the critical fix for the early exit bug."
  (clrhash claude-agent--pending-background-tasks)
  (claude-agent--clear-pending-control-requests)
  ;; Simulate pending control request (permission prompt awaiting response)
  (claude-agent--track-control-request "c8b57b4d-8e9e-4010-b2ce-bfa736df4ea2")
  ;; Result message arrives - stdin should NOT close
  (let ((claude-agent-stdin-close-delay 0))
    (test-bg--with-mock-stdin
      (claude-agent--maybe-close-stdin 'mock-process '(:type "result"))
      (should-not closed))))

(ert-deftest test-stdin-closes-after-control-response ()
  "Test stdin closes after all control requests are resolved."
  (clrhash claude-agent--pending-background-tasks)
  (claude-agent--clear-pending-control-requests)
  (let ((claude-agent-stdin-close-delay 0))
    ;; Track a control request
    (claude-agent--track-control-request "req-001")
    ;; Result arrives - should NOT close
    (test-bg--with-mock-stdin
      (claude-agent--maybe-close-stdin 'mock-process '(:type "result"))
      (should-not closed))
    ;; Response sent - untrack
    (claude-agent--untrack-control-request "req-001")
    ;; Now result should close stdin
    (test-bg--with-mock-stdin
      (claude-agent--maybe-close-stdin 'mock-process '(:type "result"))
      (should closed))))


(provide 'test-claude-agent-background-tasks)
;;; test-claude-agent-background-tasks.el ends here
