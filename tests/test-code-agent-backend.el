;;; test-code-agent-backend.el --- TDD Tests for Backend Protocol -*- lexical-binding: t; -*-

;; TDD tests for the backend protocol abstraction layer.
;; These tests define expected behavior BEFORE implementation.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'code-agent)

;;; Phase 1: Backend Protocol Struct and Generic Definitions

(ert-deftest test-backend-base-struct-exists ()
  "Backend base struct should exist as a type."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (should (fboundp 'code-agent-backend-p))
  (should (fboundp 'code-agent-backend-type)))

(ert-deftest test-backend-base-struct-is-abstract ()
  "Backend base struct should not have a public constructor."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  ;; The default make-code-agent-backend should not exist
  ;; because we use (:constructor nil)
  (should-not (fboundp 'make-code-agent-backend)))

(ert-deftest test-backend-generics-defined ()
  "All 8 backend protocol generics should be defined."
  :tags '(:unit :fast :stable :isolated :backend :phase-1)
  (should (fboundp 'code-agent-backend-query))
  (should (fboundp 'code-agent-backend-cancel))
  (should (fboundp 'code-agent-backend-cleanup))
  (should (fboundp 'code-agent-backend-active-p))
  (should (fboundp 'code-agent-backend-session-id))
  (should (fboundp 'code-agent-backend-send-input))
  (should (fboundp 'code-agent-backend-supports-p))
  (should (fboundp 'code-agent-backend-classify-error)))

;;; Phase 1: JSON stream backend struct/method tests, Phase 2 method tests,
;;; Phase 4 classify-error-internal, and Phase 5 capability-guard tests were
;;; removed 2026-07 — all instantiated code-agent-claude-code-backend, which
;;; was deleted (zero production callers after the org-as-control-plane
;;; pivot). code-agent-backend-filter-callbacks (Phase 5's subject) is still
;;; alive but currently untested — a follow-up unit should re-add coverage
;;; using a live concrete backend (e.g. code-agent-cmux-backend-create) as
;;; the fixture instead.

;;; Phase 4: Public utility functions

(ert-deftest test-make-session-key-public ()
  "code-agent-make-session-key should be a public function."
  :tags '(:unit :fast :stable :isolated :backend :phase-4)
  (should (fboundp 'code-agent-make-session-key))
  (should (equal "/tmp/test.org"
                 (code-agent-make-session-key "/tmp/test.org")))
  (should (equal "/tmp/test.org::session-1"
                 (code-agent-make-session-key "/tmp/test.org" "session-1"))))

(provide 'test-code-agent-backend)
;;; test-code-agent-backend.el ends here
