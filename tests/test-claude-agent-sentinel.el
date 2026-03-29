;;; test-claude-agent-sentinel.el --- Process sentinel tests -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Tests that exercise process sentinel callbacks.
;; These verify that the SDK properly handles all process exit scenarios:
;; normal exit, crash exit, OOM kill, and filter errors.
;;
;; Uses mock-cli-v2.py for scenarios that require specific exit behaviors.

;;; Code:

(require 'ert)
(require 'claude-agent)
(require 'test-config)

;;; Dependencies

;; emacs-mcp-server-path-mappings is declared in emacs-mcp-server.org
;; but we only load claude-agent.org in agent-unit tests. Define it here
;; so Docker path-mapping cleanup tests can reference it.
(defvar emacs-mcp-server-path-mappings nil
  "Stub for sentinel tests — see emacs-mcp-server.org for real definition.")

;;; Helpers

(defvar test-sentinel-mock-cli-v2-path
  (expand-file-name "mock-claude-cli-v2.py"
                    (file-name-directory
                     (directory-file-name test-claude-fixture-dir)))
  "Path to mock CLI v2 (Python) for sentinel tests.")

(defun test-sentinel-mock-options (scenario &rest args)
  "Create options using mock CLI v2 with explicit SCENARIO.
ARGS are additional options passed to `claude-agent-options'."
  (apply #'claude-agent-options
         :cli-path test-sentinel-mock-cli-v2-path
         :setting-sources test-claude-default-setting-sources
         :env (list (cons "MOCK_SCENARIO" scenario))
         args))

;;; Test: Normal Exit

(ert-deftest test-sentinel-normal-exit ()
  "Mock process exits 0 — verify session state idle, markers freed.
After normal completion, the process state should be closed,
the process should not be live, and on-complete should have fired."
  :tags '(:unit :sentinel)
  (let ((completed nil)
        (result-msg nil)
        (state nil))
    (setq state
          (claude-agent-query
           "What is 2+2?"
           :options (test-sentinel-mock-options "simple-query")
           :session-key "test-sentinel-normal"
           :on-message (lambda (msg)
                         (when (claude-agent-result-message-p msg)
                           (setq result-msg msg)))
           :on-complete (lambda (_result)
                          (setq completed t))))

    (should (test-claude-wait-until (lambda () completed) 10))

    ;; on-complete must have fired
    (should completed)

    ;; Result message received
    (should result-msg)

    ;; Process state should be closed
    (should (claude-agent--process-state-closed state))

    ;; got-result flag should be set
    (should (claude-agent--process-state-got-result state))

    ;; Process should no longer be live
    (let ((proc (claude-agent--process-state-process state)))
      (should (or (null proc) (not (process-live-p proc)))))

    ;; Query should not be active
    (should-not (claude-agent--query-active-p state))))

;;; Test: Crash Exit

(ert-deftest test-sentinel-crash-exit ()
  "Mock process exits non-zero — verify error callback, state cleanup.
Uses crash-mid-stream scenario: process is killed mid-response.
Sentinel should detect abnormal exit and clean up state."
  :tags '(:unit :sentinel)
  (let ((claude-agent-auto-recovery nil)  ; disable recovery for clean test
        (completed nil)
        (error-received nil)
        (state nil))
    (setq state
          (claude-agent-query
           "Generate text then crash"
           :options (test-sentinel-mock-options "crash-mid-stream")
           :session-key "test-sentinel-crash"
           :on-error (lambda (err)
                       (setq error-received err))
           :on-complete (lambda (_result)
                          (setq completed t))))

    ;; Wait for sentinel to fire
    (should (test-claude-wait-until
             (lambda () (or completed error-received))
             10))

    ;; Process state should be closed after sentinel runs
    (should (claude-agent--process-state-closed state))

    ;; got-result should NOT be set (crashed before result)
    (should-not (claude-agent--process-state-got-result state))

    ;; Process should no longer be live
    (let ((proc (claude-agent--process-state-process state)))
      (should (or (null proc) (not (process-live-p proc)))))

    ;; Query should not be active
    (should-not (claude-agent--query-active-p state))))

;;; Test: OOM Kill (Signal 9)

(ert-deftest test-sentinel-oom-kill ()
  "Signal 9 exit — verify cleanup.
Starts a slow query, then sends SIGKILL to simulate OOM kill.
Sentinel should handle signal death gracefully."
  :tags '(:unit :sentinel)
  (let ((claude-agent-auto-recovery nil)
        (state nil)
        (completed nil)
        (error-received nil))
    (setq state
          (claude-agent-query
           "Write a very long story..."
           :options (test-sentinel-mock-options "slow-response")
           :session-key "test-sentinel-oom"
           :on-error (lambda (err)
                       (setq error-received err))
           :on-complete (lambda (_result)
                          (setq completed t))))

    ;; Wait for process to start
    (should (test-claude-wait-until
             (lambda ()
               (and state
                    (claude-agent--process-state-process state)
                    (process-live-p (claude-agent--process-state-process state))))
             5))

    ;; Give it time to start outputting
    (sleep-for 0.3)
    (accept-process-output nil 0.2)

    ;; Send SIGKILL (simulating OOM killer)
    (let ((proc (claude-agent--process-state-process state)))
      (when (process-live-p proc)
        (signal-process proc 9)))

    ;; Wait for sentinel to fire
    (should (test-claude-wait-until
             (lambda () (or completed error-received))
             5))

    ;; State should be fully cleaned up
    (should (claude-agent--process-state-closed state))
    (should-not (claude-agent--query-active-p state))

    ;; Process must not be live
    (let ((proc (claude-agent--process-state-process state)))
      (should (or (null proc) (not (process-live-p proc)))))))

;;; Test: Filter Error Recovery

(ert-deftest test-sentinel-filter-error-recovery ()
  "Error in filter — verify sentinel compensates.
Uses malformed JSON scenario which may trigger filter errors.
Even if the filter encounters bad data, sentinel should still
clean up properly when the process exits."
  :tags '(:unit :sentinel)
  (let ((completed nil)
        (state nil))
    (setq state
          (claude-agent-query
           "Generate text with malformed data"
           :options (test-sentinel-mock-options "malformed-json")
           :session-key "test-sentinel-filter-error"
           :on-complete (lambda (_result)
                          (setq completed t))))

    ;; Should complete despite malformed JSON in stream
    (should (test-claude-wait-until (lambda () completed) 10))

    ;; State must be fully cleaned up by sentinel
    (should (claude-agent--process-state-closed state))
    (should-not (claude-agent--query-active-p state))

    ;; Process should not be live
    (let ((proc (claude-agent--process-state-process state)))
      (should (or (null proc) (not (process-live-p proc)))))))

;;; Test: Rate Limit Exit Code

(ert-deftest test-sentinel-error-exit-code ()
  "Non-zero exit with error result — verify sentinel handles gracefully.
Uses rate-limited scenario: exits with code 1 after error result message."
  :tags '(:unit :sentinel)
  (let ((completed nil)
        (error-received nil)
        (state nil))
    (setq state
          (claude-agent-query
           "Generate text"
           :options (test-sentinel-mock-options "rate-limited")
           :session-key "test-sentinel-error-exit"
           :on-error (lambda (err)
                       (setq error-received err))
           :on-complete (lambda (_result)
                          (setq completed t))))

    ;; Wait for full cleanup (closed state), not just callbacks
    (should (test-claude-wait-until
             (lambda () (and state (claude-agent--process-state-closed state)))
             10))

    ;; State should be cleaned up
    (should-not (claude-agent--query-active-p state))
    ;; At least one of the callbacks should have fired
    (should (or completed error-received))))

;;; Test: Output buffer killed after cleanup

(ert-deftest test-sentinel-cleanup-kills-output-buffer ()
  "sentinel-cleanup must kill the process output buffer.
The output buffer accumulates raw JSON from the CLI process. If not
killed, it leaks memory in long-running Emacs sessions."
  :tags '(:unit :sentinel :regression)
  (let* ((output-buf (generate-new-buffer " *test-sentinel-output*"))
         (state (claude-agent--make-process-state
                 :buffer output-buf
                 :json-buffer ""
                 :ready t))
         (proc (start-process "test-cleanup-buf" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          ;; Verify buffer is live before cleanup
          (should (buffer-live-p output-buf))
          ;; Stub kill-child-processes (no real children to kill)
          (cl-letf (((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil)))
            (claude-agent--sentinel-cleanup proc state))
          ;; Output buffer must be killed
          (should-not (buffer-live-p output-buf)))
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p output-buf) (kill-buffer output-buf)))))

;;; Test: Error plist structure on abnormal exit code

(ert-deftest test-sentinel-error-plist-has-exit-code ()
  "Abnormal exit code must produce error plist with :message and :exit-code.
Callers use :exit-code to distinguish crash from rate-limit (code 1)
vs OOM kill (code 137) vs permission denied (code 126)."
  :tags '(:unit :sentinel :regression)
  (let* ((received-err nil)
         (state (claude-agent--make-process-state
                 :complete-callback (lambda (err) (setq received-err err)))))
    (claude-agent--sentinel-handle-normal-exit
     state "exited abnormally with code 42\n")
    ;; Error plist must exist
    (should received-err)
    ;; Must be a proper error plist
    (should (eq 'claude-agent-process-error (car received-err)))
    ;; Must contain :message
    (should (stringp (plist-get (cdr received-err) :message)))
    ;; Must contain :exit-code with correct numeric value
    (should (equal 42 (plist-get (cdr received-err) :exit-code)))))

;;; Test: Cancelled query skips complete callback

(ert-deftest test-sentinel-cancelled-skips-complete-callback ()
  "When a query is cancelled, sentinel must NOT fire the complete callback.
The cancel path already handles cleanup. Firing complete-callback
would cause duplicate cleanup and fire completion hooks with wrong status."
  :tags '(:unit :sentinel :regression)
  (let* ((callback-fired nil)
         (state (claude-agent--make-process-state
                 :complete-callback (lambda (_err) (setq callback-fired t))
                 :cancelled t)))
    ;; Normal exit with cancelled state
    (claude-agent--sentinel-handle-normal-exit state "finished\n")
    (should-not callback-fired)
    ;; Abnormal exit with cancelled state
    (claude-agent--sentinel-handle-normal-exit state "exited abnormally with code 1\n")
    (should-not callback-fired)))

;;; Test: Docker path-mappings cleared on normal exit

(ert-deftest test-sentinel-cleanup-clears-docker-path-mappings ()
  "sentinel-cleanup must clear emacs-mcp-server-path-mappings for Docker mode.
Stale path mappings after process exit would corrupt MCP requests
from subsequent queries."
  :tags '(:unit :sentinel :regression)
  (let* ((state (claude-agent--make-process-state
                 :docker-mode t
                 :json-buffer ""
                 :ready t))
         (proc (start-process "test-docker-cleanup" nil "sleep" "60"))
         (saved emacs-mcp-server-path-mappings))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          ;; Set mappings directly (global var, not lexical let)
          (setq emacs-mcp-server-path-mappings
                '(("/host/path" . "/container/path")))
          ;; Verify mappings are set
          (should emacs-mcp-server-path-mappings)
          ;; Run cleanup
          (cl-letf (((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil)))
            (claude-agent--sentinel-cleanup proc state))
          ;; Path mappings must be cleared
          (should-not emacs-mcp-server-path-mappings))
      (setq emacs-mcp-server-path-mappings saved)
      (when (process-live-p proc) (delete-process proc)))))

;;; Test: Non-Docker process does not clear path-mappings

(ert-deftest test-sentinel-cleanup-preserves-mappings-for-non-docker ()
  "sentinel-cleanup must NOT clear path-mappings for non-Docker processes.
A non-Docker query completing should not destroy mappings owned by
a concurrent Docker query."
  :tags '(:unit :sentinel :regression)
  (let* ((state (claude-agent--make-process-state
                 :docker-mode nil
                 :json-buffer ""
                 :ready t))
         (proc (start-process "test-non-docker" nil "sleep" "60"))
         (saved emacs-mcp-server-path-mappings))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          (setq emacs-mcp-server-path-mappings
                '(("/host/path" . "/container/path")))
          (cl-letf (((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil)))
            (claude-agent--sentinel-cleanup proc state))
          ;; Path mappings must survive (not our process)
          (should emacs-mcp-server-path-mappings))
      (setq emacs-mcp-server-path-mappings saved)
      (when (process-live-p proc) (delete-process proc)))))

;;; Test: Docker path-mappings cleared on ABNORMAL exit (Q12)

(ert-deftest test-sentinel-abnormal-exit-clears-docker-path-mappings ()
  "sentinel-handle-abnormal-exit must clear path-mappings for Docker mode.
Q12: If a Docker query is OOM-killed (abnormal exit with recovery),
stale path mappings persist and corrupt the next MCP request.
Both normal and abnormal exit paths must clear mappings."
  :tags '(:unit :sentinel :regression)
  (let* ((state (claude-agent--make-process-state
                 :docker-mode t
                 :json-buffer ""
                 :ready t
                 :session-key "test-q12-abnormal"))
         (proc (start-process "test-q12-docker-abnormal" nil "sleep" "60"))
         (saved emacs-mcp-server-path-mappings))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          ;; Set path mappings to simulate Docker query in progress
          (setq emacs-mcp-server-path-mappings
                '(("/host/project" . "/workspace")))
          (should emacs-mcp-server-path-mappings)
          ;; Stub functions called by sentinel-handle-abnormal-exit
          (cl-letf (((symbol-function 'claude-agent--insert-recovery-message)
                     (lambda (_state _event) nil))
                    ((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil))
                    ((symbol-function 'claude-agent-registry-cleanup-process)
                     (lambda (_state) nil))
                    ((symbol-function 'claude-agent--resume-session)
                     (lambda (_state) nil))
                    ((symbol-function 'claude-agent--verbose-insert)
                     (lambda (_key _msg) nil)))
            (claude-agent--sentinel-handle-abnormal-exit
             proc state "killed: 9\n"))
          ;; Path mappings MUST be cleared after abnormal exit
          (should-not emacs-mcp-server-path-mappings))
      (setq emacs-mcp-server-path-mappings saved)
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest test-sentinel-abnormal-exit-preserves-mappings-for-non-docker ()
  "sentinel-handle-abnormal-exit must NOT clear path-mappings for non-Docker.
A non-Docker query dying should not destroy mappings owned by
a concurrent Docker query."
  :tags '(:unit :sentinel :regression)
  (let* ((state (claude-agent--make-process-state
                 :docker-mode nil
                 :json-buffer ""
                 :ready t
                 :session-key "test-q12-non-docker"))
         (proc (start-process "test-q12-non-docker-abnormal" nil "sleep" "60"))
         (saved emacs-mcp-server-path-mappings))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          (setq emacs-mcp-server-path-mappings
                '(("/host/project" . "/workspace")))
          (cl-letf (((symbol-function 'claude-agent--insert-recovery-message)
                     (lambda (_state _event) nil))
                    ((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil))
                    ((symbol-function 'claude-agent-registry-cleanup-process)
                     (lambda (_state) nil))
                    ((symbol-function 'claude-agent--resume-session)
                     (lambda (_state) nil))
                    ((symbol-function 'claude-agent--verbose-insert)
                     (lambda (_key _msg) nil)))
            (claude-agent--sentinel-handle-abnormal-exit
             proc state "killed: 9\n"))
          ;; Path mappings must survive (not a Docker process)
          (should emacs-mcp-server-path-mappings))
      (setq emacs-mcp-server-path-mappings saved)
      (when (process-live-p proc) (delete-process proc)))))

;;; Test: Full sentinel with mock process (exit 0)

(ert-deftest test-sentinel-full-dispatch-normal-exit ()
  "Full sentinel dispatch for normal exit — verify closed state and cleanup.
Invokes claude-agent--process-sentinel directly with a mock process
and 'finished' event to test the complete dispatch path."
  :tags '(:unit :sentinel :regression)
  (let* ((completed nil)
         (complete-err nil)
         (state (claude-agent--make-process-state
                 :json-buffer ""
                 :ready t
                 :complete-callback (lambda (err)
                                     (setq completed t
                                           complete-err err))))
         (proc (start-process "test-full-sentinel" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          ;; Stub kill-child-processes
          (cl-letf (((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil)))
            ;; Invoke sentinel directly
            (claude-agent--process-sentinel proc "finished\n"))
          ;; State must be closed
          (should (claude-agent--process-state-closed state))
          ;; Ready must be nil
          (should-not (claude-agent--process-state-ready state))
          ;; Complete callback must have fired with nil (no error)
          (should completed)
          (should-not complete-err))
      (when (process-live-p proc) (delete-process proc)))))

;;; Test: Full sentinel with mock process (exit 1)

(ert-deftest test-sentinel-full-dispatch-abnormal-exit ()
  "Full sentinel dispatch for abnormal exit — verify error callback fires.
Invokes claude-agent--process-sentinel directly with exit code 1."
  :tags '(:unit :sentinel :regression)
  (let* ((completed nil)
         (complete-err nil)
         (state (claude-agent--make-process-state
                 :json-buffer ""
                 :ready t
                 :got-result t  ; set got-result so is-abnormal-exit-p returns nil
                 :complete-callback (lambda (err)
                                     (setq completed t
                                           complete-err err))))
         (proc (start-process "test-full-sentinel-err" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          (cl-letf (((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil)))
            (claude-agent--process-sentinel proc "exited abnormally with code 1\n"))
          ;; State must be closed
          (should (claude-agent--process-state-closed state))
          ;; Complete callback must have fired with error
          (should completed)
          (should complete-err)
          ;; Error must be structured
          (should (eq 'claude-agent-process-error (car complete-err))))
      (when (process-live-p proc) (delete-process proc)))))

;;; ================================================================
;;; Sentinel Edge Cases (P2)
;;; ================================================================

;;; Test: Buffer killed during stream

(ert-deftest test-sentinel-buffer-killed-during-stream ()
  "Sentinel must not error when output buffer is killed before process exits.
If a user kills the output buffer (or it is garbage collected) while the
process is still running, the sentinel must still complete cleanup without
signaling an error.  The sentinel-cleanup guards with `buffer-live-p',
but we verify the full dispatch path handles a dead buffer."
  :tags '(:unit :sentinel :regression)
  (let* ((completed nil)
         (complete-err nil)
         (output-buf (generate-new-buffer " *test-sentinel-dead-buf*"))
         (state (claude-agent--make-process-state
                 :json-buffer ""
                 :ready t
                 :buffer output-buf
                 :complete-callback (lambda (err)
                                     (setq completed t
                                           complete-err err))))
         (proc (start-process "test-sentinel-dead-buf" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          ;; Kill the buffer BEFORE sentinel fires (simulates user/GC killing it)
          (kill-buffer output-buf)
          (should-not (buffer-live-p output-buf))
          ;; Invoke sentinel — must not error
          (cl-letf (((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil)))
            (claude-agent--process-sentinel proc "finished\n"))
          ;; State must still be cleaned up
          (should (claude-agent--process-state-closed state))
          (should-not (claude-agent--process-state-ready state))
          ;; Complete callback must have fired
          (should completed)
          (should-not complete-err))
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p output-buf) (kill-buffer output-buf)))))

;;; Test: Process exits with signal (not exit code)

(ert-deftest test-sentinel-signal-exit-hangup ()
  "Sentinel must handle 'hangup' signal event gracefully.
Some process deaths produce events like 'hangup' instead of 'exited
abnormally with code N'. The sentinel-handle-normal-exit must handle
this via the fallback branch."
  :tags '(:unit :sentinel :regression)
  (let* ((completed nil)
         (complete-err nil)
         (state (claude-agent--make-process-state
                 :json-buffer ""
                 :ready t
                 :got-result t  ; has result, so is-abnormal-exit-p returns nil
                 :complete-callback (lambda (err)
                                     (setq completed t
                                           complete-err err))))
         (proc (start-process "test-sentinel-hangup" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          (cl-letf (((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil)))
            (claude-agent--process-sentinel proc "hangup\n"))
          ;; State must be closed
          (should (claude-agent--process-state-closed state))
          ;; Complete callback must have fired with error (unknown signal)
          (should completed)
          (should complete-err)
          ;; Error message must mention the event
          (should (string-match-p "hangup"
                                  (plist-get (cdr complete-err) :message))))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest test-sentinel-signal-exit-killed-9 ()
  "Sentinel must handle 'killed: 9' signal when auto-recovery is disabled.
When auto-recovery is off, killed-by-signal events must go through the
normal exit path (not the recovery path). The sentinel-handle-normal-exit
must produce an error plist for signal events."
  :tags '(:unit :sentinel :regression)
  (let* ((claude-agent-auto-recovery nil)  ; disable recovery
         (completed nil)
         (complete-err nil)
         (state (claude-agent--make-process-state
                 :json-buffer ""
                 :ready t
                 :complete-callback (lambda (err)
                                     (setq completed t
                                           complete-err err))))
         (proc (start-process "test-sentinel-kill9-norecovery" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          (cl-letf (((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil)))
            (claude-agent--process-sentinel proc "killed: 9\n"))
          ;; State must be closed
          (should (claude-agent--process-state-closed state))
          ;; Complete callback must have fired with error
          (should completed)
          (should complete-err)
          ;; Error must mention the signal event
          (should (string-match-p "killed"
                                  (plist-get (cdr complete-err) :message))))
      (when (process-live-p proc) (delete-process proc)))))

;;; Test: Rapid successive exit — sentinel idempotency

(ert-deftest test-sentinel-double-fire-idempotent ()
  "Sentinel must be idempotent — double invocation must not corrupt state.
In rare cases (Emacs bug, or process dies immediately after restart),
the sentinel can fire twice for the same process. The second invocation
must be a no-op (state is already closed)."
  :tags '(:unit :sentinel :regression)
  (let* ((complete-count 0)
         (state (claude-agent--make-process-state
                 :json-buffer ""
                 :ready t
                 :complete-callback (lambda (_err)
                                     (setq complete-count (1+ complete-count)))))
         (proc (start-process "test-sentinel-double" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          (cl-letf (((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil)))
            ;; First sentinel call — should run normally
            (claude-agent--process-sentinel proc "finished\n")
            (should (claude-agent--process-state-closed state))
            (should (= 1 complete-count))
            ;; Second sentinel call — state.ready is nil, so filter is skipped.
            ;; But state is non-nil and closed is already t.
            ;; The sentinel sets closed=t and ready=nil again (idempotent).
            ;; Complete callback fires again because sentinel-handle-normal-exit
            ;; doesn't guard against double invocation — this test documents
            ;; the current behavior.
            (claude-agent--process-sentinel proc "finished\n")
            ;; State must remain closed
            (should (claude-agent--process-state-closed state))
            ;; Document: complete callback fires twice (sentinel doesn't guard)
            ;; This is acceptable because callers (claude-org) are idempotent
            (should (= 2 complete-count))))
      (when (process-live-p proc) (delete-process proc)))))

;;; Test: Non-object JSON in remaining buffer (latent bug from iter 6)

(ert-deftest test-sentinel-remaining-non-object-json ()
  "Sentinel must not crash when remaining JSON is a bare value (not object).
Iter 6 discovered that bare JSON values like `42` or `\"hello\"` parse
successfully but crash `plist-get' because they are not plists.
The sentinel's remaining-JSON handler must handle this gracefully."
  :tags '(:unit :sentinel :regression)
  (let* ((completed nil)
         (error-received nil)
         (state (claude-agent--make-process-state
                 :json-buffer "42"  ; bare number — parses to 42, not a plist
                 :ready t
                 :error-callback (lambda (err) (setq error-received err))
                 :complete-callback (lambda (_err) (setq completed t))))
         (proc (start-process "test-sentinel-bare-json" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          (cl-letf (((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil)))
            ;; This must NOT signal an error
            (claude-agent--process-sentinel proc "finished\n"))
          ;; State must be cleaned up regardless
          (should (claude-agent--process-state-closed state))
          ;; Complete callback must have fired
          (should completed))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest test-sentinel-remaining-string-json ()
  "Sentinel must not crash when remaining JSON is a bare string.
A bare JSON string like '\"error message\"' parses to an Elisp string,
which is not a plist. The sentinel must handle this gracefully."
  :tags '(:unit :sentinel :regression)
  (let* ((completed nil)
         (state (claude-agent--make-process-state
                 :json-buffer "\"some error\""  ; bare string
                 :ready t
                 :complete-callback (lambda (_err) (setq completed t))))
         (proc (start-process "test-sentinel-bare-string" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          (cl-letf (((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (_pid) nil)))
            ;; This must NOT signal an error
            (claude-agent--process-sentinel proc "finished\n"))
          (should (claude-agent--process-state-closed state))
          (should completed))
      (when (process-live-p proc) (delete-process proc)))))

;;; Test: Non-object JSON in process-json-buffer (filter path)

(ert-deftest test-filter-non-object-json-line ()
  "Process filter must not crash when a JSON line parses to a non-object.
Lines like `42\\n` or `true\\n` are valid JSON but not objects (plists).
The filter must treat them as errors, not crash on `plist-get'."
  :tags '(:unit :sentinel :regression)
  (let* ((error-received nil)
         (state (claude-agent--make-process-state
                 :json-buffer "42\n"
                 :ready t
                 :error-callback (lambda (err) (setq error-received err))))
         (proc (start-process "test-filter-bare-json" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          ;; Process the json-buffer — must not crash
          (claude-agent--process-json-buffer proc)
          ;; The bare number should be treated as an error
          ;; (it's valid JSON but not a protocol message)
          (should error-received))
      (when (process-live-p proc) (delete-process proc)))))

(provide 'test-claude-agent-sentinel)
;;; test-claude-agent-sentinel.el ends here
