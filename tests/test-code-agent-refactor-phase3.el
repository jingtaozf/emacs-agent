;;; test-code-agent-refactor-phase3.el --- Phase 3 refactoring tests -*- lexical-binding: t; -*-

;; Tests for Phase 3: Module extraction (F11-F13) from code-agent.org

(require 'cl-lib)
(require 'ert)
(require 'code-agent)

;;; ============================================================
;;; F11: code-agent-backend module extraction
;;; ============================================================

;; F11.1 Module provides feature
(ert-deftest test-f11-backend-module-provides-feature ()
  "The code-agent-backend module should provide its feature."
  :tags '(:unit :fast :stable :isolated :refactor :f11)
  (should (featurep 'code-agent-backend)))

;; F11.2 Backend base struct exists
(ert-deftest test-f11-backend-base-struct ()
  "Backend base struct should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f11)
  (should (fboundp 'code-agent-backend-type))
  (should (fboundp 'code-agent-backend-p)))

;; F11.3 Backend protocol generics exist
(ert-deftest test-f11-backend-protocol-generics ()
  "All backend protocol generic functions should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f11)
  (should (fboundp 'code-agent-backend-query))
  (should (fboundp 'code-agent-backend-cancel))
  (should (fboundp 'code-agent-backend-cleanup))
  (should (fboundp 'code-agent-backend-active-p))
  (should (fboundp 'code-agent-backend-session-id))
  (should (fboundp 'code-agent-backend-classify-error)))

;; F11.4/F11.5 JSON stream backend (code-agent-claude-code-backend) removed
;; 2026-07 — zero production callers after the org-as-control-plane pivot.

;; F11.6 Backend filter-callbacks helper
(ert-deftest test-f11-backend-filter-callbacks ()
  "Backend filter-callbacks should extract callback functions."
  :tags '(:unit :fast :stable :isolated :refactor :f11)
  (should (fboundp 'code-agent-backend-filter-callbacks)))

;;; ============================================================
;;; F13: code-agent-ide module extraction
;;; ============================================================

;; F13.1 Module provides feature
(ert-deftest test-f13-ide-module-provides-feature ()
  "The code-agent-ide module should provide its feature."
  :tags '(:unit :fast :stable :isolated :refactor :f13)
  (should (featurep 'code-agent-ide)))

;; F13.2 IDE context collection function exists
(ert-deftest test-f13-ide-collect-context ()
  "IDE context collection function should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f13)
  (should (fboundp 'code-agent-collect-ide-context)))

;; F13.3 System reminder building (code-agent-build-system-reminder /
;; code-agent-get-system-reminder) removed 2026-07 — zero production
;; callers after the org-as-control-plane pivot.

;; F13.4 Buffer filtering works
(ert-deftest test-f13-ide-buffer-filtering ()
  "Buffer exclusion filtering should work."
  :tags '(:unit :fast :stable :isolated :refactor :f13)
  (should (fboundp 'code-agent--buffer-excluded-p))
  ;; Internal buffers should be excluded (takes buffer object)
  (should (code-agent--buffer-excluded-p (get-buffer "*Messages*"))))

;; F13.5 IDE context returns plist
(ert-deftest test-f13-ide-context-returns-plist ()
  "IDE context should return a plist with expected keys."
  :tags '(:unit :fast :stable :isolated :refactor :f13)
  (let ((ctx (code-agent-collect-ide-context)))
    (should (listp ctx))
    ;; Should have open-files key at minimum
    (should (plist-member ctx :open-files))))

;;; ============================================================
;;; Cross-module integration
;;; ============================================================

(provide 'test-code-agent-refactor-phase3)
;;; test-code-agent-refactor-phase3.el ends here
