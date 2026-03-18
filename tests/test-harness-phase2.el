;;; test-harness-phase2.el --- Phase 2 harness tests: critical protocol gaps -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Phase 2 harness engineering tests covering critical gaps:
;; TEST-1: control_request round-trip (bidirectional protocol)
;; TEST-2: JSON buffer overflow protection
;; TEST-3: UTF-8 multi-byte handling across chunk boundaries

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-config)

;;; Helpers (reuse from error-injection tests)

(defvar test-harness-mock-cli-v2-path
  (expand-file-name "mock-claude-cli-v2.py"
                    (file-name-directory
                     (directory-file-name test-claude-fixture-dir)))
  "Path to mock CLI v2 (Python) for harness tests.")

(defun test-harness-v2-mock-options (scenario &rest args)
  "Create options using mock CLI v2 with explicit SCENARIO.
ARGS are additional options passed to `claude-agent-options'."
  (apply #'claude-agent-options
         :cli-path test-harness-mock-cli-v2-path
         :setting-sources test-claude-default-setting-sources
         :env (list (cons "MOCK_SCENARIO" scenario))
         args))

;;; ================================================================
;;; TEST-1: control_request / control_response round-trip
;;; ================================================================

(ert-deftest test-harness-control-request-round-trip ()
  "Bidirectional protocol: CLI sends control_request, SDK responds, CLI continues.
Uses permission-prompt.jsonl which embeds a can_use_tool control_request
with #WAIT_FOR_INPUT to gate on the SDK's control_response.
Verifies:
1. Permission functions run for the tool
2. control_response is sent back (mock CLI continues past #WAIT_FOR_INPUT)
3. Subsequent messages arrive after permission is granted
4. Query completes successfully"
  :tags '(:unit :harness :protocol)
  (let ((tokens '())
        (completed nil)
        (result-received nil)
        (permission-tool nil)
        (error-received nil))
    ;; Install permission function AND keep binding active through wait-until.
    ;; The process filter fires asynchronously during accept-process-output,
    ;; so the dynamic binding must still be active when permission runs.
    (let ((claude-agent-permission-functions
           (list (lambda (tool-name _tool-input _context)
                   (setq permission-tool tool-name)
                   '(:behavior "allow")))))
      (claude-agent-query
       "Read a file for me"
       :options (test-harness-v2-mock-options "permission-prompt")
       :session-key "test-ctrl-roundtrip"
       :on-token (lambda (text)
                   (push text tokens))
       :on-message (lambda (msg)
                     (when (claude-agent-result-message-p msg)
                       (setq result-received msg)))
       :on-error (lambda (err)
                   (setq error-received err))
       :on-complete (lambda (_result)
                      (setq completed t)))

      ;; Wait INSIDE the let — permission binding must be active when
      ;; the control_request handler fires during accept-process-output
      (should (test-claude-wait-until (lambda () completed) 15)))

    ;; Permission function was invoked with the correct tool
    (should (equal permission-tool "Read"))

    ;; Query completed without errors
    (should completed)
    (should-not error-received)

    ;; Result message was received (proves mock continued past permission)
    (should result-received)

    ;; Tokens should include text from both before and after permission
    (should (> (length tokens) 0))))

;;; ================================================================
;;; TEST-2: JSON buffer overflow protection
;;; ================================================================

(ert-deftest test-harness-json-buffer-overflow-fires-error ()
  "Buffer exceeding `claude-agent-max-json-buffer-size' triggers error callback.
The process filter should:
1. Clear the json buffer
2. Invoke the error callback with overflow message
3. Kill the process"
  :tags '(:unit :harness :protocol :overflow)
  (let ((error-received nil)
        (small-limit 200))  ; 200 bytes is tiny
    (let ((claude-agent-max-json-buffer-size small-limit))
      (let* ((state (claude-agent--make-process-state
                     :json-buffer ""
                     :ready t
                     :error-callback (lambda (err)
                                      (setq error-received err))))
             (process (start-process "test-overflow" nil "true")))
        (unwind-protect
            (progn
              (process-put process 'claude-agent-state state)
              ;; Feed data that exceeds the limit via the process filter
              (let ((big-data (make-string (+ small-limit 50) ?x)))
                (claude-agent--process-filter process big-data))
              ;; Error callback should have fired
              (should error-received)
              ;; Error should mention overflow
              (should (stringp (plist-get error-received :error)))
              (should (string-match-p "overflow"
                                      (plist-get error-received :error)))
              ;; JSON buffer should be cleared after overflow
              (should (equal "" (claude-agent--process-state-json-buffer state))))
          (when (process-live-p process)
            (delete-process process)))))))

(ert-deftest test-harness-json-buffer-under-limit-processes-normally ()
  "Data under the buffer limit is processed normally without error."
  :tags '(:unit :harness :protocol :overflow)
  (let ((error-received nil)
        (received-types '()))
    (let ((claude-agent-max-json-buffer-size (* 10 1024)))  ; 10KB
      (let* ((state (claude-agent--make-process-state
                     :json-buffer ""
                     :ready t
                     :error-callback (lambda (err) (setq error-received err))))
             (process (start-process "test-no-overflow" nil "true")))
        (unwind-protect
            (progn
              (process-put process 'claude-agent-state state)
              ;; Feed valid JSON under the limit
              (cl-letf (((symbol-function 'claude-agent-handle-message)
                         (lambda (_type parsed _state)
                           (push (plist-get parsed :type) received-types)))
                        ((symbol-function 'claude-agent--handle-control-request)
                         #'ignore))
                (let ((data (concat
                             (json-encode '(:type "system" :subtype "init")) "\n"
                             (json-encode '(:type "assistant" :message (:content "hi"))) "\n")))
                  (claude-agent--process-filter process data)))
              ;; Messages should arrive
              (should (= 2 (length received-types)))
              ;; No error
              (should-not error-received))
          (when (process-live-p process)
            (delete-process process)))))))

;;; ================================================================
;;; TEST-3: UTF-8 multi-byte handling across chunk boundaries
;;; ================================================================

(ert-deftest test-harness-utf8-multibyte-in-json ()
  "JSON containing multi-byte UTF-8 characters (CJK, emoji) parses correctly.
The parser must handle Emacs multibyte strings without corruption."
  :tags '(:unit :harness :protocol :utf8)
  (let ((received-texts '()))
    (let* ((state (claude-agent--make-process-state
                   :json-buffer ""
                   :ready t))
           (process (start-process "test-utf8" nil "true")))
      (unwind-protect
          (progn
            (process-put process 'claude-agent-state state)
            (cl-letf (((symbol-function 'claude-agent-handle-message)
                       (lambda (_type parsed _state)
                         (when-let* ((msg (plist-get parsed :message))
                                     (content (plist-get msg :content)))
                           (push content received-texts))))
                      ((symbol-function 'claude-agent--handle-control-request)
                       #'ignore))
              ;; Feed JSON with multi-byte characters
              (let ((data (concat
                           (json-encode '(:type "system" :subtype "init")) "\n"
                           (json-encode `(:type "assistant"
                                          :message (:content "你好世界 🌍"))) "\n"
                           (json-encode `(:type "assistant"
                                          :message (:content "日本語テスト"))) "\n")))
                (claude-agent--process-filter process data)))
            ;; Both CJK messages should arrive intact
            (should (= 2 (length received-texts)))
            (should (member "你好世界 🌍" received-texts))
            (should (member "日本語テスト" received-texts)))
        (when (process-live-p process)
          (delete-process process))))))

(ert-deftest test-harness-utf8-split-across-chunks ()
  "Multi-byte UTF-8 characters split across chunk boundaries.
Feed a JSON string containing CJK characters in two chunks split
at different positions. The parser should reassemble correctly."
  :tags '(:unit :harness :protocol :utf8 :fuzzer)
  (let ((received-texts '())
        (errors '()))
    ;; Build a JSON line with CJK text
    (let ((json-line (concat (json-encode
                              `(:type "assistant"
                                :message (:content "Hello 世界!")))
                             "\n")))
      ;; Try multiple split positions
      (dotimes (i (1- (length json-line)))
        (setq received-texts nil errors nil)
        (let* ((state (claude-agent--make-process-state
                       :json-buffer ""
                       :ready t
                       :error-callback (lambda (err) (push err errors))))
               (process (start-process "test-utf8-split" nil "true")))
          (unwind-protect
              (progn
                (process-put process 'claude-agent-state state)
                (cl-letf (((symbol-function 'claude-agent-handle-message)
                           (lambda (_type parsed _state)
                             (when-let* ((msg (plist-get parsed :message))
                                         (content (plist-get msg :content)))
                               (push content received-texts))))
                          ((symbol-function 'claude-agent--handle-control-request)
                           #'ignore))
                  ;; Split at position i
                  (let ((chunk1 (substring json-line 0 (1+ i)))
                        (chunk2 (substring json-line (1+ i))))
                    (test-json-fuzzer--feed-chunks process state
                                                   (list chunk1 chunk2)))))
            (when (process-live-p process)
              (delete-process process))))
        ;; Every split position should produce exactly one message
        (should (= 1 (length received-texts)))
        (should (equal "Hello 世界!" (car received-texts)))
        (should (null errors))))))

(provide 'test-harness-phase2)
;;; test-harness-phase2.el ends here
