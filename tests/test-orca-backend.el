;;; test-orca-backend.el --- Orca multiplexer backend unit tests -*- lexical-binding: t -*-
;;
;; Each test below pins an invariant that a live Orca session proved on
;; 2026-07-25 and that a plausible "cleanup" would silently break.  The
;; measurement that motivated the assertion is named in the docstring,
;; because the assertion alone does not explain why the value matters.
;;
;; See: lp/backend/code-agent-orca-backend.org

(require 'ert)
(require 'cl-lib)
(require 'code-agent-backend)
(require 'code-agent-multiplexer)
(require 'code-agent-orca-backend)

(defun test-orca--backend (&rest args)
  "Return a fresh Orca backend with a terminal handle already set."
  (let ((b (apply #'code-agent-orca-backend-create :session-key "test::fixture" args)))
    (setf (code-agent-multiplexer-backend-pane-id b) "term_fixture")
    b))

;;; ------------------------------------------------------------------
;;; Recording stub — captures the argv every method would have run.
;;; ------------------------------------------------------------------

;; The status dir is owned by the org layer, which `make test-backend-unit'
;; does not load.  Bind it here so the backend suite can run standalone;
;; the org layer's `defconst' still wins whenever it is loaded.
(defvar code-agent-org-terminal-status-dir
  (expand-file-name "code-agent-status" temporary-file-directory))

(defvar test-orca--calls nil
  "Argv lists captured by `test-orca--with-cli'.")

(defmacro test-orca--with-cli (stdout &rest body)
  "Run BODY with the Orca CLI replaced by a recorder answering STDOUT."
  (declare (indent 1))
  `(let ((test-orca--calls nil))
     (cl-letf (((symbol-function 'call-process)
                (lambda (_prog _infile buffer _display &rest args)
                  (push args test-orca--calls)
                  (when (bufferp buffer)
                    (with-current-buffer buffer (insert ,stdout)))
                  0)))
       ,@body)
     (setq test-orca--calls (nreverse test-orca--calls))))

(defun test-orca--arg-after (flag)
  "Return the value following FLAG in the first recorded call."
  (let ((argv (car test-orca--calls)))
    (cadr (member flag argv))))

;;; ------------------------------------------------------------------
;;; Envelope handling
;;; ------------------------------------------------------------------

(ert-deftest test-orca-error-envelope-is-data-not-signal ()
  "A failing envelope comes back as data.

`selector_not_found' (directory Orca has not registered) and
`terminal_handle_stale' (handle from before an Orca restart) are both
routine control flow — launch retries on one, ensure-session clears the
slot on the other.  Signalling would force every call site into a
`condition-case' and lose the code."
  :tags '(:unit :fast :stable :orca)
  (test-orca--with-cli "{\"ok\":false,\"error\":{\"code\":\"selector_not_found\"}}"
    (let ((reply (code-agent-orca--call (test-orca--backend) "worktree" "show")))
      (should (equal "selector_not_found" (code-agent-orca--error-code reply))))))

(ert-deftest test-orca-success-envelope-unwraps-result ()
  "A successful envelope yields the `result' alist, not the whole reply."
  :tags '(:unit :fast :stable :orca)
  (test-orca--with-cli "{\"ok\":true,\"result\":{\"terminal\":{\"handle\":\"term_x\"}}}"
    (let ((reply (code-agent-orca--call (test-orca--backend) "terminal" "show")))
      (should-not (code-agent-orca--error-code reply))
      (should (equal "term_x" (alist-get 'handle (alist-get 'terminal reply)))))))

(ert-deftest test-orca-stale-handle-clears-the-slot ()
  "`ensure-session' forgets a handle Orca no longer knows.

Leaving the dead handle in place would make every later send silently
target nothing; clearing it lets the launch path create a fresh
terminal."
  :tags '(:unit :fast :stable :orca)
  (let ((b (test-orca--backend)))
    (test-orca--with-cli "{\"ok\":false,\"error\":{\"code\":\"terminal_handle_stale\"}}"
      (should-not (code-agent-mux-ensure-session b)))
    (should-not (code-agent-multiplexer-backend-pane-id b))))

(ert-deftest test-orca-disconnected-terminal-is-not-alive ()
  "A closed tab is a dead session even though the envelope says ok.

Closing a tab does not invalidate the handle: a live run on 2026-07-25
showed `terminal show' still answering `ok: true' afterwards, with
`connected: false' and the terminal absent from `terminal list'.
Trusting the envelope alone would make `launch' focus a tab that no
longer exists and send every later prompt into nothing."
  :tags '(:unit :fast :stable :orca)
  (let ((b (test-orca--backend)))
    (test-orca--with-cli
        "{\"ok\":true,\"result\":{\"terminal\":{\"handle\":\"term_fixture\",\"connected\":false}}}"
      (should-not (code-agent-mux-ensure-session b)))
    (should-not (code-agent-multiplexer-backend-pane-id b))))

(ert-deftest test-orca-connected-terminal-is-alive ()
  "A connected terminal keeps its handle."
  :tags '(:unit :fast :stable :orca)
  (let ((b (test-orca--backend)))
    (test-orca--with-cli
        "{\"ok\":true,\"result\":{\"terminal\":{\"handle\":\"term_fixture\",\"connected\":true}}}"
      (should (equal "term_fixture" (code-agent-mux-ensure-session b))))
    (should (equal "term_fixture" (code-agent-multiplexer-backend-pane-id b)))))

;;; ------------------------------------------------------------------
;;; Wire primitives
;;; ------------------------------------------------------------------

(ert-deftest test-orca-escape-is-one-raw-byte ()
  "`:escape' is the single byte 0x1b.

Orca has no key-name vocabulary — `terminal send --text' writes raw
bytes to the pty.  A live session confirmed `bytesWritten: 1' for this
payload; sending the string \"Escape\" would type six characters into
the agent's prompt instead."
  :tags '(:unit :fast :stable :orca)
  (test-orca--with-cli "{\"ok\":true,\"result\":{}}"
    (code-agent-mux-send-key (test-orca--backend) :escape)
    (should (equal "\033" (test-orca--arg-after "--text")))))

(ert-deftest test-orca-ctrl-c-uses-the-interrupt-flag ()
  "`:ctrl-c' goes through `--interrupt' rather than a raw 0x03.

Both reach the pty; the flag keeps the intent legible in Orca's own
command log."
  :tags '(:unit :fast :stable :orca)
  (test-orca--with-cli "{\"ok\":true,\"result\":{}}"
    (code-agent-mux-send-key (test-orca--backend) :ctrl-c)
    (should (member "--interrupt" (car test-orca--calls)))))

(ert-deftest test-orca-send-text-wraps-in-bracketed-paste ()
  "Prompt text is delivered as one paste event.

`terminal send --text' writes straight to the pty, so a multi-line
prompt would submit at the first newline and the agent would answer half
a question.  The bracketed-paste wrapper is what makes a multi-line
prompt land whole in the input box."
  :tags '(:unit :fast :stable :orca)
  (let ((b (test-orca--backend)))
    (cl-letf (((symbol-function 'code-agent-orca--ensure-insert-mode) #'ignore))
      (test-orca--with-cli "{\"ok\":true,\"result\":{}}"
        (code-agent-mux-send-text b "line one\nline two")
        (let ((sent (test-orca--arg-after "--text")))
          (should (string-prefix-p "\033[200~" sent))
          (should (string-suffix-p "\033[201~" sent))
          (should (string-match-p "line one\nline two" sent)))))))

(ert-deftest test-orca-send-text-does-not-submit ()
  "Typing and submitting stay separate operations.

Callers pair `send-text' with `send-key :enter'; folding the newline in
would make it impossible to stage a prompt without running it."
  :tags '(:unit :fast :stable :orca)
  (let ((b (test-orca--backend)))
    (cl-letf (((symbol-function 'code-agent-orca--ensure-insert-mode) #'ignore))
      (test-orca--with-cli "{\"ok\":true,\"result\":{}}"
        (code-agent-mux-send-text b "hello")
        (should (= 1 (length test-orca--calls)))
        (should-not (member "--enter" (car test-orca--calls)))))))

;;; ------------------------------------------------------------------
;;; Screen classification
;;; ------------------------------------------------------------------

(ert-deftest test-orca-busy-wins-over-ready ()
  "A screen showing both markers is busy.

Claude Code renders its input box and its spinner at the same time, so
the ready pattern is present for the entire duration of a turn.  Testing
ready first would report every running session as idle."
  :tags '(:unit :fast :stable :orca)
  (let ((b (test-orca--backend)))
    (cl-letf (((symbol-function 'code-agent-mux-capture-screen)
               (lambda (_b) "-- INSERT --\n· Deliberating… (esc to interrupt)")))
      (should (eq :busy (code-agent-mux-session-status b))))))

(ert-deftest test-orca-idle-prompt-is-ready ()
  "An input box with no spinner is ready."
  :tags '(:unit :fast :stable :orca)
  (let ((b (test-orca--backend)))
    (cl-letf (((symbol-function 'code-agent-mux-capture-screen)
               (lambda (_b) "❯\n-- INSERT -- bypass permissions on")))
      (should (eq :ready (code-agent-mux-session-status b))))))

(ert-deftest test-orca-no-handle-is-missing ()
  "A backend with no terminal reports `:missing', never `:ready'."
  :tags '(:unit :fast :stable :orca)
  (let ((b (code-agent-orca-backend-create :session-key "test::fixture")))
    (should (eq :missing (code-agent-mux-session-status b)))))

;;; ------------------------------------------------------------------
;;; Identity
;;; ------------------------------------------------------------------

(ert-deftest test-orca-adopt-identity-reads-cached-handle ()
  "Identity comes from the status-dir cache, never from an org property.

A handle is meaningless once Orca restarts, so it must not travel in a
committed org file; the worktree is not adopted at all because it
re-resolves from the project root.  Adoption therefore reads exactly
one thing: the cache file keyed by CLAUDE_SESSION_ID."
  :tags '(:unit :fast :stable :orca)
  (let* ((dir (make-temp-file "orca-status-" t))
         (code-agent-org-terminal-status-dir dir)
         (b (code-agent-orca-backend-create :session-key "test::fixture")))
    (unwind-protect
        (cl-letf (((symbol-function 'org-entry-get)
                   (lambda (_pom prop &rest _)
                     (pcase prop
                       ("CLAUDE_SESSION_ID" "sdd-fixture")
                       ;; A leftover property from before the cache must
                       ;; not be resurrected.
                       ("ORCA_TERMINAL" "term_from_property")
                       (_ nil)))))
          (should-not (code-agent-org-backend-adopt-identity b))
          (code-agent-orca--save-handle "sdd-fixture" "term_abc")
          (should (equal "term_abc" (code-agent-org-backend-adopt-identity b)))
          (should (equal "term_abc" (code-agent-multiplexer-backend-pane-id b)))
          (should-not (code-agent-multiplexer-backend-multiplexer-session-id b))
          (code-agent-orca--forget-handle "sdd-fixture")
          (should-not (code-agent-orca--read-handle "sdd-fixture")))
      (delete-directory dir t))))

(ert-deftest test-orca-unregistered-directory-names-the-fix ()
  "`selector_not_found' becomes an instruction, not a raw error code.

Orca hosts terminals only inside repos it has registered, and the CLI
has no `repo rm', so the backend refuses rather than registering on the
user's behalf.  The message has to carry the exact command."
  :tags '(:unit :fast :stable :orca)
  (let ((b (code-agent-orca-backend-create :session-key "test::fixture")))
    (cl-letf (((symbol-function 'code-agent-orca--git-top-level)
               (lambda (_dir) "/tmp/not-registered")))
      (test-orca--with-cli "{\"ok\":false,\"error\":{\"code\":\"selector_not_found\"}}"
        (let ((err (should-error (code-agent-orca--resolve-worktree b "/tmp/not-registered")
                                 :type 'user-error)))
          (should (string-match-p "orca repo add --path /tmp/not-registered"
                                  (error-message-string err))))))))

;;; ------------------------------------------------------------------
;;; Capabilities
;;; ------------------------------------------------------------------

(ert-deftest test-orca-declares-no-verbose-follower ()
  "Orca reports no verbose follower.

The CLI has no streaming read, and under a full-screen TUI the cursor
stream never advances — a follower would poll forever and collect
nothing.  Orca's own pane is the live view."
  :tags '(:unit :fast :stable :orca)
  (let ((b (test-orca--backend)))
    (should-not (code-agent-backend-supports-p b :verbose-follower))
    (should-not (code-agent-backend-supports-p b :sidebar-feedback))
    (should (code-agent-backend-supports-p b :interactive-input))))

(provide 'test-orca-backend)
;;; test-orca-backend.el ends here
