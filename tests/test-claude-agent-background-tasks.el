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
  (let ((closed nil))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'process-send-eof) (lambda (_) (setq closed t))))
      (claude-agent--maybe-close-stdin 'mock-process '(:type "result")))
    (should-not closed)))

(ert-deftest test-maybe-close-stdin-no-pending ()
  "Test stdin closed when no background tasks pending."
  (clrhash claude-agent--pending-background-tasks)
  (let ((closed nil))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'process-send-eof) (lambda (_) (setq closed t))))
      (claude-agent--maybe-close-stdin 'mock-process '(:type "result")))
    (should closed)))

(ert-deftest test-maybe-close-stdin-non-result ()
  "Test non-result messages don't trigger close."
  (clrhash claude-agent--pending-background-tasks)
  (let ((closed nil))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'process-send-eof) (lambda (_) (setq closed t))))
      (claude-agent--maybe-close-stdin 'mock-process '(:type "assistant"))
      (claude-agent--maybe-close-stdin 'mock-process '(:type "user")))
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
  "Test dispatch-post-tool-use calls hook with correct args."
  (let ((hook-calls nil))
    (cl-letf (((symbol-function 'run-hook-with-args)
               (lambda (&rest args) (push args hook-calls))))
      (claude-agent--dispatch-post-tool-use
       '(:type "user"
         :message (:content ((:type "tool_result"
                              :tool_use_id "toolu_123"
                              :content "file contents"
                              :is_error nil)))
         :toolUseResult (:isAsync t :agentId "abc"))
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

;;; Test: Integration - Full Flow

(ert-deftest test-background-task-full-flow ()
  "Test complete background task lifecycle."
  (clrhash claude-agent--pending-background-tasks)

  ;; 1. Task launched
  (claude-agent--background-task-tracker
   "toolu_01" nil nil
   '(:isAsync t :agentId "agent123")
   nil)
  (should (claude-agent--has-pending-background-tasks-p))

  ;; 2. First result - stdin should NOT close
  (let ((closed nil))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'process-send-eof) (lambda (_) (setq closed t))))
      (claude-agent--maybe-close-stdin 'mock-process '(:type "result")))
    (should-not closed))

  ;; 3. TaskOutput shows running - still pending
  (claude-agent--background-task-tracker
   "toolu_02" nil nil
   '(:task (:task_id "agent123" :status "running"))
   nil)
  (should (claude-agent--has-pending-background-tasks-p))

  ;; 4. TaskOutput shows completed - removed
  (claude-agent--background-task-tracker
   "toolu_03" nil nil
   '(:task (:task_id "agent123" :status "completed"))
   nil)
  (should-not (claude-agent--has-pending-background-tasks-p))

  ;; 5. Now result should close stdin
  (let ((closed nil))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'process-send-eof) (lambda (_) (setq closed t))))
      (claude-agent--maybe-close-stdin 'mock-process '(:type "result")))
    (should closed)))

(provide 'test-claude-agent-background-tasks)
;;; test-claude-agent-background-tasks.el ends here
