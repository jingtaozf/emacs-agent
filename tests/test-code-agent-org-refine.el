;;; test-code-agent-org-refine.el --- Tests for prompt refinement -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Tests for code-agent-org-refine-prompt and code-agent-refine-prompt.
;; Ensures async callbacks properly capture buffer/marker variables
;; (regression test for lexical-let vs let in dynamic-binding context).
;; These tests do NOT make actual API calls.

;;; Code:

(require 'ert)
(require 'org)
(require 'code-agent-org)

;; ═══════════════════════════════════════════════════
;; Helper: simulate async refine-prompt completion
;; ═══════════════════════════════════════════════════

(defvar test-refine--captured-callbacks nil
  "Alist of callbacks captured from the last mocked code-agent-query call.
Keys: :on-message, :on-error, :on-complete.")

(defun test-refine--mock-query (prompt &rest args)
  "Mock `code-agent-query' that captures callbacks without spawning a process.
PROMPT and ARGS match the real signature."
  (ignore prompt)
  (setq test-refine--captured-callbacks
        (list :on-message  (plist-get args :on-message)
              :on-error    (plist-get args :on-error)
              :on-complete (plist-get args :on-complete))))

(defun test-refine--fire-on-complete (&optional result)
  "Invoke the captured :on-complete callback with RESULT."
  (let ((cb (plist-get test-refine--captured-callbacks :on-complete)))
    (when cb (funcall cb result))))

(defun test-refine--fire-on-message (msg)
  "Invoke the captured :on-message callback with MSG."
  (let ((cb (plist-get test-refine--captured-callbacks :on-message)))
    (when cb (funcall cb msg))))

(defun test-refine--fire-on-error (err)
  "Invoke the captured :on-error callback with ERR."
  (let ((cb (plist-get test-refine--captured-callbacks :on-error)))
    (when cb (funcall cb err))))

;; ═══════════════════════════════════════════════════
;; Tests: code-agent-refine-prompt (core SDK layer)
;; ═══════════════════════════════════════════════════

(ert-deftest test-refine-prompt-on-result-callback-receives-text ()
  "Test that on-result callback receives the collected refined text."
  :tags '(:unit :fast :stable :isolated :refine)
  (let ((result-text nil))
    (cl-letf (((symbol-function 'code-agent-query)
               #'test-refine--mock-query))
      (code-agent-refine-prompt
       "original prompt" "make it better"
       :on-result (lambda (refined) (setq result-text refined)))
      ;; Simulate assistant messages arriving
      (test-refine--fire-on-message
       (code-agent-make-assistant-message
        :content (list (code-agent-make-text-block :text "improved "))))
      (test-refine--fire-on-message
       (code-agent-make-assistant-message
        :content (list (code-agent-make-text-block :text "prompt here"))))
      ;; Simulate completion
      (test-refine--fire-on-complete nil)
      (should (equal "improved prompt here" result-text)))))

(ert-deftest test-refine-prompt-trims-whitespace ()
  "Test that on-result callback trims leading/trailing whitespace."
  :tags '(:unit :fast :stable :isolated :refine)
  (let ((result-text nil))
    (cl-letf (((symbol-function 'code-agent-query)
               #'test-refine--mock-query))
      (code-agent-refine-prompt
       "original" "intent"
       :on-result (lambda (refined) (setq result-text refined)))
      (test-refine--fire-on-message
       (code-agent-make-assistant-message
        :content (list (code-agent-make-text-block :text "  trimmed  \n"))))
      (test-refine--fire-on-complete nil)
      (should (equal "trimmed" result-text)))))

(ert-deftest test-refine-prompt-on-error-callback ()
  "Test that on-error callback is passed through to code-agent-query."
  :tags '(:unit :fast :stable :isolated :refine)
  (let ((error-received nil))
    (cl-letf (((symbol-function 'code-agent-query)
               #'test-refine--mock-query))
      (code-agent-refine-prompt
       "prompt" "intent"
       :on-error (lambda (err) (setq error-received err)))
      (test-refine--fire-on-error "something went wrong")
      (should (equal "something went wrong" error-received)))))

;; ═══════════════════════════════════════════════════
;; Tests: code-agent-org-refine-prompt (org-mode layer)
;; Regression: lexical-let must capture source-buffer
;; ═══════════════════════════════════════════════════

(ert-deftest test-org-refine-prompt-replaces-block-content ()
  "Test that refine-prompt callback correctly replaces ai block content.
This is the REGRESSION TEST for the void-variable source-buffer bug.
The callback must work even though it fires after the let scope exits."
  :tags '(:unit :fast :stable :isolated :refine :regression)
  (let ((refine-on-result nil)
        (refine-on-error nil))
    ;; Mock code-agent-refine-prompt to capture callbacks without network
    (cl-letf (((symbol-function 'code-agent-refine-prompt)
               (lambda (content intent &rest args)
                 (ignore content intent)
                 (setq refine-on-result (plist-get args :on-result)
                       refine-on-error  (plist-get args :on-error))))
              ((symbol-function 'read-string)
               (lambda (&rest _) "make it more specific")))
      (with-temp-buffer
        (org-mode)
        (insert "#+begin_src ai\noriginal prompt here\n#+end_src\n")
        (goto-char (point-min))
        (forward-line 1) ; position inside the block
        ;; Call refine - this captures source-buffer via lexical-let
        (code-agent-org-refine-prompt)
        ;; At this point the let* in code-agent-org-refine-prompt has exited.
        ;; Under dynamic binding with plain let, source-buffer would be void.
        ;; With lexical-let, the callback should still work.
        (should refine-on-result)
        ;; Now fire the callback (simulating async completion)
        (funcall refine-on-result "refined prompt text")
        ;; Verify block content was replaced
        (goto-char (point-min))
        (should (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai" nil t))
        (forward-line 1)
        (let ((start (point)))
          (re-search-forward "^[ \t]*#\\+end_src" nil t)
          (forward-line 0)
          (should (equal "refined prompt text\n"
                         (buffer-substring-no-properties start (point)))))))))

(ert-deftest test-org-refine-prompt-handles-killed-buffer ()
  "Test that refine callback gracefully handles a killed source buffer."
  :tags '(:unit :fast :stable :isolated :refine :regression)
  (let ((refine-on-result nil)
        (message-logged nil))
    (cl-letf (((symbol-function 'code-agent-refine-prompt)
               (lambda (_content _intent &rest args)
                 (setq refine-on-result (plist-get args :on-result))))
              ((symbol-function 'read-string)
               (lambda (&rest _) "make it better"))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-logged (apply #'format fmt args)))))
      (let ((buf (generate-new-buffer " *test-refine-killed*")))
        (with-current-buffer buf
          (org-mode)
          (insert "#+begin_src ai\nold prompt\n#+end_src\n")
          (goto-char (point-min))
          (forward-line 1)
          (code-agent-org-refine-prompt))
        ;; Kill the buffer before callback fires
        (kill-buffer buf)
        ;; Now fire callback — should not error, just message
        (should refine-on-result)
        (funcall refine-on-result "new prompt")
        (should (equal "Source buffer no longer exists" message-logged))))))

;; ═══════════════════════════════════════════════════
;; Tests: code-agent-chat--send-input (chat layer)
;; Regression: lexical-let must capture chat-buf
;; ═══════════════════════════════════════════════════

(ert-deftest test-chat-send-input-callbacks-capture-buffer ()
  "Test that chat send-input callbacks correctly capture the chat buffer.
Regression test for void-variable chat-buf bug."
  :tags '(:unit :fast :stable :isolated :chat :regression)
  (let ((captured-on-message nil)
        (captured-on-complete nil)
        (message-handler-called nil)
        (complete-handler-called nil))
    ;; Mock code-agent-query to capture the callbacks
    (cl-letf (((symbol-function 'code-agent-query)
               (lambda (_prompt &rest args)
                 (setq captured-on-message  (plist-get args :on-message)
                       captured-on-complete (plist-get args :on-complete))))
              ;; Mock the chat helper functions to avoid needing full chat setup
              ((symbol-function 'code-agent-chat--insert-response-start)
               #'ignore)
              ((symbol-function 'code-agent-chat--insert)
               (lambda (&rest _) nil))
              ((symbol-function 'code-agent-chat--handle-message)
               (lambda (_msg) (setq message-handler-called t)))
              ((symbol-function 'code-agent-chat--handle-complete)
               (lambda (_result) (setq complete-handler-called t))))
      (with-temp-buffer
        ;; Set up minimal chat buffer state
        (setq-local code-agent-chat--waiting nil)
        (setq-local code-agent-chat--current-response "")
        (setq-local code-agent-chat--session-id nil)
        (setq-local code-agent-chat--options nil)
        (setq-local code-agent-chat--system-prompt nil)
        (setq-local code-agent-chat--mcp-config nil)
        (setq-local code-agent-chat-include-ide-context nil)
        ;; Send input - this binds chat-buf with lexical-let
        (code-agent-chat--send-input "hello")
        ;; The let* in chat--send-input has exited by now.
        ;; With plain let + dynamic binding, chat-buf would be void.
        (should captured-on-message)
        (should captured-on-complete)
        ;; Fire callbacks — these must not error
        (funcall captured-on-message
                 (code-agent-make-assistant-message
                  :content (list (code-agent-make-text-block :text "hi"))))
        (should message-handler-called)
        (funcall captured-on-complete nil)
        (should complete-handler-called)))))

(ert-deftest test-chat-send-input-handles-killed-buffer ()
  "Test that chat callbacks gracefully handle a killed buffer."
  :tags '(:unit :fast :stable :isolated :chat :regression)
  (let ((captured-on-message nil)
        (captured-on-complete nil))
    (cl-letf (((symbol-function 'code-agent-query)
               (lambda (_prompt &rest args)
                 (setq captured-on-message  (plist-get args :on-message)
                       captured-on-complete (plist-get args :on-complete))))
              ((symbol-function 'code-agent-chat--insert-response-start)
               #'ignore)
              ((symbol-function 'code-agent-chat--insert)
               (lambda (&rest _) nil)))
      (let ((buf (generate-new-buffer " *test-chat-killed*")))
        (with-current-buffer buf
          (setq-local code-agent-chat--waiting nil)
          (setq-local code-agent-chat--current-response "")
          (setq-local code-agent-chat--session-id nil)
          (setq-local code-agent-chat--options nil)
          (setq-local code-agent-chat--system-prompt nil)
          (setq-local code-agent-chat--mcp-config nil)
          (setq-local code-agent-chat-include-ide-context nil)
          (code-agent-chat--send-input "hello"))
        ;; Kill the buffer before callbacks fire
        (kill-buffer buf)
        ;; Fire callbacks — should silently skip, not error
        (should captured-on-message)
        (should-not
         (condition-case err
             (progn
               (funcall captured-on-message
                        (code-agent-make-assistant-message
                         :content (list (code-agent-make-text-block :text "hi"))))
               nil)  ; no error
           (error err)))
        (should-not
         (condition-case err
             (progn (funcall captured-on-complete nil) nil)
           (error err)))))))

(provide 'test-code-agent-org-refine)
;;; test-code-agent-org-refine.el ends here
