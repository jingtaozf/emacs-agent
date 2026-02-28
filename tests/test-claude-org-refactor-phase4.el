;;; test-claude-org-refactor-phase4.el --- Phase 4 refactoring tests -*- lexical-binding: t; -*-

;; Tests for Phase 4: Session struct decomposition (F14)

(require 'cl-lib)
(require 'ert)
(require 'claude-agent)
(require 'claude-org)

;;; ============================================================
;;; F14: Session struct decomposition
;;; ============================================================

;; F14.1 Sub-structs exist
(ert-deftest test-f14-lifecycle-substruct-exists ()
  "session-lifecycle sub-struct should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (should (fboundp 'claude-org--make-session-lifecycle)))

(ert-deftest test-f14-render-substruct-exists ()
  "session-render sub-struct should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (should (fboundp 'claude-org--make-session-render)))

(ert-deftest test-f14-loop-substruct-exists ()
  "session-loop sub-struct should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (should (fboundp 'claude-org--make-session-loop)))

(ert-deftest test-f14-identity-substruct-exists ()
  "session-identity sub-struct should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (should (fboundp 'claude-org--make-session-identity)))

;; F14.2 Composed session-state still works
(ert-deftest test-f14-session-state-still-constructable ()
  "session-state should still be constructable and contain sub-structs."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (let ((state (claude-org--make-session-state)))
    (should (claude-org--session-state-p state))
    ;; Sub-structs should be accessible
    (should (claude-org--session-lifecycle-p
             (claude-org--session-state-lifecycle state)))
    (should (claude-org--session-render-p
             (claude-org--session-state-render state)))
    (should (claude-org--session-loop-p
             (claude-org--session-state-loop state)))
    (should (claude-org--session-identity-p
             (claude-org--session-state-identity state)))))

;; F14.3 Backward compatibility: all session-get/put still work
(ert-deftest test-f14-backward-compat-session-get-put ()
  "All existing session-get/put keyword properties should still work."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((key "test::f14-compat"))
      ;; Test lifecycle fields
      (claude-org--session-put key :busy t)
      (should (eq t (claude-org--session-get key :busy)))
      (claude-org--session-put key :recovering "recovery-id")
      (should (equal "recovery-id" (claude-org--session-get key :recovering)))
      (claude-org--session-put key :start-time 12345.0)
      (should (equal 12345.0 (claude-org--session-get key :start-time)))

      ;; Test render fields
      (claude-org--session-put key :section-level 3)
      (should (= 3 (claude-org--session-get key :section-level)))
      (claude-org--session-put key :current-line-length 42)
      (should (= 42 (claude-org--session-get key :current-line-length)))

      ;; Test loop fields
      (claude-org--session-put key :loop-max 5)
      (should (= 5 (claude-org--session-get key :loop-max)))
      (claude-org--session-put key :loop-current 2)
      (should (= 2 (claude-org--session-get key :loop-current)))

      ;; Test identity fields
      (claude-org--session-put key :query-id "q123")
      (should (equal "q123" (claude-org--session-get key :query-id)))
      (claude-org--session-put key :custom-id "custom-abc")
      (should (equal "custom-abc" (claude-org--session-get key :custom-id)))
      (claude-org--session-put key :sdk-uuid "uuid-xyz")
      (should (equal "uuid-xyz" (claude-org--session-get key :sdk-uuid)))

      ;; Test extras fallback
      (claude-org--session-put key :unknown-prop "fallback")
      (should (equal "fallback" (claude-org--session-get key :unknown-prop))))))

;; F14.4 Reset clears sub-struct fields
(ert-deftest test-f14-reset-clears-substructs ()
  "reset-session-state should clear fields across sub-structs."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((key "test::f14-reset"))
      (claude-org--session-put key :busy t)
      (claude-org--session-put key :recovering "recovery")
      (claude-org--session-put key :last-assistant-query-id "q1")
      (claude-org--reset-session-state key)
      (should-not (claude-org--session-get key :busy))
      (should-not (claude-org--session-get key :recovering))
      (should-not (claude-org--session-get key :last-assistant-query-id)))))

;; F14.5 Accessor alists are complete (same count as before)
(ert-deftest test-f14-accessor-alist-complete ()
  "Accessor alist should still have entries for all 22 fields."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  ;; 22 named fields (everything except :extras which is the fallback)
  (should (>= (length claude-org--session-field-accessors) 22))
  (should (>= (length claude-org--session-field-setters) 22)))

;; F14.6 Sub-struct defaults
(ert-deftest test-f14-substruct-defaults ()
  "Sub-structs should have sensible defaults."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (let ((lc (claude-org--make-session-lifecycle)))
    (should-not (claude-org--session-lifecycle-busy lc))
    (should-not (claude-org--session-lifecycle-recovering lc)))
  (let ((rd (claude-org--make-session-render)))
    (should-not (claude-org--session-render-section-level rd)))
  (let ((lp (claude-org--make-session-loop)))
    (should-not (claude-org--session-loop-loop-max lp)))
  (let ((id (claude-org--make-session-identity)))
    (should-not (claude-org--session-identity-query-id id))))

;; F14.7 session-state-set routes to correct sub-struct
(ert-deftest test-f14-session-state-set-routes-to-substruct ()
  "session-state-set should write to the correct sub-struct field."
  :tags '(:unit :fast :stable :isolated :refactor :f14)
  (let ((state (claude-org--make-session-state)))
    ;; Lifecycle field
    (claude-org--session-state-set state :busy t)
    (should (eq t (claude-org--session-state-get state :busy)))
    ;; Render field
    (claude-org--session-state-set state :spinner 2)
    (should (= 2 (claude-org--session-state-get state :spinner)))
    ;; Identity field
    (claude-org--session-state-set state :query-id "q-test")
    (should (equal "q-test" (claude-org--session-state-get state :query-id)))
    ;; Loop field
    (claude-org--session-state-set state :loop-max 10)
    (should (= 10 (claude-org--session-state-get state :loop-max)))
    ;; Verify sub-struct routing (values landed in correct sub-struct)
    (should (eq t (claude-org--session-lifecycle-busy
                   (claude-org--session-state-lifecycle state))))
    (should (= 2 (claude-org--session-render-spinner
                  (claude-org--session-state-render state))))))

(provide 'test-claude-org-refactor-phase4)
;;; test-claude-org-refactor-phase4.el ends here
