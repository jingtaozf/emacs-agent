;;; test-backend-protocol3.el --- Protocol 3 smoke tests -*- lexical-binding: t -*-
;;
;; Covers the default methods of the Org-Integration Protocol (Protocol 3)
;; added in the 2026-04-24 tri-protocol refactor.  Verifies the generics
;; dispatch without error and the defaults behave as documented.
;;
;; See: docs/design-docs/2026-tri-protocol-backend-refactor.org §Protocol 3.

(require 'ert)
(require 'cl-lib)
(require 'code-agent-backend)
(require 'code-agent-multiplexer)
(require 'code-agent-cmux-backend)
(require 'code-agent-tmux-backend)

;;; Test fixture — a minimal concrete agent backend for dispatch testing.
;;; `code-agent-backend' is the Protocol 1 base (`:constructor nil',
;;; abstract).  Concrete agents inherit from it directly; we instantiate
;;; `code-agent-claude-code-backend' for dispatch tests.

(defun test-p3--fresh-claude-code-backend ()
  "Return a fresh `code-agent-claude-code-backend' for Protocol 3 dispatch tests."
  (code-agent-claude-code-backend--create))

(defun test-p3--fresh-cmux-backend ()
  "Return a fresh `code-agent-cmux-backend' instance."
  (code-agent-cmux-backend-create :session-key "test::fixture"))

(defun test-p3--fresh-tmux-backend ()
  "Return a fresh `code-agent-tmux-backend' instance."
  (code-agent-tmux-backend-create :session-key "test::fixture"))

;;; Protocol 3 — Smoke tests for default methods

(ert-deftest test-p3-insert-prompt-default-is-noop ()
  "Default `insert-prompt' method returns nil without side effects."
  :tags '(:unit :fast :stable :protocol-3)
  (let ((backend (test-p3--fresh-claude-code-backend)))
    (should-not (code-agent-org-backend-insert-prompt backend '(:prompt "hi")))))

(ert-deftest test-p3-open-response-section-default-returns-nil ()
  "Default `open-response-section' returns nil (frontend must override)."
  :tags '(:unit :fast :stable :protocol-3)
  (let ((backend (test-p3--fresh-claude-code-backend)))
    (should-not (code-agent-org-backend-open-response-section backend
                                                          '(:prompt "hi")))))

(ert-deftest test-p3-append-response-default-inserts-at-marker ()
  "Default `append-response' inserts CHUNK at MARKER and advances it."
  :tags '(:unit :fast :stable :protocol-3)
  (let ((backend (test-p3--fresh-claude-code-backend)))
    (with-temp-buffer
      (let ((marker (point-marker)))
        (code-agent-org-backend-append-response backend marker "hello ")
        (code-agent-org-backend-append-response backend marker "world")
        (should (equal (buffer-string) "hello world"))
        (should (= (marker-position marker) (point-max)))))))

(ert-deftest test-p3-append-response-survives-dead-buffer ()
  "`append-response' is a safe no-op when marker's buffer is dead."
  :tags '(:unit :fast :stable :protocol-3)
  (let ((backend (test-p3--fresh-claude-code-backend))
        (dead-marker
         (let ((buf (generate-new-buffer " *test-dead*")))
           (with-current-buffer buf (prog1 (point-marker) (kill-buffer buf))))))
    (should-not (code-agent-org-backend-append-response backend dead-marker "x"))))

(ert-deftest test-p3-finalize-response-default-is-noop ()
  :tags '(:unit :fast :stable :protocol-3)
  (let ((backend (test-p3--fresh-claude-code-backend)))
    (should-not (code-agent-org-backend-finalize-response backend nil nil))))

(ert-deftest test-p3-query-completed-default-is-noop ()
  :tags '(:unit :fast :stable :protocol-3)
  (let ((backend (test-p3--fresh-claude-code-backend)))
    (should-not (code-agent-org-backend-query-completed backend "sk"))))

(ert-deftest test-p3-recover-session-default-is-noop ()
  :tags '(:unit :fast :stable :protocol-3)
  (let ((backend (test-p3--fresh-claude-code-backend)))
    (should-not (code-agent-org-backend-recover-session backend))))

(ert-deftest test-p3-status-badge-default-returns-nil ()
  :tags '(:unit :fast :stable :protocol-3)
  (let ((backend (test-p3--fresh-claude-code-backend)))
    (should-not (code-agent-org-backend-status-badge backend "sk"))))

(ert-deftest test-p3-todos-update-default-is-noop ()
  :tags '(:unit :fast :stable :protocol-3)
  (let ((backend (test-p3--fresh-claude-code-backend)))
    (should-not (code-agent-org-backend-todos-update backend '() nil))))

(ert-deftest test-p3-open-terminal-tab-default-errors-for-agent ()
  "Agent-family default signals `user-error' — no terminal to open."
  :tags '(:unit :fast :stable :protocol-3)
  (let ((backend (test-p3--fresh-claude-code-backend)))
    (should-error (code-agent-org-backend-open-terminal-tab backend)
                  :type 'user-error)))

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

(ert-deftest test-p3-tmux-shell-quote-embeds-single-quotes ()
  "`code-agent-tmux--shell-quote' correctly escapes embedded quotes."
  :tags '(:unit :fast :stable :protocol-3 :tmux)
  (should (equal "'/tmp/x'" (code-agent-tmux--shell-quote "/tmp/x")))
  (should (equal "'/tmp/a b'" (code-agent-tmux--shell-quote "/tmp/a b")))
  (should (equal "'/tmp/a'\\''b'"
                 (code-agent-tmux--shell-quote "/tmp/a'b"))))

(ert-deftest test-p3-tmux-send-text-invokes-tmux-send-keys-dashl ()
  "`send-text' calls `tmux send-keys -l' against the backend's pane target."
  :tags '(:unit :fast :stable :protocol-3 :tmux)
  (let* ((backend (test-p3--fresh-tmux-backend))
         (calls '()))
    (setf (code-agent-multiplexer-backend-pane-id backend) "sess:0.0")
    (cl-letf (((symbol-function 'code-agent-tmux--call)
               (lambda (_b &rest args)
                 (push args calls)
                 "ok")))
      (code-agent-mux-send-text backend "hello"))
    (should (= (length calls) 1))
    (should (equal (car calls)
                   '("send-keys" "-t" "sess:0.0" "-l" "hello")))))

(ert-deftest test-p3-tmux-send-key-maps-keyword-to-tmux-name ()
  :tags '(:unit :fast :stable :protocol-3 :tmux)
  (let* ((backend (test-p3--fresh-tmux-backend))
         (calls '()))
    (setf (code-agent-multiplexer-backend-pane-id backend) "sess:0.0")
    (cl-letf (((symbol-function 'code-agent-tmux--call)
               (lambda (_b &rest args) (push args calls) "ok")))
      (code-agent-mux-send-key backend :enter)
      (code-agent-mux-send-key backend :ctrl-c))
    (should (equal (cadr (nth 1 calls)) "-t")) ; enter call
    (should (member "Enter" (car (last calls))))
    (should (member "C-c" (car calls)))))

(ert-deftest test-p3-tmux-start-follower-emits-single-quoted-sink ()
  "`start-follower' passes the sink wrapped in single quotes to pipe-pane."
  :tags '(:unit :fast :stable :protocol-3 :tmux)
  (let* ((backend (test-p3--fresh-tmux-backend))
         (calls '()))
    (setf (code-agent-multiplexer-backend-pane-id backend) "sess:0.0")
    (cl-letf (((symbol-function 'code-agent-tmux--call)
               (lambda (_b &rest args) (push args calls) "ok")))
      (code-agent-mux-start-follower backend "/tmp/sink.log"))
    (let ((args (car calls)))
      (should (equal (car args) "pipe-pane"))
      ;; Final arg should be "cat >> '/tmp/sink.log'"
      (should (string-match "cat >> '/tmp/sink\\.log'"
                            (car (last args)))))
    (should (eq :active
                (code-agent-multiplexer-backend-follower-proc backend)))))

(ert-deftest test-p3-tmux-stop-follower-is-noop-when-inactive ()
  "`stop-follower' does not call tmux when no follower is active."
  :tags '(:unit :fast :stable :protocol-3 :tmux)
  (let* ((backend (test-p3--fresh-tmux-backend))
         (called nil))
    (cl-letf (((symbol-function 'code-agent-tmux--call)
               (lambda (&rest _) (setq called t) "ok")))
      (code-agent-mux-stop-follower backend))
    (should-not called)))

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
