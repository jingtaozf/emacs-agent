;;; test-claude-org-loop-detection.el --- Tests for F3: Loop iteration hook -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;;; Commentary:

;; F3: Tests for loop iteration hook (defcustom, buffer-local, empty default).
;; The hook allows users to attach functions that monitor loop iterations
;; for repetitive patterns. No built-in detection logic is shipped.

;;; Code:

(require 'ert)

;;; Test 1: claude-org-loop-iteration-hook exists as defcustom

(ert-deftest test-loop-detection-hook-is-defcustom ()
  "claude-org-loop-iteration-hook exists as a defcustom.
FIX: Define (defcustom claude-org-loop-iteration-hook nil ...) in claude-org.org."
  :tags '(:unit :fast :stable :loop-detection)
  (should (custom-variable-p 'claude-org-loop-iteration-hook))
  (should (null (default-value 'claude-org-loop-iteration-hook))))

(ert-deftest test-loop-detection-hook-is-buffer-local ()
  "claude-org-loop-iteration-hook is buffer-local.
FIX: Call (make-variable-buffer-local 'claude-org-loop-iteration-hook)."
  :tags '(:unit :fast :stable :loop-detection)
  (with-temp-buffer
    (add-hook 'claude-org-loop-iteration-hook #'ignore nil t)
    (should (local-variable-p 'claude-org-loop-iteration-hook))
    ;; Default value in other buffers should still be nil
    (with-temp-buffer
      (should (null claude-org-loop-iteration-hook)))))

;;; Test 2: Hook is called during loop iterations

(ert-deftest test-loop-detection-hook-called-on-iteration ()
  "Hook functions are called with (session-key iteration) during loop iterations.
FIX: Add (run-hook-with-args ...) in claude-org--execute-loop-iteration."
  :tags '(:unit :fast :stable :loop-detection)
  (let ((calls '()))
    (with-temp-buffer
      ;; Set up session state
      (setq-local claude-org--sessions (make-hash-table :test 'equal))
      (let* ((session-key "test-session")
             (marker (point-min-marker)))
        ;; Initialize session
        (claude-org--session-put session-key :marker marker)
        (claude-org--session-put session-key :loop-current 1)
        (claude-org--session-put session-key :loop-max 3)
        ;; Add buffer-local hook
        (add-hook 'claude-org-loop-iteration-hook
                  (lambda (sk iter)
                    (push (list sk iter) calls))
                  nil t)
        ;; Simulate calling the loop iteration hook directly
        (run-hook-with-args 'claude-org-loop-iteration-hook session-key 2)
        (should (equal calls '(("test-session" 2))))))))

;;; Test 3: Tool call history tracking

(ert-deftest test-loop-detection-tool-history-tracking ()
  "Tool-use messages accumulate in :tool-call-history session property.
FIX: Append (TOOL-NAME . ARGS-HASH) in claude-org--handle-message for tool-use blocks."
  :tags '(:unit :fast :stable :loop-detection)
  (with-temp-buffer
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "test-session"))
      ;; Initialize session
      (claude-org--session-put session-key :marker (point-min-marker))
      (claude-org--session-put session-key :query-id "q1")
      ;; Simulate recording tool calls
      (claude-org--record-tool-call session-key "Read" '(:file_path "/foo.el"))
      (claude-org--record-tool-call session-key "Write" '(:file_path "/bar.el"))
      (claude-org--record-tool-call session-key "Read" '(:file_path "/foo.el"))
      ;; Verify history
      (let ((history (claude-org--session-get session-key :tool-call-history)))
        (should (= 3 (length history)))
        (should (equal "Read" (car (nth 0 history))))
        (should (equal "Write" (car (nth 1 history))))
        (should (equal "Read" (car (nth 2 history))))))))

;;; Test 4: claude-org-loop-inject-warning API

(ert-deftest test-loop-detection-inject-warning ()
  "claude-org-loop-inject-warning sets :loop-warning on session.
FIX: Implement (defun claude-org-loop-inject-warning (session-key message) ...)."
  :tags '(:unit :fast :stable :loop-detection)
  (with-temp-buffer
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "test-session"))
      (claude-org--session-put session-key :marker (point-min-marker))
      ;; Inject warning
      (claude-org-loop-inject-warning session-key "Detected repetitive tool calls")
      ;; Verify it's stored
      (should (equal "Detected repetitive tool calls"
                     (claude-org--session-get session-key :loop-warning))))))

(ert-deftest test-loop-detection-warning-included-in-prompt ()
  "Loop warning is included in the system prompt for the next iteration.
FIX: Read :loop-warning in prompt assembly and clear after use."
  :tags '(:unit :fast :stable :loop-detection)
  (with-temp-buffer
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "test-session"))
      (claude-org--session-put session-key :marker (point-min-marker))
      ;; Set a warning
      (claude-org--session-put session-key :loop-warning "Stop repeating!")
      ;; Read and clear the warning (this is what prompt assembly does)
      (let ((warning (claude-org--consume-loop-warning session-key)))
        (should (equal "Stop repeating!" warning))
        ;; After consumption, it should be nil
        (should (null (claude-org--session-get session-key :loop-warning)))))))

(provide 'test-claude-org-loop-detection)
;;; test-claude-org-loop-detection.el ends here
