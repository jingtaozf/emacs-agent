;;; test-claude-agent-backend-protocol.el --- F1: Protocol Extension Tests -*- lexical-binding: t; -*-

;; TDD tests for F1: Protocol Extensions
;; Tests new optional generics: backend-verbose-buffer, backend-ready-p
;; Tests new capabilities: :hook-permissions, :terminal-verbose

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-agent)

;;; F1 Phase 1: New Generic Definitions

(ert-deftest test-f1-verbose-buffer-generic-defined ()
  "backend-verbose-buffer generic should be defined."
  :tags '(:unit :fast :stable :isolated :backend :f1)
  (should (fboundp 'claude-agent-backend-verbose-buffer)))

(ert-deftest test-f1-ready-p-generic-defined ()
  "backend-ready-p generic should be defined."
  :tags '(:unit :fast :stable :isolated :backend :f1)
  (should (fboundp 'claude-agent-backend-ready-p)))

;;; F1 Phase 2: Default Method Behaviors

(ert-deftest test-f1-verbose-buffer-default-nil ()
  "Default backend-verbose-buffer should return nil."
  :tags '(:unit :fast :stable :isolated :backend :f1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should-not (claude-agent-backend-verbose-buffer backend))))

(ert-deftest test-f1-ready-p-default-t ()
  "Default backend-ready-p should return t."
  :tags '(:unit :fast :stable :isolated :backend :f1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should (claude-agent-backend-ready-p backend))))

;;; F1 Phase 3: JSON Backend Specializations

(ert-deftest test-f1-claude-code-backend-verbose-buffer-nil ()
  "JSON backend verbose-buffer should return nil (uses shared system)."
  :tags '(:unit :fast :stable :isolated :backend :f1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should-not (claude-agent-backend-verbose-buffer backend))))

(ert-deftest test-f1-claude-code-backend-ready-p-no-query ()
  "JSON backend ready-p should return t when no active query."
  :tags '(:unit :fast :stable :isolated :backend :f1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should (claude-agent-backend-ready-p backend))))

(ert-deftest test-f1-claude-code-backend-ready-p-active-query ()
  "JSON backend ready-p should return nil when query is active."
  :tags '(:unit :fast :stable :isolated :backend :f1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    ;; Simulate active query via process-state
    (let ((mock-state (claude-agent--make-process-state :request-id "test")))
      (setf (claude-agent-claude-code-backend-process-state backend) mock-state)
      (should-not (claude-agent-backend-ready-p backend)))))

;;; F1 Phase 4: New Capabilities Queryable

(ert-deftest test-f1-claude-code-backend-hook-permissions-nil ()
  "JSON backend should return nil for :hook-permissions."
  :tags '(:unit :fast :stable :isolated :backend :f1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should-not (claude-agent-backend-supports-p backend :hook-permissions))))

(ert-deftest test-f1-claude-code-backend-terminal-verbose-nil ()
  "JSON backend should return nil for :terminal-verbose."
  :tags '(:unit :fast :stable :isolated :backend :f1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should-not (claude-agent-backend-supports-p backend :terminal-verbose))))

;;; F1 Phase 5: Existing Protocol Unaffected

(ert-deftest test-f1-filter-callbacks-unchanged ()
  "Callback filter should work identically after protocol extension."
  :tags '(:unit :fast :stable :isolated :backend :f1)
  (let* ((backend (claude-agent-claude-code-backend--create))
         (callbacks (list :on-token #'ignore :on-message #'ignore
                         :on-error #'ignore :on-complete #'ignore))
         (filtered (claude-agent-backend-filter-callbacks backend callbacks)))
    ;; JSON backend supports all standard capabilities
    (should (plist-get filtered :on-token))
    (should (plist-get filtered :on-message))
    (should (plist-get filtered :on-error))
    (should (plist-get filtered :on-complete))))

(ert-deftest test-f1-existing-generics-still-work ()
  "All 8 original generics should still work after adding new ones."
  :tags '(:unit :fast :stable :isolated :backend :f1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    ;; active-p should work
    (should-not (claude-agent-backend-active-p backend))
    ;; session-id should work
    (should-not (claude-agent-backend-session-id backend))
    ;; classify-error should work
    (should (eq 'unknown (claude-agent-backend-classify-error backend "foo")))
    ;; cancel with nil should be no-op
    (claude-agent-backend-cancel backend nil)
    ;; cleanup should be no-op
    (claude-agent-backend-cleanup backend)
    ;; send-input should be no-op
    (claude-agent-backend-send-input backend "test")
    ;; supports-p should work
    (should (claude-agent-backend-supports-p backend :streaming-tokens))))

(provide 'test-claude-agent-backend-protocol)
;;; test-claude-agent-backend-protocol.el ends here
