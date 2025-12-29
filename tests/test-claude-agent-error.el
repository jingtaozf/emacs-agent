;;; test-claude-agent-error.el --- Tests for error analysis feature -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit and integration tests for claude-agent error analysis feature.
;; These tests verify debouncing, buffer creation, and prompt building.

;;; Code:

(require 'ert)
(require 'claude-agent)

;;; Unit Tests - Debounce Behavior

(ert-deftest test-error-analysis-debounce ()
  "Test that rapid analyze calls are debounced."
  :tags '(:unit :fast :stable :error-analysis)
  (let ((claude-agent-error--counter 0)
        (claude-agent-error--pending nil)
        (claude-agent-error--debounce-timer nil)
        (claude-agent-error-debounce-delay 0.1)
        (analysis-count 0))
    ;; Mock the start-chat function
    (cl-letf (((symbol-function 'claude-agent-error--start-chat)
               (lambda (_) (cl-incf analysis-count))))
      ;; Rapid calls - should only process the last one
      (claude-agent-error--queue-analysis "error 1")
      (claude-agent-error--queue-analysis "error 2")
      (claude-agent-error--queue-analysis "error 3")
      ;; Wait for debounce timer to fire
      (sleep-for 0.2)
      ;; Should only have one analysis (the last one)
      (should (= analysis-count 1))
      ;; Pending should be cleared
      (should (null claude-agent-error--pending)))))

(ert-deftest test-error-analysis-debounce-content ()
  "Test that debouncing keeps the last error content."
  :tags '(:unit :fast :stable :error-analysis)
  (let ((claude-agent-error--counter 0)
        (claude-agent-error--pending nil)
        (claude-agent-error--debounce-timer nil)
        (claude-agent-error-debounce-delay 0.1)
        (captured-content nil))
    (cl-letf (((symbol-function 'claude-agent-error--start-chat)
               (lambda (content) (setq captured-content content))))
      (claude-agent-error--queue-analysis "first error")
      (claude-agent-error--queue-analysis "second error")
      (claude-agent-error--queue-analysis "third error")
      (sleep-for 0.2)
      ;; Should have captured the last error
      (should (equal captured-content "third error")))))

;;; Unit Tests - Unique Buffer Creation

(ert-deftest test-error-analysis-unique-buffers ()
  "Test that each analysis creates a unique buffer."
  :tags '(:unit :fast :stable :error-analysis)
  (let ((claude-agent-error--counter 0))
    (let ((buf1 (claude-agent-error--create-chat-buffer))
          (buf2 (claude-agent-error--create-chat-buffer))
          (buf3 (claude-agent-error--create-chat-buffer)))
      (unwind-protect
          (progn
            (should (string= (buffer-name buf1) "*Claude Error Analysis 1*"))
            (should (string= (buffer-name buf2) "*Claude Error Analysis 2*"))
            (should (string= (buffer-name buf3) "*Claude Error Analysis 3*"))
            ;; All buffers should be distinct
            (should-not (eq buf1 buf2))
            (should-not (eq buf2 buf3)))
        ;; Cleanup
        (when (buffer-live-p buf1) (kill-buffer buf1))
        (when (buffer-live-p buf2) (kill-buffer buf2))
        (when (buffer-live-p buf3) (kill-buffer buf3))))))

(ert-deftest test-error-analysis-counter-persistence ()
  "Test that counter persists across calls."
  :tags '(:unit :fast :stable :error-analysis)
  (let ((claude-agent-error--counter 10))
    (let ((buf (claude-agent-error--create-chat-buffer)))
      (unwind-protect
          (progn
            (should (= claude-agent-error--counter 11))
            (should (string= (buffer-name buf) "*Claude Error Analysis 11*")))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;; Unit Tests - System Prompt Loading

(ert-deftest test-error-analysis-load-system-prompt ()
  "Test system prompt loading from file."
  :tags '(:unit :fast :stable :error-analysis)
  (let ((test-file (make-temp-file "error-prompt" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "You are an Emacs debugging assistant."))
          (let ((claude-agent-error-prompt-file test-file))
            (should (string-match-p "debugging assistant"
                                    (claude-agent-error--load-system-prompt)))))
      (delete-file test-file))))

(ert-deftest test-error-analysis-default-prompt-fallback ()
  "Test fallback to default prompt when file not found."
  :tags '(:unit :fast :stable :error-analysis)
  (let ((claude-agent-error-prompt-file "/nonexistent/path.org")
        (claude-agent-error-default-system-prompt "Default test prompt"))
    (should (string= (claude-agent-error--load-system-prompt)
                     "Default test prompt"))))

(ert-deftest test-error-analysis-nil-prompt-file ()
  "Test fallback when prompt file is nil."
  :tags '(:unit :fast :stable :error-analysis)
  (let ((claude-agent-error-prompt-file nil)
        (claude-agent-error-default-system-prompt "Fallback prompt"))
    (should (string= (claude-agent-error--load-system-prompt)
                     "Fallback prompt"))))

;;; Unit Tests - Prompt Building

(ert-deftest test-error-analysis-build-prompt ()
  "Test that prompt includes error content."
  :tags '(:unit :fast :stable :error-analysis)
  (let ((prompt (claude-agent-error--build-prompt
                 "Debugger entered: void-variable foo")))
    (should (string-match-p "void-variable foo" prompt))
    (should (string-match-p "analyze" (downcase prompt)))))

(ert-deftest test-error-analysis-build-prompt-multiline ()
  "Test prompt building with multiline backtrace."
  :tags '(:unit :fast :stable :error-analysis)
  (let* ((backtrace "Debugger entered--Lisp error: (void-variable test-var)
  debug(error (void-variable test-var))
  eval((print test-var) nil nil)
  pp-eval-expression((print test-var) nil)")
         (prompt (claude-agent-error--build-prompt backtrace)))
    (should (string-match-p "void-variable test-var" prompt))
    (should (string-match-p "pp-eval-expression" prompt))))

;;; Unit Tests - Backtrace Extraction

(ert-deftest test-error-analysis-extract-backtrace ()
  "Test backtrace content extraction from debugger-mode buffer."
  :tags '(:unit :fast :stable :error-analysis)
  (with-temp-buffer
    (insert "Debugger entered--Lisp error: (void-variable test-var)")
    (let ((major-mode 'debugger-mode)
          (captured-content nil))
      (cl-letf (((symbol-function 'claude-agent-error--queue-analysis)
                 (lambda (content) (setq captured-content content))))
        (claude-agent-analyze-backtrace)
        (should (string-match-p "void-variable test-var" captured-content))))))

(ert-deftest test-error-analysis-analyze-region ()
  "Test region analysis."
  :tags '(:unit :fast :stable :error-analysis)
  (with-temp-buffer
    (insert "Some text before\nError: something went wrong\nSome text after")
    (let ((captured-content nil))
      (cl-letf (((symbol-function 'claude-agent-error--queue-analysis)
                 (lambda (content) (setq captured-content content))))
        ;; Select the error line
        (goto-char (point-min))
        (forward-line 1)
        (let ((start (point)))
          (forward-line 1)
          (claude-agent-analyze-region start (point)))
        (should (string-match-p "something went wrong" captured-content))))))

;;; Integration Tests - Full Flow

(ert-deftest test-error-analysis-full-flow ()
  "Test full error analysis flow with mocked Claude."
  :tags '(:integration :error-analysis)
  (let ((claude-agent-error--counter 0)
        (claude-agent-error--pending nil)
        (claude-agent-error--debounce-timer nil)
        (claude-agent-error-debounce-delay 0.1)
        (chat-started nil)
        (created-buffer nil))
    ;; Mock chat mode functions
    (cl-letf (((symbol-function 'claude-agent-chat-mode)
               (lambda () (setq major-mode 'claude-agent-chat-mode)))
              ((symbol-function 'claude-agent-chat--initialize-buffer)
               (lambda () nil))
              ((symbol-function 'claude-agent-chat--send-input)
               (lambda (prompt)
                 (setq chat-started t)
                 (should (string-match-p "Test error" prompt))))
              ((symbol-function 'start-process)
               (lambda (name buf &rest _)
                 (setq created-buffer buf)
                 nil))
              ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
              ((symbol-function 'set-process-filter) #'ignore)
              ((symbol-function 'pop-to-buffer) #'ignore))
      ;; Trigger analysis
      (claude-agent-error--queue-analysis "Test error content")
      (sleep-for 0.2)
      ;; Verify chat was started
      (should chat-started)
      ;; Verify buffer was created with correct name
      (should (get-buffer "*Claude Error Analysis 1*"))
      ;; Cleanup
      (when (get-buffer "*Claude Error Analysis 1*")
        (kill-buffer "*Claude Error Analysis 1*")))))

(ert-deftest test-error-analysis-buffer-local-vars ()
  "Test that buffer-local variables are set correctly."
  :tags '(:integration :error-analysis)
  (let ((claude-agent-error--counter 0)
        (claude-agent-error--pending nil)
        (claude-agent-error--debounce-timer nil)
        (claude-agent-error-debounce-delay 0.1)
        (claude-agent-error-mcp-config "/test/mcp.json")
        (test-system-prompt "Test system prompt"))
    (cl-letf (((symbol-function 'claude-agent-chat-mode)
               (lambda () (setq major-mode 'claude-agent-chat-mode)))
              ((symbol-function 'claude-agent-chat--initialize-buffer) #'ignore)
              ((symbol-function 'claude-agent-chat--send-input) #'ignore)
              ((symbol-function 'start-process) (lambda (&rest _) nil))
              ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
              ((symbol-function 'set-process-filter) #'ignore)
              ((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'claude-agent-error--load-system-prompt)
               (lambda () test-system-prompt)))
      (claude-agent-error--queue-analysis "Test")
      (sleep-for 0.2)
      ;; Check buffer-local variables
      (when (get-buffer "*Claude Error Analysis 1*")
        (with-current-buffer "*Claude Error Analysis 1*"
          (should (equal claude-agent-chat--system-prompt test-system-prompt))
          (should (equal claude-agent-chat--mcp-config "/test/mcp.json"))
          (should (null claude-agent-chat-include-ide-context)))
        (kill-buffer "*Claude Error Analysis 1*")))))

(provide 'test-claude-agent-error)
;;; test-claude-agent-error.el ends here
