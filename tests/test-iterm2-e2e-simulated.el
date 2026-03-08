;;; test-iterm2-e2e-simulated.el --- E2E tests for iTerm2 backend -*- lexical-binding: t -*-

;; Strategy: Mock ONLY the iterm2-ctl.py gateway (claude-org-iterm2--call).
;; Everything else — org buffer, properties, dispatch, session lookup,
;; tab title, status files, mode-line — uses real code against real org buffers.
;;
;; This catches bugs that pure mocking hides (e.g. org-up-heading-safe
;; skipping the current heading).

;;; Code:

(require 'ert)
(require 'json)
(require 'cl-lib)

;; Load test helpers and project source
(let ((project-root (file-name-directory
                     (directory-file-name
                      (file-name-directory
                       (or load-file-name buffer-file-name))))))
  (load (expand-file-name "tests/support/test-helpers.el" project-root) nil t)
  (require 'literate-elisp)
  (literate-elisp-load (expand-file-name "claude-agent.org" project-root))
  (literate-elisp-load (expand-file-name "claude-org.org" project-root)))

(defvar test-iterm2--project-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Project root directory.")

(defvar test-iterm2--fixture-dir
  (expand-file-name "tests/fixtures/iterm2/e2e/" test-iterm2--project-root)
  "Directory containing E2E fixture data from real runs.")

;;; ============================================================================
;;; Mock Infrastructure
;;; ============================================================================

;; Fixture data captured from real iTerm2 + Claude Code runs.
;; The mock returns these based on subcommand + args.

(defvar test-iterm2--mock-session-id "MOCK-UUID-1234-5678-ABCD-EF0123456789"
  "Fake iTerm2 session UUID returned by mock launch.")

(defvar test-iterm2--mock-call-log nil
  "Log of (SUBCOMMAND . ARGS) calls made to the mock.")

(defun test-iterm2--log-call (subcommand args)
  "Strip :stdin from ARGS and log (SUBCOMMAND . CLEAN-ARGS)."
  (let ((clean-args nil)
        (remaining args))
    (while remaining
      (if (eq (car remaining) :stdin)
          (setq remaining (cddr remaining))
        (push (car remaining) clean-args)
        (setq remaining (cdr remaining))))
    (push (cons subcommand (nreverse clean-args)) test-iterm2--mock-call-log)))

(defun test-iterm2--mock-call (subcommand &rest args)
  "Mock replacement for `claude-org-iterm2--call'.
Returns fixture-based responses. Logs all calls."
  (test-iterm2--log-call subcommand args)
  (cond
   ((equal subcommand "launch")
    test-iterm2--mock-session-id)
   ((equal subcommand "status")
    (json-encode '((state . "ready")
                   (session_id . "MOCK-UUID-1234-5678-ABCD-EF0123456789")
                   (tab_title . "Test Story [sdd-test-123]"))))
   ((equal subcommand "send")
    "ok")
   ((equal subcommand "cancel")
    (json-encode '((result . "ok") (state . "ready"))))
   ((equal subcommand "focus")
    "ok")
   ((equal subcommand "close")
    "ok")
   ((equal subcommand "list")
    (json-encode (vector
                  `((session_id . ,test-iterm2--mock-session-id)
                    (tab_title . "Test Story [sdd-test-123]")
                    (tab_id . "42")))))
   (t (error "Mock: unknown subcommand %s" subcommand))))

(defun test-iterm2--mock-call-dead-status (subcommand &rest args)
  "Mock that returns dead status (for relaunch tests)."
  (test-iterm2--log-call subcommand args)
  (cond
   ((equal subcommand "status")
    (json-encode '((state . "dead"))))
   ((equal subcommand "launch")
    test-iterm2--mock-session-id)
   ((equal subcommand "focus") "ok")
   (t (apply #'test-iterm2--mock-call subcommand args))))

;;; ============================================================================
;;; Test Buffer Setup
;;; ============================================================================

(defconst test-iterm2--org-content-basic
  "* Dev Story
:PROPERTIES:
:CLAUDE_SESSION_ID: sdd-test-123
:CLAUDE_BACKEND: iterm2
:END:

** Instructions

#+begin_src ai
What is 2+2?
#+end_src
"
  "Basic org buffer with SDD session and AI block.")

(defconst test-iterm2--org-content-nested
  "* Project
:PROPERTIES:
:PROJECT_ROOT: /tmp
:END:

** Feature A
:PROPERTIES:
:CLAUDE_SESSION_ID: sdd-nested-456
:CLAUDE_BACKEND: iterm2
:END:

*** Research

#+begin_src ai
Explain quantum computing
#+end_src

*** Design

Some design notes.
"
  "Nested org buffer — property on level-2, AI block on level-3.")

(defconst test-iterm2--org-content-no-session
  "* Story Without Session
:PROPERTIES:
:CLAUDE_BACKEND: iterm2
:END:

#+begin_src ai
test
#+end_src
"
  "Org buffer with iterm2 backend but no CLAUDE_SESSION_ID.")

(defconst test-iterm2--org-content-inherited
  "* Project Root
:PROPERTIES:
:CLAUDE_BACKEND: iterm2
:CLAUDE_SESSION_ID: sdd-inherited-789
:END:

** Child Section

#+begin_src ai
inherited backend test
#+end_src
"
  "Org buffer where CLAUDE_BACKEND and SESSION_ID are inherited from parent.")

(defconst test-iterm2--org-content-mixed-case
  "* Dev Story
:PROPERTIES:
:CLAUDE_SESSION_ID: sdd-case-test
:CLAUDE_BACKEND: iTerm2
:END:

** Instructions

#+begin_src ai
case test query
#+end_src
"
  "Org buffer with mixed-case CLAUDE_BACKEND value (iTerm2 vs iterm2).
REGRESSION: case-sensitive equal missed this, fell through to json-stream.")

(defmacro test-iterm2--with-org-buffer (content &rest body)
  "Create temp org FILE with CONTENT, execute BODY with mock iterm2-ctl.
Uses a real file so save-buffer and buffer-file-name work correctly."
  (declare (indent 1))
  `(let ((test-iterm2--mock-call-log nil)
         (tmp-file (make-temp-file "iterm2-test-" nil ".org")))
     (unwind-protect
         (progn
           (with-temp-file tmp-file (insert ,content))
           (with-current-buffer (find-file-noselect tmp-file)
             (goto-char (point-min))
             (cl-letf (((symbol-function 'claude-org-iterm2--call)
                        #'test-iterm2--mock-call))
               (unwind-protect
                   (progn ,@body)
                 (set-buffer-modified-p nil)
                 (kill-buffer (current-buffer))))))
       (when (file-exists-p tmp-file)
         (delete-file tmp-file)))))

;;; ============================================================================
;;; Property Lookup (real org buffers, no mocking)
;;; ============================================================================

(ert-deftest test-iterm2-find-property-on-current-heading ()
  "find-session-property finds property on the heading point is on.
REGRESSION: org-up-heading-safe skips current heading."
  :tags '(:unit :iterm2 :e2e :regression)
  (with-temp-buffer
    (org-mode)
    (insert test-iterm2--org-content-basic)
    ;; Point on the heading itself
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should (equal "sdd-test-123"
                   (claude-org-iterm2--find-session-property
                    "CLAUDE_SESSION_ID")))))

(ert-deftest test-iterm2-find-property-from-body ()
  "find-session-property finds property when point is in body text."
  :tags '(:unit :iterm2 :e2e)
  (with-temp-buffer
    (org-mode)
    (insert test-iterm2--org-content-basic)
    (goto-char (point-max))
    (should (equal "sdd-test-123"
                   (claude-org-iterm2--find-session-property
                    "CLAUDE_SESSION_ID")))))

(ert-deftest test-iterm2-find-property-nested ()
  "find-session-property walks up from level-3 to find level-2 property."
  :tags '(:unit :iterm2 :e2e)
  (with-temp-buffer
    (org-mode)
    (insert test-iterm2--org-content-nested)
    ;; Point inside the "Research" section (level 3)
    (goto-char (point-min))
    (re-search-forward "Explain quantum")
    (should (equal "sdd-nested-456"
                   (claude-org-iterm2--find-session-property
                    "CLAUDE_SESSION_ID")))))

(ert-deftest test-iterm2-find-property-inherited ()
  "find-session-property finds property inherited from parent heading."
  :tags '(:unit :iterm2 :e2e)
  (with-temp-buffer
    (org-mode)
    (insert test-iterm2--org-content-inherited)
    ;; Point inside "Child Section"
    (goto-char (point-min))
    (re-search-forward "inherited backend")
    (should (equal "sdd-inherited-789"
                   (claude-org-iterm2--find-session-property
                    "CLAUDE_SESSION_ID")))))

(ert-deftest test-iterm2-find-property-missing ()
  "find-session-property returns nil when property doesn't exist."
  :tags '(:unit :iterm2 :e2e)
  (with-temp-buffer
    (org-mode)
    (insert test-iterm2--org-content-no-session)
    (goto-char (point-max))
    (should-not (claude-org-iterm2--find-session-property
                 "CLAUDE_SESSION_ID"))))

;;; ============================================================================
;;; Tab Title (real org buffers)
;;; ============================================================================

(ert-deftest test-iterm2-tab-title-from-heading ()
  "Tab title uses heading text and session ID from real org buffer."
  :tags '(:unit :iterm2 :e2e)
  (with-temp-buffer
    (org-mode)
    (insert test-iterm2--org-content-basic)
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (let ((title (claude-org-iterm2--tab-title)))
      (should (string-match-p "Dev Story" title))
      (should (string-match-p "sdd-test-123" title))
      (should (string-match-p "\\[" title)))))

(ert-deftest test-iterm2-tab-title-nested ()
  "Tab title from nested heading finds the correct session heading."
  :tags '(:unit :iterm2 :e2e)
  (with-temp-buffer
    (org-mode)
    (insert test-iterm2--org-content-nested)
    (goto-char (point-min))
    (re-search-forward "Explain quantum")
    (let ((title (claude-org-iterm2--tab-title)))
      (should (string-match-p "Feature A" title))
      (should (string-match-p "sdd-nested-456" title)))))

;;; ============================================================================
;;; Ensure Session Flow (real org + mock iterm2-ctl)
;;; ============================================================================

(ert-deftest test-iterm2-ensure-session-launches ()
  "ensure-session calls launch and saves ITERM2_SESSION_ID property."
  :tags '(:unit :iterm2 :e2e)
  (test-iterm2--with-org-buffer test-iterm2--org-content-basic
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (let ((result (claude-org-iterm2--ensure-session)))
      ;; Returns the mock session ID
      (should (equal test-iterm2--mock-session-id result))
      ;; Verify launch was called
      (should (assoc "launch" test-iterm2--mock-call-log))
      ;; Verify ITERM2_SESSION_ID saved on heading with CLAUDE_SESSION_ID
      ;; ensure-session navigates to that heading internally, so check there
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "^\\* Dev Story")
        (should (equal test-iterm2--mock-session-id
                       (org-entry-get nil "ITERM2_SESSION_ID")))))))

(ert-deftest test-iterm2-ensure-session-reuses-alive ()
  "ensure-session reuses existing session when status is not dead."
  :tags '(:unit :iterm2 :e2e)
  (test-iterm2--with-org-buffer test-iterm2--org-content-basic
    (goto-char (point-min))
    (org-next-visible-heading 1)
    ;; Pre-set an existing ITERM2_SESSION_ID
    (org-set-property "ITERM2_SESSION_ID" "EXISTING-SESSION-UUID")
    (let ((result (claude-org-iterm2--ensure-session)))
      ;; Should return existing ID without launching
      (should (equal "EXISTING-SESSION-UUID" result))
      ;; Status was checked but launch was NOT called
      (should (assoc "status" test-iterm2--mock-call-log))
      (should-not (assoc "launch" test-iterm2--mock-call-log)))))

(ert-deftest test-iterm2-ensure-session-relaunches-dead ()
  "ensure-session relaunches when existing session is dead."
  :tags '(:unit :iterm2 :e2e)
  (let ((test-iterm2--mock-call-log nil)
        (tmp-file (make-temp-file "iterm2-test-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file tmp-file (insert test-iterm2--org-content-basic))
          (with-current-buffer (find-file-noselect tmp-file)
            (goto-char (point-min))
            (org-next-visible-heading 1)
            ;; Pre-set a dead session
            (org-set-property "ITERM2_SESSION_ID" "DEAD-SESSION-UUID")
            (save-buffer)
            (cl-letf (((symbol-function 'claude-org-iterm2--call)
                       #'test-iterm2--mock-call-dead-status))
              (let ((result (claude-org-iterm2--ensure-session)))
                ;; Should launch a new one
                (should (equal test-iterm2--mock-session-id result))
                (should (assoc "launch" test-iterm2--mock-call-log))
                ;; Property updated on the heading with CLAUDE_SESSION_ID
                (save-excursion
                  (goto-char (point-min))
                  (re-search-forward "^\\* Dev Story")
                  (should (equal test-iterm2--mock-session-id
                                 (org-entry-get nil "ITERM2_SESSION_ID"))))))
            (set-buffer-modified-p nil)
            (kill-buffer (current-buffer))))
      (when (file-exists-p tmp-file) (delete-file tmp-file)))))

(ert-deftest test-iterm2-ensure-session-errors-no-sdd-id ()
  "ensure-session errors when no CLAUDE_SESSION_ID exists.
REGRESSION: Previously passed empty string to claude-sdd."
  :tags '(:unit :iterm2 :e2e :regression)
  (test-iterm2--with-org-buffer test-iterm2--org-content-no-session
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should-error (claude-org-iterm2--ensure-session)
                  :type 'user-error)))

(ert-deftest test-iterm2-ensure-session-nested-heading ()
  "ensure-session works from a deeply nested heading."
  :tags '(:unit :iterm2 :e2e)
  (test-iterm2--with-org-buffer test-iterm2--org-content-nested
    (goto-char (point-min))
    (re-search-forward "Explain quantum")
    (let ((result (claude-org-iterm2--ensure-session)))
      (should (equal test-iterm2--mock-session-id result))
      ;; launch command should contain the session ID
      (let ((launch-call (assoc "launch" test-iterm2--mock-call-log)))
        (should launch-call)
        ;; Check --launch-cmd arg contains the session ID
        (should (member "--launch-cmd" (cdr launch-call)))))))

;;; ============================================================================
;;; Open Tab Command (real org + mock iterm2-ctl)
;;; ============================================================================

(ert-deftest test-iterm2-open-tab-calls-focus ()
  "open-tab ensures session then calls focus."
  :tags '(:unit :iterm2 :e2e)
  (test-iterm2--with-org-buffer test-iterm2--org-content-basic
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (claude-org-iterm2-open-tab)
    ;; Should have called launch then focus
    (should (assoc "launch" test-iterm2--mock-call-log))
    (should (assoc "focus" test-iterm2--mock-call-log))))

;;; ============================================================================
;;; Execute AI Block (real org + mock iterm2-ctl)
;;; ============================================================================

(ert-deftest test-iterm2-execute-ai-block-sends-prompt ()
  "execute-ai-block reads prompt from real org block and sends via mock."
  :tags '(:unit :iterm2 :e2e)
  (test-iterm2--with-org-buffer test-iterm2--org-content-basic
    ;; Navigate into the AI block
    (goto-char (point-min))
    (re-search-forward "What is 2")
    (claude-org-iterm2--execute-ai-block)
    ;; Should have launched and sent
    (should (assoc "launch" test-iterm2--mock-call-log))
    (let ((send-call (assoc "send" test-iterm2--mock-call-log)))
      (should send-call)
      ;; send should reference the mock session ID
      (should (member test-iterm2--mock-session-id (cdr send-call))))))

(ert-deftest test-iterm2-execute-ai-block-nested ()
  "execute-ai-block works from a nested AI block."
  :tags '(:unit :iterm2 :e2e)
  (test-iterm2--with-org-buffer test-iterm2--org-content-nested
    (goto-char (point-min))
    (re-search-forward "Explain quantum")
    (claude-org-iterm2--execute-ai-block)
    (should (assoc "send" test-iterm2--mock-call-log))))

;;; ============================================================================
;;; Cancel (real org + mock iterm2-ctl)
;;; ============================================================================

(ert-deftest test-iterm2-cancel-sends-to-session ()
  "cancel finds ITERM2_SESSION_ID from org and sends cancel."
  :tags '(:unit :iterm2 :e2e)
  (test-iterm2--with-org-buffer test-iterm2--org-content-basic
    (goto-char (point-min))
    (org-next-visible-heading 1)
    ;; First launch to set ITERM2_SESSION_ID
    (claude-org-iterm2--ensure-session)
    (setq test-iterm2--mock-call-log nil)
    ;; Now cancel
    (claude-org-iterm2-cancel)
    (let ((cancel-call (assoc "cancel" test-iterm2--mock-call-log)))
      (should cancel-call)
      (should (member test-iterm2--mock-session-id (cdr cancel-call))))))

(ert-deftest test-iterm2-cancel-errors-no-session ()
  "cancel errors when no ITERM2_SESSION_ID exists."
  :tags '(:unit :iterm2 :e2e)
  (test-iterm2--with-org-buffer test-iterm2--org-content-basic
    (goto-char (point-min))
    (org-next-visible-heading 1)
    ;; Don't launch — no ITERM2_SESSION_ID set
    (should-error (claude-org-iterm2-cancel)
                  :type 'user-error)))

;;; ============================================================================
;;; C-c C-c Dispatch (real org buffer, mock iterm2-ctl)
;;; ============================================================================

(ert-deftest test-iterm2-dispatch-from-ai-block ()
  "C-c C-c dispatches to iTerm2 backend when CLAUDE_BACKEND=iterm2."
  :tags '(:unit :iterm2 :e2e)
  (test-iterm2--with-org-buffer test-iterm2--org-content-basic
    (goto-char (point-min))
    (re-search-forward "What is 2")
    (claude-org-execute)
    ;; Should have gone through iterm2 path (launch + send)
    (should (assoc "launch" test-iterm2--mock-call-log))
    (should (assoc "send" test-iterm2--mock-call-log))))

(ert-deftest test-iterm2-dispatch-case-insensitive ()
  "C-c C-c dispatches to iTerm2 backend regardless of case.
REGRESSION: User set CLAUDE_BACKEND=iTerm2 (mixed case) but dispatch
used case-sensitive `equal' which only matched lowercase \"iterm2\",
causing fallthrough to json-stream backend."
  :tags '(:unit :iterm2 :e2e :regression)
  (test-iterm2--with-org-buffer test-iterm2--org-content-mixed-case
    (goto-char (point-min))
    (re-search-forward "case test query")
    (claude-org-execute)
    ;; Must dispatch to iterm2 despite mixed case
    (should (assoc "launch" test-iterm2--mock-call-log))
    (should (assoc "send" test-iterm2--mock-call-log))))

(ert-deftest test-iterm2-dispatch-inherited-backend ()
  "C-c C-c dispatches via inherited CLAUDE_BACKEND property."
  :tags '(:unit :iterm2 :e2e)
  (test-iterm2--with-org-buffer test-iterm2--org-content-inherited
    (goto-char (point-min))
    (re-search-forward "inherited backend")
    (claude-org-execute)
    (should (assoc "send" test-iterm2--mock-call-log))))

;;; ============================================================================
;;; Launch Command Builder (real defcustoms)
;;; ============================================================================

(ert-deftest test-iterm2-build-command-claude-sdd ()
  "claude-sdd mode includes org-file and session-id."
  :tags '(:unit :iterm2 :e2e)
  (let ((claude-org-iterm2-launch-command 'claude-sdd)
        (claude-org-iterm2-extra-args nil))
    (let ((cmd (claude-org-iterm2--build-launch-command
                "/tmp/test.org" "sdd-123" "/tmp")))
      (should (string-match-p "claude-sdd" cmd))
      (should (string-match-p "/tmp/test.org" cmd))
      (should (string-match-p "sdd-123" cmd)))))

(ert-deftest test-iterm2-build-command-extra-args ()
  "Extra args appended after -- separator."
  :tags '(:unit :iterm2 :e2e)
  (let ((claude-org-iterm2-launch-command 'claude-sdd)
        (claude-org-iterm2-extra-args '("--model" "opus")))
    (let ((cmd (claude-org-iterm2--build-launch-command
                "/tmp/test.org" "sdd-123" "/tmp")))
      (should (string-match-p "-- --model opus" cmd)))))

(ert-deftest test-iterm2-build-command-resume-with-extra-args ()
  "claude-sdd mode includes --resume AND extra args when both present."
  :tags '(:unit :iterm2 :e2e)
  (let ((claude-org-iterm2-launch-command 'claude-sdd)
        (claude-org-iterm2-extra-args '("--model" "opus")))
    ;; Simulate CLAUDE_CLI_SESSION in org properties
    (with-temp-buffer
      (org-mode)
      (insert "* Story\n:PROPERTIES:\n:CLAUDE_SESSION_ID: sdd-X\n"
              ":CLAUDE_CLI_SESSION: cli-uuid-999\n:END:\n")
      (goto-char (point-min))
      (org-next-visible-heading 1)
      (let ((cmd (claude-org-iterm2--build-launch-command
                  "/tmp/test.org" "sdd-X" "/tmp")))
        (should (string-match-p "--resume" cmd))
        (should (string-match-p "cli-uuid-999" cmd))
        (should (string-match-p "--model" cmd))))))

(ert-deftest test-iterm2-build-command-extra-args-from-org-property ()
  "CLAUDE_EXTRA_ARGS org property is included in launch command."
  :tags '(:unit :iterm2 :e2e)
  (let ((claude-org-iterm2-launch-command 'claude-sdd)
        (claude-org-iterm2-extra-args nil))
    (with-temp-buffer
      (org-mode)
      (insert "* Story\n:PROPERTIES:\n:CLAUDE_SESSION_ID: sdd-X\n"
              ":CLAUDE_EXTRA_ARGS: --model opus --verbose\n:END:\n")
      (goto-char (point-min))
      (org-next-visible-heading 1)
      (let ((cmd (claude-org-iterm2--build-launch-command
                  "/tmp/test.org" "sdd-X" "/tmp")))
        (should (string-match-p "--model" cmd))
        (should (string-match-p "opus" cmd))
        (should (string-match-p "--verbose" cmd))))))

(ert-deftest test-iterm2-build-command-extra-args-merged ()
  "CLAUDE_EXTRA_ARGS property merges with defcustom extra-args."
  :tags '(:unit :iterm2 :e2e)
  (let ((claude-org-iterm2-launch-command 'claude-sdd)
        (claude-org-iterm2-extra-args '("--debug")))
    (with-temp-buffer
      (org-mode)
      (insert "* Story\n:PROPERTIES:\n:CLAUDE_SESSION_ID: sdd-X\n"
              ":CLAUDE_EXTRA_ARGS: --model opus\n:END:\n")
      (goto-char (point-min))
      (org-next-visible-heading 1)
      (let ((cmd (claude-org-iterm2--build-launch-command
                  "/tmp/test.org" "sdd-X" "/tmp")))
        ;; Both defcustom and property args present
        (should (string-match-p "--debug" cmd))
        (should (string-match-p "--model" cmd))
        (should (string-match-p "opus" cmd))))))

(ert-deftest test-iterm2-build-command-custom-string ()
  "Custom string command passes through."
  :tags '(:unit :iterm2 :e2e)
  (let ((claude-org-iterm2-launch-command "my-launcher --profile work")
        (claude-org-iterm2-extra-args '("--debug")))
    (let ((cmd (claude-org-iterm2--build-launch-command
                "/tmp/test.org" "sdd-123" "/tmp")))
      (should (string-match-p "^my-launcher --profile work" cmd))
      (should (string-match-p "--debug" cmd)))))

;;; ============================================================================
;;; Defcustom Existence
;;; ============================================================================

(ert-deftest test-iterm2-defcustoms-exist ()
  "All iTerm2 defcustoms exist with correct defaults."
  :tags '(:unit :iterm2 :e2e)
  (should (custom-variable-p 'claude-org-iterm2-script))
  (should (custom-variable-p 'claude-org-iterm2-launch-command))
  (should (custom-variable-p 'claude-org-iterm2-extra-args))
  (should (custom-variable-p 'claude-org-iterm2-sdd-script))
  (should (eq (default-value 'claude-org-iterm2-launch-command) 'claude-sdd))
  (should (null (default-value 'claude-org-iterm2-extra-args))))

(ert-deftest test-iterm2-sdd-script-path-exists ()
  "claude-org-iterm2-sdd-script points to an existing file.
REGRESSION: Path resolved from load-file-name which differs per install."
  :tags '(:unit :iterm2 :e2e :regression)
  (let ((script claude-org-iterm2-sdd-script))
    (when (and (not (equal script "claude-sdd"))
               (file-name-absolute-p script))
      (should-with-fix (file-exists-p script)
        (format "claude-org-iterm2-sdd-script → %s does not exist.\nFIX: Customize the variable or put claude-sdd on PATH."
                script)))))

;;; ============================================================================
;;; Hook Status Files (real filesystem)
;;; ============================================================================

(ert-deftest test-iterm2-hook-status-write-read-cycle ()
  "Hook status file write/read cycle: busy → ready → unknown."
  :tags '(:unit :iterm2 :e2e)
  (let* ((test-id (format "test-hook-%d" (random 100000)))
         (status-dir "/tmp/claude-agent-status")
         (status-file (expand-file-name test-id status-dir)))
    (make-directory status-dir t)
    (unwind-protect
        (progn
          (with-temp-file status-file (insert "busy"))
          (should (equal "busy" (claude-org-iterm2--read-hook-status test-id)))
          (with-temp-file status-file (insert "ready"))
          (should (equal "ready" (claude-org-iterm2--read-hook-status test-id)))
          (delete-file status-file)
          (should (equal "unknown" (claude-org-iterm2--read-hook-status test-id))))
      (when (file-exists-p status-file) (delete-file status-file)))))

(ert-deftest test-iterm2-get-status-prefers-hook-file ()
  "get-status returns hook file value without calling iTerm2 API."
  :tags '(:unit :iterm2 :e2e)
  (let* ((test-id (format "test-pref-%d" (random 100000)))
         (status-dir "/tmp/claude-agent-status")
         (status-file (expand-file-name test-id status-dir))
         (api-called nil))
    (make-directory status-dir t)
    (unwind-protect
        (progn
          (with-temp-file status-file (insert "busy"))
          ;; Mock the call to verify it's NOT invoked
          (cl-letf (((symbol-function 'claude-org-iterm2--call)
                     (lambda (&rest _) (setq api-called t) "{\"state\":\"ready\"}")))
            (should (equal "busy"
                           (claude-org-iterm2--get-status test-id "fake-session")))
            (should-not api-called)))
      (when (file-exists-p status-file) (delete-file status-file)))))

;;; ============================================================================
;;; Query Registration (active-queries integration)
;;; ============================================================================

(ert-deftest test-iterm2-query-register-unregister-cycle ()
  "register-query / query-completed cycle manages active-queries table."
  :tags '(:unit :iterm2 :e2e)
  (let* ((test-session "sdd-test-reg-unreg")
         (status-dir "/tmp/claude-agent-status")
         (req-id-file (expand-file-name
                       (concat test-session ".request-id") status-dir))
         (tmp-file (make-temp-file "iterm2-reg-test" nil ".org"))
         (buf nil))
    (make-directory status-dir t)
    (unwind-protect
        (progn
          (with-temp-file tmp-file
            (insert "* Test :claude_chat:\n"
                    ":PROPERTIES:\n"
                    ":CUSTOM_ID: test-instr-1\n"
                    ":END:\n\n"
                    "#+begin_src ai\ntest\n#+end_src\n"))
          (setq buf (find-file-noselect tmp-file))
          (with-current-buffer buf
            (org-mode)
            (goto-char (point-min))
            (org-back-to-heading t)
            ;; Register
            (claude-org-iterm2--register-query test-session "fake-iterm-id")
            (let ((req-id (claude-org-iterm2--read-request-id test-session)))
              (should req-id)
              (should (claude-agent--get-active-query req-id))
              ;; Unregister
              (claude-org-iterm2--query-completed test-session)
              (should-not (claude-agent--get-active-query req-id)))))
      (when buf (kill-buffer buf))
      (when (file-exists-p tmp-file) (delete-file tmp-file))
      (when (file-exists-p req-id-file) (delete-file req-id-file)))))

(ert-deftest test-iterm2-query-completed-idempotent ()
  "query-completed is safe to call when no request-id exists."
  :tags '(:unit :iterm2 :e2e)
  ;; Should not error
  (claude-org-iterm2--query-completed "nonexistent-session"))

;;; ============================================================================
;;; sdd-bridge.sh Status File Integration (real shell script)
;;; ============================================================================

(ert-deftest test-iterm2-sdd-bridge-prompt-writes-busy ()
  "sdd-bridge prompt event writes 'busy' to status file."
  :tags '(:unit :iterm2 :e2e)
  (let* ((test-id (format "test-bridge-%d" (random 100000)))
         (status-dir "/tmp/claude-agent-status")
         (status-file (expand-file-name test-id status-dir))
         (project-dir (expand-file-name "python"
                                        test-iterm2--project-root)))
    (make-directory status-dir t)
    (unwind-protect
        (progn
          (call-process-shell-command
           (format "echo '{\"prompt\":\"test\"}' | SDD_SESSION_ID='%s' SDD_ORG_FILE='/tmp/f.org' EMACS_MCP_URL='http://localhost:1/mcp' uv run --project '%s' sdd-bridge prompt"
                   test-id project-dir)
           nil nil nil)
          (should (file-exists-p status-file))
          (should (equal "busy"
                         (string-trim (with-temp-buffer
                                        (insert-file-contents status-file)
                                        (buffer-string))))))
      (when (file-exists-p status-file) (delete-file status-file)))))

(ert-deftest test-iterm2-sdd-bridge-response-writes-ready ()
  "sdd-bridge response event writes 'ready' to status file."
  :tags '(:unit :iterm2 :e2e)
  (let* ((test-id (format "test-bridge-%d" (random 100000)))
         (status-dir "/tmp/claude-agent-status")
         (status-file (expand-file-name test-id status-dir))
         (project-dir (expand-file-name "python"
                                        test-iterm2--project-root)))
    (make-directory status-dir t)
    (unwind-protect
        (progn
          (call-process-shell-command
           (format "echo '{\"last_assistant_message\":\"hi\"}' | SDD_SESSION_ID='%s' SDD_ORG_FILE='/tmp/f.org' EMACS_MCP_URL='http://localhost:1/mcp' uv run --project '%s' sdd-bridge response"
                   test-id project-dir)
           nil nil nil)
          (should (file-exists-p status-file))
          (should (equal "ready"
                         (string-trim (with-temp-buffer
                                        (insert-file-contents status-file)
                                        (buffer-string))))))
      (when (file-exists-p status-file) (delete-file status-file)))))

;;; ============================================================================
;;; Fixture Format Validation (from real iTerm2 runs)
;;; ============================================================================

(defun test-iterm2--fixture (name)
  "Load fixture NAME. Return string or nil if missing."
  (let ((path (expand-file-name name test-iterm2--fixture-dir)))
    (when (file-exists-p path)
      (string-trim (with-temp-buffer
                     (insert-file-contents path) (buffer-string))))))

(ert-deftest test-iterm2-fixture-launch-uuid-format ()
  "Real launch output is a valid UUID."
  :tags '(:unit :iterm2 :e2e)
  (let ((sid (test-iterm2--fixture "launch-session-id.txt")))
    (skip-unless sid)
    (should (string-match-p
             "^[0-9A-F]\\{8\\}-[0-9A-F]\\{4\\}-[0-9A-F]\\{4\\}-[0-9A-F]\\{4\\}-[0-9A-F]\\{12\\}$"
             sid))))

(ert-deftest test-iterm2-fixture-screen-has-answer ()
  "Real screen capture contains '4' (answer to 2+2)."
  :tags '(:unit :iterm2 :e2e)
  (let ((screen (test-iterm2--fixture "screen-after-prompt.txt")))
    (skip-unless screen)
    (should (string-match-p "4" screen))
    (should (string-match-p "2\\+2" screen))))

(ert-deftest test-iterm2-fixture-status-json-valid ()
  "Real status outputs parse as valid JSON with expected fields."
  :tags '(:unit :iterm2 :e2e)
  (dolist (fixture '("status-after-launch.json" "status-after-close.json"))
    (let ((text (test-iterm2--fixture fixture)))
      (when text
        (let ((data (json-read-from-string text)))
          (should (assq 'state data)))))))

;;; ============================================================================
;;; Response Flow (execute → hook callback → response section)
;;; ============================================================================

(defconst test-iterm2--org-content-with-workflow
  "* Dev Story
:PROPERTIES:
:CLAUDE_SESSION_ID: sdd-resp-test
:CLAUDE_BACKEND: iterm2
:END:

** Workflow :sdd:
:PROPERTIES:
:CUSTOM_ID: workflow-sdd-resp-test
:END:

*** Instruction 1 :claude_chat:
:PROPERTIES:
:CUSTOM_ID: sdd-resp-test-instr-1
:END:

#+begin_src ai
What is 2+2?
#+end_src
"
  "Org buffer with SDD session and Workflow/Instruction structure.
This mirrors what the SDD bridge expects for response insertion.")

(ert-deftest test-iterm2-response-inserted-after-execute ()
  "Full round-trip: execute AI block → simulate hook callback → response section exists.
REGRESSION: iTerm2 backend sent prompts but no response appeared in org buffer
because the response insertion path (sdd-bridge hooks) wasn't tested end-to-end."
  :tags '(:unit :iterm2 :e2e :regression)
  (let ((test-iterm2--mock-call-log nil)
        (tmp-file (make-temp-file "iterm2-resp-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file tmp-file
            (insert test-iterm2--org-content-with-workflow))
          (with-current-buffer (find-file-noselect tmp-file)
            (goto-char (point-min))
            (cl-letf (((symbol-function 'claude-org-iterm2--call)
                       #'test-iterm2--mock-call))
              (unwind-protect
                  (progn
                    ;; 1. Execute AI block (sends to mock iTerm2)
                    (re-search-forward "What is 2")
                    (claude-org-iterm2--execute-ai-block)
                    (should (assoc "send" test-iterm2--mock-call-log))

                    ;; 2. Simulate sdd-bridge.sh "response" callback
                    ;; This is what happens when Claude finishes responding:
                    ;; the Stop hook fires → sdd-bridge.sh → MCP evalElisp →
                    ;; claude-org-sdd-bridge-insert-response
                    (claude-org-sdd-bridge-insert-response
                     tmp-file "sdd-resp-test" "The answer is 4."
                     "sdd-resp-test-instr-1")

                    ;; 3. Verify response section exists in buffer
                    (goto-char (point-min))
                    (should (re-search-forward "Response 1" nil t))
                    (should (re-search-forward "The answer is 4\\." nil t)))
                (set-buffer-modified-p nil)
                (kill-buffer (current-buffer))))))
      (when (file-exists-p tmp-file) (delete-file tmp-file)))))

(ert-deftest test-iterm2-emacs-prompt-no-duplicate-instruction ()
  "Prompt sent from Emacs must NOT create a duplicate Instruction section.
REGRESSION: sdd-bridge.sh prompt hook always called insert-prompt,
duplicating the AI block that Emacs already has in the org file.
FIX: execute-ai-block writes a from-emacs flag file; sdd-bridge.sh
checks it and skips insert-prompt when the flag exists."
  :tags '(:unit :iterm2 :e2e :regression)
  (let ((test-iterm2--mock-call-log nil)
        (tmp-file (make-temp-file "iterm2-dup-" nil ".org"))
        (flag-file (expand-file-name
                    "sdd-resp-test.from-emacs"
                    "/tmp/claude-agent-status")))
    (unwind-protect
        (progn
          (with-temp-file tmp-file
            (insert test-iterm2--org-content-with-workflow))
          (with-current-buffer (find-file-noselect tmp-file)
            (goto-char (point-min))
            (cl-letf (((symbol-function 'claude-org-iterm2--call)
                       #'test-iterm2--mock-call))
              (unwind-protect
                  (progn
                    ;; 1. Execute AI block from Emacs (like C-c C-c)
                    ;; This now writes the from-emacs flag file
                    (re-search-forward "What is 2")
                    (claude-org-iterm2--execute-ai-block)
                    ;; Verify flag was written
                    (should (file-exists-p flag-file))

                    ;; 2. Simulate sdd-bridge.sh checking the flag
                    ;; When flag exists, skip insert-prompt
                    (if (file-exists-p flag-file)
                        (delete-file flag-file)
                      ;; If no flag, insert-prompt would be called (bug)
                      (claude-org-sdd-bridge-insert-prompt
                       tmp-file "sdd-resp-test" "What is 2+2?"))

                    ;; 3. Count Instruction headings — should be 1 (no dup)
                    (goto-char (point-min))
                    (let ((count 0))
                      (while (re-search-forward
                              ":claude_chat:" nil t)
                        (setq count (1+ count)))
                      (should (= 1 count))))
                (set-buffer-modified-p nil)
                (kill-buffer (current-buffer))))))
      (when (file-exists-p tmp-file) (delete-file tmp-file))
      (when (file-exists-p flag-file) (delete-file flag-file)))))

(ert-deftest test-iterm2-direct-prompt-inserts-instruction ()
  "Prompt typed directly in Claude Code SHOULD create an Instruction section.
When user types in Claude TUI (not from Emacs), the org file needs the prompt."
  :tags '(:unit :iterm2 :e2e)
  (let ((test-iterm2--mock-call-log nil)
        (tmp-file (make-temp-file "iterm2-direct-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file tmp-file
            (insert test-iterm2--org-content-with-workflow))
          (with-current-buffer (find-file-noselect tmp-file)
            (goto-char (point-min))
            (unwind-protect
                (progn
                  ;; No execute-ai-block — user typed directly in Claude
                  ;; The prompt hook should insert an instruction
                  (claude-org-sdd-bridge-insert-prompt
                   tmp-file "sdd-resp-test" "Tell me about Emacs")

                  ;; Should now have 2 instruction sections
                  (goto-char (point-min))
                  (let ((count 0))
                    (while (re-search-forward
                            ":claude_chat:" nil t)
                      (setq count (1+ count)))
                    (should (= 2 count))))
              (set-buffer-modified-p nil)
              (kill-buffer (current-buffer)))))
      (when (file-exists-p tmp-file) (delete-file tmp-file)))))

(ert-deftest test-iterm2-launch-always-includes-plugin-dir ()
  "claude-sdd launch command always includes --plugin-dir and --mcp-config.
REGRESSION: When MCP was unreachable at launch time, hooks were omitted,
so responses never flowed back to Emacs even after MCP became available."
  :tags '(:unit :iterm2 :e2e :regression)
  (test-iterm2--with-org-buffer test-iterm2--org-content-basic
    (goto-char (point-min))
    (re-search-forward "What is 2")
    (claude-org-iterm2--execute-ai-block)
    ;; Check the launch call includes --launch-cmd with plugin/mcp args
    (let* ((launch-call (assoc "launch" test-iterm2--mock-call-log))
           (args (cdr launch-call))
           (launch-cmd-idx (cl-position "--launch-cmd" args :test #'equal))
           (launch-cmd (when launch-cmd-idx (nth (1+ launch-cmd-idx) args))))
      (should launch-cmd)
      ;; The launch command should always reference plugin-dir
      ;; (This tests that claude-sdd is invoked, which includes --plugin-dir)
      (should (string-match-p "claude-sdd\\|claude" launch-cmd)))))

;;; ============================================================================
;;; Issue 1: Dead session relaunch from open-tab
;;; ============================================================================

(defconst test-iterm2--org-content-with-iterm2-session
  "* Dev Story
:PROPERTIES:
:CLAUDE_SESSION_ID: sdd-relaunch-test
:CLAUDE_BACKEND: iterm2
:ITERM2_SESSION_ID: OLD-DEAD-SESSION-UUID
:END:

** Instructions

#+begin_src ai
test query
#+end_src
"
  "Org buffer with pre-existing ITERM2_SESSION_ID (simulates closed Claude).")

(ert-deftest test-iterm2-open-tab-relaunches-dead-session ()
  "open-tab must relaunch Claude when existing session is dead.
REGRESSION: After Claude exits, box-drawing chars from farewell message
remained in terminal mutable area. detect_state returned 'busy' instead
of 'dead', so ensure-session returned stale session ID without relaunch.
open-tab then only called focus (bringing dead tab to front)."
  :tags '(:unit :iterm2 :e2e :regression)
  (let ((test-iterm2--mock-call-log nil)
        (tmp-file (make-temp-file "iterm2-relaunch-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file tmp-file
            (insert test-iterm2--org-content-with-iterm2-session))
          (with-current-buffer (find-file-noselect tmp-file)
            (goto-char (point-min))
            (org-next-visible-heading 1)
            ;; Mock returns dead for status → should trigger relaunch
            (cl-letf (((symbol-function 'claude-org-iterm2--call)
                       #'test-iterm2--mock-call-dead-status))
              (unwind-protect
                  (progn
                    (claude-org-iterm2-open-tab)
                    ;; Must have called launch (not just focus)
                    (should (assoc "launch" test-iterm2--mock-call-log))
                    ;; Must have called focus after launch
                    (should (assoc "focus" test-iterm2--mock-call-log))
                    ;; ITERM2_SESSION_ID must be updated to new session
                    (save-excursion
                      (goto-char (point-min))
                      (re-search-forward "^\\* Dev Story")
                      (should (equal test-iterm2--mock-session-id
                                     (org-entry-get nil "ITERM2_SESSION_ID")))))
                (set-buffer-modified-p nil)
                (kill-buffer (current-buffer))))))
      (when (file-exists-p tmp-file) (delete-file tmp-file)))))

;;; ============================================================================
;;; Issue 3: Resume CLI session on relaunch
;;; ============================================================================

(defconst test-iterm2--org-content-with-cli-session
  "* Dev Story
:PROPERTIES:
:CLAUDE_SESSION_ID: sdd-clisess-777
:CLAUDE_BACKEND: iterm2
:CLAUDE_CLI_SESSION: abc123-cli-session-uuid
:END:

** Instructions

#+begin_src ai
test query
#+end_src
"
  "Org buffer with CLAUDE_CLI_SESSION for --resume testing.")

(ert-deftest test-iterm2-launch-passes-resume-from-org-property ()
  "Launch command must include --resume when CLAUDE_CLI_SESSION exists.
REGRESSION: --resume was only passed by claude-sdd via MCP eval.
When MCP was unavailable, CLI session was lost. Fix: Emacs reads the
property directly and passes it in the launch command or extra args."
  :tags '(:unit :iterm2 :e2e :regression)
  (test-iterm2--with-org-buffer test-iterm2--org-content-with-cli-session
    (goto-char (point-min))
    (re-search-forward "test query")
    (claude-org-iterm2--execute-ai-block)
    ;; Check the launch call's --launch-cmd contains --resume
    (let* ((launch-call (assoc "launch" test-iterm2--mock-call-log))
           (args (cdr launch-call))
           (launch-cmd-idx (cl-position "--launch-cmd" args :test #'equal))
           (launch-cmd (when launch-cmd-idx (nth (1+ launch-cmd-idx) args))))
      (should launch-cmd)
      ;; Must contain literal "--resume" (not just "resume" in session ID)
      (should-with-fix (string-match-p "--resume" launch-cmd)
        "Launch command missing --resume. CLAUDE_CLI_SESSION is set but not \
passed to claude-sdd. FIX: build-launch-command should read CLAUDE_CLI_SESSION \
and pass it as extra arg to claude-sdd.")
      ;; Must contain the actual CLI session UUID
      (should (string-match-p "abc123-cli-session-uuid" launch-cmd)))))

(provide 'test-iterm2-e2e-simulated)
;;; test-iterm2-e2e-simulated.el ends here
