;;; test-cmux-env-injection.el --- ENV_FILE + ANTHROPIC_* injection for cmux backend  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Regression coverage for the gap where `:CLAUDE_BACKEND: cmux' silently
;; dropped #+PROPERTY: ENV_FILE / ANTHROPIC_*  org properties that
;; agent-family (json-stream) backends honour via `:env' subprocess
;; injection.  See `code-agent-org-cmux--build-env-prefix' for the prose
;; rationale; the tests below pin the contract:
;;
;; 1. No properties + no ENV_FILE → empty prefix (zero behaviour change).
;; 2. ENV_FILE only → `set -a; . FILE; set +a; '.
;; 3. ANTHROPIC_* properties only → inline `VAR=VAL ' pairs.
;; 4. Both → sourced file first, inline overrides second (json-stream
;;    layering: explicit org property beats file value).
;; 5. End-to-end via `--build-launch-command' → real launcher string is
;;    prefixed unchanged when nothing is set, prefixed correctly otherwise.
;;
;; All tests use file-backed buffers (not `with-temp-buffer') because the
;; org property lookup chain reads file-level `#+PROPERTY:' lines, which
;; require a real buffer associated with a real file.  No cmux or claude
;; subprocesses are touched — these are pure string-shape assertions on
;; `--build-env-prefix' and a controlled stub of the agent-profile
;; launch-fn for the `--build-launch-command' wrapper test.

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
    (dolist (mod '("claude-agent-trace.org"
                   "claude-agent.org"
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

;; --- env-prefix helper: 4 contract cases -------------------------------

(ert-deftest test-cmux-env-prefix/empty-when-nothing-set ()
  "No ENV_FILE, no ANTHROPIC_* → empty string (zero behaviour change)."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-org-file
      "#+TITLE: empty\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
    (goto-char (point-max))
    (should (equal "" (code-agent-org-cmux--build-env-prefix)))))

(ert-deftest test-cmux-env-prefix/anthropic-props-only ()
  "ANTHROPIC_* org properties → inline `VAR=VAL ' shell exports."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-org-file
      (concat
       "#+TITLE: t\n"
       "#+PROPERTY: ANTHROPIC_MODEL mimo-v2.5-pro\n"
       "#+PROPERTY: ANTHROPIC_BASE_URL https://example.test\n"
       "* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n")
    (goto-char (point-max))
    (let ((prefix (code-agent-org-cmux--build-env-prefix)))
      ;; Inline assignments present.  Values are passed through
      ;; `shell-quote-argument' which on macOS/zsh may add backslash escapes
      ;; around `:' and other tokens; we assert variable name + identifiable
      ;; value substring rather than the literal value to stay quote-agnostic.
      (should (string-match-p "ANTHROPIC_MODEL=mimo-v2" prefix))
      (should (string-match-p "ANTHROPIC_BASE_URL=https" prefix))
      (should (string-match-p "example\\.test" prefix))
      ;; No file-sourcing block when ENV_FILE absent.
      (should-not (string-match-p "set -a" prefix)))))

(ert-deftest test-cmux-env-prefix/env-file-only ()
  "ENV_FILE → `set -a; . FILE; set +a; ' source block, nothing inline."
  :tags '(:cmux-env-injection :fast)
  (let ((env-file (make-temp-file "test-cmux-env-source-" nil ".env")))
    (unwind-protect
        (progn
          (with-temp-file env-file (insert "FOO=bar\n"))
          (test-cmux-env--with-org-file
              (format
               "#+TITLE: t\n#+PROPERTY: ENV_FILE %s\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
               env-file)
            (goto-char (point-max))
            (let ((prefix (code-agent-org-cmux--build-env-prefix)))
              ;; Source block syntax: `set -a; . <quoted-path>; set +a; '.
              ;; The path is shell-quoted so there is no space between path
              ;; and trailing `;'.
              (should (string-match-p "set -a; \\. " prefix))
              (should (string-match-p "; set \\+a; " prefix))
              (should (string-match-p (regexp-quote env-file) prefix))
              ;; No org-property-derived inline assignments here.
              (should-not (string-match-p "ANTHROPIC_" prefix)))))
      (delete-file env-file))))

(ert-deftest test-cmux-env-prefix/file-and-properties-layered ()
  "ENV_FILE comes first, then inline ANTHROPIC_* — inline wins per shell semantics."
  :tags '(:cmux-env-injection :fast)
  (let ((env-file (make-temp-file "test-cmux-env-source-" nil ".env")))
    (unwind-protect
        (progn
          (with-temp-file env-file (insert "ANTHROPIC_AUTH_TOKEN=tok-from-file\n"))
          (test-cmux-env--with-org-file
              (format
               (concat
                "#+TITLE: t\n"
                "#+PROPERTY: ENV_FILE %s\n"
                "#+PROPERTY: ANTHROPIC_MODEL claude-haiku\n"
                "* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n")
               env-file)
            (goto-char (point-max))
            (let* ((prefix (code-agent-org-cmux--build-env-prefix))
                   (file-idx (and (string-match "set -a; \\. " prefix)
                                  (match-beginning 0)))
                   (var-idx  (and (string-match "ANTHROPIC_MODEL=claude-haiku" prefix)
                                  (match-beginning 0))))
              (should file-idx)
              (should var-idx)
              ;; Layering invariant: file-source precedes inline VAR=VAL so the
              ;; latter overrides the former at exec time.
              (should (< file-idx var-idx)))))
      (delete-file env-file))))

;; --- end-to-end through --build-launch-command -------------------------

(ert-deftest test-cmux-env-prefix/build-launch-command-prepends-prefix ()
  "`--build-launch-command' returns prefix + bare launcher when env present.

We stub the agent profile so the test doesn't depend on `uv' / paths /
cmux being installed — the assertion is purely about string composition."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-org-file
      (concat
       "#+TITLE: t\n"
       "#+PROPERTY: ANTHROPIC_MODEL test-model\n"
       "* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n")
    (goto-char (point-max))
    (cl-letf (((symbol-function 'code-agent-org-cmux--get-agent-profile)
               (lambda () nil))
              ((symbol-function 'code-agent-org-cmux--build-claude-legacy-launch-command)
               (lambda (_o _s _p) "STUB_LAUNCHER")))
      (let ((cmd (code-agent-org-cmux--build-launch-command
                  "/tmp/fake.org" "sdd-fake" "/tmp")))
        (should (string-match-p "ANTHROPIC_MODEL=test-model " cmd))
        (should (string-suffix-p "STUB_LAUNCHER" cmd))
        ;; Prefix must come BEFORE the launcher — otherwise the shell would
        ;; treat VAR=VAL as args to STUB_LAUNCHER instead of exports.
        (let ((var-idx (string-match "ANTHROPIC_MODEL=test-model" cmd))
              (stub-idx (string-match "STUB_LAUNCHER" cmd)))
          (should (< var-idx stub-idx)))))))

(ert-deftest test-cmux-env-prefix/build-launch-command-no-env-is-pass-through ()
  "When org has no ENV_FILE and no ANTHROPIC_* properties,
`--build-launch-command' returns the bare launcher unchanged."
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
        (should (equal "STUB_LAUNCHER" cmd))))))

;; --- ANTHROPIC_MODEL → --model CLI fallback --------------------------

(ert-deftest test-cmux-env-model/empty-when-property-unset ()
  "No ANTHROPIC_MODEL property → no auto --model args."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-org-file
      "#+TITLE: t\n* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n"
    (goto-char (point-max))
    (should-not (code-agent-org-cmux--anthropic-model-fallback-args nil))))

(ert-deftest test-cmux-env-model/inject-when-property-set ()
  "ANTHROPIC_MODEL property → (\"--model\" VALUE) list."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-org-file
      (concat
       "#+TITLE: t\n"
       "#+PROPERTY: ANTHROPIC_MODEL mimo-v2.5-pro\n"
       "* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n")
    (goto-char (point-max))
    (should (equal '("--model" "mimo-v2.5-pro")
                   (code-agent-org-cmux--anthropic-model-fallback-args nil)))))

(ert-deftest test-cmux-env-model/skip-when-user-passes-model ()
  "User's CLAUDE_EXTRA_ARGS already contains `--model' → skip auto-injection.
Avoids `--model A --model B' duplicate that some parsers handle inconsistently."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-org-file
      (concat
       "#+TITLE: t\n"
       "#+PROPERTY: ANTHROPIC_MODEL property-derived\n"
       "* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n")
    (goto-char (point-max))
    ;; space-separated form: ("--model" "user-value")
    (should-not (code-agent-org-cmux--anthropic-model-fallback-args
                 '("--dangerously-skip-permissions" "--model" "user-value")))
    ;; `--model=value' form: single token starting with --model=
    (should-not (code-agent-org-cmux--anthropic-model-fallback-args
                 '("--model=user-value")))))

(ert-deftest test-cmux-env-model/legacy-builder-includes-model-flag ()
  "End-to-end: --build-claude-legacy-launch-command produces a launcher
string that includes `--model VALUE' when ANTHROPIC_MODEL is set and
the user has not already specified --model."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-org-file
      (concat
       "#+TITLE: t\n"
       "#+PROPERTY: ANTHROPIC_MODEL test-marker-model\n"
       "* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n")
    (goto-char (point-max))
    (let ((code-agent-org-cmux-launch-command 'claude-workspace)
          (code-agent-org-cmux-workspace-script "STUB_LAUNCHER")
          (code-agent-org-cmux-extra-args nil))
      (cl-letf (((symbol-function 'code-agent-org-terminal--find-session-property)
                 (lambda (_p) nil))
                ((symbol-function 'code-agent-org-terminal--goto-session-heading)
                 (lambda () nil)))
        (let ((cmd (code-agent-org-cmux--build-claude-legacy-launch-command
                    "/tmp/fake.org" "sdd-fake" "/tmp")))
          (should (string-match-p "--model" cmd))
          (should (string-match-p "test-marker-model" cmd)))))))

(ert-deftest test-cmux-env-model/full-pipeline-prepends-env-and-appends-model ()
  "Full path through --build-launch-command:
- env prefix at start (ANTHROPIC_MODEL=… for runtime env)
- launcher + extras including --model VALUE at end (CLI override)
Both channels active for belt-and-suspenders against settings.json model pin."
  :tags '(:cmux-env-injection :fast)
  (test-cmux-env--with-org-file
      (concat
       "#+TITLE: t\n"
       "#+PROPERTY: ANTHROPIC_MODEL pipeline-model\n"
       "* Story\n:PROPERTIES:\n:CLAUDE_BACKEND: cmux\n:END:\n")
    (goto-char (point-max))
    (cl-letf (((symbol-function 'code-agent-org-cmux--get-agent-profile)
               (lambda () nil))
              ((symbol-function 'code-agent-org-cmux--build-claude-legacy-launch-command)
               (lambda (_o _s _p) "STUB_LAUNCHER --model pipeline-model")))
      (let ((cmd (code-agent-org-cmux--build-launch-command
                  "/tmp/fake.org" "sdd-fake" "/tmp")))
        ;; env prefix asserts the runtime channel
        (should (string-match-p "ANTHROPIC_MODEL=pipeline-model" cmd))
        ;; --model on stub launcher asserts the CLI channel
        (should (string-match-p "STUB_LAUNCHER --model pipeline-model$" cmd))))))

(provide 'test-cmux-env-injection)
;;; test-cmux-env-injection.el ends here
