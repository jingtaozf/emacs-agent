;;; test-cmux-env-injection.el --- ENV_FILE injection + CLI flag surfacing for cmux backend  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Regression coverage for the env-injection contract on the cmux backend
;; after the ENV_FILE-only refactor.  The single source of truth is
;; `#+PROPERTY: ENV_FILE'; per-name org properties (e.g. `:ANTHROPIC_MODEL:'
;; on a section) are no longer read.  Two CLI flags must still be surfaced
;; on the launcher extras to beat ~/.claude/settings.json:
;;   ANTHROPIC_MODEL         → --model VALUE
;;   CLAUDE_CODE_EFFORT_LEVEL → --effort VALUE
;; See `code-agent-org--env-cli-flag-map'.
;;
;; Tests pinned:
;;
;; 1. No ENV_FILE → empty prefix (zero behaviour change).
;; 2. ENV_FILE only → `set -a; . FILE; set +a; ' source block, nothing inline.
;; 3. Per-name org property without ENV_FILE → empty prefix (legacy path gone).
;; 4. End-to-end via `--build-launch-command' → prefix prepended unchanged
;;    when ENV_FILE present, bare launcher otherwise.
;; 5. ENV_FILE-derived ANTHROPIC_MODEL / CLAUDE_CODE_EFFORT_LEVEL surfaced as
;;    --model / --effort CLI flags; author intent (user-extra-args) wins.
;;
;; All tests use file-backed buffers (not `with-temp-buffer') because the
;; org property lookup chain reads file-level `#+PROPERTY:' lines, which
;; require a real buffer associated with a real file.  No cmux or claude
;; subprocesses are touched — these are pure string-shape assertions on
;; `--build-env-prefix' / `--env-cli-fallback-args' and a controlled stub
;; of the agent-profile launch-fn for the `--build-launch-command' wrapper
;; test.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Production code is loaded by the Makefile harness via $(LOAD_ALL).  When
;; the test is invoked standalone (e.g. `emacs -l ...'), self-load so the
;; same file runs identically in both contexts.
(unless (fboundp 'code-agent-org-cmux--build-env-prefix)
  (let* ((tests-dir (file-name-directory (or load-file-name buffer-file-name)))
         (repo (file-name-directory (directory-file-name tests-dir))))
    (add-to-list 'load-path (expand-file-name "../literate-elisp" repo))
    (require 'literate-elisp)
    (dolist (mod '("code-agent-trace.org"
                   "code-agent.org"
                   "code-agent-org.org"
                   "code-agent-org-terminal-base.org"
                   "code-agent-org-cmux.org"))
      (literate-elisp-load (expand-file-name mod repo)))))

(defmacro test-cmux-env--with-org-file (content &rest body-forms)
  "Run BODY-FORMS in a file-backed org buffer initialised with CONTENT.
Cleans up the temp file afterwards.  Tests need a file-backed buffer
because file-level `#+PROPERTY:' inheritance is resolved through
`org-collect-keywords' which reads from the underlying file."
  (declare (indent 1) (debug t))
  (let ((path (gensym "path-"))
        (buf  (gensym "buf-")))
    `(let* ((,path (make-temp-file "test-cmux-env-" nil ".org"))
            (,buf nil))
       (unwind-protect
           (progn
             (with-temp-file ,path (insert ,content))
             (setq ,buf (find-file-noselect ,path))
             (with-current-buffer ,buf
               ,@body-forms))
         (when (and ,buf (buffer-live-p ,buf))
           (kill-buffer ,buf))
         (delete-file ,path)))))

(defmacro test-cmux-env--with-env-file (env-content &rest body-forms)
  "Create a tmp .env file with ENV-CONTENT bound to `env-file' in BODY-FORMS."
  (declare (indent 1) (debug t))
  `(let ((env-file (make-temp-file "test-cmux-env-source-" nil ".env")))
     (unwind-protect
         (progn
           (with-temp-file env-file (insert ,env-content))
           ,@body-forms)
       (delete-file env-file))))

;; --- env-prefix helper -------------------------------------------------

(ert-deftest test-cmux-env-prefix/empty-when-nothing-set ()
  "No ENV_FILE → just the always-on `unset VIRTUAL_ENV;' guard.

Post-2026-05-26 (the ``claude-agent`` → ``emacs-agent`` rename
incident), the prefix unconditionally clears ``VIRTUAL_ENV`` so a
stale value inherited from cmux's process ancestry can't make `uv
run' emit its mismatched-venv warning.  No ENV_FILE means no file
sourcing, but the guard remains."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-org-file
      "#+TITLE: empty\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
    (goto-char (point-max))
    (should (equal "unset VIRTUAL_ENV; "
                   (code-agent-org-cmux--build-env-prefix)))))

(ert-deftest test-cmux-env-prefix/per-name-property-is-ignored ()
  "`#+PROPERTY: ANTHROPIC_MODEL …' alone (no ENV_FILE) → unset-only prefix.

After the ENV_FILE-only refactor, per-name org properties are not read.
Asserts the legacy inline VAR=VAL emission path is gone.  Only the
always-on `unset VIRTUAL_ENV;' guard remains (see sibling test)."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-org-file
      (concat
       "#+TITLE: t\n"
       "#+PROPERTY: ANTHROPIC_MODEL mimo-v2.5-pro\n"
       "#+PROPERTY: ANTHROPIC_BASE_URL https://example.test\n"
       "* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n")
    (goto-char (point-max))
    (let ((prefix (code-agent-org-cmux--build-env-prefix)))
      (should (equal "unset VIRTUAL_ENV; " prefix)))))

(ert-deftest test-cmux-env-prefix/env-file-only ()
  "ENV_FILE → `set -a; . FILE; set +a; ' source block."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-env-file "FOO=bar\n"
    (test-cmux-env--with-org-file
        (format
         "#+TITLE: t\n#+PROPERTY: ENV_FILE %s\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
         env-file)
      (goto-char (point-max))
      (let ((prefix (code-agent-org-cmux--build-env-prefix)))
        (should (string-match-p "set -a; \\. " prefix))
        (should (string-match-p "; set \\+a; " prefix))
        (should (string-match-p (regexp-quote env-file) prefix))
        ;; No inline VAR=VAL pairs — that path was removed.
        (should-not (string-match-p "ANTHROPIC_" prefix))
        (should-not (string-match-p "CLAUDE_CODE_" prefix))))))

(ert-deftest test-cmux-env-prefix/env-file-plus-property-still-only-sources-file ()
  "Even when both ENV_FILE and per-name `#+PROPERTY:' are set, only the file
is sourced — per-name properties are ignored after the refactor."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-env-file "ANTHROPIC_AUTH_TOKEN=tok-from-file\n"
    (test-cmux-env--with-org-file
        (format
         (concat
          "#+TITLE: t\n"
          "#+PROPERTY: ENV_FILE %s\n"
          "#+PROPERTY: ANTHROPIC_MODEL claude-haiku\n"
          "* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n")
         env-file)
      (goto-char (point-max))
      (let ((prefix (code-agent-org-cmux--build-env-prefix)))
        (should (string-match-p "set -a; \\. " prefix))
        ;; ANTHROPIC_MODEL inline emission no longer occurs.
        (should-not (string-match-p "ANTHROPIC_MODEL=" prefix))))))

;; --- end-to-end through --build-launch-command -------------------------

(ert-deftest test-cmux-env-prefix/build-launch-command-prepends-prefix ()
  "`--build-launch-command' returns prefix + bare launcher when ENV_FILE
present; the file-sourcing block comes before the launcher."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-env-file "ANTHROPIC_MODEL=test-model\n"
    (test-cmux-env--with-org-file
        (format
         "#+TITLE: t\n#+PROPERTY: ENV_FILE %s\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
         env-file)
      (goto-char (point-max))
      (cl-letf (((symbol-function 'code-agent-org-cmux--get-agent-profile)
                 (lambda () nil))
                ((symbol-function 'code-agent-org-cmux--build-claude-legacy-launch-command)
                 (lambda (_o _s _p) "STUB_LAUNCHER")))
        (let ((cmd (code-agent-org-cmux--build-launch-command
                    "/tmp/fake.org" "sdd-fake" "/tmp")))
          (should (string-match-p "set -a; \\. " cmd))
          (should (string-suffix-p "STUB_LAUNCHER" cmd))
          (let ((src-idx (string-match "set -a; \\. " cmd))
                (stub-idx (string-match "STUB_LAUNCHER" cmd)))
            (should (< src-idx stub-idx))))))))

(ert-deftest test-cmux-env-prefix/build-launch-command-no-env-is-pass-through ()
  "When org has no ENV_FILE, `--build-launch-command' returns the bare
launcher prefixed only by the always-on `unset VIRTUAL_ENV;' guard
(post-2026-05-26 rename-incident change — see sibling
`empty-when-nothing-set' for the motivation)."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-org-file
      "#+TITLE: t\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
    (goto-char (point-max))
    (cl-letf (((symbol-function 'code-agent-org-cmux--get-agent-profile)
               (lambda () nil))
              ((symbol-function 'code-agent-org-cmux--build-claude-legacy-launch-command)
               (lambda (_o _s _p) "STUB_LAUNCHER")))
      (let ((cmd (code-agent-org-cmux--build-launch-command
                  "/tmp/fake.org" "sdd-fake" "/tmp")))
        (should (equal "unset VIRTUAL_ENV; STUB_LAUNCHER" cmd))))))

;; --- ENV_FILE → CLI flag surfacing --------------------------------------

(ert-deftest test-cmux-env-cli/empty-when-no-env-file ()
  "No ENV_FILE → no auto CLI flags."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-org-file
      "#+TITLE: t\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
    (goto-char (point-max))
    (should-not (code-agent-org-cmux--env-cli-fallback-args nil))))

(ert-deftest test-cmux-env-cli/empty-when-mapped-keys-absent ()
  "ENV_FILE present but no mapped keys → no auto CLI flags."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-env-file "FOO=bar\n"
    (test-cmux-env--with-org-file
        (format
         "#+TITLE: t\n#+PROPERTY: ENV_FILE %s\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
         env-file)
      (goto-char (point-max))
      (should-not (code-agent-org-cmux--env-cli-fallback-args nil)))))

(ert-deftest test-cmux-env-cli/model-from-env-file ()
  "ENV_FILE `ANTHROPIC_MODEL=…' → (\"--model\" VALUE) list."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-env-file "ANTHROPIC_MODEL=mimo-v2.5-pro\n"
    (test-cmux-env--with-org-file
        (format
         "#+TITLE: t\n#+PROPERTY: ENV_FILE %s\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
         env-file)
      (goto-char (point-max))
      (should (equal '("--model" "mimo-v2.5-pro")
                     (code-agent-org-cmux--env-cli-fallback-args nil))))))

(ert-deftest test-cmux-env-cli/effort-from-env-file ()
  "ENV_FILE `CLAUDE_CODE_EFFORT_LEVEL=…' → (\"--effort\" VALUE) list."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-env-file "CLAUDE_CODE_EFFORT_LEVEL=high\n"
    (test-cmux-env--with-org-file
        (format
         "#+TITLE: t\n#+PROPERTY: ENV_FILE %s\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
         env-file)
      (goto-char (point-max))
      (should (equal '("--effort" "high")
                     (code-agent-org-cmux--env-cli-fallback-args nil))))))

(ert-deftest test-cmux-env-cli/model-and-effort-together ()
  "Both mapped keys → both CLI flags emitted in map order."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-env-file
      "ANTHROPIC_MODEL=mimo\nCLAUDE_CODE_EFFORT_LEVEL=medium\n"
    (test-cmux-env--with-org-file
        (format
         "#+TITLE: t\n#+PROPERTY: ENV_FILE %s\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
         env-file)
      (goto-char (point-max))
      (should (equal '("--model" "mimo" "--effort" "medium")
                     (code-agent-org-cmux--env-cli-fallback-args nil))))))

(ert-deftest test-cmux-env-cli/skip-when-user-passes-model ()
  "User's CLAUDE_EXTRA_ARGS already contains `--model' → skip auto-injection
for `--model' but still emit `--effort' if mapped."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-env-file
      "ANTHROPIC_MODEL=ignored\nCLAUDE_CODE_EFFORT_LEVEL=low\n"
    (test-cmux-env--with-org-file
        (format
         "#+TITLE: t\n#+PROPERTY: ENV_FILE %s\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
         env-file)
      (goto-char (point-max))
      ;; --model A passed by user → skip --model from env, keep --effort
      (should (equal '("--effort" "low")
                     (code-agent-org-cmux--env-cli-fallback-args
                      '("--dangerously-skip-permissions"
                        "--model" "user-value"))))
      ;; --model=VALUE form is also recognised
      (should (equal '("--effort" "low")
                     (code-agent-org-cmux--env-cli-fallback-args
                      '("--model=user-value")))))))

(ert-deftest test-cmux-env-cli/skip-when-user-passes-effort ()
  "User's CLAUDE_EXTRA_ARGS already contains `--effort' → skip --effort
auto-injection but still emit --model if mapped."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-env-file
      "ANTHROPIC_MODEL=mimo\nCLAUDE_CODE_EFFORT_LEVEL=ignored\n"
    (test-cmux-env--with-org-file
        (format
         "#+TITLE: t\n#+PROPERTY: ENV_FILE %s\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
         env-file)
      (goto-char (point-max))
      (should (equal '("--model" "mimo")
                     (code-agent-org-cmux--env-cli-fallback-args
                      '("--effort" "user-value")))))))

(ert-deftest test-cmux-env-cli/legacy-builder-includes-model-and-effort ()
  "End-to-end: `--build-claude-legacy-launch-command' produces a launcher
string with `--model VALUE' and `--effort VALUE' from ENV_FILE."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-env-file
      "ANTHROPIC_MODEL=test-marker-model\nCLAUDE_CODE_EFFORT_LEVEL=xhigh\n"
    (test-cmux-env--with-org-file
        (format
         "#+TITLE: t\n#+PROPERTY: ENV_FILE %s\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
         env-file)
      (goto-char (point-max))
      (let ((code-agent-org-cmux-launch-command 'claude-workspace)
            (code-agent-org-cmux-workspace-script "STUB_LAUNCHER")
            (code-agent-org-cmux-extra-args nil))
        (cl-letf (((symbol-function 'code-agent-org-terminal-find-session-property)
                   (lambda (_p) nil))
                  ((symbol-function 'code-agent-org-terminal-goto-session-heading)
                   (lambda () nil)))
          (let ((cmd (code-agent-org-cmux--build-claude-legacy-launch-command
                      "/tmp/fake.org" "sdd-fake" "/tmp")))
            (should (string-match-p "--model" cmd))
            (should (string-match-p "test-marker-model" cmd))
            (should (string-match-p "--effort" cmd))
            (should (string-match-p "xhigh" cmd))))))))

(ert-deftest test-cmux-env-cli/full-pipeline-prepends-source-and-appends-flags ()
  "Full path through `--build-launch-command':
- env prefix at start (set -a; . FILE; set +a;)
- launcher + extras at end including --model and --effort CLI flags.
Both channels active for belt-and-suspenders against settings.json pins."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-env-file
      "ANTHROPIC_MODEL=pipeline-model\nCLAUDE_CODE_EFFORT_LEVEL=high\n"
    (test-cmux-env--with-org-file
        (format
         "#+TITLE: t\n#+PROPERTY: ENV_FILE %s\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
         env-file)
      (goto-char (point-max))
      (cl-letf (((symbol-function 'code-agent-org-cmux--get-agent-profile)
                 (lambda () nil))
                ((symbol-function 'code-agent-org-cmux--build-claude-legacy-launch-command)
                 (lambda (_o _s _p)
                   "STUB_LAUNCHER --model pipeline-model --effort high")))
        (let ((cmd (code-agent-org-cmux--build-launch-command
                    "/tmp/fake.org" "sdd-fake" "/tmp")))
          ;; env prefix asserts the runtime channel
          (should (string-match-p "set -a; \\. " cmd))
          (should (string-match-p (regexp-quote env-file) cmd))
          ;; CLI flags on stub launcher assert the CLI channel
          (should (string-match-p "--model pipeline-model" cmd))
          (should (string-match-p "--effort high" cmd)))))))

(provide 'test-cmux-env-injection)
;;; test-cmux-env-injection.el ends here
