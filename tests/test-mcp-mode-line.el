;;; test-mcp-mode-line.el --- Tests for MCP server mode-line spinner -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit and integration tests for the MCP server mode-line spinner feature.
;; Tests verify:
;; - Spinner state management (start/stop/advance)
;; - Activity string updates
;; - Mode-line integration
;; - Verbose logging functionality

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; Unit Tests - Spinner State Management

(ert-deftest test-mcp-mode-line-variables-defined ()
  "Test that mode-line related variables are defined."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (should (boundp 'emacs-mcp-server-show-mode-line))
  (should (boundp 'emacs-mcp-server--eval-active))
  (should (boundp 'emacs-mcp-server--eval-count))
  (should (boundp 'emacs-mcp-server--spinner-index))
  (should (boundp 'emacs-mcp-server--spinner-timer))
  (should (boundp 'emacs-mcp-server--spinner-frames))
  (should (boundp 'emacs-mcp-server-activity-string)))

(ert-deftest test-mcp-mode-line-functions-defined ()
  "Test that mode-line related functions are defined."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (should (fboundp 'emacs-mcp-server--update-activity-string))
  (should (fboundp 'emacs-mcp-server--start-spinner))
  (should (fboundp 'emacs-mcp-server--stop-spinner))
  (should (fboundp 'emacs-mcp-server--advance-spinner))
  (should (fboundp 'emacs-mcp-server--eval-start))
  (should (fboundp 'emacs-mcp-server--eval-end)))

(ert-deftest test-mcp-mode-line-spinner-frames ()
  "Test that spinner frames array is valid."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (should (vectorp emacs-mcp-server--spinner-frames))
  (should (> (length emacs-mcp-server--spinner-frames) 0))
  ;; Each frame should be a string
  (dotimes (i (length emacs-mcp-server--spinner-frames))
    (should (stringp (aref emacs-mcp-server--spinner-frames i)))))

(ert-deftest test-mcp-mode-line-eval-start-sets-active ()
  "Test that eval-start sets the active flag."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (let ((orig-active emacs-mcp-server--eval-active)
        (orig-count emacs-mcp-server--eval-count)
        (orig-timer emacs-mcp-server--spinner-timer))
    (unwind-protect
        (progn
          ;; Reset state
          (setq emacs-mcp-server--eval-active nil)
          (setq emacs-mcp-server--eval-count 0)
          ;; Start eval
          (emacs-mcp-server--eval-start)
          ;; Check state
          (should emacs-mcp-server--eval-active)
          (should (= 1 emacs-mcp-server--eval-count))
          ;; Clean up
          (emacs-mcp-server--eval-end))
      ;; Restore original state
      (setq emacs-mcp-server--eval-active orig-active)
      (setq emacs-mcp-server--eval-count orig-count)
      (when (and orig-timer (not emacs-mcp-server--spinner-timer))
        (emacs-mcp-server--start-spinner)))))

(ert-deftest test-mcp-mode-line-eval-end-clears-active ()
  "Test that eval-end clears the active flag when count reaches zero."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (let ((orig-active emacs-mcp-server--eval-active)
        (orig-count emacs-mcp-server--eval-count))
    (unwind-protect
        (progn
          ;; Start eval
          (setq emacs-mcp-server--eval-active nil)
          (setq emacs-mcp-server--eval-count 0)
          (emacs-mcp-server--eval-start)
          (should emacs-mcp-server--eval-active)
          ;; End eval
          (emacs-mcp-server--eval-end)
          (should-not emacs-mcp-server--eval-active)
          (should (= 0 emacs-mcp-server--eval-count)))
      ;; Restore
      (setq emacs-mcp-server--eval-active orig-active)
      (setq emacs-mcp-server--eval-count orig-count))))

(ert-deftest test-mcp-mode-line-nested-eval-count ()
  "Test that nested evals are tracked correctly."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (let ((orig-active emacs-mcp-server--eval-active)
        (orig-count emacs-mcp-server--eval-count))
    (unwind-protect
        (progn
          (setq emacs-mcp-server--eval-active nil)
          (setq emacs-mcp-server--eval-count 0)
          ;; Start first eval
          (emacs-mcp-server--eval-start)
          (should (= 1 emacs-mcp-server--eval-count))
          (should emacs-mcp-server--eval-active)
          ;; Start second (nested) eval
          (emacs-mcp-server--eval-start)
          (should (= 2 emacs-mcp-server--eval-count))
          (should emacs-mcp-server--eval-active)
          ;; End first eval - still active
          (emacs-mcp-server--eval-end)
          (should (= 1 emacs-mcp-server--eval-count))
          (should emacs-mcp-server--eval-active)
          ;; End second eval - now inactive
          (emacs-mcp-server--eval-end)
          (should (= 0 emacs-mcp-server--eval-count))
          (should-not emacs-mcp-server--eval-active))
      ;; Restore
      (setq emacs-mcp-server--eval-active orig-active)
      (setq emacs-mcp-server--eval-count orig-count))))

(ert-deftest test-mcp-mode-line-activity-string-when-active ()
  "Test that activity string is set when eval is active."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (let ((orig-active emacs-mcp-server--eval-active)
        (orig-string emacs-mcp-server-activity-string)
        (orig-show emacs-mcp-server-show-mode-line))
    (unwind-protect
        (progn
          (setq emacs-mcp-server-show-mode-line t)
          (setq emacs-mcp-server--eval-active t)
          (emacs-mcp-server--update-activity-string)
          ;; Should contain MCP
          (should (string-match-p "MCP" emacs-mcp-server-activity-string))
          ;; Should contain a spinner character
          (should (> (length emacs-mcp-server-activity-string) 0)))
      ;; Restore
      (setq emacs-mcp-server--eval-active orig-active)
      (setq emacs-mcp-server-activity-string orig-string)
      (setq emacs-mcp-server-show-mode-line orig-show))))

(ert-deftest test-mcp-mode-line-activity-string-when-inactive ()
  "Test that activity string is empty when eval is not active."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (let ((orig-active emacs-mcp-server--eval-active)
        (orig-string emacs-mcp-server-activity-string))
    (unwind-protect
        (progn
          (setq emacs-mcp-server--eval-active nil)
          (emacs-mcp-server--update-activity-string)
          (should (string= "" emacs-mcp-server-activity-string)))
      ;; Restore
      (setq emacs-mcp-server--eval-active orig-active)
      (setq emacs-mcp-server-activity-string orig-string))))

(ert-deftest test-mcp-mode-line-activity-string-respects-show-flag ()
  "Test that activity string respects show-mode-line setting."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (let ((orig-active emacs-mcp-server--eval-active)
        (orig-string emacs-mcp-server-activity-string)
        (orig-show emacs-mcp-server-show-mode-line))
    (unwind-protect
        (progn
          (setq emacs-mcp-server--eval-active t)
          ;; With show-mode-line disabled
          (setq emacs-mcp-server-show-mode-line nil)
          (emacs-mcp-server--update-activity-string)
          (should (string= "" emacs-mcp-server-activity-string))
          ;; With show-mode-line enabled
          (setq emacs-mcp-server-show-mode-line t)
          (emacs-mcp-server--update-activity-string)
          (should (string-match-p "MCP" emacs-mcp-server-activity-string)))
      ;; Restore
      (setq emacs-mcp-server--eval-active orig-active)
      (setq emacs-mcp-server-activity-string orig-string)
      (setq emacs-mcp-server-show-mode-line orig-show))))

(ert-deftest test-mcp-mode-line-spinner-advance ()
  "Test that spinner index advances correctly."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (let ((orig-index emacs-mcp-server--spinner-index)
        (orig-active emacs-mcp-server--eval-active))
    (unwind-protect
        (progn
          (setq emacs-mcp-server--spinner-index 0)
          (setq emacs-mcp-server--eval-active t)
          ;; Advance spinner
          (emacs-mcp-server--advance-spinner)
          (should (= 1 emacs-mcp-server--spinner-index))
          ;; Advance again
          (emacs-mcp-server--advance-spinner)
          (should (= 2 emacs-mcp-server--spinner-index))
          ;; Test wraparound
          (setq emacs-mcp-server--spinner-index
                (1- (length emacs-mcp-server--spinner-frames)))
          (emacs-mcp-server--advance-spinner)
          (should (= 0 emacs-mcp-server--spinner-index)))
      ;; Restore
      (setq emacs-mcp-server--spinner-index orig-index)
      (setq emacs-mcp-server--eval-active orig-active))))

(ert-deftest test-mcp-mode-line-stop-spinner-resets-index ()
  "Test that stop-spinner resets the spinner index."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (let ((orig-index emacs-mcp-server--spinner-index)
        (orig-timer emacs-mcp-server--spinner-timer))
    (unwind-protect
        (progn
          (setq emacs-mcp-server--spinner-index 5)
          (emacs-mcp-server--stop-spinner)
          (should (= 0 emacs-mcp-server--spinner-index))
          (should-not emacs-mcp-server--spinner-timer))
      ;; Restore
      (setq emacs-mcp-server--spinner-index orig-index)
      (setq emacs-mcp-server--spinner-timer orig-timer))))

;;; Integration Tests - Mode-Line Registration

(ert-deftest test-mcp-mode-line-in-misc-info ()
  "Test that activity string is registered in mode-line-misc-info."
  :tags '(:integration :mcp-mode-line)
  (should (member '(:eval emacs-mcp-server-activity-string) mode-line-misc-info)))

(ert-deftest test-mcp-mode-line-rendered-during-eval ()
  "Test that mode-line contains MCP indicator during eval."
  :tags '(:integration :mcp-mode-line)
  ;; Skip in batch mode as format-mode-line may not work correctly
  (skip-unless (not noninteractive))
  (let ((orig-active emacs-mcp-server--eval-active)
        (orig-string emacs-mcp-server-activity-string)
        (orig-show emacs-mcp-server-show-mode-line))
    (unwind-protect
        (progn
          (setq emacs-mcp-server-show-mode-line t)
          (setq emacs-mcp-server--eval-active t)
          (emacs-mcp-server--update-activity-string)
          ;; Force mode-line update
          (force-mode-line-update t)
          ;; Check rendered mode-line contains MCP
          (let ((rendered (format-mode-line mode-line-misc-info)))
            (should (string-match-p "MCP" rendered))))
      ;; Restore
      (setq emacs-mcp-server--eval-active orig-active)
      (setq emacs-mcp-server-activity-string orig-string)
      (setq emacs-mcp-server-show-mode-line orig-show)
      (force-mode-line-update t))))

;;; Verbose Logging Tests

(ert-deftest test-mcp-verbose-logging-functions-defined ()
  "Test that verbose logging functions are defined."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (should (fboundp 'emacs-mcp-server--log))
  (should (fboundp 'emacs-mcp-server--log-eval-start))
  (should (fboundp 'emacs-mcp-server--log-eval-end))
  (should (fboundp 'emacs-mcp-server--log-eval-error))
  (should (fboundp 'emacs-mcp-server-toggle-verbose))
  (should (fboundp 'emacs-mcp-server-show-log)))

(ert-deftest test-mcp-verbose-logging-toggle ()
  "Test verbose logging toggle."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (let ((orig-verbose emacs-mcp-server-verbose))
    (unwind-protect
        (progn
          (setq emacs-mcp-server-verbose nil)
          (emacs-mcp-server-toggle-verbose)
          (should emacs-mcp-server-verbose)
          (emacs-mcp-server-toggle-verbose)
          (should-not emacs-mcp-server-verbose))
      ;; Restore
      (setq emacs-mcp-server-verbose orig-verbose))))

(ert-deftest test-mcp-verbose-logging-writes-to-buffer ()
  "Test that verbose logging writes to log buffer."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (let ((orig-verbose emacs-mcp-server-verbose)
        (log-buffer (get-buffer emacs-mcp-server--log-buffer)))
    (unwind-protect
        (progn
          ;; Enable verbose and log something
          (setq emacs-mcp-server-verbose t)
          (emacs-mcp-server--log "Test message %d" 123)
          ;; Check buffer exists and contains message
          (let ((buf (get-buffer emacs-mcp-server--log-buffer)))
            (should buf)
            (with-current-buffer buf
              (should (string-match-p "Test message 123" (buffer-string))))))
      ;; Restore and cleanup
      (setq emacs-mcp-server-verbose orig-verbose)
      (let ((buf (get-buffer emacs-mcp-server--log-buffer)))
        (when (and buf (not log-buffer))
          (kill-buffer buf))))))

(ert-deftest test-mcp-verbose-logging-respects-flag ()
  "Test that logging respects verbose flag."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (let ((orig-verbose emacs-mcp-server-verbose))
    (unwind-protect
        (progn
          ;; Disable verbose
          (setq emacs-mcp-server-verbose nil)
          ;; Kill log buffer if exists
          (let ((buf (get-buffer emacs-mcp-server--log-buffer)))
            (when buf (kill-buffer buf)))
          ;; Try to log
          (emacs-mcp-server--log "Should not appear")
          ;; Buffer should not exist or be empty
          (let ((buf (get-buffer emacs-mcp-server--log-buffer)))
            (should (or (null buf)
                        (with-current-buffer buf
                          (string= "" (buffer-string)))))))
      ;; Restore
      (setq emacs-mcp-server-verbose orig-verbose))))

;;; State Preservation Tests

(ert-deftest test-mcp-state-preservation-function-defined ()
  "Test that state preservation function is defined."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (should (fboundp 'emacs-mcp-server--eval-with-state-preservation)))

(ert-deftest test-mcp-state-preservation-restores-buffer ()
  "Test that state preservation restores buffer after eval."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (let ((orig-buffer (current-buffer)))
    (with-temp-buffer
      (let ((temp-buf (current-buffer)))
        ;; Eval something that switches buffer
        (emacs-mcp-server--eval-with-state-preservation
         '(progn (switch-to-buffer "*scratch*") nil))
        ;; Should be back in temp buffer
        (should (eq (current-buffer) temp-buf))))))

(ert-deftest test-mcp-state-preservation-restores-point ()
  "Test that state preservation restores point after eval."
  :tags '(:unit :fast :stable :mcp-mode-line)
  (with-temp-buffer
    (insert "line 1\nline 2\nline 3\n")
    (goto-char 10)
    (let ((orig-point (point)))
      ;; Eval something that moves point
      (emacs-mcp-server--eval-with-state-preservation
       '(goto-char (point-min)))
      ;; Point should be restored
      (should (= (point) orig-point)))))

(provide 'test-mcp-mode-line)
;;; test-mcp-mode-line.el ends here
