;;; test-code-agent-org-refactor-phase4.el --- Phase 4 refactoring tests -*- lexical-binding: t; -*-

;; Tests for Phase 4: Session struct decomposition (F14)

(require 'cl-lib)
(require 'ert)
(require 'code-agent)
(require 'code-agent-org)

;;; ============================================================
;;; F14: Session struct decomposition
;;; ============================================================

;; F14.1 Sub-structs exist
(ert-deftest test-f14-lifecycle-substruct-exists ()
  "session-lifecycle sub-struct should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (should (fboundp 'code-agent-org--make-session-lifecycle)))

(ert-deftest test-f14-render-substruct-exists ()
  "session-render sub-struct should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (should (fboundp 'code-agent-org--make-session-render)))

(ert-deftest test-f14-loop-substruct-exists ()
  "session-loop sub-struct should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (should (fboundp 'code-agent-org--make-session-loop)))

(ert-deftest test-f14-identity-substruct-exists ()
  "session-identity sub-struct should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (should (fboundp 'code-agent-org--make-session-identity)))

;; F14.2 Composed session-state still works
(ert-deftest test-f14-session-state-still-constructable ()
  "session-state should still be constructable and contain sub-structs."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (let ((state (code-agent-org--make-session-state)))
    (should (code-agent-org--session-state-p state))
    ;; Sub-structs should be accessible
    (should (code-agent-org--session-lifecycle-p
             (code-agent-org--session-state-lifecycle state)))
    (should (code-agent-org--session-render-p
             (code-agent-org--session-state-render state)))
    (should (code-agent-org--session-loop-p
             (code-agent-org--session-state-loop state)))
    (should (code-agent-org--session-identity-p
             (code-agent-org--session-state-identity state)))))

;; F14.3 Backward compatibility: all session-get/put still work
(ert-deftest test-f14-backward-compat-session-get-put ()
  "All existing session-get/put keyword properties should still work."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (with-temp-buffer
    (org-mode)
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((key "test::f14-compat"))
      ;; Test lifecycle fields
      (code-agent-org--session-put key :busy t)
      (should (eq t (code-agent-org--session-get key :busy)))
      (code-agent-org--session-put key :recovering "recovery-id")
      (should (equal "recovery-id" (code-agent-org--session-get key :recovering)))
      (code-agent-org--session-put key :start-time 12345.0)
      (should (equal 12345.0 (code-agent-org--session-get key :start-time)))

      ;; Test render fields
      (code-agent-org--session-put key :section-level 3)
      (should (= 3 (code-agent-org--session-get key :section-level)))
      (code-agent-org--session-put key :current-line-length 42)
      (should (= 42 (code-agent-org--session-get key :current-line-length)))

      ;; Test loop fields
      (code-agent-org--session-put key :loop-max 5)
      (should (= 5 (code-agent-org--session-get key :loop-max)))
      (code-agent-org--session-put key :loop-current 2)
      (should (= 2 (code-agent-org--session-get key :loop-current)))

      ;; Test identity fields
      (code-agent-org--session-put key :query-id "q123")
      (should (equal "q123" (code-agent-org--session-get key :query-id)))
      (code-agent-org--session-put key :custom-id "custom-abc")
      (should (equal "custom-abc" (code-agent-org--session-get key :custom-id)))
      (code-agent-org--session-put key :sdk-uuid "uuid-xyz")
      (should (equal "uuid-xyz" (code-agent-org--session-get key :sdk-uuid)))

      ;; Test extras fallback
      (code-agent-org--session-put key :unknown-prop "fallback")
      (should (equal "fallback" (code-agent-org--session-get key :unknown-prop))))))

;; F14.4 Reset clears sub-struct fields
(ert-deftest test-f14-reset-clears-substructs ()
  "reset-session-state should clear fields across sub-structs."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (with-temp-buffer
    (org-mode)
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((key "test::f14-reset"))
      (code-agent-org--session-put key :busy t)
      (code-agent-org--session-put key :recovering "recovery")
      (code-agent-org--session-put key :last-assistant-query-id "q1")
      (code-agent-org--reset-session-state key)
      (should-not (code-agent-org--session-get key :busy))
      (should-not (code-agent-org--session-get key :recovering))
      (should-not (code-agent-org--session-get key :last-assistant-query-id)))))

;; F14.5 Accessor alists are complete (same count as before)
(ert-deftest test-f14-accessor-alist-complete ()
  "Accessor alist should still have entries for all 22 fields."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  ;; 22 named fields (everything except :extras which is the fallback)
  (should (>= (length code-agent-org--session-field-accessors) 22))
  (should (>= (length code-agent-org--session-field-setters) 22)))

;; F14.6 Sub-struct defaults
(ert-deftest test-f14-substruct-defaults ()
  "Sub-structs should have sensible defaults."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (let ((lc (code-agent-org--make-session-lifecycle)))
    (should-not (code-agent-org--session-lifecycle-busy lc))
    (should-not (code-agent-org--session-lifecycle-recovering lc)))
  (let ((rd (code-agent-org--make-session-render)))
    (should-not (code-agent-org--session-render-section-level rd)))
  (let ((lp (code-agent-org--make-session-loop)))
    (should-not (code-agent-org--session-loop-loop-max lp)))
  (let ((id (code-agent-org--make-session-identity)))
    (should-not (code-agent-org--session-identity-query-id id))))

;; F14.7 session-state-set routes to correct sub-struct
(ert-deftest test-f14-session-state-set-routes-to-substruct ()
  "session-state-set should write to the correct sub-struct field."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (let ((state (code-agent-org--make-session-state)))
    ;; Lifecycle field
    (code-agent-org--session-state-set state :busy t)
    (should (eq t (code-agent-org--session-state-get state :busy)))
    ;; Render field
    (code-agent-org--session-state-set state :spinner 2)
    (should (= 2 (code-agent-org--session-state-get state :spinner)))
    ;; Identity field
    (code-agent-org--session-state-set state :query-id "q-test")
    (should (equal "q-test" (code-agent-org--session-state-get state :query-id)))
    ;; Loop field
    (code-agent-org--session-state-set state :loop-max 10)
    (should (= 10 (code-agent-org--session-state-get state :loop-max)))
    ;; Verify sub-struct routing (values landed in correct sub-struct)
    (should (eq t (code-agent-org--session-lifecycle-busy
                   (code-agent-org--session-state-lifecycle state))))
    (should (= 2 (code-agent-org--session-render-spinner
                  (code-agent-org--session-state-render state))))))

(provide 'test-code-agent-org-refactor-phase4)
;;; test-code-agent-org-refactor-phase4.el ends here
