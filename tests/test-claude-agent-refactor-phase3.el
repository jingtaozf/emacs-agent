;;; test-claude-agent-refactor-phase3.el --- Phase 3 refactoring tests -*- lexical-binding: t; -*-

;; Tests for Phase 3: Module extraction (F11-F13) from claude-agent.org

(require 'cl-lib)
(require 'ert)
(require 'claude-agent)

;;; ============================================================
;;; F11: claude-agent-backend module extraction
;;; ============================================================

;; F11.1 Module provides feature
(ert-deftest test-f11-backend-module-provides-feature ()
  "The claude-agent-backend module should provide its feature."
  :tags '(:unit :fast :stable :isolated :refactor :f11)
  (should (featurep 'claude-agent-backend)))

;; F11.2 Backend base struct exists
(ert-deftest test-f11-backend-base-struct ()
  "Backend base struct should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f11)
  (should (fboundp 'claude-agent-backend-type))
  (should (fboundp 'claude-agent-backend-p)))

;; F11.3 Backend protocol generics exist
(ert-deftest test-f11-backend-protocol-generics ()
  "All backend protocol generic functions should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f11)
  (should (fboundp 'claude-agent-backend-query))
  (should (fboundp 'claude-agent-backend-cancel))
  (should (fboundp 'claude-agent-backend-cleanup))
  (should (fboundp 'claude-agent-backend-active-p))
  (should (fboundp 'claude-agent-backend-session-id))
  (should (fboundp 'claude-agent-backend-classify-error)))

;; F11.4 JSON stream backend struct and constructor
(ert-deftest test-f11-json-backend-struct ()
  "JSON stream backend struct should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f11)
  (should (fboundp 'claude-agent-json-backend-p))
  (should (fboundp 'claude-agent-json-backend--create)))

;; F11.5 Claude CLI backend exists (if eat is available)
(ert-deftest test-f11-claude-cli-backend-struct ()
  "Claude CLI backend struct should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f11)
  (should (fboundp 'claude-agent-claude-backend-p)))

;; F11.6 Backend filter-callbacks helper
(ert-deftest test-f11-backend-filter-callbacks ()
  "Backend filter-callbacks should extract callback functions."
  :tags '(:unit :fast :stable :isolated :refactor :f11)
  (should (fboundp 'claude-agent-backend-filter-callbacks)))

;;; ============================================================
;;; F12: claude-agent-permission module extraction
;;; ============================================================

;; F12.1 Module provides feature
(ert-deftest test-f12-permission-module-provides-feature ()
  "The claude-agent-permission module should provide its feature."
  :tags '(:unit :fast :stable :isolated :refactor :f12)
  (should (featurep 'claude-agent-permission)))

;; F12.2 Permission protocol struct exists
(ert-deftest test-f12-permission-protocol-struct ()
  "Permission checker structs should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f12)
  (should (fboundp 'claude-agent-permission-checker-p))
  (should (fboundp 'claude-agent-pattern-checker-p)))

;; F12.3 Permission check functions exist
(ert-deftest test-f12-permission-check-functions ()
  "Core permission check functions should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f12)
  (should (fboundp 'claude-agent-permission-check-patterns))
  (should (boundp 'claude-agent-permission-functions)))

;; F12.4 Permission matching works
(ert-deftest test-f12-permission-match-basic ()
  "Permission pattern matching should work correctly."
  :tags '(:unit :fast :stable :isolated :refactor :f12)
  (should (fboundp 'claude-agent-permission-match-p))
  ;; Wildcard matches everything
  (should (claude-agent-permission-match-p "Read" nil "*"))
  ;; Exact tool name match
  (should (claude-agent-permission-match-p "Read" nil "Read"))
  (should-not (claude-agent-permission-match-p "Write" nil "Read")))

;; F12.5 Permission cache functions exist
(ert-deftest test-f12-permission-cache-functions ()
  "Permission cache functions should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f12)
  (should (fboundp 'claude-agent--permission-cache-key)))

;; F12.6 Permission prompt functions exist
(ert-deftest test-f12-permission-prompt-functions ()
  "Permission prompt functions should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f12)
  (should (fboundp 'claude-agent-permission-prompt))
  (should (fboundp 'claude-agent-permission-auto-allow)))

;;; ============================================================
;;; F13: claude-agent-ide module extraction
;;; ============================================================

;; F13.1 Module provides feature
(ert-deftest test-f13-ide-module-provides-feature ()
  "The claude-agent-ide module should provide its feature."
  :tags '(:unit :fast :stable :isolated :refactor :f13)
  (should (featurep 'claude-agent-ide)))

;; F13.2 IDE context collection function exists
(ert-deftest test-f13-ide-collect-context ()
  "IDE context collection function should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f13)
  (should (fboundp 'claude-agent-collect-ide-context)))

;; F13.3 System reminder building function exists
(ert-deftest test-f13-ide-build-system-reminder ()
  "System reminder building function should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f13)
  (should (fboundp 'claude-agent-build-system-reminder)))

;; F13.4 Buffer filtering works
(ert-deftest test-f13-ide-buffer-filtering ()
  "Buffer exclusion filtering should work."
  :tags '(:unit :fast :stable :isolated :refactor :f13)
  (should (fboundp 'claude-agent--buffer-excluded-p))
  ;; Internal buffers should be excluded (takes buffer object)
  (should (claude-agent--buffer-excluded-p (get-buffer "*Messages*"))))

;; F13.5 IDE context returns plist
(ert-deftest test-f13-ide-context-returns-plist ()
  "IDE context should return a plist with expected keys."
  :tags '(:unit :fast :stable :isolated :refactor :f13)
  (let ((ctx (claude-agent-collect-ide-context)))
    (should (listp ctx))
    ;; Should have open-files key at minimum
    (should (plist-member ctx :open-files))))

;;; ============================================================
;;; Cross-module integration
;;; ============================================================

(ert-deftest test-f11-f13-cross-module-backend-uses-permissions ()
  "Backend protocol and permissions should work together."
  :tags '(:unit :fast :stable :isolated :refactor :integration)
  ;; Just verify both modules are loaded and key functions exist
  (should (featurep 'claude-agent-backend))
  (should (featurep 'claude-agent-permission))
  (should (featurep 'claude-agent-ide))
  ;; Main claude-agent should still work with extracted modules
  (should (featurep 'claude-agent)))

(provide 'test-claude-agent-refactor-phase3)
;;; test-claude-agent-refactor-phase3.el ends here
