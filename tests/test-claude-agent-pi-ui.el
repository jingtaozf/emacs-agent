;;; test-claude-agent-pi-ui.el --- Tests for Pi UI Phase 1 -*- lexical-binding: t; -*-

;;; Commentary:

;; Smoke + live tests for `claude-agent-pi-ui.org' — the Phase 1
;; RPC-driven control panel and extension UI request handlers.

;;; Code:

(require 'ert)
(require 'cl-lib)

(let* ((root (or (and (boundp 'test-claude-agent-project-root)
                      test-claude-agent-project-root)
                 (expand-file-name
                  ".."
                  (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path root)
  (add-to-list 'load-path (expand-file-name "tests/support" root))
  (require 'literate-elisp)
  (unless (featurep 'claude-agent-backend)
    (literate-elisp-load (expand-file-name "claude-agent-backend.org" root)))
  (unless (featurep 'claude-agent-pi-backend)
    (literate-elisp-load (expand-file-name "claude-agent-pi-backend.org" root)))
  (unless (featurep 'claude-agent-pi-ui)
    (literate-elisp-load (expand-file-name "claude-agent-pi-ui.org" root))))

(require 'claude-agent-pi-backend)
(require 'claude-agent-pi-ui)
(require 'pi-test-helpers)


;; --- Smoke ---

(ert-deftest claude-agent-pi-ui-smoke--symbols ()
  "Public symbols are defined after load."
  :tags '(:smoke :pi-ui)
  (dolist (s '(claude-agent-pi-ui-menu
               claude-agent-pi-ui-new-session
               claude-agent-pi-ui-cycle-model
               claude-agent-pi-ui-pick-model
               claude-agent-pi-ui-cycle-thinking
               claude-agent-pi-ui-set-thinking
               claude-agent-pi-ui-steer
               claude-agent-pi-ui-follow-up
               claude-agent-pi-ui-abort
               claude-agent-pi-ui-compact
               claude-agent-pi-ui-stats
               claude-agent-pi-ui-export-html
               claude-agent-pi-ui-login))
    (should (fboundp s))))

(ert-deftest claude-agent-pi-ui-smoke--menu-prefix ()
  "Transient submenu is registered as a prefix."
  :tags '(:smoke :pi-ui)
  (should (get 'claude-agent-pi-ui-menu 'transient--prefix)))

(ert-deftest claude-agent-pi-ui-smoke--extension-ui-handler-installed ()
  "Loading pi-ui replaces the auto-cancel default with the rich handler."
  :tags '(:smoke :pi-ui)
  (should (eq claude-agent-pi-extension-ui-handler
              #'claude-agent-pi-ui--extension-ui-handler)))

(ert-deftest claude-agent-pi-ui-smoke--current-backend-errors-cleanly ()
  "Outside a session, `--current-backend' raises a clear user-error."
  :tags '(:smoke :pi-ui)
  (let ((err (should-error (claude-agent-pi-ui--current-backend)
                           :type 'user-error)))
    (should (stringp (cadr err)))))


;; --- Live (real pi subprocess) ---

(ert-deftest claude-agent-pi-ui-live--cycle-thinking-mutates-state ()
  "Drive `set_thinking_level' on a spawned backend; verify get_state
reports the new level.  This proves the synchronous RPC pipe — a
prerequisite for every Phase 1 command — works end to end."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi--with-backend b
    (let (ready)
      (claude-agent-pi--ensure-spawn-and-handshake
       b (lambda () (setq ready :ok)) (lambda (msg) (setq ready (cons :err msg))))
      (should (test-pi--wait-until (lambda () ready) 12))
      (should (eq ready :ok)))
    (let* ((state-before
            (claude-agent-pi-ui--unwrap
             (claude-agent-pi-ui--call b '((type . "get_state")))))
           (level-before (map-elt state-before 'thinkingLevel))
           (target (if (equal level-before "low") "medium" "low")))
      (claude-agent-pi-ui--unwrap
       (claude-agent-pi-ui--call b `((type . "set_thinking_level")
                                      (level . ,target))))
      (let* ((state-after
              (claude-agent-pi-ui--unwrap
               (claude-agent-pi-ui--call b '((type . "get_state")))))
             (level-after (map-elt state-after 'thinkingLevel)))
        (should (equal target level-after))))))


(ert-deftest claude-agent-pi-ui-live--steer-and-followup-accepted ()
  "`steer' and `follow_up' RPC commands return success when idle."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi--with-backend b
    (claude-agent-pi--ensure-spawn-and-handshake
     b (lambda () nil) (lambda (_msg) nil))
    (test-pi--wait-until (lambda () (claude-agent-backend-ready-p b)) 12)
    (let ((s-resp (claude-agent-pi-ui--call
                   b '((type . "steer") (message . "noop steer")))))
      (should (eq (map-elt s-resp 'success) t)))
    (let ((f-resp (claude-agent-pi-ui--call
                   b '((type . "follow_up") (message . "noop follow-up")))))
      (should (eq (map-elt f-resp 'success) t)))))


(provide 'test-claude-agent-pi-ui)
;;; test-claude-agent-pi-ui.el ends here
