;;; test-cli-session-persistence.el --- E2E: CLI session id persistence + restart resume -*- lexical-binding: t -*-

;;; Commentary:
;; Regression tests for the 2026-07-12 stale-resume bug: restart built
;; `--resume' from a CLAUDE_CLI_SESSION property that nothing wrote
;; anymore, so every restart resumed an old conversation.  These tests
;; exercise the restored writer chain end-to-end on the elisp side:
;;
;;   save-cli-session (what the Python SessionStart hook evals via MCP)
;;     -> property lands on the RIGHT workspace heading (never by point)
;;     -> code-agent-org-cmux--build-launch-command picks it up as
;;        `--resume <id>' on the next restart.
;;
;; Requires: code-agent-org.org (loads the workspace module) +
;; code-agent-org-terminal-base.org + code-agent-org-cmux.org.

;;; Code:

(require 'ert)
(require 'org)

(defmacro test-cli-session--with-two-workspaces (&rest body)
  "Run BODY with a temp org file of two workspaces bound to `file'.
Workspace A: session ws-A, stale CLAUDE_CLI_SESSION stale-111.
Workspace B: session ws-B + CUSTOM_ID ws-b-custom, no CLI session yet.
Point starts inside workspace A (the wrong heading, deliberately)."
  `(let ((file (make-temp-file "cli-session-test" nil ".org")))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "* Workspace A\n"
                     ":PROPERTIES:\n"
                     ":CLAUDE_SESSION_ID: ws-A\n"
                     ":CLAUDE_CLI_SESSION: stale-111\n"
                     ":END:\n"
                     "Some body text.\n"
                     "* Workspace B\n"
                     ":PROPERTIES:\n"
                     ":CLAUDE_SESSION_ID: ws-B\n"
                     ":CUSTOM_ID: ws-b-custom\n"
                     ":END:\n"))
           (with-current-buffer (find-file-noselect file)
             (goto-char (point-min))) ; point on A — saves must not care
           ,@body)
       (when-let* ((buf (find-buffer-visiting file)))
         (with-current-buffer buf (set-buffer-modified-p nil))
         (kill-buffer buf))
       (delete-file file))))

(ert-deftest test-cli-session-save-routes-by-session-id-not-point ()
  "Saving for ws-B lands on B even though point is inside A."
  (test-cli-session--with-two-workspaces
   (code-agent-org-workspace-bridge-save-cli-session file "ws-B" "new-222")
   (with-current-buffer (find-buffer-visiting file)
     (org-with-wide-buffer
      (goto-char (point-min))
      (re-search-forward "^\\* Workspace B")
      (should (equal (org-entry-get nil "CLAUDE_CLI_SESSION") "new-222"))
      ;; A's stale value untouched — no cross-workspace stomping.
      (goto-char (point-min))
      (re-search-forward "^\\* Workspace A")
      (should (equal (org-entry-get nil "CLAUDE_CLI_SESSION") "stale-111"))))))

(ert-deftest test-cli-session-save-routes-by-custom-id ()
  "CUSTOM_ID is the preferred routing key (WORKSPACE_CUSTOM_ID env)."
  (test-cli-session--with-two-workspaces
   (code-agent-org-workspace-bridge-save-cli-session file "ws-b-custom" "new-333")
   (should (equal (code-agent-org-workspace-bridge-get-cli-session file "ws-B")
                  "new-333"))))

(ert-deftest test-cli-session-save-custom-property-name ()
  "Copilot variant writes COPILOT_CLI_SESSION, not the Claude property."
  (test-cli-session--with-two-workspaces
   (code-agent-org-workspace-bridge-save-cli-session
    file "ws-B" "cop-444" "COPILOT_CLI_SESSION")
   (with-current-buffer (find-buffer-visiting file)
     (org-with-wide-buffer
      (goto-char (point-min))
      (re-search-forward "^\\* Workspace B")
      (should (equal (org-entry-get nil "COPILOT_CLI_SESSION") "cop-444"))
      (should-not (org-entry-get nil "CLAUDE_CLI_SESSION"))))))

(ert-deftest test-cli-session-save-unknown-key-errors ()
  "A routing key with no matching workspace signals an error."
  (test-cli-session--with-two-workspaces
   (should-error
    (code-agent-org-workspace-bridge-save-cli-session file "no-such" "x"))))

(ert-deftest test-cli-session-restart-resumes-saved-session ()
  "E2E: after the hook saves the live id, restart's launch command
resumes exactly that id — the bug was resuming stale-111 forever."
  (test-cli-session--with-two-workspaces
   ;; The SessionStart hook fires for B's conversation new-222:
   (code-agent-org-workspace-bridge-save-cli-session file "ws-B" "new-222")
   (with-current-buffer (find-buffer-visiting file)
     (org-with-wide-buffer
      ;; Restart is invoked with point in B's subtree (transient menu).
      (goto-char (point-min))
      (re-search-forward "^\\* Workspace B")
      (let ((cmd (code-agent-org-cmux--build-launch-command file "ws-B" "/tmp")))
        (should (string-match-p "--resume new-222" cmd))
        (should-not (string-match-p "stale-111" cmd)))
      ;; A still resumes its own (stale-in-A's-world) id — isolation.
      (goto-char (point-min))
      (re-search-forward "^\\* Workspace A")
      (let ((cmd (code-agent-org-cmux--build-launch-command file "ws-A" "/tmp")))
        (should (string-match-p "--resume stale-111" cmd)))))))

(provide 'test-cli-session-persistence)
;;; test-cli-session-persistence.el ends here
