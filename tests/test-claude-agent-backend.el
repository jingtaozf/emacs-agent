;;; test-claude-agent-backend.el --- TDD Tests for Backend Protocol -*- lexical-binding: t; -*-

;; TDD tests for the backend protocol abstraction layer.
;; These tests define expected behavior BEFORE implementation.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-agent)

;;; Phase 1: Backend Protocol Struct and Generic Definitions

(ert-deftest test-backend-base-struct-exists ()
  "Backend base struct should exist as a type."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (should (fboundp 'claude-agent-backend-p))
  (should (fboundp 'claude-agent-backend-type)))

(ert-deftest test-backend-base-struct-is-abstract ()
  "Backend base struct should not have a public constructor."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  ;; The default make-claude-agent-backend should not exist
  ;; because we use (:constructor nil)
  (should-not (fboundp 'make-claude-agent-backend)))

(ert-deftest test-backend-generics-defined ()
  "All 8 backend protocol generics should be defined."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (should (fboundp 'claude-agent-backend-query))
  (should (fboundp 'claude-agent-backend-cancel))
  (should (fboundp 'claude-agent-backend-cleanup))
  (should (fboundp 'claude-agent-backend-active-p))
  (should (fboundp 'claude-agent-backend-session-id))
  (should (fboundp 'claude-agent-backend-send-input))
  (should (fboundp 'claude-agent-backend-supports-p))
  (should (fboundp 'claude-agent-backend-classify-error)))

(ert-deftest test-backend-json-struct-exists ()
  "JSON stream backend struct should exist with constructor."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (should (fboundp 'claude-agent-claude-code-backend-p))
  (should (fboundp 'claude-agent-claude-code-backend--create)))

(ert-deftest test-backend-json-struct-inherits-base ()
  "JSON backend instances should satisfy the base backend predicate."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should (claude-agent-claude-code-backend-p backend))
    (should (claude-agent-backend-p backend))))

(ert-deftest test-backend-json-struct-type-field ()
  "JSON backend type field should be :claude-code."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should (eq :claude-code (claude-agent-backend-type backend)))))

(ert-deftest test-backend-json-struct-slots ()
  "JSON backend should have expected slots."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (let ((backend (claude-agent-claude-code-backend--create
                  :session-key "test-key"
                  :persistent-p nil)))
    (should (equal "test-key" (claude-agent-claude-code-backend-session-key backend)))
    (should-not (claude-agent-claude-code-backend-persistent-p backend))
    (should-not (claude-agent-claude-code-backend-process-state backend))
    (should-not (claude-agent-claude-code-backend-client backend))))

(ert-deftest test-backend-json-struct-persistent-mode ()
  "JSON backend should support persistent-p flag."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (let ((backend (claude-agent-claude-code-backend--create :persistent-p t)))
    (should (claude-agent-claude-code-backend-persistent-p backend))))

;;; Phase 1: Default Method Behaviors

(ert-deftest test-backend-supports-p-default-nil ()
  "Default supports-p should return nil for unknown capabilities."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    ;; Should not error — default method returns nil
    (should-not (claude-agent-backend-supports-p backend :nonexistent-capability))))

(ert-deftest test-backend-active-p-default-nil ()
  "Default active-p should return nil when no query is running."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should-not (claude-agent-backend-active-p backend))))

(ert-deftest test-backend-session-id-default-nil ()
  "Default session-id should return nil when no session exists."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should-not (claude-agent-backend-session-id backend))))

(ert-deftest test-backend-classify-error-default-unknown ()
  "Default classify-error should return 'unknown for unrecognized errors."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should (eq 'unknown
                (claude-agent-backend-classify-error backend "some random error")))))

;;; Phase 2: JSON Backend Method Implementations

(ert-deftest test-claude-code-backend-classify-error-context-limit ()
  "JSON backend should classify context-too-long errors."
  :tags '(:unit :fast :stable :isolated :backend :phase-2)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should (eq 'context-limit
                (claude-agent-backend-classify-error backend "Prompt is too long")))
    (should (eq 'context-limit
                (claude-agent-backend-classify-error backend "context too long for model")))
    (should (eq 'context-limit
                (claude-agent-backend-classify-error backend "exceeds context window")))
    (should (eq 'context-limit
                (claude-agent-backend-classify-error backend "token limit reached")))))

(ert-deftest test-claude-code-backend-classify-error-session-expired ()
  "JSON backend should classify session-expired errors."
  :tags '(:unit :fast :stable :isolated :backend :phase-2)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should (eq 'session-expired
                (claude-agent-backend-classify-error
                 backend "No conversation found with session ID abc-123")))
    (should (eq 'session-expired
                (claude-agent-backend-classify-error
                 backend "session xyz not found")))
    (should (eq 'session-expired
                (claude-agent-backend-classify-error
                 backend "session has expired")))))

(ert-deftest test-claude-code-backend-classify-error-non-string ()
  "JSON backend classify-error should handle non-string errors gracefully."
  :tags '(:unit :fast :stable :isolated :backend :phase-2)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should (eq 'unknown (claude-agent-backend-classify-error backend nil)))
    (should (eq 'unknown (claude-agent-backend-classify-error backend 42)))
    (should (eq 'unknown (claude-agent-backend-classify-error backend '(error "oops"))))))

(ert-deftest test-claude-code-backend-supports-p-capabilities ()
  "JSON backend should report all standard capabilities."
  :tags '(:unit :fast :stable :isolated :backend :phase-2)
  (let ((backend (claude-agent-claude-code-backend--create)))
    (should (claude-agent-backend-supports-p backend :streaming-tokens))
    (should (claude-agent-backend-supports-p backend :structured-messages))
    (should (claude-agent-backend-supports-p backend :tool-use))
    (should (claude-agent-backend-supports-p backend :session-resume))
    (should (claude-agent-backend-supports-p backend :interactive-input))
    ;; Unknown capability should still return nil
    (should-not (claude-agent-backend-supports-p backend :teleportation))))

(ert-deftest test-claude-code-backend-supports-p-persistent-client ()
  "JSON backend persistent-client capability depends on persistent-p flag."
  :tags '(:unit :fast :stable :isolated :backend :phase-2)
  (let ((non-persistent (claude-agent-claude-code-backend--create :persistent-p nil))
        (persistent (claude-agent-claude-code-backend--create :persistent-p t)))
    (should-not (claude-agent-backend-supports-p non-persistent :persistent-client))
    (should (claude-agent-backend-supports-p persistent :persistent-client))))

(ert-deftest test-claude-code-backend-active-p-with-process-state ()
  "JSON backend active-p should check process-state."
  :tags '(:unit :fast :stable :isolated :backend :phase-2)
  (let ((backend (claude-agent-claude-code-backend--create)))
    ;; No process-state → not active
    (should-not (claude-agent-backend-active-p backend))
    ;; With a process-state (not closed, no process) → active per query-active-p
    ;; (process nil means "not yet started", which counts as active)
    (let ((mock-state (claude-agent--make-process-state :request-id "test-req")))
      (setf (claude-agent-claude-code-backend-process-state backend) mock-state)
      (should (claude-agent-backend-active-p backend)))
    ;; With a closed process-state → not active
    (let ((closed-state (claude-agent--make-process-state :request-id "closed-req"
                                                          :closed t)))
      (setf (claude-agent-claude-code-backend-process-state backend) closed-state)
      (should-not (claude-agent-backend-active-p backend)))))

(ert-deftest test-claude-code-backend-session-id-from-session-key ()
  "JSON backend session-id should use session-key to look up SDK UUID."
  :tags '(:unit :fast :stable :isolated :backend :phase-2)
  (let ((backend (claude-agent-claude-code-backend--create :session-key "test-session")))
    ;; With no stored UUID → nil
    (should-not (claude-agent-backend-session-id backend))
    ;; Store a UUID mapping and check
    (claude-agent--store-sdk-uuid "test-session" "sdk-uuid-123")
    (unwind-protect
        (should (equal "sdk-uuid-123" (claude-agent-backend-session-id backend)))
      ;; Cleanup
      (claude-agent--clear-session "test-session"))))

(ert-deftest test-claude-code-backend-cancel-nil-handle ()
  "JSON backend cancel with nil handle should not error."
  :tags '(:unit :fast :stable :isolated :backend :phase-2)
  (let ((backend (claude-agent-claude-code-backend--create)))
    ;; Should be a no-op, not an error
    (claude-agent-backend-cancel backend nil)))

(ert-deftest test-claude-code-backend-cleanup-no-state ()
  "JSON backend cleanup with no state should not error."
  :tags '(:unit :fast :stable :isolated :backend :phase-2)
  (let ((backend (claude-agent-claude-code-backend--create)))
    ;; Should be a no-op
    (claude-agent-backend-cleanup backend)))

(ert-deftest test-claude-code-backend-send-input-no-state ()
  "JSON backend send-input with no active query should not error."
  :tags '(:unit :fast :stable :isolated :backend :phase-2)
  (let ((backend (claude-agent-claude-code-backend--create)))
    ;; Should be a no-op
    (claude-agent-backend-send-input backend "test input")))

;;; Phase 4: Public utility functions

(ert-deftest test-make-session-key-public ()
  "claude-agent-make-session-key should be a public function."
  :tags '(:unit :fast :stable :isolated :backend :phase-4)
  (should (fboundp 'claude-agent-make-session-key))
  (should (equal "/tmp/test.org"
                 (claude-agent-make-session-key "/tmp/test.org")))
  (should (equal "/tmp/test.org::session-1"
                 (claude-agent-make-session-key "/tmp/test.org" "session-1"))))

(ert-deftest test-get-verbose-buffer-public ()
  "claude-agent-get-verbose-buffer should be a public function."
  :tags '(:unit :fast :stable :isolated :backend :phase-4)
  (should (fboundp 'claude-agent-get-verbose-buffer))
  ;; With no buffer stored, should return nil
  (should-not (claude-agent-get-verbose-buffer "nonexistent-key")))

(ert-deftest test-classify-error-internal ()
  "Error classification predicates should work correctly."
  :tags '(:unit :fast :stable :isolated :backend :phase-4)
  (should (fboundp 'claude-agent--session-expired-p))
  (should (fboundp 'claude-agent--context-too-long-p))
  (should (claude-agent--session-expired-p "No conversation found with session ID x"))
  (should (claude-agent--context-too-long-p "Prompt is too long"))
  (should-not (claude-agent--session-expired-p "random error"))
  (should-not (claude-agent--context-too-long-p "random error")))

;;; Phase 5: Capability-based feature negotiation

(ert-deftest test-backend-capability-guard-streaming-tokens ()
  "Backend capability guard should filter :on-token when not supported."
  :tags '(:unit :fast :stable :isolated :backend :phase-5)
  (should (fboundp 'claude-agent-backend-filter-callbacks))
  ;; JSON backend supports :streaming-tokens, so :on-token should pass through
  (let* ((backend (claude-agent-claude-code-backend--create))
         (callbacks (list :on-token #'ignore :on-message #'ignore
                          :on-error #'ignore :on-complete #'ignore))
         (filtered (claude-agent-backend-filter-callbacks backend callbacks)))
    (should (plist-get filtered :on-token))))

(ert-deftest test-backend-capability-guard-removes-unsupported ()
  "Callback filter should remove :on-token when streaming not supported."
  :tags '(:unit :fast :stable :isolated :backend :phase-5)
  ;; Create a mock backend that doesn't support streaming
  (let* ((backend (claude-agent-claude-code-backend--create))
         (callbacks (list :on-token #'ignore :on-message #'ignore
                          :on-error #'ignore :on-complete #'ignore)))
    ;; Override supports-p to deny :streaming-tokens
    (cl-letf (((symbol-function 'claude-agent-backend-supports-p)
               (lambda (_b cap) (not (eq cap :streaming-tokens)))))
      (let ((filtered (claude-agent-backend-filter-callbacks backend callbacks)))
        (should-not (plist-get filtered :on-token))
        ;; :on-message should still be there (supported)
        (should (plist-get filtered :on-message))
        (should (plist-get filtered :on-error))
        (should (plist-get filtered :on-complete))))))

(ert-deftest test-backend-capability-guard-removes-structured-messages ()
  "Callback filter should remove :on-message when not supported."
  :tags '(:unit :fast :stable :isolated :backend :phase-5)
  (let* ((backend (claude-agent-claude-code-backend--create))
         (callbacks (list :on-token #'ignore :on-message #'ignore
                          :on-error #'ignore :on-complete #'ignore)))
    ;; Override to deny :structured-messages
    (cl-letf (((symbol-function 'claude-agent-backend-supports-p)
               (lambda (_b cap) (not (eq cap :structured-messages)))))
      (let ((filtered (claude-agent-backend-filter-callbacks backend callbacks)))
        (should-not (plist-get filtered :on-message))
        ;; :on-token should still be there
        (should (plist-get filtered :on-token))))))

(ert-deftest test-backend-capability-guard-preserves-error-complete ()
  "Callback filter should always preserve :on-error and :on-complete."
  :tags '(:unit :fast :stable :isolated :backend :phase-5)
  (let* ((backend (claude-agent-claude-code-backend--create))
         (callbacks (list :on-token #'ignore :on-message #'ignore
                          :on-error #'ignore :on-complete #'ignore)))
    ;; Override to deny everything
    (cl-letf (((symbol-function 'claude-agent-backend-supports-p)
               (lambda (_b _cap) nil)))
      (let ((filtered (claude-agent-backend-filter-callbacks backend callbacks)))
        ;; Error and complete are essential, never filtered
        (should (plist-get filtered :on-error))
        (should (plist-get filtered :on-complete))
        ;; But streaming features are filtered
        (should-not (plist-get filtered :on-token))
        (should-not (plist-get filtered :on-message))))))

(ert-deftest test-backend-capability-guard-nil-callbacks ()
  "Callback filter should handle nil callbacks gracefully."
  :tags '(:unit :fast :stable :isolated :backend :phase-5)
  (let ((backend (claude-agent-claude-code-backend--create)))
    ;; nil callbacks should produce empty list
    (let ((filtered (claude-agent-backend-filter-callbacks backend nil)))
      (should (listp filtered)))))

(ert-deftest test-backend-capability-guard-partial-callbacks ()
  "Callback filter should handle partial callback lists."
  :tags '(:unit :fast :stable :isolated :backend :phase-5)
  (let* ((backend (claude-agent-claude-code-backend--create))
         ;; Only error and complete, no token/message
         (callbacks (list :on-error #'ignore :on-complete #'ignore)))
    (let ((filtered (claude-agent-backend-filter-callbacks backend callbacks)))
      (should (plist-get filtered :on-error))
      (should (plist-get filtered :on-complete))
      (should-not (plist-get filtered :on-token)))))

(provide 'test-claude-agent-backend)
;;; test-claude-agent-backend.el ends here
