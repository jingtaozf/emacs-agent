;;; test-verbose-formatter.el --- Tests for verbose message formatters -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Tests for claude-agent--verbose-format-* helper functions extracted from
;; the monolithic claude-agent--verbose-format-message dispatcher.
;; Verifies each message type formatter independently.

;;; Code:

(require 'ert)
(require 'claude-agent)

;;; Test: Assistant message formatting

(ert-deftest test-verbose-format-assistant-text-block ()
  "Assistant message with a text block returns the text."
  :tags '(:unit :regression)
  (let* ((block (claude-agent-make-text-block :text "Hello world"))
         (msg (claude-agent-make-assistant-message :content (list block)))
         (result (claude-agent--verbose-format-assistant-msg msg)))
    (should (stringp result))
    (should (string-match-p "Hello world" result))))

(ert-deftest test-verbose-format-assistant-empty-content ()
  "Assistant message with empty content returns nil."
  :tags '(:unit)
  (let* ((msg (claude-agent-make-assistant-message :content nil))
         (result (claude-agent--verbose-format-assistant-msg msg)))
    (should (null result))))

(ert-deftest test-verbose-format-assistant-multiple-blocks ()
  "Assistant message with multiple blocks joins them."
  :tags '(:unit)
  (let* ((b1 (claude-agent-make-text-block :text "First. "))
         (b2 (claude-agent-make-text-block :text "Second."))
         (msg (claude-agent-make-assistant-message :content (list b1 b2)))
         (result (claude-agent--verbose-format-assistant-msg msg)))
    (should (stringp result))
    (should (string-match-p "First" result))
    (should (string-match-p "Second" result))))

;;; Test: User message formatting

(ert-deftest test-verbose-format-user-string-content ()
  "User message with string content returns nil (already in header)."
  :tags '(:unit)
  (let* ((msg (claude-agent-make-user-message :content "Hello"))
         (result (claude-agent--verbose-format-user-msg msg)))
    (should (null result))))

(ert-deftest test-verbose-format-user-nil-content ()
  "User message with nil content returns nil."
  :tags '(:unit)
  (let* ((msg (claude-agent-make-user-message :content nil))
         (result (claude-agent--verbose-format-user-msg msg)))
    (should (null result))))

;;; Test: System message formatting

(ert-deftest test-verbose-format-system-error ()
  "System error message shows error prefix."
  :tags '(:unit)
  (let* ((msg (claude-agent-make-system-message
               :subtype "error"
               :data '(:message "Something broke")))
         (result (claude-agent--verbose-format-system-msg msg)))
    (should (stringp result))
    (should (string-match-p "Error" result))
    (should (string-match-p "Something broke" result))))

(ert-deftest test-verbose-format-system-init ()
  "System init message shows init text."
  :tags '(:unit)
  (let* ((msg (claude-agent-make-system-message
               :subtype "init"
               :data '(:message "Starting up")))
         (result (claude-agent--verbose-format-system-msg msg)))
    (should (stringp result))
    (should (string-match-p "Starting up" result))))

(ert-deftest test-verbose-format-system-init-no-message ()
  "System init message without text uses default."
  :tags '(:unit)
  (let* ((msg (claude-agent-make-system-message
               :subtype "init"
               :data nil))
         (result (claude-agent--verbose-format-system-msg msg)))
    (should (stringp result))
    (should (string-match-p "Initializing" result))))

(ert-deftest test-verbose-format-system-with-message-text ()
  "System message with generic message text shows it."
  :tags '(:unit)
  (let* ((msg (claude-agent-make-system-message
               :subtype "compaction"
               :data '(:message "Compacting conversation...")))
         (result (claude-agent--verbose-format-system-msg msg)))
    (should (stringp result))
    (should (string-match-p "Compacting conversation" result))))

(ert-deftest test-verbose-format-system-subtype-only ()
  "System message with just subtype (no message) shows subtype."
  :tags '(:unit)
  (let* ((msg (claude-agent-make-system-message
               :subtype "heartbeat"
               :data nil))
         (result (claude-agent--verbose-format-system-msg msg)))
    (should (stringp result))
    (should (string-match-p "heartbeat" result))))

(ert-deftest test-verbose-format-system-nil-everything ()
  "System message with nil subtype and nil data returns nil."
  :tags '(:unit)
  (let* ((msg (claude-agent-make-system-message
               :subtype nil
               :data nil))
         (result (claude-agent--verbose-format-system-msg msg)))
    (should (null result))))

;;; Test: Result message formatting

(ert-deftest test-verbose-format-result-message ()
  "Result message shows duration and cost."
  :tags '(:unit)
  (let* ((msg (claude-agent-make-result-message
               :duration-ms 5000
               :total-cost-usd 0.0123))
         (result (claude-agent--verbose-format-result-msg msg)))
    (should (stringp result))
    (should (string-match-p "5\\.0s" result))
    (should (string-match-p "0\\.0123" result))
    (should (string-match-p "Complete" result))))

(ert-deftest test-verbose-format-result-nil-values ()
  "Result message handles nil duration and cost gracefully."
  :tags '(:unit)
  (let* ((msg (claude-agent-make-result-message
               :duration-ms nil
               :total-cost-usd nil))
         (result (claude-agent--verbose-format-result-msg msg)))
    (should (stringp result))
    (should (string-match-p "0\\.0s" result))
    (should (string-match-p "0\\.0000" result))))

;;; Test: Dispatcher

(ert-deftest test-verbose-format-message-dispatches-correctly ()
  "Top-level dispatcher routes to correct type-specific formatter."
  :tags '(:unit)
  ;; Assistant
  (let* ((block (claude-agent-make-text-block :text "test"))
         (msg (claude-agent-make-assistant-message :content (list block))))
    (should (string-match-p "test" (claude-agent--verbose-format-message msg))))
  ;; System
  (let ((msg (claude-agent-make-system-message :subtype "error" :data '(:message "oops"))))
    (should (string-match-p "oops" (claude-agent--verbose-format-message msg))))
  ;; Result
  (let ((msg (claude-agent-make-result-message :duration-ms 1000 :total-cost-usd 0.01)))
    (should (string-match-p "Complete" (claude-agent--verbose-format-message msg))))
  ;; Unknown type → nil
  (should (null (claude-agent--verbose-format-message "not-a-message"))))

;;; Test: Content blocks helper

(ert-deftest test-verbose-format-content-blocks-basic ()
  "format-content-blocks joins multiple blocks."
  :tags '(:unit)
  (let* ((b1 (claude-agent-make-text-block :text "A"))
         (b2 (claude-agent-make-text-block :text "B"))
         (result (claude-agent--verbose-format-content-blocks (list b1 b2))))
    (should (stringp result))
    (should (string-match-p "A" result))
    (should (string-match-p "B" result))))

(ert-deftest test-verbose-format-content-blocks-empty ()
  "format-content-blocks with empty list returns nil."
  :tags '(:unit)
  (should (null (claude-agent--verbose-format-content-blocks nil))))

(provide 'test-verbose-formatter)
;;; test-verbose-formatter.el ends here
