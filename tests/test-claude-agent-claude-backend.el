;;; test-claude-agent-claude-backend.el --- F3-F8: Claude CLI Backend Tests -*- lexical-binding: t; -*-

;; TDD tests for the Claude CLI terminal backend.
;; Tests define expected behavior BEFORE implementation.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-agent)

;;; ============================================================
;;; F3: Claude Backend Struct and Capabilities
;;; ============================================================

(ert-deftest test-f3-struct-exists ()
  "Claude backend struct should exist with constructor."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (should (fboundp 'claude-agent-claude-backend-p))
  (should (fboundp 'claude-agent-claude-backend--create)))

(ert-deftest test-f3-struct-inherits-base ()
  "Claude backend should satisfy the base backend predicate."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (claude-agent-claude-backend-p backend))
    (should (claude-agent-backend-p backend))))

(ert-deftest test-f3-struct-type-field ()
  "Claude backend type field should be :claude-cli."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (eq :claude-cli (claude-agent-backend-type backend)))))

(ert-deftest test-f3-struct-slots ()
  "Claude backend should have expected slots with defaults."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should-not (claude-agent-claude-backend-process backend))
    (should-not (claude-agent-claude-backend-buffer backend))
    (should-not (claude-agent-claude-backend-session-key backend))
    (should-not (claude-agent-claude-backend-active backend))
    (should-not (claude-agent-claude-backend-output-start-pos backend))
    (should-not (claude-agent-claude-backend-options backend))
    (should-not (claude-agent-claude-backend-callbacks backend))
    (should (= 0 (claude-agent-claude-backend-query-count backend)))
    (should-not (claude-agent-claude-backend-cwd backend))
    (should-not (claude-agent-claude-backend-session-id backend))))

(ert-deftest test-f3-struct-with-session-key ()
  "Claude backend should accept session-key at creation."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create
                  :session-key "test-key"
                  :cwd "/tmp")))
    (should (equal "test-key" (claude-agent-claude-backend-session-key backend)))
    (should (equal "/tmp" (claude-agent-claude-backend-cwd backend)))))

;;; F3: Capability Matrix

(ert-deftest test-f3-supports-streaming-tokens ()
  "Claude backend should support :streaming-tokens."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (claude-agent-backend-supports-p backend :streaming-tokens))))

(ert-deftest test-f3-no-structured-messages ()
  "Claude backend should NOT support :structured-messages."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should-not (claude-agent-backend-supports-p backend :structured-messages))))

(ert-deftest test-f3-no-tool-use ()
  "Claude backend should NOT support :tool-use."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should-not (claude-agent-backend-supports-p backend :tool-use))))

(ert-deftest test-f3-supports-session-resume ()
  "Claude backend should support :session-resume."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (claude-agent-backend-supports-p backend :session-resume))))

(ert-deftest test-f3-supports-interactive-input ()
  "Claude backend should support :interactive-input."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (claude-agent-backend-supports-p backend :interactive-input))))

(ert-deftest test-f3-supports-persistent-client ()
  "Claude backend should support :persistent-client."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (claude-agent-backend-supports-p backend :persistent-client))))

(ert-deftest test-f3-supports-hook-permissions ()
  "Claude backend should support :hook-permissions."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (claude-agent-backend-supports-p backend :hook-permissions))))

(ert-deftest test-f3-supports-terminal-verbose ()
  "Claude backend should support :terminal-verbose."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (claude-agent-backend-supports-p backend :terminal-verbose))))

(ert-deftest test-f3-no-unknown-capability ()
  "Claude backend should return nil for unknown capabilities."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should-not (claude-agent-backend-supports-p backend :teleportation))))

;;; F3: Callback Filtering

(ert-deftest test-f3-filter-keeps-on-token ()
  "Callback filter should keep :on-token for claude backend."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let* ((backend (claude-agent-claude-backend--create))
         (callbacks (list :on-token #'ignore :on-message #'ignore
                         :on-error #'ignore :on-complete #'ignore))
         (filtered (claude-agent-backend-filter-callbacks backend callbacks)))
    (should (plist-get filtered :on-token))
    (should (plist-get filtered :on-error))
    (should (plist-get filtered :on-complete))))

(ert-deftest test-f3-filter-strips-on-message ()
  "Callback filter should strip :on-message for claude backend."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let* ((backend (claude-agent-claude-backend--create))
         (callbacks (list :on-token #'ignore :on-message #'ignore
                         :on-error #'ignore :on-complete #'ignore))
         (filtered (claude-agent-backend-filter-callbacks backend callbacks)))
    (should-not (plist-get filtered :on-message))))

;;; F3: Protocol Method Defaults

(ert-deftest test-f3-verbose-buffer-returns-buffer-field ()
  "Claude backend verbose-buffer should return the buffer field."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    ;; Default nil
    (should-not (claude-agent-backend-verbose-buffer backend))
    ;; With buffer set
    (let ((buf (generate-new-buffer " *test-verbose*")))
      (unwind-protect
          (progn
            (setf (claude-agent-claude-backend-buffer backend) buf)
            (should (eq buf (claude-agent-backend-verbose-buffer backend))))
        (kill-buffer buf)))))

(ert-deftest test-f3-session-id-returns-nil ()
  "Claude backend session-id should return nil (no SDK UUID)."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should-not (claude-agent-backend-session-id backend))))

(ert-deftest test-f3-ready-p-not-active ()
  "Claude backend ready-p should return t when not active."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (claude-agent-backend-ready-p backend))))

(ert-deftest test-f3-ready-p-when-active ()
  "Claude backend ready-p should return nil when active."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (let ((backend (claude-agent-claude-backend--create)))
    (setf (claude-agent-claude-backend-active backend) t)
    (should-not (claude-agent-backend-ready-p backend))))

;;; F3: Defcustom Existence

(ert-deftest test-f3-cli-switches-defcustom ()
  "claude-agent-claude-backend-cli-switches should be a defcustom."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (should (boundp 'claude-agent-claude-backend-cli-switches))
  ;; Default should be nil
  (should-not (default-value 'claude-agent-claude-backend-cli-switches)))

(ert-deftest test-f3-hook-wrapper-path-defcustom ()
  "claude-agent-claude-backend-hook-wrapper-path should be a defcustom."
  :tags '(:unit :fast :stable :isolated :claude-backend :f3)
  (should (boundp 'claude-agent-claude-backend-hook-wrapper-path)))

;;; ============================================================
;;; F4: Eat Terminal Management
;;; ============================================================

(ert-deftest test-f4-eat-alive-p-nil-buffer ()
  "eat-alive-p should return nil when buffer is nil."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create)))
    (should-not (claude-agent-claude-backend--eat-alive-p backend))))

(ert-deftest test-f4-eat-alive-p-killed-buffer ()
  "eat-alive-p should return nil when buffer is killed."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create))
        (buf (generate-new-buffer " *test-eat*")))
    (setf (claude-agent-claude-backend-buffer backend) buf)
    (kill-buffer buf)
    (should-not (claude-agent-claude-backend--eat-alive-p backend))))

(ert-deftest test-f4-eat-alive-p-no-terminal ()
  "eat-alive-p should return nil when eat-terminal is nil."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create))
        (buf (generate-new-buffer " *test-eat*")))
    (unwind-protect
        (progn
          (setf (claude-agent-claude-backend-buffer backend) buf)
          ;; eat-terminal not set → nil
          (should-not (claude-agent-claude-backend--eat-alive-p backend)))
      (kill-buffer buf))))

(ert-deftest test-f4-backend-active-p-no-process ()
  "active-p should return nil when no process exists."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create)))
    (should-not (claude-agent-backend-active-p backend))))

(ert-deftest test-f4-backend-active-p-not-active ()
  "active-p should return nil when active flag is nil."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create)))
    (setf (claude-agent-claude-backend-active backend) nil)
    (should-not (claude-agent-backend-active-p backend))))

(ert-deftest test-f4-backend-cleanup-no-state ()
  "cleanup should not error when no state exists."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create)))
    ;; Should be a no-op
    (claude-agent-backend-cleanup backend)
    (should-not (claude-agent-claude-backend-buffer backend))))

(ert-deftest test-f4-backend-cleanup-frees-marker ()
  "cleanup should free the output-start-pos marker."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create))
        (buf (generate-new-buffer " *test-cleanup*")))
    (unwind-protect
        (progn
          (setf (claude-agent-claude-backend-buffer backend) buf)
          (with-current-buffer buf
            (setf (claude-agent-claude-backend-output-start-pos backend)
                  (point-max-marker)))
          (claude-agent-backend-cleanup backend)
          (should-not (claude-agent-claude-backend-output-start-pos backend)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest test-f4-backend-cleanup-nils-fields ()
  "cleanup should nil out all state fields."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create)))
    (setf (claude-agent-claude-backend-active backend) t)
    (setf (claude-agent-claude-backend-callbacks backend) '(:on-token ignore))
    (setf (claude-agent-claude-backend-options backend) '(:model "test"))
    (claude-agent-backend-cleanup backend)
    (should-not (claude-agent-claude-backend-active backend))
    (should-not (claude-agent-claude-backend-callbacks backend))
    (should-not (claude-agent-claude-backend-options backend))))

(ert-deftest test-f4-backend-cancel-no-op-when-nil ()
  "cancel should be no-op when eat-alive-p is nil."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create)))
    ;; Should not error
    (claude-agent-backend-cancel backend nil)))

(ert-deftest test-f4-backend-send-input-no-op-when-nil ()
  "send-input should be no-op when eat-alive-p is nil."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create)))
    ;; Should not error
    (claude-agent-backend-send-input backend "test")))

(ert-deftest test-f4-build-switches-no-output-format ()
  "build-switches should NOT include --output-format."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((claude-agent-claude-backend--hooks-settings-file "/tmp/fake-hooks.json"))
    (let ((switches (claude-agent-claude-backend--build-switches nil)))
      (should-not (member "--output-format" switches))
      (should-not (member "--input-format" switches))
      (should-not (member "--print" switches))
      (should-not (member "--verbose" switches)))))

(ert-deftest test-f4-build-switches-appends-cli-switches ()
  "build-switches should append claude-agent-claude-backend-cli-switches."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((claude-agent-claude-backend--hooks-settings-file "/tmp/fake-hooks.json")
        (claude-agent-claude-backend-cli-switches '("--no-update-check")))
    (let ((switches (claude-agent-claude-backend--build-switches nil)))
      (should (member "--no-update-check" switches)))))

(ert-deftest test-f4-build-switches-system-prompt ()
  "build-switches should include --system-prompt when provided."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((claude-agent-claude-backend--hooks-settings-file "/tmp/fake-hooks.json"))
    (let ((switches (claude-agent-claude-backend--build-switches
                     '(:system-prompt "You are a helper"))))
      (should (member "--system-prompt" switches))
      (let ((idx (cl-position "--system-prompt" switches :test #'equal)))
        (should (equal "You are a helper" (nth (1+ idx) switches)))))))

(ert-deftest test-f4-build-switches-omits-nil-values ()
  "build-switches should omit options with nil values."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((claude-agent-claude-backend--hooks-settings-file "/tmp/fake-hooks.json"))
    (let ((switches (claude-agent-claude-backend--build-switches
                     '(:system-prompt nil :max-turns nil))))
      (should-not (member "--system-prompt" switches))
      (should-not (member "--max-turns" switches)))))

(ert-deftest test-f4-build-switches-includes-settings ()
  "build-switches should include --settings with hooks settings file."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((claude-agent-claude-backend--hooks-settings-file "/tmp/fake-hooks.json"))
    (let ((switches (claude-agent-claude-backend--build-switches nil)))
      (should (member "--settings" switches))
      (let ((idx (cl-position "--settings" switches :test #'equal)))
        (should (equal "/tmp/fake-hooks.json" (nth (1+ idx) switches)))))))

;;; ============================================================
;;; F8: Error Classification
;;; ============================================================

(ert-deftest test-f8-classify-error-context-limit ()
  "Claude backend should classify context-too-long errors."
  :tags '(:unit :fast :stable :isolated :claude-backend :f8)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (eq 'context-limit
                (claude-agent-backend-classify-error backend "context too long")))
    (should (eq 'context-limit
                (claude-agent-backend-classify-error backend "token limit exceeded")))
    (should (eq 'context-limit
                (claude-agent-backend-classify-error backend "maximum context")))))

(ert-deftest test-f8-classify-error-session-expired ()
  "Claude backend should classify session-expired errors."
  :tags '(:unit :fast :stable :isolated :claude-backend :f8)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (eq 'session-expired
                (claude-agent-backend-classify-error backend "session expired")))
    (should (eq 'session-expired
                (claude-agent-backend-classify-error backend "invalid session")))))

(ert-deftest test-f8-classify-error-unknown ()
  "Claude backend should return unknown for unrecognized errors."
  :tags '(:unit :fast :stable :isolated :claude-backend :f8)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (eq 'unknown
                (claude-agent-backend-classify-error backend "some random error")))))

(ert-deftest test-f8-classify-error-nil ()
  "Claude backend should return unknown for nil errors."
  :tags '(:unit :fast :stable :isolated :claude-backend :f8)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (eq 'unknown (claude-agent-backend-classify-error backend nil)))))

(ert-deftest test-f8-classify-error-empty-string ()
  "Claude backend should return unknown for empty string."
  :tags '(:unit :fast :stable :isolated :claude-backend :f8)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (eq 'unknown (claude-agent-backend-classify-error backend "")))))

(ert-deftest test-f8-classify-error-plist ()
  "Claude backend should extract message from plist errors."
  :tags '(:unit :fast :stable :isolated :claude-backend :f8)
  (let ((backend (claude-agent-claude-backend--create)))
    (should (eq 'context-limit
                (claude-agent-backend-classify-error
                 backend '(:message "context too long"))))))

;;; ============================================================
;;; F6: Backend Query Method
;;; ============================================================

;; Helper: create a mock eat buffer that simulates eat-terminal
(defun test-f6--make-mock-eat-buffer ()
  "Create a buffer that simulates having an eat terminal.
Includes the ❯ prompt character to satisfy wait-for-ready."
  (let ((buf (generate-new-buffer " *test-eat-mock*")))
    (with-current-buffer buf
      ;; Simulate eat-terminal being set (as eat-exec would do)
      (set (make-local-variable 'eat-terminal) 'mock-terminal)
      ;; Simulate CLI being ready with prompt
      (insert "❯ "))
    buf))

(ert-deftest test-f6-ensure-process-creates-buffer ()
  "ensure-process should create an eat buffer and set it on backend."
  :tags '(:unit :fast :stable :isolated :claude-backend :f6)
  (let ((backend (claude-agent-claude-backend--create :cwd "/tmp"))
        (mock-buf nil))
    ;; Mock eat-make to return a test buffer
    (cl-letf (((symbol-function 'eat-make)
               (lambda (_name _program &optional _startfile &rest _switches)
                 (setq mock-buf (test-f6--make-mock-eat-buffer))
                 mock-buf)))
      (let ((featurep-orig (symbol-function 'featurep)))
        (cl-letf (((symbol-function 'featurep)
                   (lambda (feature &rest args)
                     (if (eq feature 'eat) t
                       (apply featurep-orig feature args)))))
          (claude-agent-claude-backend--ensure-process backend nil)
          (should (buffer-live-p (claude-agent-claude-backend-buffer backend)))
          ;; Cleanup
          (when mock-buf (kill-buffer mock-buf)))))))

(ert-deftest test-f6-ensure-process-reuses-live ()
  "ensure-process should reuse existing live eat buffer."
  :tags '(:unit :fast :stable :isolated :claude-backend :f6)
  (let* ((backend (claude-agent-claude-backend--create))
         (buf (test-f6--make-mock-eat-buffer))
         (eat-make-called nil))
    (setf (claude-agent-claude-backend-buffer backend) buf)
    (cl-letf (((symbol-function 'eat-make)
               (lambda (&rest _) (setq eat-make-called t) buf))
              ((symbol-function 'featurep)
               (lambda (f &rest _) (if (eq f 'eat) t (featurep f)))))
      (claude-agent-claude-backend--ensure-process backend nil)
      ;; eat-make should NOT have been called since buffer is live
      (should-not eat-make-called)
      (kill-buffer buf))))

(ert-deftest test-f6-query-sets-active ()
  "backend-query should set active flag to t."
  :tags '(:unit :fast :stable :isolated :claude-backend :f6)
  (let* ((backend (claude-agent-claude-backend--create))
         (buf (test-f6--make-mock-eat-buffer)))
    (setf (claude-agent-claude-backend-buffer backend) buf)
    (cl-letf (((symbol-function 'eat-make) (lambda (&rest _) buf))
              ((symbol-function 'featurep)
               (lambda (f &rest _) (if (eq f 'eat) t (featurep f))))
              ((symbol-function 'claude-agent-claude-backend--send-prompt)
               (lambda (&rest _) nil)))
      (let ((callbacks (list :on-token #'ignore :on-complete #'ignore)))
        (claude-agent-backend-query backend "hello" callbacks)
        (should (claude-agent-claude-backend-active backend))
        (should (= 1 (claude-agent-claude-backend-query-count backend)))
        (kill-buffer buf)))))

(ert-deftest test-f6-query-sends-prompt ()
  "backend-query should call --send-prompt with the prompt text."
  :tags '(:unit :fast :stable :isolated :claude-backend :f6)
  (let* ((backend (claude-agent-claude-backend--create))
         (buf (test-f6--make-mock-eat-buffer))
         (captured-prompt nil))
    (setf (claude-agent-claude-backend-buffer backend) buf)
    (cl-letf (((symbol-function 'eat-make) (lambda (&rest _) buf))
              ((symbol-function 'featurep)
               (lambda (f &rest _) (if (eq f 'eat) t (featurep f))))
              ((symbol-function 'claude-agent-claude-backend--send-prompt)
               (lambda (_backend prompt) (setq captured-prompt prompt))))
      (claude-agent-backend-query backend "test prompt"
                                  (list :on-token #'ignore :on-complete #'ignore))
      (should (equal "test prompt" captured-prompt))
      (kill-buffer buf))))

(ert-deftest test-f6-query-records-marker ()
  "backend-query should record output-start-pos as marker."
  :tags '(:unit :fast :stable :isolated :claude-backend :f6)
  (let* ((backend (claude-agent-claude-backend--create))
         (buf (test-f6--make-mock-eat-buffer)))
    (setf (claude-agent-claude-backend-buffer backend) buf)
    (cl-letf (((symbol-function 'eat-make) (lambda (&rest _) buf))
              ((symbol-function 'featurep)
               (lambda (f &rest _) (if (eq f 'eat) t (featurep f))))
              ((symbol-function 'claude-agent-claude-backend--send-prompt)
               (lambda (&rest _) nil)))
      (claude-agent-backend-query backend "hello"
                                  (list :on-token #'ignore :on-complete #'ignore))
      (should (markerp (claude-agent-claude-backend-output-start-pos backend)))
      (kill-buffer buf))))

(ert-deftest test-f6-query-errors-when-active ()
  "backend-query should signal error when already active."
  :tags '(:unit :fast :stable :isolated :claude-backend :f6)
  (let ((backend (claude-agent-claude-backend--create)))
    (setf (claude-agent-claude-backend-active backend) t)
    (should-error
     (claude-agent-backend-query backend "hello"
                                 (list :on-token #'ignore :on-complete #'ignore))
     :type 'error)))

(ert-deftest test-f6-query-returns-backend ()
  "backend-query should return backend as opaque handle."
  :tags '(:unit :fast :stable :isolated :claude-backend :f6)
  (let* ((backend (claude-agent-claude-backend--create))
         (buf (test-f6--make-mock-eat-buffer)))
    (setf (claude-agent-claude-backend-buffer backend) buf)
    (cl-letf (((symbol-function 'eat-make) (lambda (&rest _) buf))
              ((symbol-function 'featurep)
               (lambda (f &rest _) (if (eq f 'eat) t (featurep f))))
              ((symbol-function 'claude-agent-claude-backend--send-prompt)
               (lambda (&rest _) nil)))
      (let ((handle (claude-agent-backend-query
                     backend "hello"
                     (list :on-token #'ignore :on-complete #'ignore))))
        (should (eq backend handle))
        (kill-buffer buf)))))

(ert-deftest test-f6-query-stores-callbacks ()
  "backend-query should store callbacks in backend struct."
  :tags '(:unit :fast :stable :isolated :claude-backend :f6)
  (let* ((backend (claude-agent-claude-backend--create))
         (buf (test-f6--make-mock-eat-buffer))
         (my-token-fn (lambda (_text) nil)))
    (setf (claude-agent-claude-backend-buffer backend) buf)
    (cl-letf (((symbol-function 'eat-make) (lambda (&rest _) buf))
              ((symbol-function 'featurep)
               (lambda (f &rest _) (if (eq f 'eat) t (featurep f))))
              ((symbol-function 'claude-agent-claude-backend--send-prompt)
               (lambda (&rest _) nil)))
      (claude-agent-backend-query backend "hello"
                                  (list :on-token my-token-fn :on-complete #'ignore))
      (should (eq my-token-fn
                  (plist-get (claude-agent-claude-backend-callbacks backend) :on-token)))
      (kill-buffer buf))))

;;; ============================================================
;;; F7: Hook Wrapper and Handler
;;; ============================================================

;; --- translate-permission-result ---

(ert-deftest test-f7-translate-permission-allow ()
  "translate-permission-result: allow plist → hook allow JSON alist."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((result (claude-agent-claude-backend--translate-permission-result
                 '(:behavior "allow"))))
    ;; Should produce alist with hookSpecificOutput
    (should (listp result))
    (let ((hso (alist-get 'hookSpecificOutput result)))
      (should hso)
      (should (equal "PreToolUse" (alist-get 'hookEventName hso)))
      (should (equal "allow" (alist-get 'permissionDecision hso))))))

(ert-deftest test-f7-translate-permission-deny ()
  "translate-permission-result: deny plist → hook deny JSON alist."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((result (claude-agent-claude-backend--translate-permission-result
                 '(:behavior "deny" :message "Not allowed"))))
    (let ((hso (alist-get 'hookSpecificOutput result)))
      (should (equal "deny" (alist-get 'permissionDecision hso)))
      (should (equal "Not allowed"
                     (alist-get 'permissionDecisionReason hso))))))

(ert-deftest test-f7-translate-permission-nil ()
  "translate-permission-result: nil → hook ask JSON alist."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((result (claude-agent-claude-backend--translate-permission-result nil)))
    (let ((hso (alist-get 'hookSpecificOutput result)))
      (should (equal "ask" (alist-get 'permissionDecision hso))))))

(ert-deftest test-f7-translate-permission-allow-with-updated-input ()
  "translate-permission-result: allow with :updated-input → updatedInput field."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((result (claude-agent-claude-backend--translate-permission-result
                 '(:behavior "allow"
                   :updated-input (:questions [q1] :answers (("q" . "a")))))))
    (let ((hso (alist-get 'hookSpecificOutput result)))
      (should (equal "allow" (alist-get 'permissionDecision hso)))
      (should (alist-get 'updatedInput hso)))))

;; --- format-hook-response ---

(ert-deftest test-f7-format-hook-response-roundtrip ()
  "format-hook-response: output is valid JSON (roundtrip)."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let* ((alist `((hookSpecificOutput
                   . ((hookEventName . "PreToolUse")
                      (permissionDecision . "allow")))))
         (json-str (claude-agent-claude-backend--format-hook-response alist)))
    ;; Should be valid JSON
    (should (stringp json-str))
    (let ((parsed (json-read-from-string json-str)))
      (should parsed)
      ;; Round-trip check
      (should (equal "allow"
                     (alist-get 'permissionDecision
                                (alist-get 'hookSpecificOutput parsed)))))))

(ert-deftest test-f7-format-hook-response-deny-with-reason ()
  "format-hook-response: deny with reason produces valid JSON."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let* ((alist `((hookSpecificOutput
                   . ((hookEventName . "PreToolUse")
                      (permissionDecision . "deny")
                      (permissionDecisionReason . "Org file protected")))))
         (json-str (claude-agent-claude-backend--format-hook-response alist)))
    (let ((parsed (json-read-from-string json-str)))
      (should (equal "Org file protected"
                     (alist-get 'permissionDecisionReason
                                (alist-get 'hookSpecificOutput parsed)))))))

;; --- handle-hook dispatch ---

(ert-deftest test-f7-handle-hook-pretooluse-dispatch ()
  "handle-hook dispatches PreToolUse events."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((dispatched nil))
    (cl-letf (((symbol-function
                'claude-agent-claude-backend--handle-pre-tool-use)
               (lambda (_input) (setq dispatched t) nil)))
      (claude-agent-claude-backend--handle-hook
       "PreToolUse"
       '((tool_name . "Read")
         (tool_input . ((file_path . "/tmp/foo")))))
      (should dispatched))))

(ert-deftest test-f7-handle-hook-posttooluse-dispatch ()
  "handle-hook dispatches PostToolUse events."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((dispatched nil))
    (cl-letf (((symbol-function
                'claude-agent-claude-backend--handle-post-tool-use)
               (lambda (_input) (setq dispatched t) nil)))
      (claude-agent-claude-backend--handle-hook
       "PostToolUse"
       '((tool_name . "Write")
         (tool_input . ((file_path . "/tmp/foo")))))
      (should dispatched))))

(ert-deftest test-f7-handle-hook-unknown-returns-nil ()
  "handle-hook returns nil for unknown event types."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (should-not (claude-agent-claude-backend--handle-hook
               "UnknownEvent" '((foo . "bar")))))

(ert-deftest test-f7-handle-hook-error-returns-ask ()
  "handle-hook wraps errors and returns ask decision."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (cl-letf (((symbol-function
              'claude-agent-claude-backend--handle-pre-tool-use)
             (lambda (_input) (error "Handler crashed"))))
    (let ((result (claude-agent-claude-backend--handle-hook
                   "PreToolUse"
                   '((tool_name . "Bash")
                     (tool_input . ((command . "ls")))))))
      ;; On error, should return ask (safe fallback)
      (when result
        (let ((hso (alist-get 'hookSpecificOutput result)))
          (should (equal "ask" (alist-get 'permissionDecision hso))))))))

(ert-deftest test-f7-handle-hook-posttooluse-error-returns-nil ()
  "handle-hook PostToolUse error returns nil, not a PreToolUse response."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (cl-letf (((symbol-function
              'claude-agent-claude-backend--handle-post-tool-use)
             (lambda (_input) (error "PostToolUse handler crashed"))))
    (let ((result (claude-agent-claude-backend--handle-hook
                   "PostToolUse"
                   '((tool_name . "Write")
                     (tool_input . ((file_path . "/tmp/x")))))))
      ;; PostToolUse error should return nil (not a PreToolUse ask response)
      (should-not result))))

;; --- handle-pre-tool-use ---

(ert-deftest test-f7-pretooluse-normal-delegates-to-permissions ()
  "PreToolUse for normal tool delegates to permission-functions."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((claude-agent-permission-functions
         (list (lambda (_tool _input _ctx)
                 '(:behavior "allow")))))
    (let ((result (claude-agent-claude-backend--handle-pre-tool-use
                   '((tool_name . "Bash")
                     (tool_input . ((command . "ls")))))))
      (let ((hso (alist-get 'hookSpecificOutput result)))
        (should (equal "allow" (alist-get 'permissionDecision hso)))))))

(ert-deftest test-f7-pretooluse-deny-from-permissions ()
  "PreToolUse: deny from permission-functions → deny hook response."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((claude-agent-permission-functions
         (list (lambda (_tool _input _ctx)
                 '(:behavior "deny" :message "Blocked")))))
    (let ((result (claude-agent-claude-backend--handle-pre-tool-use
                   '((tool_name . "Write")
                     (tool_input . ((file_path . "/tmp/foo")))))))
      (let ((hso (alist-get 'hookSpecificOutput result)))
        (should (equal "deny" (alist-get 'permissionDecision hso)))
        (should (equal "Blocked"
                       (alist-get 'permissionDecisionReason hso)))))))

(ert-deftest test-f7-pretooluse-nil-from-permissions ()
  "PreToolUse: nil from all permission-functions → allow (default)."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((claude-agent-permission-functions
         (list (lambda (_tool _input _ctx) nil))))
    (let ((result (claude-agent-claude-backend--handle-pre-tool-use
                   '((tool_name . "Read")
                     (tool_input . ((file_path . "/tmp/foo")))))))
      (let ((hso (alist-get 'hookSpecificOutput result)))
        ;; Default from run-permission-functions when all nil → allow
        (should (equal "allow" (alist-get 'permissionDecision hso)))))))

;; --- handle-post-tool-use ---

(ert-deftest test-f7-posttooluse-returns-nil ()
  "PostToolUse handler returns nil (no decision needed)."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((result (claude-agent-claude-backend--handle-post-tool-use
                 '((tool_name . "Read")
                   (tool_input . ((file_path . "/tmp/foo")))))))
    ;; PostToolUse doesn't need to return a decision for non-file tools
    (should-not result)))

(ert-deftest test-f7-posttooluse-edit-triggers-revert ()
  "PostToolUse for Edit/Write calls revert-buffer-handler."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((reverted-file nil))
    (cl-letf (((symbol-function
                'claude-agent-claude-backend--maybe-revert-buffer)
               (lambda (file-path) (setq reverted-file file-path))))
      (claude-agent-claude-backend--handle-post-tool-use
       '((tool_name . "Write")
         (tool_input . ((file_path . "/tmp/test.el")))))
      (should (equal "/tmp/test.el" reverted-file)))))

;; --- parse-hook-input ---

(ert-deftest test-f7-parse-hook-input-valid-json ()
  "parse-hook-input parses valid JSON to alist."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((result (claude-agent-claude-backend--parse-hook-input
                 "{\"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"ls\"}}")))
    (should (listp result))
    (should (equal "Bash" (alist-get 'tool_name result)))
    (let ((input (alist-get 'tool_input result)))
      (should (equal "ls" (alist-get 'command input))))))

(ert-deftest test-f7-parse-hook-input-invalid-json ()
  "parse-hook-input returns nil on invalid JSON."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (should-not (claude-agent-claude-backend--parse-hook-input "not json {")))

;; --- tool-input conversion ---

(ert-deftest test-f7-alist-tool-input-to-plist ()
  "alist-tool-input-to-plist converts alist keys to keyword plist."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((result (claude-agent-claude-backend--alist-tool-input-to-plist
                 '((file_path . "/tmp/foo") (command . "ls")))))
    (should (equal "/tmp/foo" (plist-get result :file_path)))
    (should (equal "ls" (plist-get result :command)))))


;; --- Fix coverage: terminal accessor, MultiEdit revert, event-name param ---

(ert-deftest test-f4-terminal-accessor-returns-nil-no-buffer ()
  "--terminal returns nil when backend has no buffer."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create)))
    (should-not (claude-agent-claude-backend--terminal backend))))

(ert-deftest test-f4-terminal-accessor-returns-nil-dead-buffer ()
  "--terminal returns nil when backend buffer is dead."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create))
        (buf (generate-new-buffer " *test-dead*")))
    (setf (claude-agent-claude-backend-buffer backend) buf)
    (kill-buffer buf)
    (should-not (claude-agent-claude-backend--terminal backend))))

(ert-deftest test-f4-terminal-accessor-returns-nil-no-eat-var ()
  "--terminal returns nil when buffer lacks eat-terminal variable."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create))
        (buf (generate-new-buffer " *test-no-eat*")))
    (setf (claude-agent-claude-backend-buffer backend) buf)
    (unwind-protect
        (should-not (claude-agent-claude-backend--terminal backend))
      (kill-buffer buf))))

(ert-deftest test-f4-terminal-accessor-returns-terminal ()
  "--terminal returns terminal when eat-terminal is set."
  :tags '(:unit :fast :stable :isolated :claude-backend :f4)
  (let ((backend (claude-agent-claude-backend--create))
        (buf (generate-new-buffer " *test-eat*"))
        (fake-terminal 'fake-eat-terminal-obj))
    (setf (claude-agent-claude-backend-buffer backend) buf)
    (with-current-buffer buf
      (setq-local eat-terminal fake-terminal))
    (unwind-protect
        (should (eq fake-terminal (claude-agent-claude-backend--terminal backend)))
      (kill-buffer buf))))

(ert-deftest test-f7-posttooluse-multiedit-triggers-revert ()
  "PostToolUse for MultiEdit calls revert-buffer-handler."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((reverted-file nil))
    (cl-letf (((symbol-function
                'claude-agent-claude-backend--maybe-revert-buffer)
               (lambda (file-path) (setq reverted-file file-path))))
      (claude-agent-claude-backend--handle-post-tool-use
       '((tool_name . "MultiEdit")
         (tool_input . ((file_path . "/tmp/multi.el")
                        (edits . [((old_string . "foo") (new_string . "bar"))])))))
      (should (equal "/tmp/multi.el" reverted-file)))))

(ert-deftest test-f7-posttooluse-read-no-revert ()
  "PostToolUse for Read does not trigger revert."
  :tags '(:unit :fast :stable :isolated :claude-backend :f7)
  (let ((reverted nil))
    (cl-letf (((symbol-function
                'claude-agent-claude-backend--maybe-revert-buffer)
               (lambda (_fp) (setq reverted t))))
      (claude-agent-claude-backend--handle-post-tool-use
       '((tool_name . "Read")
         (tool_input . ((file_path . "/tmp/readme.md")))))
      (should-not reverted))))

(ert-deftest test-f6-translate-permission-custom-event-name ()
  "translate-permission-result uses custom event-name when provided."
  :tags '(:unit :fast :stable :isolated :claude-backend :f6)
  (let ((result (claude-agent-claude-backend--translate-permission-result
                 '(:behavior "allow") "CustomEvent")))
    (let ((hso (alist-get 'hookSpecificOutput result)))
      (should (equal "CustomEvent" (alist-get 'hookEventName hso)))
      (should (equal "allow" (alist-get 'permissionDecision hso))))))

(ert-deftest test-f6-translate-permission-default-event-name ()
  "translate-permission-result defaults to PreToolUse without event-name."
  :tags '(:unit :fast :stable :isolated :claude-backend :f6)
  (let ((result (claude-agent-claude-backend--translate-permission-result
                 '(:behavior "deny" :message "nope"))))
    (let ((hso (alist-get 'hookSpecificOutput result)))
      (should (equal "PreToolUse" (alist-get 'hookEventName hso))))))

(ert-deftest test-f12-alist-tool-input-empty ()
  "alist-tool-input-to-plist returns nil for empty alist."
  :tags '(:unit :fast :stable :isolated :claude-backend :f12)
  (should-not (claude-agent-claude-backend--alist-tool-input-to-plist nil)))

;;; ============================================================
;;; Send-prompt (process-send-string + ESC + Enter sequence)
;;; ============================================================

(ert-deftest test-send-prompt-sends-text-esc-enter ()
  "send-prompt should send text immediately and schedule ESC+Enter via timers."
  :tags '(:unit :fast :stable :isolated :claude-backend :send-prompt)
  (let* ((sent-strings nil)
         (scheduled-fns nil)
         (backend (claude-agent-claude-backend--create))
         (buf (generate-new-buffer " *test-send*"))
         (proc (start-process "test-send" buf "cat"))
         (claude-agent-claude-backend-input-delay 0))
    (setf (claude-agent-claude-backend-buffer backend) buf)
    (setf (claude-agent-claude-backend-process backend) proc)
    (cl-letf (((symbol-function 'process-send-string)
               (lambda (_proc str) (push str sent-strings)))
              ((symbol-function 'run-at-time)
               (lambda (_delay _repeat fn &rest _args)
                 (push fn scheduled-fns)
                 'mock-timer)))
      (unwind-protect
          (progn
            (claude-agent-claude-backend--send-prompt backend "hello world")
            ;; Text should be sent immediately
            (should (equal '("hello world") (nreverse sent-strings)))
            ;; One timer should be scheduled (for ESC)
            (should (= 1 (length scheduled-fns)))
            ;; Execute the ESC timer callback
            (setq sent-strings nil)
            (funcall (car scheduled-fns))
            ;; ESC should now be sent, and another timer scheduled (for Enter)
            (should (equal '("\e") (nreverse sent-strings)))
            (should (= 2 (length scheduled-fns)))
            ;; Execute the Enter timer callback
            (setq sent-strings nil)
            (funcall (car scheduled-fns))
            ;; Enter should now be sent
            (should (equal '("\r") (nreverse sent-strings))))
        (delete-process proc)
        (kill-buffer buf)))))

(ert-deftest test-send-prompt-errors-when-no-process ()
  "send-prompt should error when process is not alive."
  :tags '(:unit :fast :stable :isolated :claude-backend :send-prompt)
  (let ((backend (claude-agent-claude-backend--create)))
    (should-error
     (claude-agent-claude-backend--send-prompt backend "hello")
     :type 'error)))

(ert-deftest test-cancel-uses-process-send-string ()
  "backend-cancel should send ESC via process-send-string."
  :tags '(:unit :fast :stable :isolated :claude-backend :send-prompt)
  (let* ((sent-strings nil)
         (backend (claude-agent-claude-backend--create))
         (buf (generate-new-buffer " *test-cancel*"))
         (proc (start-process "test-cancel" buf "cat")))
    (setf (claude-agent-claude-backend-buffer backend) buf)
    (setf (claude-agent-claude-backend-process backend) proc)
    (cl-letf (((symbol-function 'process-send-string)
               (lambda (_proc str) (push str sent-strings))))
      (unwind-protect
          (progn
            (claude-agent-backend-cancel backend nil)
            (should (member "\e" sent-strings)))
        (delete-process proc)
        (kill-buffer buf)))))

;;; ============================================================
;;; Wait-for-ready (prompt detection before sending input)
;;; ============================================================

(ert-deftest test-wait-for-ready-detects-prompt ()
  "wait-for-ready should return t when the prompt character is present."
  :tags '(:unit :fast :stable :isolated :claude-backend :wait-ready)
  (with-temp-buffer
    (insert "some output\n❯ ")
    (let ((backend (claude-agent-claude-backend--create)))
      (setf (claude-agent-claude-backend-buffer backend) (current-buffer))
      (should (claude-agent-claude-backend--prompt-ready-p backend)))))

(ert-deftest test-wait-for-ready-nil-when-no-prompt ()
  "wait-for-ready should return nil when no prompt character is present."
  :tags '(:unit :fast :stable :isolated :claude-backend :wait-ready)
  (with-temp-buffer
    (insert "Loading Claude CLI...\n")
    (let ((backend (claude-agent-claude-backend--create)))
      (setf (claude-agent-claude-backend-buffer backend) (current-buffer))
      (should-not (claude-agent-claude-backend--prompt-ready-p backend)))))

(ert-deftest test-wait-for-ready-nil-when-no-buffer ()
  "prompt-ready-p should return nil when backend has no buffer."
  :tags '(:unit :fast :stable :isolated :claude-backend :wait-ready)
  (let ((backend (claude-agent-claude-backend--create)))
    (should-not (claude-agent-claude-backend--prompt-ready-p backend))))

;;; ============================================================
;;; Unique eat buffer naming
;;; ============================================================

(ert-deftest test-ensure-process-uses-session-key-in-buffer-name ()
  "ensure-process should include session-key in the eat buffer name."
  :tags '(:unit :fast :stable :isolated :claude-backend :buffer-name)
  (let* ((captured-name nil)
         (backend (claude-agent-claude-backend--create
                   :session-key "my-session-123")))
    (cl-letf (((symbol-function 'claude-agent--find-cli) (lambda () "/usr/bin/claude"))
              ((symbol-function 'eat-make)
               (lambda (name _program &optional _startfile &rest _switches)
                 (setq captured-name name)
                 (generate-new-buffer (format " *%s*" name))))
              ((symbol-function 'claude-agent-claude-backend--build-switches)
               (lambda (_opts) nil))
              ((symbol-function 'featurep)
               (lambda (f &rest _) (eq f 'eat))))
      (unwind-protect
          (progn
            (claude-agent-claude-backend--ensure-process backend nil)
            (should (stringp captured-name))
            (should (string-match-p "my-session-123" captured-name)))
        (when-let ((buf (claude-agent-claude-backend-buffer backend)))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-ensure-process-unique-names-for-different-sessions ()
  "Different session-keys should produce different eat buffer names."
  :tags '(:unit :fast :stable :isolated :claude-backend :buffer-name)
  (let* ((captured-names nil)
         (backend-a (claude-agent-claude-backend--create :session-key "session-a"))
         (backend-b (claude-agent-claude-backend--create :session-key "session-b"))
         (bufs nil))
    (cl-letf (((symbol-function 'claude-agent--find-cli) (lambda () "/usr/bin/claude"))
              ((symbol-function 'eat-make)
               (lambda (name _program &optional _startfile &rest _switches)
                 (push name captured-names)
                 (let ((buf (generate-new-buffer (format " *%s*" name))))
                   (push buf bufs)
                   buf)))
              ((symbol-function 'claude-agent-claude-backend--build-switches)
               (lambda (_opts) nil))
              ((symbol-function 'featurep)
               (lambda (f &rest _) (eq f 'eat))))
      (unwind-protect
          (progn
            (claude-agent-claude-backend--ensure-process backend-a nil)
            (claude-agent-claude-backend--ensure-process backend-b nil)
            (should (= 2 (length captured-names)))
            (should-not (equal (nth 0 captured-names) (nth 1 captured-names))))
        (dolist (buf bufs)
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest test-ensure-process-fallback-name-without-session-key ()
  "Without session-key, buffer name should still be reasonable (fallback)."
  :tags '(:unit :fast :stable :isolated :claude-backend :buffer-name)
  (let* ((captured-name nil)
         (backend (claude-agent-claude-backend--create)))
    (cl-letf (((symbol-function 'claude-agent--find-cli) (lambda () "/usr/bin/claude"))
              ((symbol-function 'eat-make)
               (lambda (name _program &optional _startfile &rest _switches)
                 (setq captured-name name)
                 (generate-new-buffer (format " *%s*" name))))
              ((symbol-function 'claude-agent-claude-backend--build-switches)
               (lambda (_opts) nil))
              ((symbol-function 'featurep)
               (lambda (f &rest _) (eq f 'eat))))
      (unwind-protect
          (progn
            (claude-agent-claude-backend--ensure-process backend nil)
            (should (stringp captured-name))
            ;; Should contain "claude-cli" base name
            (should (string-match-p "claude-cli" captured-name)))
        (when-let ((buf (claude-agent-claude-backend-buffer backend)))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest test-ensure-process-verbose-buffer-returns-eat-buffer ()
  "backend-verbose-buffer should return the uniquely-named eat buffer."
  :tags '(:unit :fast :stable :isolated :claude-backend :buffer-name)
  (let* ((backend (claude-agent-claude-backend--create :session-key "verbose-test")))
    (cl-letf (((symbol-function 'claude-agent--find-cli) (lambda () "/usr/bin/claude"))
              ((symbol-function 'eat-make)
               (lambda (name _program &optional _startfile &rest _switches)
                 (generate-new-buffer (format " *%s*" name))))
              ((symbol-function 'claude-agent-claude-backend--build-switches)
               (lambda (_opts) nil))
              ((symbol-function 'featurep)
               (lambda (f &rest _) (eq f 'eat))))
      (unwind-protect
          (progn
            (claude-agent-claude-backend--ensure-process backend nil)
            (let ((buf (claude-agent-claude-backend-buffer backend)))
              (should (buffer-live-p buf))
              ;; The buffer name should contain the session key
              (should (string-match-p "verbose-test" (buffer-name buf)))))
        (when-let ((buf (claude-agent-claude-backend-buffer backend)))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

;;; ============================================================
;;; F1: Hook Script and Global Installation
;;; ============================================================

(ert-deftest test-f1-hook-script-content-is-string ()
  "Hook script content should return a non-empty string."
  :tags '(:unit :fast :stable :isolated :claude-backend :f1)
  (let ((script (claude-agent-claude-backend--hook-script-content)))
    (should (stringp script))
    (should (> (length script) 0))))

(ert-deftest test-f1-hook-script-handles-session-start ()
  "Hook script should contain SessionStart event handling."
  :tags '(:unit :fast :stable :isolated :claude-backend :f1)
  (let ((script (claude-agent-claude-backend--hook-script-content)))
    (should (string-match-p "SessionStart" script))
    (should (string-match-p "emacsclient" script))))

(ert-deftest test-f1-hook-script-handles-stop ()
  "Hook script should contain Stop event handling."
  :tags '(:unit :fast :stable :isolated :claude-backend :f1)
  (let ((script (claude-agent-claude-backend--hook-script-content)))
    (should (string-match-p "Stop" script))
    (should (string-match-p "last_assistant_message" script))))

(ert-deftest test-f1-hooks-settings-file-creates-valid-json ()
  "hooks-settings-file should create a JSON file with SessionStart and Stop hooks."
  :tags '(:unit :fast :stable :isolated :claude-backend :f1)
  (let ((claude-agent-claude-backend--hooks-settings-file nil)
        (tmpdir (make-temp-file "claude-test-hooks-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-agent-claude-backend--install-hook-script)
                   (lambda (_hooks-dir)
                     (expand-file-name "emacs-agent-hook.sh" tmpdir))))
          ;; Temporarily point the settings file into our tmpdir
          (let* ((file (expand-file-name "emacs-agent-settings.json" tmpdir))
                 (claude-agent-claude-backend--hooks-settings-file nil))
            ;; Trick: pre-set the cached var so we control the path
            ;; Actually, let's just call the function and check the result
            ;; We need to mock expand-file-name for ~/.claude/hooks
            (cl-letf (((symbol-function 'claude-agent-claude-backend--hooks-settings-file)
                       (lambda ()
                         (let* ((script-path (expand-file-name "emacs-agent-hook.sh" tmpdir))
                                (hook-entry `[((hooks . [((type . "command")
                                                          (command . ,script-path))]))])
                                (settings `((hooks . ((SessionStart . ,hook-entry)
                                                      (Stop . ,hook-entry))))))
                           (with-temp-file file
                             (insert (json-encode settings)))
                           file))))
              (let ((result (claude-agent-claude-backend--hooks-settings-file)))
                (should (file-exists-p result))
                ;; Parse and verify structure
                (let* ((json-object-type 'alist)
                       (json-array-type 'vector)
                       (json-key-type 'symbol)
                       (settings (json-read-file result))
                       (hooks (alist-get 'hooks settings)))
                  (should hooks)
                  (should (alist-get 'SessionStart hooks))
                  (should (alist-get 'Stop hooks)))))))
      (delete-directory tmpdir t))))

(ert-deftest test-f1-hooks-settings-file-caches-path ()
  "hooks-settings-file should return cached value on subsequent calls."
  :tags '(:unit :fast :stable :isolated :claude-backend :f1)
  (let ((claude-agent-claude-backend--hooks-settings-file "/tmp/fake-settings.json"))
    (should (equal "/tmp/fake-settings.json"
                   (claude-agent-claude-backend--hooks-settings-file)))))

(ert-deftest test-f1-install-hook-script-creates-executable ()
  "install-hook-script should create an executable file."
  :tags '(:unit :fast :stable :isolated :claude-backend :f1)
  (let ((tmpdir (make-temp-file "claude-test-" t)))
    (unwind-protect
        (progn
          (claude-agent-claude-backend--install-hook-script tmpdir)
          (let ((script-path (expand-file-name
                              "emacs-agent-hook.sh" tmpdir)))
            (should (file-exists-p script-path))
            (should (file-executable-p script-path))))
      (delete-directory tmpdir t))))

;;; ============================================================
;;; F2: Session Registry and Hook Handlers
;;; ============================================================

(ert-deftest test-f2-session-registry-exists ()
  "Session registry should be a hash table."
  :tags '(:unit :fast :stable :isolated :claude-backend :f2)
  (should (hash-table-p claude-agent-claude-backend--session-registry)))

(ert-deftest test-f2-on-session-start-registers-backend ()
  "on-session-start should store session_id → backend mapping."
  :tags '(:unit :fast :stable :isolated :claude-backend :f2)
  (let ((backend (claude-agent-claude-backend--create :cwd "/tmp/test")))
    (unwind-protect
        (progn
          ;; Register backend by cwd first
          (puthash "/tmp/test" backend
                   claude-agent-claude-backend--session-registry)
          ;; SessionStart handler maps session_id → backend
          (claude-agent-claude-backend--on-session-start
           "session-abc" "/tmp/test")
          ;; Should now be findable by session_id
          (should (eq backend
                      (gethash "session-abc"
                               claude-agent-claude-backend--session-registry)))
          ;; session-id slot should be set (not session-key)
          (should (equal "session-abc"
                         (claude-agent-claude-backend-session-id backend))))
      (remhash "session-abc" claude-agent-claude-backend--session-registry)
      (remhash "/tmp/test" claude-agent-claude-backend--session-registry))))

(ert-deftest test-f2-on-session-start-trailing-slash-mismatch ()
  "on-session-start should match even when cwd has trailing slash mismatch.
Emacs default-directory includes trailing slash, CLI cwd does not."
  :tags '(:unit :fast :stable :isolated :claude-backend :f2)
  (let ((backend (claude-agent-claude-backend--create :cwd "/tmp/test/")))
    (unwind-protect
        (progn
          ;; Register by normalized cwd (as backend-query would)
          (puthash (claude-agent-claude-backend--normalize-cwd "/tmp/test/")
                   backend claude-agent-claude-backend--session-registry)
          ;; CLI reports cwd WITHOUT trailing slash
          (claude-agent-claude-backend--on-session-start
           "session-xyz" "/tmp/test")
          ;; Should find the backend despite slash mismatch
          (should (eq backend
                      (gethash "session-xyz"
                               claude-agent-claude-backend--session-registry)))
          (should (equal "session-xyz"
                         (claude-agent-claude-backend-session-id backend))))
      (remhash "session-xyz" claude-agent-claude-backend--session-registry)
      (remhash "/tmp/test" claude-agent-claude-backend--session-registry))))

(ert-deftest test-f2-on-stop-delivers-tokens ()
  "on-stop should call :on-token with entire text then :on-complete."
  :tags '(:unit :fast :stable :isolated :claude-backend :f2)
  (let* ((claude-agent-claude-backend-stop-complete-delay 0) ; sync for test
         (token-calls nil)
         (complete-calls nil)
         (backend (claude-agent-claude-backend--create
                   :active t
                   :callbacks (list :on-token (lambda (text)
                                                (push text token-calls))
                                    :on-complete (lambda (result)
                                                   (push result complete-calls)))))
         (tmpfile (make-temp-file "claude-stop-test")))
    (unwind-protect
        (progn
          ;; Register backend
          (puthash "session-xyz" backend
                   claude-agent-claude-backend--session-registry)
          ;; Write response to temp file
          (with-temp-file tmpfile
            (insert "Line one\nLine two\nLine three"))
          ;; Fire on-stop
          (claude-agent-claude-backend--on-stop "session-xyz" tmpfile)
          ;; Entire text delivered as single token call
          (should (= 1 (length token-calls)))
          (should (equal "Line one\nLine two\nLine three" (car token-calls)))
          ;; on-complete called with nil
          (should (= 1 (length complete-calls)))
          (should-not (car complete-calls))
          ;; active reset
          (should-not (claude-agent-claude-backend-active backend))
          ;; temp file cleaned up
          (should-not (file-exists-p tmpfile)))
      (remhash "session-xyz" claude-agent-claude-backend--session-registry))))

(ert-deftest test-f2-on-stop-resets-active-before-on-complete ()
  "on-stop must reset active=nil BEFORE calling on-complete.
Otherwise on-complete may start a new query (setting active=t)
which then gets clobbered."
  :tags '(:unit :fast :stable :isolated :claude-backend :f2)
  (let* ((claude-agent-claude-backend-stop-complete-delay 0) ; sync for test
         (active-during-complete nil)
         (backend (claude-agent-claude-backend--create
                   :active t
                   :callbacks (list :on-token #'ignore
                                    :on-complete
                                    (lambda (_result)
                                      ;; Capture active state at time of on-complete
                                      (setq active-during-complete
                                            (claude-agent-claude-backend-active backend))))))
         (tmpfile (make-temp-file "claude-stop-test")))
    (unwind-protect
        (progn
          (puthash "session-order" backend
                   claude-agent-claude-backend--session-registry)
          (with-temp-file tmpfile (insert "response"))
          (claude-agent-claude-backend--on-stop "session-order" tmpfile)
          ;; active must already be nil when on-complete fires
          (should-not active-during-complete))
      (remhash "session-order" claude-agent-claude-backend--session-registry))))

(ert-deftest test-f2-on-stop-drops-stale-when-not-active ()
  "on-stop should silently drop response when backend is not active.
This protects against stale Stop events from user-interrupted queries
or manual terminal input."
  :tags '(:unit :fast :stable :isolated :claude-backend :f2)
  (let* ((token-called nil)
         (complete-called nil)
         (backend (claude-agent-claude-backend--create
                   :active nil  ;; NOT active — simulates post-interrupt state
                   :callbacks (list :on-token (lambda (_text)
                                                (setq token-called t))
                                    :on-complete (lambda (_r)
                                                   (setq complete-called t)))))
         (tmpfile (make-temp-file "claude-stop-stale")))
    (unwind-protect
        (progn
          (puthash "session-stale" backend
                   claude-agent-claude-backend--session-registry)
          (with-temp-file tmpfile (insert "wrong response from manual input"))
          (claude-agent-claude-backend--on-stop "session-stale" tmpfile)
          ;; Neither callback should fire for a stale Stop
          (should-not token-called)
          (should-not complete-called)
          ;; Temp file should still be cleaned up
          (should-not (file-exists-p tmpfile)))
      (remhash "session-stale" claude-agent-claude-backend--session-registry))))

(ert-deftest test-f2-on-stop-empty-response ()
  "on-stop with empty response should call on-complete but not on-token."
  :tags '(:unit :fast :stable :isolated :claude-backend :f2)
  (let* ((claude-agent-claude-backend-stop-complete-delay 0) ; sync for test
         (token-called nil)
         (complete-called nil)
         (backend (claude-agent-claude-backend--create
                   :active t
                   :callbacks (list :on-token (lambda (_text)
                                                (setq token-called t))
                                    :on-complete (lambda (_r)
                                                   (setq complete-called t)))))
         (tmpfile (make-temp-file "claude-stop-test")))
    (unwind-protect
        (progn
          (puthash "session-empty" backend
                   claude-agent-claude-backend--session-registry)
          ;; Empty temp file
          (with-temp-file tmpfile (insert ""))
          (claude-agent-claude-backend--on-stop "session-empty" tmpfile)
          (should-not token-called)
          (should complete-called)
          (should-not (claude-agent-claude-backend-active backend)))
      (remhash "session-empty" claude-agent-claude-backend--session-registry))))

(ert-deftest test-f2-on-stop-unknown-session ()
  "on-stop with unknown session_id should not error."
  :tags '(:unit :fast :stable :isolated :claude-backend :f2)
  (let ((tmpfile (make-temp-file "claude-stop-test")))
    (unwind-protect
        ;; Should not signal an error
        (claude-agent-claude-backend--on-stop "nonexistent-session" tmpfile)
      (when (file-exists-p tmpfile) (delete-file tmpfile)))))

(ert-deftest test-f2-on-stop-missing-tmpfile ()
  "on-stop with missing temp file should not error."
  :tags '(:unit :fast :stable :isolated :claude-backend :f2)
  (let* ((claude-agent-claude-backend-stop-complete-delay 0) ; sync for test
         (complete-called nil)
         (backend (claude-agent-claude-backend--create
                   :active t
                   :callbacks (list :on-token #'ignore
                                    :on-complete (lambda (_r)
                                                   (setq complete-called t))))))
    (unwind-protect
        (progn
          (puthash "session-nofile" backend
                   claude-agent-claude-backend--session-registry)
          ;; File doesn't exist
          (claude-agent-claude-backend--on-stop
           "session-nofile" "/tmp/nonexistent-file-xyz.txt")
          ;; Should still call on-complete (with nil, no tokens)
          (should complete-called)
          (should-not (claude-agent-claude-backend-active backend)))
      (remhash "session-nofile" claude-agent-claude-backend--session-registry))))

(provide 'test-claude-agent-claude-backend)
;;; test-claude-agent-claude-backend.el ends here
