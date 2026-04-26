;;; test-code-agent-org-telemetry.el --- Tests for F5: Basic telemetry -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;;; Commentary:

;; F5: Tests for persisting per-query metrics (usage, duration, tool count)
;; to org properties on the response heading.

;;; Code:

(require 'ert)

;;; Test 1: Usage data persisted to org properties

(ert-deftest test-telemetry-usage-persisted ()
  "Usage tokens are written to response heading properties.
FIX: In the completion handler, call org-entry-put for token counts."
  :tags '(:unit :fast :stable :telemetry)
  (with-temp-buffer
    (org-mode)
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "test-session"))
      (insert "* Instruction\n")
      (insert "** Response\n")
      (insert ":PROPERTIES:\n")
      (insert ":QUERY_ID: q-tel-1\n")
      (insert ":END:\n")
      (insert "Response text\n")
      (code-agent-org--session-put session-key :marker (point-min-marker))
      (code-agent-org--session-put session-key :query-id "q-tel-1")
      ;; Simulate persisting usage data
      (code-agent-org--persist-telemetry session-key
                                     '(:input-tokens 1500
                                       :output-tokens 300
                                       :cache-read-tokens 800))
      ;; Verify org properties
      (goto-char (point-min))
      (re-search-forward ":QUERY_ID: q-tel-1" nil t)
      (org-back-to-heading t)
      (should (equal "1500" (org-entry-get nil "INPUT_TOKENS")))
      (should (equal "300" (org-entry-get nil "OUTPUT_TOKENS")))
      (should (equal "800" (org-entry-get nil "CACHE_READ_TOKENS"))))))

;;; Test 2: Duration tracking

(ert-deftest test-telemetry-duration-persisted ()
  "Query duration in seconds is persisted to DURATION_SECS property.
FIX: Record start-time on query begin, compute duration on completion."
  :tags '(:unit :fast :stable :telemetry)
  (with-temp-buffer
    (org-mode)
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "test-session"))
      (insert "* Instruction\n")
      (insert "** Response\n")
      (insert ":PROPERTIES:\n")
      (insert ":QUERY_ID: q-tel-2\n")
      (insert ":END:\n")
      (insert "Response text\n")
      (code-agent-org--session-put session-key :marker (point-min-marker))
      (code-agent-org--session-put session-key :query-id "q-tel-2")
      (code-agent-org--session-put session-key :start-time (- (float-time) 5.3))
      ;; Persist duration
      (code-agent-org--persist-duration session-key)
      ;; Verify property (should be approximately 5 seconds)
      (goto-char (point-min))
      (re-search-forward ":QUERY_ID: q-tel-2" nil t)
      (org-back-to-heading t)
      (let ((duration (string-to-number (or (org-entry-get nil "DURATION_SECS") "0"))))
        (should (> duration 4.0))
        (should (< duration 10.0))))))

;;; Test 3: Tool call count

(ert-deftest test-telemetry-tool-count-persisted ()
  "Tool call count is persisted to TOOL_CALLS property.
FIX: Increment counter on each tool-use message, persist on completion."
  :tags '(:unit :fast :stable :telemetry)
  (with-temp-buffer
    (org-mode)
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "test-session"))
      (insert "* Instruction\n")
      (insert "** Response\n")
      (insert ":PROPERTIES:\n")
      (insert ":QUERY_ID: q-tel-3\n")
      (insert ":END:\n")
      (insert "Response text\n")
      (code-agent-org--session-put session-key :marker (point-min-marker))
      (code-agent-org--session-put session-key :query-id "q-tel-3")
      ;; Simulate 5 tool calls
      (code-agent-org--session-put session-key :tool-call-count 5)
      ;; Persist tool count
      (code-agent-org--persist-tool-count session-key)
      ;; Verify property
      (goto-char (point-min))
      (re-search-forward ":QUERY_ID: q-tel-3" nil t)
      (org-back-to-heading t)
      (should (equal "5" (org-entry-get nil "TOOL_CALLS"))))))

(provide 'test-code-agent-org-telemetry)
;;; test-code-agent-org-telemetry.el ends here
