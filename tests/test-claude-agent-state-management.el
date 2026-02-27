;;; test-claude-agent-state-management.el --- Tests for query lifecycle state management -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for bugs in query lifecycle state management:
;;
;; Bug 1: sentinel-handle-abnormal-exit doesn't unregister from active-queries
;;   When a process exits abnormally and triggers recovery:
;;   1. sentinel-handle-abnormal-exit calls registry-cleanup-process
;;   2. registry-cleanup-process removes from claude-agent--registry
;;   3. BUT it does NOT call claude-agent--unregister-query
;;   4. The old dead entry remains in claude-agent--active-queries
;;   5. The *Claude Queries* buffer shows a stale/dead query
;;
;; Bug 2: Process killed by signal (e.g., OOM killer signal 9) remains in active queries
;;   This is a consequence of Bug 1 — when a process is killed by the system:
;;   1. Sentinel fires with "killed: 9"
;;   2. is-abnormal-exit-p returns t (has session-id, not cancelled)
;;   3. sentinel-handle-abnormal-exit runs (recovery path)
;;   4. Old entry stays in active-queries (Bug 1)
;;   5. Even after recovery completes, old dead entry persists
;;
;; Bug 3: sentinel-handle-normal-exit calls complete-callback after cancel
;;   When user cancels and the process eventually exits:
;;   1. cancel sets cancelled=t, sends SIGINT
;;   2. Process exits, sentinel fires
;;   3. is-abnormal-exit-p returns nil (cancelled=t), goes to normal path
;;   4. sentinel-handle-normal-exit calls complete-callback
;;   5. complete-callback (handle-complete) runs AFTER cancel already cleaned up
;;   6. This causes duplicate cleanup and completion hooks firing with wrong status

;;; Code:

(require 'ert)
(require 'claude-agent)

;;; Bug 1: sentinel-handle-abnormal-exit doesn't unregister from active-queries

(ert-deftest test-abnormal-exit-should-unregister-from-active-queries ()
  "Abnormal exit (recovery path) should remove the old entry from active-queries.
Bug: sentinel-handle-abnormal-exit calls registry-cleanup-process which
removes from the registry but NOT from claude-agent--active-queries.
The old dead entry persists in the queries buffer."
  :tags '(:unit :fast :stable :isolated :state-management :recovery)
  (let* ((proc (start-process "test-abnormal-exit" nil "sleep" "10"))
         (state (claude-agent--make-process-state
                 :process proc
                 :request-id "test-abnormal-001"
                 :session-id "test-session-abnormal"
                 :session-key "test-session-key"))
         ;; Save and restore global state
         (saved-active-queries (copy-hash-table claude-agent--active-queries))
         (saved-active-states (copy-sequence claude-agent--active-states)))
    (unwind-protect
        (progn
          ;; Register the query in active-queries
          (claude-agent--register-query "test-abnormal-001" state)
          (should (gethash "test-abnormal-001" claude-agent--active-queries))

          ;; Simulate what the sentinel does for abnormal exit:
          ;; 1. Set closed=t and ready=nil (sentinel always does this first)
          (setf (claude-agent--process-state-closed state) t)
          (setf (claude-agent--process-state-ready state) nil)

          ;; 2. Call registry-cleanup-process (what sentinel-handle-abnormal-exit does)
          (claude-agent-registry-cleanup-process state)

          ;; BUG: After registry-cleanup-process, the entry should be removed
          ;; from active-queries, but it's NOT because registry-cleanup-process
          ;; only removes from claude-agent--registry, not claude-agent--active-queries
          (should-not (gethash "test-abnormal-001" claude-agent--active-queries)))
      ;; Cleanup
      (when (process-live-p proc) (delete-process proc))
      (setq claude-agent--active-queries saved-active-queries)
      (setq claude-agent--active-states saved-active-states))))

(ert-deftest test-normal-exit-does-unregister-from-active-queries ()
  "Normal exit path (sentinel-cleanup) should remove from active-queries.
This test verifies the normal path works correctly as a control case."
  :tags '(:unit :fast :stable :isolated :state-management)
  (let* ((proc (start-process "test-normal-exit" nil "sleep" "10"))
         (state (claude-agent--make-process-state
                 :process proc
                 :request-id "test-normal-001"
                 :session-key "test-session-key"))
         (saved-active-queries (copy-hash-table claude-agent--active-queries))
         (saved-active-states (copy-sequence claude-agent--active-states)))
    (unwind-protect
        (progn
          ;; Register the query
          (claude-agent--register-query "test-normal-001" state)
          (push state claude-agent--active-states)
          (should (gethash "test-normal-001" claude-agent--active-queries))

          ;; Simulate normal exit: sentinel-cleanup unregisters
          (claude-agent--sentinel-cleanup proc state)

          ;; After sentinel-cleanup, entry should be gone
          (should-not (gethash "test-normal-001" claude-agent--active-queries)))
      ;; Cleanup
      (when (process-live-p proc) (delete-process proc))
      (setq claude-agent--active-queries saved-active-queries)
      (setq claude-agent--active-states saved-active-states))))

;;; Bug 2: Process killed by signal 9 (OOM) stays in active-queries

(ert-deftest test-signal-9-killed-process-removed-from-active-queries ()
  "Process killed by signal 9 (e.g., OOM killer) should be removed from active-queries.
Bug: When a process is killed by signal 9:
  1. Sentinel fires with 'killed: 9'
  2. is-abnormal-exit-p returns t (triggers recovery path)
  3. sentinel-handle-abnormal-exit runs
  4. Old entry stays in active-queries because recovery path skips unregister-query
  5. The dead process appears in *Claude Queries* buffer indefinitely"
  :tags '(:unit :fast :stable :isolated :state-management :recovery)
  (let* ((proc (start-process "test-oom-kill" nil "sleep" "10"))
         (state (claude-agent--make-process-state
                 :process proc
                 :request-id "test-oom-001"
                 :session-id "test-session-oom"
                 :session-key "test-session-key"))
         (claude-agent-auto-recovery t)
         (saved-active-queries (copy-hash-table claude-agent--active-queries))
         (saved-active-states (copy-sequence claude-agent--active-states)))
    (unwind-protect
        (progn
          ;; Register the query
          (claude-agent--register-query "test-oom-001" state)
          (should (gethash "test-oom-001" claude-agent--active-queries))

          ;; Verify this IS an abnormal exit scenario (would trigger recovery)
          (should (claude-agent--is-abnormal-exit-p "killed: 9\n" state))

          ;; Simulate what sentinel does for abnormal exit:
          (setf (claude-agent--process-state-closed state) t)
          (setf (claude-agent--process-state-ready state) nil)

          ;; Call the same cleanup that sentinel-handle-abnormal-exit calls
          ;; (but skip resume-session which would start a new process)
          (claude-agent-registry-cleanup-process state)

          ;; BUG: The old entry should be removed from active-queries
          ;; but it's still there because registry-cleanup-process
          ;; doesn't touch claude-agent--active-queries
          (should-not (gethash "test-oom-001" claude-agent--active-queries)))
      ;; Cleanup
      (when (process-live-p proc) (delete-process proc))
      (setq claude-agent--active-queries saved-active-queries)
      (setq claude-agent--active-states saved-active-states))))

(ert-deftest test-abnormal-exit-cleanup-parity-with-normal-exit ()
  "Both normal and abnormal exit paths should remove entries from active-queries.
The abnormal exit path (recovery) should do at least the same cleanup
as the normal exit path regarding active-queries hash table."
  :tags '(:unit :fast :stable :isolated :state-management)
  (let* ((saved-active-queries (copy-hash-table claude-agent--active-queries))
         (saved-active-states (copy-sequence claude-agent--active-states))
         ;; Create two processes with identical setup
         (proc-normal (start-process "test-parity-normal" nil "sleep" "10"))
         (state-normal (claude-agent--make-process-state
                        :process proc-normal
                        :request-id "test-parity-normal-001"
                        :session-key "test-session-key"))
         (proc-abnormal (start-process "test-parity-abnormal" nil "sleep" "10"))
         (state-abnormal (claude-agent--make-process-state
                          :process proc-abnormal
                          :request-id "test-parity-abnormal-001"
                          :session-id "test-session-parity"
                          :session-key "test-session-key")))
    (unwind-protect
        (progn
          ;; Register both
          (claude-agent--register-query "test-parity-normal-001" state-normal)
          (claude-agent--register-query "test-parity-abnormal-001" state-abnormal)
          (push state-normal claude-agent--active-states)
          (push state-abnormal claude-agent--active-states)

          ;; Normal exit path
          (setf (claude-agent--process-state-closed state-normal) t)
          (claude-agent--sentinel-cleanup proc-normal state-normal)
          (should-not (gethash "test-parity-normal-001" claude-agent--active-queries))

          ;; Abnormal exit path (recovery cleanup only, no resume-session)
          (setf (claude-agent--process-state-closed state-abnormal) t)
          (claude-agent-registry-cleanup-process state-abnormal)

          ;; BUG: abnormal exit should have same result as normal exit
          ;; regarding active-queries cleanup
          (should-not (gethash "test-parity-abnormal-001" claude-agent--active-queries)))
      ;; Cleanup
      (when (process-live-p proc-normal) (delete-process proc-normal))
      (when (process-live-p proc-abnormal) (delete-process proc-abnormal))
      (setq claude-agent--active-queries saved-active-queries)
      (setq claude-agent--active-states saved-active-states))))

;;; Bug 3: complete-callback fires after cancel

(ert-deftest test-cancel-prevents-complete-callback-from-firing ()
  "After cancel, the sentinel's normal-exit handler should not call complete-callback.
Bug: When user cancels:
  1. cancel sets cancelled=t on process state
  2. Process exits, sentinel fires
  3. is-abnormal-exit-p returns nil (cancelled=t prevents recovery)
  4. sentinel-handle-normal-exit calls complete-callback
  5. complete-callback (e.g., handle-complete) runs AFTER cancel cleaned up
  6. This causes duplicate state resets and completion hooks with wrong status

The complete-callback should NOT be called if the query was cancelled."
  :tags '(:unit :fast :stable :isolated :state-management :cancel)
  (let* ((proc (start-process "test-cancel-cb" nil "sleep" "10"))
         (complete-called nil)
         (state (claude-agent--make-process-state
                 :process proc
                 :request-id "test-cancel-cb-001"
                 :session-id "test-session-cancel-cb"
                 :complete-callback (lambda (result)
                                      (setq complete-called t)))))
    (unwind-protect
        (progn
          ;; Simulate cancel: set cancelled flag
          (setf (claude-agent--process-state-cancelled state) t)

          ;; Simulate what sentinel does after cancel:
          ;; is-abnormal-exit-p returns nil → goes to normal exit handler
          (should-not (claude-agent--is-abnormal-exit-p "finished\n" state))

          ;; sentinel-handle-normal-exit calls complete-callback
          (claude-agent--sentinel-handle-normal-exit state "finished\n")

          ;; BUG: complete-callback should NOT be called for cancelled queries
          ;; because the cancel path already handled cleanup.
          ;; Currently it IS called, causing duplicate cleanup.
          (should-not complete-called))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest test-cancel-then-killed-event-no-complete-callback ()
  "After cancel, a 'killed' event should not call complete-callback.
When cancel sends SIGINT and the process is killed, the sentinel receives
a 'killed: 2' event. The complete-callback should not fire."
  :tags '(:unit :fast :stable :isolated :state-management :cancel)
  (let* ((proc (start-process "test-cancel-killed" nil "sleep" "10"))
         (complete-called nil)
         (complete-error nil)
         (state (claude-agent--make-process-state
                 :process proc
                 :request-id "test-cancel-killed-001"
                 :session-id "test-session-cancel-killed"
                 :complete-callback (lambda (result)
                                      (setq complete-called t)
                                      (setq complete-error result)))))
    (unwind-protect
        (progn
          ;; Simulate cancel
          (setf (claude-agent--process-state-cancelled state) t)

          ;; For "killed: 2", is-abnormal-exit-p returns nil (cancelled)
          (should-not (claude-agent--is-abnormal-exit-p "killed: 2\n" state))

          ;; Normal exit handler processes the event
          ;; "killed: 2" doesn't match "finished" or "exited abnormally",
          ;; falls through to default clause which calls complete-callback with error
          (claude-agent--sentinel-handle-normal-exit state "killed: 2\n")

          ;; BUG: complete-callback fires even though query was cancelled
          (should-not complete-called))
      (when (process-live-p proc) (delete-process proc)))))

;;; Dual-tracking consistency tests

(ert-deftest test-registry-and-active-queries-are-different-tables ()
  "Verify that registry-queries and active-queries are separate hash tables.
This test documents the architectural fact that there are TWO separate
tracking systems, which is the root cause of the cleanup inconsistency."
  :tags '(:unit :fast :stable :isolated :state-management)
  (let ((registry-queries (claude-agent--registry-queries claude-agent--registry)))
    ;; They should be different objects
    (should-not (eq registry-queries claude-agent--active-queries))))

(ert-deftest test-register-query-only-adds-to-active-queries ()
  "register-query should add to active-queries, verify it doesn't add to registry."
  :tags '(:unit :fast :stable :isolated :state-management)
  (let* ((state (claude-agent--make-process-state :request-id "test-dual-001"))
         (saved-active-queries (copy-hash-table claude-agent--active-queries))
         (registry-queries (claude-agent--registry-queries claude-agent--registry)))
    (unwind-protect
        (progn
          (claude-agent--register-query "test-dual-001" state)
          ;; Should be in active-queries
          (should (gethash "test-dual-001" claude-agent--active-queries))
          ;; Should NOT be in registry-queries (separate system)
          (should-not (gethash "test-dual-001" registry-queries)))
      ;; Cleanup
      (remhash "test-dual-001" claude-agent--active-queries)
      (setq claude-agent--active-queries saved-active-queries))))

(provide 'test-claude-agent-state-management)
;;; test-claude-agent-state-management.el ends here
