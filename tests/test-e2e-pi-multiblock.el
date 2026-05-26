;;; test-e2e-pi-multiblock.el --- Multi-block same-workspace Pi E2E -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives `code-agent-org-execute' (the real C-c C-c path) against the
;; `tests/e2e/org/pi-backend-multiblock-test.org' fixture to prove:
;;
;;   1. Block 1 + Block 2 in the SAME workspace heading share ONE Pi
;;      subprocess (continuous session).  After block 1 finishes, the
;;      session's :busy flag must clear so block 2 dispatches (not
;;      gets queued forever).  This is the 2026-05-25 regression
;;      target — the user reported a stuck :busy after the first
;;      query's agent_end.
;;
;;   2. Block 3 after an explicit Pi process kill triggers a respawn
;;      through the same session-key.  Pi PID differs from blocks
;;      1+2 but the session-key + backend struct are reused.
;;
;; Unlike `tests/test-e2e-pi-backend.el' (which constructs the backend
;; struct directly), this runner goes through `code-agent-org-execute'
;; so frontend dispatch, busy-tracking, queue-pumping, and response
;; rendering are all in the loop.  That is exactly the bug surface the
;; direct-struct tests bypass.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-element)

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (root (expand-file-name ".." here)))
  (add-to-list 'load-path root)
  (add-to-list 'load-path (expand-file-name "tests/support" root))
  (require 'literate-elisp)
  (unless (featurep 'code-agent-backend)
    (literate-elisp-load (expand-file-name "lp/sdk/code-agent-backend.org" root)))
  (unless (featurep 'code-agent-pi-backend)
    (literate-elisp-load (expand-file-name "lp/backend/code-agent-pi-backend.org" root)))
  ;; Need the full org-integration stack for the real execute path.
  (unless (featurep 'code-agent-org)
    (load-file (expand-file-name "code-agent.el" root))))

(require 'pi-test-helpers)

;; The fixture's ai blocks don't call any emacs_* tools, so the MCP
;; server is unnecessary.  Disabling auto-start also avoids port 9999
;; conflicts with the user's running Emacs MCP server.
(setq code-agent-org-auto-start-mcp-server nil)

;; In batch mode there is no Phoenix collector / OTel bridge to talk to;
;; `code-agent-with-span''s synchronous span/start call would block for
;; 2 s on every traced step and swallow downstream messages.  Disable
;; tracing for the test.  (In an interactive Emacs with Phoenix running
;; the macro short-circuits via the running bridge — no impact.)
(setq code-agent-trace-enabled nil)

(defconst test-mb--fixture
  (expand-file-name "tests/e2e/org/pi-backend-multiblock-test.org"
                    (file-name-directory
                     (directory-file-name
                      (file-name-directory
                       (or load-file-name buffer-file-name)))))
  "Absolute path to the multi-block Pi E2E fixture.")


;; --- Fixture buffer management ---

(defmacro test-mb--with-fresh-fixture (buf &rest body)
  "Open the fixture in a fresh buffer bound to BUF, run BODY, always
revert + kill so the fixture file on disk is not mutated by the
response sections that `code-agent-org-execute' inserts."
  (declare (indent 1) (debug t))
  `(let ((,buf (find-file-noselect test-mb--fixture)))
     (unwind-protect
         (with-current-buffer ,buf
           (org-mode)
           (when (fboundp 'code-agent-org-mode)
             (code-agent-org-mode 1))
           ,@body)
       ;; Discard any response sections inserted by C-c C-c.
       (with-current-buffer ,buf
         (set-buffer-modified-p nil))
       (kill-buffer ,buf))))


(defun test-mb--goto-block (custom-id)
  "Move point INSIDE the first `#+begin_src ai' block under the
heading with :CUSTOM_ID: CUSTOM-ID."
  (goto-char (point-min))
  (unless (re-search-forward (format ":CUSTOM_ID: %s$" custom-id) nil t)
    (error "Block %s not found" custom-id))
  (org-back-to-heading t)
  (unless (re-search-forward "^#\\+begin_src ai" nil t)
    (error "No `ai' src block under %s" custom-id))
  (forward-line 1)
  (point))


(defun test-mb--session-key (buf)
  "Return the session-key for the multiblock fixture, mirroring
how `code-agent-org-execute' computes it: file-qualified."
  (with-current-buffer buf
    (format "%s::%s"
            (buffer-file-name)
            (save-excursion
              (goto-char (point-min))
              (when (re-search-forward
                     ":CLAUDE_SESSION_ID: \\(\\S-+\\)" nil t)
                (match-string 1))))))


(defun test-mb--wait-for-completion (buf sk timeout)
  "Pump the event loop in BUF until session SK's :busy flag clears,
or TIMEOUT seconds elapse.  Returns t on completion, nil on timeout.

On timeout, dumps session state slots + Pi backend struct so a
hanging multiblock test diagnoses itself (without needing
TEST_MB_VERBOSE)."
  (with-current-buffer buf
    (let ((deadline (+ (float-time) timeout)))
      (while (and (code-agent-org--session-get sk :busy)
                  (< (float-time) deadline))
        (accept-process-output nil 0.1)
        (sleep-for 0.05))
      (let ((cleared (not (code-agent-org--session-get sk :busy))))
        (unless cleared
          (let* ((b (code-agent-org--session-get sk :backend))
                 (proc (and (code-agent-pi-backend-p b)
                            (code-agent-pi-backend-process b))))
            (princ (format "TIMEOUT DUMP: busy=%s query-handle=%s query-id=%s backend=%s process-status=%s handshake-done=%s active-prompt-id=%s pending=%s\n"
                           (code-agent-org--session-get sk :busy)
                           (code-agent-org--session-get sk :query-handle)
                           (code-agent-org--session-get sk :query-id)
                           (and b (type-of b))
                           (and proc (process-status proc))
                           (and (code-agent-pi-backend-p b)
                                (code-agent-pi-backend-handshake-done b))
                           (and (code-agent-pi-backend-p b)
                                (code-agent-pi-backend-active-prompt-id b))
                           (and (code-agent-pi-backend-p b)
                                (hash-table-count
                                 (code-agent-pi-backend-pending-by-id b)))))))
        cleared))))


(defun test-mb--response-text (buf custom-id)
  "Return the text of the response section that immediately follows the
AI block under heading CUSTOM-ID in BUF.

The response is inserted as a *sibling* heading (`*** Response NNN
:ai_output:`) of the Instruction heading, NOT as a child — so
`org-end-of-subtree' on the Instruction does NOT reach it.  We walk
forward from `:CUSTOM_ID: <id>' to the first heading tagged
`:ai_output:' (or `:claude_chat:` for a sibling Instruction) and
return that subtree's body."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (re-search-forward (format ":CUSTOM_ID: %s$" custom-id))
      (org-back-to-heading t)
      ;; Advance past the Instruction's own subtree (includes the src
      ;; block and the ai_output sibling lives JUST after the subtree end).
      (let ((instr-end (save-excursion (org-end-of-subtree t t) (point))))
        (goto-char instr-end))
      ;; The next heading is either the Response (ai_output) or, if
      ;; the assistant produced nothing, the next Instruction.  Match
      ;; on the heading-line bytes directly — `org-get-heading' is
      ;; finicky in batch mode (returns nil for tags-only).
      (when (looking-at "^\\*+ .*:ai_output:.*$")
        (let* ((start (line-beginning-position 2))
               (end (save-excursion (org-end-of-subtree t t) (point))))
          (buffer-substring-no-properties start end))))))


(defun test-mb--backend-pid (buf sk)
  "Return the PID of the Pi subprocess cached in SK's :backend, or nil."
  (with-current-buffer buf
    (when-let* ((b (code-agent-org--session-get sk :backend))
                (p (and (code-agent-pi-backend-p b)
                        (code-agent-pi-backend-process b))))
      (and (process-live-p p) (process-id p)))))


;; --- The single ERT story ---

(ert-deftest e2e-pi-multiblock--same-session-and-restart ()
  "Run 3 ai blocks under the same workspace heading, asserting:

  Block 1 → block 2: SAME Pi PID (continuous in-process session) AND
                     block 2 recalls the number from block 1 (Pi-side
                     context within the same subprocess).

  Block 2 → block 3 (after kill): Pi respawns (DIFFERENT PID),
                     and block 3 STILL recalls the number — proving
                     Pi-side session persistence via
                     `:PI_SESSION_ID:` org property + Pi's default
                     ~/.pi/agent/sessions/ store.

If block 2 hangs with :busy stuck, the 2026-05-25 regression bit.
If block 3 succeeds in different PID but the response does NOT
contain '4242', persistence wiring is broken — registry didn't
write :PI_SESSION_ID:, or didn't pass --session on respawn."
  :tags '(:e2e-pi-multiblock)
  (skip-unless (test-pi--available-p))
  (test-mb--with-fresh-fixture buf
    (let ((sk (test-mb--session-key buf)))
      ;; Clear any leftover state from prior runs (this fixture's
      ;; session-key is stable, so consecutive `make' invocations
      ;; would otherwise inherit cached backends).
      (when (boundp 'code-agent-org--sessions)
        (when (and code-agent-org--sessions
                   (hash-table-p code-agent-org--sessions))
          (remhash sk code-agent-org--sessions)))
      ;; Also clear any stale :PI_SESSION_ID: from a prior run — we
      ;; want this test to validate the PERSIST-then-RESUME loop end
      ;; to end, starting from a clean slate.
      (save-excursion
        (goto-char (point-min))
        (re-search-forward ":CUSTOM_ID: pi-mb-workspace$")
        (org-entry-delete nil "PI_SESSION_ID"))

      ;; ---- Block 1 ----
      (test-mb--goto-block "pi-mb-1")
      (code-agent-org-execute)
      (should (test-mb--wait-for-completion buf sk 60))
      (let ((resp1 (test-mb--response-text buf "pi-mb-1"))
            (pid1 (test-mb--backend-pid buf sk)))
        (should (integerp pid1))
        (should (string-match-p "ACK_ONE" resp1))
        ;; By now :PI_SESSION_ID: must be persisted on the workspace.
        (let ((persisted (save-excursion
                           (goto-char (point-min))
                           (re-search-forward ":CUSTOM_ID: pi-mb-workspace$")
                           (org-entry-get nil "PI_SESSION_ID" t))))
          (should (and persisted (> (length persisted) 0))))

        ;; ---- Block 2 (must share PID + recall context) ----
        (test-mb--goto-block "pi-mb-2")
        (code-agent-org-execute)
        (should (test-mb--wait-for-completion buf sk 60))
        (let ((resp2 (test-mb--response-text buf "pi-mb-2"))
              (pid2 (test-mb--backend-pid buf sk)))
          (should (integerp pid2))
          ;; SAME subprocess — proves in-process continuity.
          (should (= pid1 pid2))
          ;; Pi remembers the number even though we never repeated it.
          (should (string-match-p "4242" resp2)))

        ;; ---- Kill Pi between blocks ----
        (let* ((backend (code-agent-org--session-get sk :backend))
               (proc (and backend
                          (code-agent-pi-backend-p backend)
                          (code-agent-pi-backend-process backend))))
          (should (process-live-p proc))
          (delete-process proc)
          ;; Give the sentinel time to fire + clear backend state.
          (let ((t0 (float-time)))
            (while (and (< (- (float-time) t0) 3.0)
                        (process-live-p proc))
              (accept-process-output nil 0.05))))

        ;; ---- Block 3 (respawn — different PID, session resumed) ----
        (test-mb--goto-block "pi-mb-3")
        (code-agent-org-execute)
        (should (test-mb--wait-for-completion buf sk 60))
        (let ((resp3 (test-mb--response-text buf "pi-mb-3"))
              (pid3 (test-mb--backend-pid buf sk)))
          (should (integerp pid3))
          ;; New subprocess (restart succeeded).
          (should-not (= pid1 pid3))
          ;; The number should still be recalled even though the
          ;; subprocess was killed — Pi loaded the persisted session.
          (should (string-match-p "4242" resp3)))))))


(provide 'test-e2e-pi-multiblock)
;;; test-e2e-pi-multiblock.el ends here
