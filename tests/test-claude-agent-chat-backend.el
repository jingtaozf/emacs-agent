;;; test-claude-agent-chat-backend.el --- Tests for chat backend integration -*- lexical-binding: t; -*-

;;; Commentary:
;; TDD tests for wiring claude-agent-chat to the backend system.
;; Feature groups: F1 (defcustom), F2 (buffer-local), F3 (make-backend),
;; F4 (send-input), F5 (interrupt/cancel), F6 (kill cleanup), F7 (clear/new-session).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-agent)

;; ---------------------------------------------------------------------------
;; F1: defcustom claude-agent-chat-backend-type
;; ---------------------------------------------------------------------------

(ert-deftest test-chat-f1-backend-type-defcustom-exists ()
  "claude-agent-chat-backend-type defcustom should exist."
  :tags '(:unit :fast :stable :isolated :chat-backend :f1)
  (should (boundp 'claude-agent-chat-backend-type)))

(ert-deftest test-chat-f1-backend-type-default-is-json-stream ()
  "claude-agent-chat-backend-type should default to json-stream."
  :tags '(:unit :fast :stable :isolated :chat-backend :f1)
  (should (eq 'json-stream claude-agent-chat-backend-type)))

;; ---------------------------------------------------------------------------
;; F2: Buffer-local claude-agent-chat--backend
;; ---------------------------------------------------------------------------

(ert-deftest test-chat-f2-backend-var-is-buffer-local ()
  "claude-agent-chat--backend should be buffer-local after mode activation."
  :tags '(:unit :fast :stable :isolated :chat-backend :f2)
  (with-temp-buffer
    (let ((claude-agent-chat--backend nil))
      ;; defvar-local makes it automatically buffer-local
      (should (local-variable-if-set-p 'claude-agent-chat--backend)))))

(ert-deftest test-chat-f2-query-handle-var-is-buffer-local ()
  "claude-agent-chat--query-handle should be buffer-local after mode activation."
  :tags '(:unit :fast :stable :isolated :chat-backend :f2)
  (with-temp-buffer
    (let ((claude-agent-chat--query-handle nil))
      (should (local-variable-if-set-p 'claude-agent-chat--query-handle)))))

;; ---------------------------------------------------------------------------
;; F3: claude-agent-chat--make-backend
;; ---------------------------------------------------------------------------

(ert-deftest test-chat-f3-make-backend-json-stream ()
  "make-backend with json-stream type creates json-backend."
  :tags '(:unit :fast :stable :isolated :chat-backend :f3)
  (let ((claude-agent-chat-backend-type 'json-stream))
    (let ((backend (claude-agent-chat--make-backend)))
      (should (claude-agent-json-backend-p backend)))))

;; ---------------------------------------------------------------------------
;; F4: send-input uses backend
;; ---------------------------------------------------------------------------

(ert-deftest test-chat-f4-send-input-creates-backend-on-first-call ()
  "send-input should create backend if none exists."
  :tags '(:unit :fast :stable :isolated :chat-backend :f4)
  (with-temp-buffer
    (let ((claude-agent-chat--backend nil)
          (claude-agent-chat--query-handle nil)
          (claude-agent-chat--waiting nil)
          (claude-agent-chat--current-response "")
          (claude-agent-chat--session-id nil)
          (claude-agent-chat--system-prompt nil)
          (claude-agent-chat--mcp-config nil)
          (claude-agent-chat--options nil)
          (claude-agent-chat--response-start-marker nil)
          (claude-agent-chat-backend-type 'json-stream)
          (claude-agent-chat-include-ide-context nil)
          (query-called nil))
      (cl-letf (((symbol-function 'claude-agent-backend-query)
                 (lambda (backend prompt callbacks &rest args)
                   (setq query-called t)
                   'mock-handle))
                ((symbol-function 'claude-agent-chat--insert-response-start)
                 (lambda () nil))
                ((symbol-function 'claude-agent-chat--insert)
                 (lambda (&rest _) nil))
                ((symbol-function 'claude-agent-chat--show-prompt)
                 (lambda () nil)))
        (claude-agent-chat--send-input "hello")
        (should claude-agent-chat--backend)
        (should (claude-agent-json-backend-p claude-agent-chat--backend))
        (should query-called)))))

(ert-deftest test-chat-f4-send-input-reuses-existing-backend ()
  "send-input should reuse existing backend on subsequent calls."
  :tags '(:unit :fast :stable :isolated :chat-backend :f4)
  (with-temp-buffer
    (let* ((mock-backend (claude-agent-json-backend--create :session-key "test"))
           (claude-agent-chat--backend mock-backend)
           (claude-agent-chat--query-handle nil)
           (claude-agent-chat--waiting nil)
           (claude-agent-chat--current-response "")
           (claude-agent-chat--session-id nil)
           (claude-agent-chat--system-prompt nil)
           (claude-agent-chat--mcp-config nil)
           (claude-agent-chat--options nil)
           (claude-agent-chat--response-start-marker nil)
           (claude-agent-chat-include-ide-context nil)
           (queried-backend nil))
      (cl-letf (((symbol-function 'claude-agent-backend-query)
                 (lambda (backend prompt callbacks &rest args)
                   (setq queried-backend backend)
                   'mock-handle))
                ((symbol-function 'claude-agent-chat--insert-response-start)
                 (lambda () nil))
                ((symbol-function 'claude-agent-chat--insert)
                 (lambda (&rest _) nil))
                ((symbol-function 'claude-agent-chat--show-prompt)
                 (lambda () nil)))
        (claude-agent-chat--send-input "hello")
        (should (eq mock-backend queried-backend))))))

(ert-deftest test-chat-f4-send-input-stores-handle ()
  "send-input should store the returned handle."
  :tags '(:unit :fast :stable :isolated :chat-backend :f4)
  (with-temp-buffer
    (let ((claude-agent-chat--backend nil)
          (claude-agent-chat--query-handle nil)
          (claude-agent-chat--waiting nil)
          (claude-agent-chat--current-response "")
          (claude-agent-chat--session-id nil)
          (claude-agent-chat--system-prompt nil)
          (claude-agent-chat--mcp-config nil)
          (claude-agent-chat--options nil)
          (claude-agent-chat--response-start-marker nil)
          (claude-agent-chat-backend-type 'json-stream)
          (claude-agent-chat-include-ide-context nil))
      (cl-letf (((symbol-function 'claude-agent-backend-query)
                 (lambda (backend prompt callbacks &rest args)
                   'the-handle))
                ((symbol-function 'claude-agent-chat--insert-response-start)
                 (lambda () nil))
                ((symbol-function 'claude-agent-chat--insert)
                 (lambda (&rest _) nil))
                ((symbol-function 'claude-agent-chat--show-prompt)
                 (lambda () nil)))
        (claude-agent-chat--send-input "hello")
        (should (eq 'the-handle claude-agent-chat--query-handle))))))

(ert-deftest test-chat-f4-send-input-passes-callbacks-plist ()
  "send-input should pass callbacks as a plist to backend-query."
  :tags '(:unit :fast :stable :isolated :chat-backend :f4)
  (with-temp-buffer
    (let ((claude-agent-chat--backend nil)
          (claude-agent-chat--query-handle nil)
          (claude-agent-chat--waiting nil)
          (claude-agent-chat--current-response "")
          (claude-agent-chat--session-id nil)
          (claude-agent-chat--system-prompt nil)
          (claude-agent-chat--mcp-config nil)
          (claude-agent-chat--options nil)
          (claude-agent-chat--response-start-marker nil)
          (claude-agent-chat-backend-type 'json-stream)
          (claude-agent-chat-include-ide-context nil)
          (received-callbacks nil))
      (cl-letf (((symbol-function 'claude-agent-backend-query)
                 (lambda (backend prompt callbacks &rest args)
                   (setq received-callbacks callbacks)
                   'mock-handle))
                ((symbol-function 'claude-agent-chat--insert-response-start)
                 (lambda () nil))
                ((symbol-function 'claude-agent-chat--insert)
                 (lambda (&rest _) nil))
                ((symbol-function 'claude-agent-chat--show-prompt)
                 (lambda () nil)))
        (claude-agent-chat--send-input "hello")
        ;; Should have :on-token, :on-message, :on-error, :on-complete
        (should (plist-get received-callbacks :on-token))
        (should (plist-get received-callbacks :on-message))
        (should (plist-get received-callbacks :on-error))
        (should (plist-get received-callbacks :on-complete))))))

(ert-deftest test-chat-f4-send-input-passes-options ()
  "send-input should pass options to backend-query."
  :tags '(:unit :fast :stable :isolated :chat-backend :f4)
  (with-temp-buffer
    (let ((claude-agent-chat--backend nil)
          (claude-agent-chat--query-handle nil)
          (claude-agent-chat--waiting nil)
          (claude-agent-chat--current-response "")
          (claude-agent-chat--session-id "resume-123")
          (claude-agent-chat--system-prompt nil)
          (claude-agent-chat--mcp-config nil)
          (claude-agent-chat--options nil)
          (claude-agent-chat--response-start-marker nil)
          (claude-agent-chat-backend-type 'json-stream)
          (claude-agent-chat-include-ide-context nil)
          (received-args nil))
      (cl-letf (((symbol-function 'claude-agent-backend-query)
                 (lambda (backend prompt callbacks &rest args)
                   (setq received-args args)
                   'mock-handle))
                ((symbol-function 'claude-agent-chat--insert-response-start)
                 (lambda () nil))
                ((symbol-function 'claude-agent-chat--insert)
                 (lambda (&rest _) nil))
                ((symbol-function 'claude-agent-chat--show-prompt)
                 (lambda () nil)))
        (claude-agent-chat--send-input "hello")
        (let ((opts (plist-get received-args :options)))
          (should opts)
          (should (plist-get opts :resume))
          (should (equal "resume-123" (plist-get opts :resume))))))))

(ert-deftest test-chat-f4-send-input-waiting-guard ()
  "send-input should refuse when already waiting."
  :tags '(:unit :fast :stable :isolated :chat-backend :f4)
  (with-temp-buffer
    (let ((claude-agent-chat--waiting t)
          (query-called nil))
      (cl-letf (((symbol-function 'claude-agent-backend-query)
                 (lambda (&rest _) (setq query-called t) nil)))
        (claude-agent-chat--send-input "hello")
        (should-not query-called)))))

;; ---------------------------------------------------------------------------
;; F5: interrupt uses backend cancel
;; ---------------------------------------------------------------------------

(ert-deftest test-chat-f5-interrupt-calls-backend-cancel ()
  "chat-interrupt should call backend-cancel with handle."
  :tags '(:unit :fast :stable :isolated :chat-backend :f5)
  (with-temp-buffer
    (let* ((cancel-called nil)
           (mock-backend (claude-agent-json-backend--create))
           (claude-agent-chat--backend mock-backend)
           (claude-agent-chat--query-handle 'the-handle)
           (claude-agent-chat--waiting t))
      (cl-letf (((symbol-function 'claude-agent-backend-cancel)
                 (lambda (backend handle)
                   (setq cancel-called (list backend handle))))
                ((symbol-function 'claude-agent-chat--insert)
                 (lambda (&rest _) nil))
                ((symbol-function 'claude-agent-chat--show-prompt)
                 (lambda () nil)))
        (claude-agent-chat-interrupt)
        (should cancel-called)
        (should (eq mock-backend (car cancel-called)))
        (should (eq 'the-handle (cadr cancel-called)))
        (should-not claude-agent-chat--waiting)))))

(ert-deftest test-chat-f5-interrupt-no-backend-no-error ()
  "chat-interrupt should not error when no backend exists."
  :tags '(:unit :fast :stable :isolated :chat-backend :f5)
  (with-temp-buffer
    (let ((claude-agent-chat--backend nil)
          (claude-agent-chat--query-handle nil)
          (claude-agent-chat--waiting t))
      (cl-letf (((symbol-function 'claude-agent-chat--insert)
                 (lambda (&rest _) nil))
                ((symbol-function 'claude-agent-chat--show-prompt)
                 (lambda () nil)))
        ;; Should not error
        (claude-agent-chat-interrupt)
        (should-not claude-agent-chat--waiting)))))

(ert-deftest test-chat-f5-interrupt-nils-handle ()
  "chat-interrupt should nil out the query handle."
  :tags '(:unit :fast :stable :isolated :chat-backend :f5)
  (with-temp-buffer
    (let ((claude-agent-chat--backend (claude-agent-json-backend--create))
          (claude-agent-chat--query-handle 'some-handle)
          (claude-agent-chat--waiting t))
      (cl-letf (((symbol-function 'claude-agent-backend-cancel)
                 (lambda (&rest _) nil))
                ((symbol-function 'claude-agent-chat--insert)
                 (lambda (&rest _) nil))
                ((symbol-function 'claude-agent-chat--show-prompt)
                 (lambda () nil)))
        (claude-agent-chat-interrupt)
        (should-not claude-agent-chat--query-handle)))))

;; ---------------------------------------------------------------------------
;; F6: kill-buffer cleanup
;; ---------------------------------------------------------------------------

(ert-deftest test-chat-f6-kill-buffer-calls-backend-cleanup ()
  "Killing chat buffer should call backend-cleanup."
  :tags '(:unit :fast :stable :isolated :chat-backend :f6)
  (let ((cleanup-called nil))
    (cl-letf (((symbol-function 'claude-agent-backend-cleanup)
               (lambda (backend)
                 (setq cleanup-called backend)))
              ;; Prevent comint from needing real process
              ((symbol-function 'start-process)
               (lambda (&rest _) nil))
              ((symbol-function 'set-process-query-on-exit-flag)
               (lambda (&rest _) nil))
              ((symbol-function 'set-process-filter)
               (lambda (&rest _) nil)))
      (let ((buf (generate-new-buffer " *test-chat-kill*")))
        (with-current-buffer buf
          (setq-local claude-agent-chat--backend
                      (claude-agent-json-backend--create))
          ;; Simulate adding the hook (as chat-mode would)
          (add-hook 'kill-buffer-hook #'claude-agent-chat--kill-buffer-cleanup nil t))
        (kill-buffer buf)
        (should cleanup-called)))))

(ert-deftest test-chat-f6-kill-buffer-no-backend-no-error ()
  "Killing chat buffer without backend should not error."
  :tags '(:unit :fast :stable :isolated :chat-backend :f6)
  (let ((buf (generate-new-buffer " *test-chat-kill-nil*")))
    (with-current-buffer buf
      (setq-local claude-agent-chat--backend nil)
      (add-hook 'kill-buffer-hook #'claude-agent-chat--kill-buffer-cleanup nil t))
    ;; Should not error
    (kill-buffer buf)))

;; ---------------------------------------------------------------------------
;; F7: clear and new-session with backend
;; ---------------------------------------------------------------------------

(ert-deftest test-chat-f7-clear-cleans-up-backend ()
  "chat-clear should cleanup and nil out the backend."
  :tags '(:unit :fast :stable :isolated :chat-backend :f7)
  (with-temp-buffer
    (let ((cleanup-called nil)
          (claude-agent-chat--backend (claude-agent-json-backend--create))
          (claude-agent-chat--query-handle 'some-handle)
          (claude-agent-chat--session-id "sess-1")
          (claude-agent-chat--waiting nil)
          (claude-agent-chat--total-cost 1.5)
          (claude-agent-chat--current-response ""))
      (cl-letf (((symbol-function 'claude-agent-backend-cleanup)
                 (lambda (backend) (setq cleanup-called t)))
                ((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) t))
                ((symbol-function 'claude-agent-chat--initialize-buffer)
                 (lambda () nil)))
        (let ((inhibit-read-only t))
          (claude-agent-chat-clear))
        (should cleanup-called)
        (should-not claude-agent-chat--backend)
        (should-not claude-agent-chat--query-handle)
        (should-not claude-agent-chat--session-id)))))

(ert-deftest test-chat-f7-new-session-json-stream-nils-session ()
  "new-session with json-stream backend nils session-id."
  :tags '(:unit :fast :stable :isolated :chat-backend :f7)
  (with-temp-buffer
    (let ((claude-agent-chat--backend (claude-agent-json-backend--create))
          (claude-agent-chat--session-id "old-sess")
          (claude-agent-chat-backend-type 'json-stream))
      (cl-letf (((symbol-function 'claude-agent-chat--insert)
                 (lambda (&rest _) nil)))
        (claude-agent-chat-new-session)
        (should-not claude-agent-chat--session-id)))))

(provide 'test-claude-agent-chat-backend)
;;; test-claude-agent-chat-backend.el ends here
