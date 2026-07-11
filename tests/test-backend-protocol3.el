;;; test-backend-protocol3.el --- Protocol 3 smoke tests -*- lexical-binding: t -*-
;;
;; Structural checks for the multiplexer-family backends (cmux/tmux)
;; that implement the Org-Integration Protocol (Protocol 3) added in
;; the 2026-04-24 tri-protocol refactor, plus tmux's Protocol 2b
;; session-status smoke tests.
;;
;; See: docs/design-docs/2026-tri-protocol-backend-refactor.org §Protocol 3.

(require 'ert)
(require 'cl-lib)
(require 'code-agent-backend)
(require 'code-agent-multiplexer)
(require 'code-agent-cmux-backend)
(require 'code-agent-tmux-backend)

;;; Test fixture — concrete multiplexer backends for dispatch testing.
;;; `code-agent-backend' is the Protocol 1 base (`:constructor nil',
;;; abstract). The only concrete agent-family backend
;;; (`code-agent-claude-code-backend') was deleted 2026-07 (zero
;;; production callers); no concrete agent-family backend remains, so
;;; the "default errors for agent-family backends" dispatch test that
;;; used it was removed along with its fixture.

(defun test-p3--fresh-cmux-backend ()
  "Return a fresh `code-agent-cmux-backend' instance."
  (code-agent-cmux-backend-create :session-key "test::fixture"))

(defun test-p3--fresh-tmux-backend ()
  "Return a fresh `code-agent-tmux-backend' instance."
  (code-agent-tmux-backend-create :session-key "test::fixture"))

;;; Multiplexer backend structural checks

(ert-deftest test-p3-cmux-backend-inherits-session-key-slot ()
  "`code-agent-cmux-backend' carries the `session-key' slot from the
multiplexer base — the registry constructor passes :session-key."
  :tags '(:unit :fast :stable :protocol-3)
  (let ((backend (test-p3--fresh-cmux-backend)))
    (should (code-agent-cmux-backend-p backend))
    (should (code-agent-multiplexer-backend-p backend))
    (should (equal "test::fixture"
                   (code-agent-multiplexer-backend-session-key backend)))))

(ert-deftest test-p3-tmux-backend-inherits-session-key-slot ()
  :tags '(:unit :fast :stable :protocol-3)
  (let ((backend (test-p3--fresh-tmux-backend)))
    (should (code-agent-tmux-backend-p backend))
    (should (code-agent-multiplexer-backend-p backend))
    (should (equal "test::fixture"
                   (code-agent-multiplexer-backend-session-key backend)))))

;;; tmux backend — Protocol 2b smoke tests (mocked tmux CLI)


(ert-deftest test-p3-tmux-session-status-missing-when-sid-nil ()
  :tags '(:unit :fast :stable :protocol-3 :tmux)
  (let ((backend (test-p3--fresh-tmux-backend)))
    (should (eq :missing (code-agent-mux-session-status backend)))))

(ert-deftest test-p3-tmux-session-status-unset-when-pane-nil ()
  "Session status distinguishes :missing (no session) from :unset (pane absent)."
  :tags '(:unit :fast :stable :protocol-3 :tmux)
  (let ((backend (test-p3--fresh-tmux-backend)))
    (setf (code-agent-multiplexer-backend-multiplexer-session-id backend)
          "claude-test")
    (should (eq :unset (code-agent-mux-session-status backend)))))

(provide 'test-backend-protocol3)
;;; test-backend-protocol3.el ends here
