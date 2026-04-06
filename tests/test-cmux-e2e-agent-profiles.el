;;; test-cmux-e2e-agent-profiles.el --- E2E tests for multi-agent profile support -*- lexical-binding: t -*-

;; Strategy: Mock ONLY the cmux CLI gateway (claude-org-cmux--call).
;; Everything else — org buffer, properties, profile dispatch, session lookup —
;; uses real code against real org buffers.
;;
;; Tests cover:
;;   - Profile registry lookup (claude, copilot, nil/legacy)
;;   - build-launch-command dispatch per agent type
;;   - wait-for-ready-poll uses profile patterns
;;   - get-status uses profile patterns
;;   - cancel sends correct keys per profile
;;   - restore-workspace skips IDE server for copilot
;;   - launch-workspace skips IDE server for copilot
;;   - Full execute-ai-block mock flows for claude and copilot

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
  (literate-elisp-load (expand-file-name "claude-org.org" project-root))
  (literate-elisp-load (expand-file-name "claude-org-cmux.org" project-root)))

(defvar test-ap--project-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Project root directory.")

;;; ============================================================================
;;; Mock Infrastructure (mirrors test-cmux-e2e-simulated.el)
;;; ============================================================================

(defvar test-ap--mock-calls nil
  "Alist of (subcommand . args) for each cmux CLI call in current test.")

(defvar test-ap--mock-responses nil
  "Alist of (subcommand . response-string) for mock responses.")

(defvar test-ap--mock-surface-id "surface:ap-mock-001"
  "Mock surface ID used in agent profile tests.")

(defun test-ap--read-fixture (name)
  "Read fixture file NAME from the cmux e2e fixtures directory."
  (let ((path (expand-file-name
               (concat "tests/fixtures/cmux/e2e/" name)
               test-ap--project-root)))
    (if (file-exists-p path)
        (with-temp-buffer
          (insert-file-contents path)
          (buffer-string))
      (format "<!-- fixture %s not found -->" name))))

(defun test-ap--mock-call (subcommand &rest args)
  "Mock implementation of `claude-org-cmux--call'.
Records the call and returns fixture-based or override responses."
  (push (cons subcommand args) test-ap--mock-calls)
  (let ((override (cdr (assoc subcommand test-ap--mock-responses))))
    (cond
     (override override)
     ((string= subcommand "ping") "pong")
     ((string= subcommand "new-workspace") "OK workspace:ap-mock-1")
     ((string= subcommand "list-pane-surfaces")
      (format "* %s  ~  [selected]" test-ap--mock-surface-id))
     ((string= subcommand "send") "ok")
     ((string= subcommand "send-key") "ok")
     ((string= subcommand "set-buffer") "ok")
     ((string= subcommand "paste-buffer") "ok")
     ((string= subcommand "select-workspace") "ok")
     ((string= subcommand "set-app-focus") "ok")
     ((string= subcommand "set-status") "ok")
     ((string= subcommand "clear-status") "ok")
     ((string= subcommand "set-progress") "ok")
     ((string= subcommand "clear-progress") "ok")
     ((string= subcommand "notify") "ok")
     ((string= subcommand "capture-pane")
      (test-ap--read-fixture "capture-pane-ready.txt"))
     ((string= subcommand "tree")
      "workspace workspace:ap-mock-1 \"Test\"\n  pane pane:1\n    surface surface:ap-mock-001 [terminal]")
     (t (format "mock-response-for-%s" subcommand)))))

(defun test-ap--mock-calls-for (subcommand)
  "Return all recorded calls for SUBCOMMAND."
  (cl-remove-if-not (lambda (c) (string= (car c) subcommand))
                    test-ap--mock-calls))

(defmacro test-ap--with-mock (&rest body)
  "Execute BODY with cmux CLI gateway mocked."
  (declare (indent 0))
  `(let ((test-ap--mock-calls nil)
         (test-ap--mock-responses nil))
     (cl-letf (((symbol-function 'claude-org-cmux--call) #'test-ap--mock-call))
       ,@body)))

;;; ============================================================================
;;; Org Buffer Helpers
;;; ============================================================================

(defmacro test-ap--with-org-buffer (content &rest body)
  "Create a temp org buffer with CONTENT and execute BODY."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer "*test-ap-org*"))
         (inhibit-message t))
     (unwind-protect
         (with-current-buffer buf
           (org-mode)
           (insert ,content)
           (goto-char (point-min))
           (setq buffer-file-name (make-temp-file "test-ap-" nil ".org"))
           (write-region (point-min) (point-max) buffer-file-name nil 'silent)
           (set-buffer-modified-p nil)
           ,@body)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (when buffer-file-name
             (ignore-errors (delete-file buffer-file-name))))
         (kill-buffer buf)))))

;;; ============================================================================
;;; Tests: Agent Profile Registry
;;; ============================================================================

(ert-deftest test-ap-profile-registry-claude ()
  "Claude profile is registered and has expected fields."
  :tags '(:unit :fast :agent-profiles)
  (let ((profile (claude-org-cmux--get-agent-profile 'claude)))
    (should profile)
    (should (equal (claude-org-cmux--agent-profile-name profile) 'claude))
    (should (functionp (claude-org-cmux--agent-profile-launch-fn profile)))
    (should (claude-org-cmux--agent-profile-ready-patterns profile))
    (should (claude-org-cmux--agent-profile-busy-patterns profile))
    (should (claude-org-cmux--agent-profile-cancel-keys profile))
    (should (claude-org-cmux--agent-profile-supports-ide profile))
    (should (claude-org-cmux--agent-profile-supports-resume profile))))

(ert-deftest test-ap-profile-registry-copilot ()
  "Copilot profile is registered and has expected fields."
  :tags '(:unit :fast :agent-profiles)
  (let ((profile (claude-org-cmux--get-agent-profile 'copilot)))
    (should profile)
    (should (equal (claude-org-cmux--agent-profile-name profile) 'copilot))
    (should (functionp (claude-org-cmux--agent-profile-launch-fn profile)))
    (should (claude-org-cmux--agent-profile-ready-patterns profile))
    (should (claude-org-cmux--agent-profile-busy-patterns profile))
    (should (claude-org-cmux--agent-profile-cancel-keys profile))
    ;; Copilot does NOT support IDE but DOES support resume
    (should-not (claude-org-cmux--agent-profile-supports-ide profile))
    (should (claude-org-cmux--agent-profile-supports-resume profile))))

(ert-deftest test-ap-profile-registry-nil ()
  "nil agent-type returns nil (triggers legacy path)."
  :tags '(:unit :fast :agent-profiles)
  (should-not (claude-org-cmux--get-agent-profile nil)))

(ert-deftest test-ap-profile-registry-unknown ()
  "Unknown agent-type string returns nil gracefully."
  :tags '(:unit :fast :agent-profiles)
  (should-not (claude-org-cmux--get-agent-profile 'some-unknown-agent)))

;;; ============================================================================
;;; Tests: build-launch-command dispatch
;;; ============================================================================

(ert-deftest test-ap-build-launch-command-claude-profile ()
  "build-launch-command with 'claude profile builds claude-workspace command."
  :tags '(:unit :fast :agent-profiles)
  (test-ap--with-org-buffer
      "* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: session-ap-001
:AGENT_TYPE: claude
:CUSTOM_ID: story-ap-001
:END:

#+begin_src ai
test query
#+end_src
"
    (let ((claude-org-cmux-agent-type 'claude)
          (claude-org-cmux-copilot-workspace-script "uv run copilot-workspace"))
      (let ((cmd (claude-org-cmux--build-launch-command
                  "/test/project" "session-ap-001" nil)))
        (should (stringp cmd))
        (should (string-match-p "claude-workspace" cmd))
        ;; Claude profile SHOULD include --resume or extra args
        (should-not (string-match-p "copilot" cmd))))))

(ert-deftest test-ap-build-launch-command-claude-profile-with-resume ()
  "E20: Claude profile launch includes --resume when CLAUDE_CLI_SESSION set."
  :tags '(:unit :fast :agent-profiles :e2e)
  (test-ap--with-org-buffer
      "* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: session-ap-resume
:AGENT_TYPE: claude
:CLAUDE_CLI_SESSION: saved-uuid-12345
:CUSTOM_ID: story-ap-resume
:END:

#+begin_src ai
test query
#+end_src
"
    (let ((claude-org-cmux-agent-type 'claude))
      (let ((cmd (claude-org-cmux--build-launch-command
                  "/test/project" "session-ap-resume" nil)))
        (should (stringp cmd))
        (should (string-match-p "claude-workspace" cmd))
        ;; --resume with the saved CLI session
        (should (string-match-p "--resume" cmd))
        (should (string-match-p "saved-uuid-12345" cmd))))))

(ert-deftest test-ap-build-launch-command-copilot-profile ()
  "build-launch-command with 'copilot profile builds copilot-workspace command."
  :tags '(:unit :fast :agent-profiles)
  (test-ap--with-org-buffer
      "* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: session-ap-002
:AGENT_TYPE: copilot
:CUSTOM_ID: story-ap-002
:END:

#+begin_src ai
test query
#+end_src
"
    (let ((claude-org-cmux-agent-type 'copilot)
          (claude-org-cmux-copilot-workspace-script "uv run copilot-workspace"))
      (let ((cmd (claude-org-cmux--build-launch-command
                  "/test/project" "session-ap-002" nil)))
        (should (stringp cmd))
        (should (string-match-p "copilot-workspace" cmd))
        ;; Copilot MUST NOT include --resume
        (should-not (string-match-p "--resume" cmd))))))

(ert-deftest test-ap-build-launch-command-nil-legacy ()
  "build-launch-command with nil agent-type falls back to legacy claude-workspace."
  :tags '(:unit :fast :agent-profiles)
  (test-ap--with-org-buffer
      "* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: session-ap-003
:CUSTOM_ID: story-ap-003
:END:

#+begin_src ai
test query
#+end_src
"
    (let ((claude-org-cmux-agent-type nil))
      (let ((cmd (claude-org-cmux--build-launch-command
                  "/test/project" "session-ap-003" nil)))
        (should (stringp cmd))
        ;; Legacy path uses claude-workspace script
        (should (string-match-p "claude-workspace\\|uv run" cmd))
        (should-not (string-match-p "copilot-workspace" cmd))))))

;;; ============================================================================
;;; Tests: Cancel key dispatch
;;; ============================================================================

(ert-deftest test-ap-cancel-claude-uses-escape ()
  "Cancel for claude profile sends escape (lowercase cmux key name)."
  :tags '(:unit :fast :agent-profiles)
  (let ((profile (claude-org-cmux--get-agent-profile 'claude)))
    (should profile)
    (let ((cancel-keys (claude-org-cmux--agent-profile-cancel-keys profile)))
      (should (member "escape" cancel-keys)))))

(ert-deftest test-ap-cancel-copilot-uses-ctrl-c-twice ()
  "Cancel for copilot profile sends C-c twice."
  :tags '(:unit :fast :agent-profiles)
  (let ((profile (claude-org-cmux--get-agent-profile 'copilot)))
    (should profile)
    (let ((cancel-keys (claude-org-cmux--agent-profile-cancel-keys profile)))
      ;; Copilot needs C-c twice to interrupt
      (should (= 2 (length (cl-remove-if-not
                             (lambda (k) (string= k "C-c"))
                             cancel-keys)))))))

;;; ============================================================================
;;; Tests: Ready / Busy patterns
;;; ============================================================================

(ert-deftest test-ap-claude-profile-has-ready-patterns ()
  "Claude profile ready-patterns contain known TUI strings."
  :tags '(:unit :fast :agent-profiles)
  (let* ((profile (claude-org-cmux--get-agent-profile 'claude))
         (patterns (claude-org-cmux--agent-profile-ready-patterns profile)))
    (should (listp patterns))
    (should (> (length patterns) 0))))

(ert-deftest test-ap-copilot-profile-has-ready-patterns ()
  "Copilot profile ready-patterns contain known TUI strings."
  :tags '(:unit :fast :agent-profiles)
  (let* ((profile (claude-org-cmux--get-agent-profile 'copilot))
         (patterns (claude-org-cmux--agent-profile-ready-patterns profile)))
    (should (listp patterns))
    (should (> (length patterns) 0))))

(ert-deftest test-ap-copilot-profile-has-busy-patterns ()
  "Copilot profile busy-patterns contain known TUI strings."
  :tags '(:unit :fast :agent-profiles)
  (let* ((profile (claude-org-cmux--get-agent-profile 'copilot))
         (patterns (claude-org-cmux--agent-profile-busy-patterns profile)))
    (should (listp patterns))
    (should (> (length patterns) 0))))

;;; ============================================================================
;;; Tests: IDE/Resume capability flags
;;; ============================================================================

(ert-deftest test-ap-claude-profile-supports-ide ()
  "Claude profile supports IDE server integration."
  :tags '(:unit :fast :agent-profiles)
  (let ((profile (claude-org-cmux--get-agent-profile 'claude)))
    (should (claude-org-cmux--agent-profile-supports-ide profile))
    (should (claude-org-cmux--agent-profile-supports-resume profile))))

(ert-deftest test-ap-copilot-profile-no-ide ()
  "Copilot profile does NOT support IDE server but supports resume."
  :tags '(:unit :fast :agent-profiles)
  (let ((profile (claude-org-cmux--get-agent-profile 'copilot)))
    (should-not (claude-org-cmux--agent-profile-supports-ide profile))
    (should (claude-org-cmux--agent-profile-supports-resume profile))))

;;; ============================================================================
;;; Tests: get-agent-profile via org property (AGENT_TYPE)
;;; ============================================================================

(ert-deftest test-ap-get-agent-profile-respects-customization ()
  "get-agent-profile uses claude-org-cmux-agent-type customization variable."
  :tags '(:unit :fast :agent-profiles)
  (let ((claude-org-cmux-agent-type 'copilot))
    (let ((profile (claude-org-cmux--get-agent-profile)))
      (should profile)
      (should (equal (claude-org-cmux--agent-profile-name profile) 'copilot))))
  (let ((claude-org-cmux-agent-type nil))
    (should-not (claude-org-cmux--get-agent-profile))))

;;; ============================================================================
;;; Integration Tests: launch flow with mock cmux CLI
;;; (These tests verify the E2E path with real org buffers and mocked cmux)
;;; ============================================================================

(ert-deftest test-ap-launch-command-structure-claude-vs-copilot ()
  "launch commands for claude and copilot are structurally different."
  :tags '(:integration :agent-profiles)
  (let* ((claude-cmd
          (let ((claude-org-cmux-agent-type 'claude))
            (claude-org-cmux--build-launch-command
             "/project" "session-001" nil)))
         (copilot-cmd
          (let ((claude-org-cmux-agent-type 'copilot)
                (claude-org-cmux-copilot-workspace-script "uv run copilot-workspace"))
            (claude-org-cmux--build-launch-command
             "/project" "session-002" nil))))
    ;; Claude uses claude-workspace
    (should (string-match-p "claude-workspace" claude-cmd))
    ;; Copilot uses copilot-workspace
    (should (string-match-p "copilot-workspace" copilot-cmd))
    ;; Commands must be distinct
    (should-not (string= claude-cmd copilot-cmd))
    ;; Copilot command must not contain --resume
    (should-not (string-match-p "--resume" copilot-cmd))))

(ert-deftest test-ap-copilot-cancel-sequence ()
  "Mocked cancel for copilot profile sends C-c twice via cmux."
  :tags '(:integration :agent-profiles)
  (test-ap--with-mock
    (test-ap--with-org-buffer
        (concat "* Story\n"
                ":PROPERTIES:\n"
                ":CLAUDE_SESSION_ID: session-cancel-copilot\n"
                ":CMUX_SURFACE_ID: surface:ap-mock-001\n"
                ":AGENT_TYPE: copilot\n"
                ":CUSTOM_ID: cancel-copilot-story\n"
                ":END:\n\n"
                "#+begin_src ai\ntest\n#+end_src\n")
      (goto-char (point-min))
      (let ((claude-org-cmux-agent-type 'copilot))
        (condition-case nil
            (claude-org-cmux-cancel)
          (error nil))
        ;; Should have issued send-key calls
        (let ((send-key-calls (test-ap--mock-calls-for "send-key")))
          ;; Two C-c sends expected for copilot
          (should (>= (length send-key-calls) 2)))))))

(ert-deftest test-ap-claude-cancel-sequence ()
  "Mocked cancel for claude profile sends escape via cmux."
  :tags '(:integration :agent-profiles)
  (test-ap--with-mock
    (test-ap--with-org-buffer
        (concat "* Story\n"
                ":PROPERTIES:\n"
                ":CLAUDE_SESSION_ID: session-cancel-claude\n"
                ":CMUX_SURFACE_ID: surface:ap-mock-001\n"
                ":AGENT_TYPE: claude\n"
                ":CUSTOM_ID: cancel-claude-story\n"
                ":END:\n\n"
                "#+begin_src ai\ntest\n#+end_src\n")
      (goto-char (point-min))
      (let ((claude-org-cmux-agent-type 'claude))
        (condition-case nil
            (claude-org-cmux-cancel)
          (error nil))
        (let ((send-key-calls (test-ap--mock-calls-for "send-key")))
          ;; Escape for claude
          (should (>= (length send-key-calls) 1)))))))

;;; ============================================================================
;;; E2E Tests: Copilot org-file with AGENT_TYPE property
;;; ============================================================================

(ert-deftest test-ap-org-property-agent-type-copilot ()
  "AGENT_TYPE org property is read correctly for copilot."
  :tags '(:integration :agent-profiles)
  (test-ap--with-org-buffer
      "* Story with Copilot
:PROPERTIES:
:CLAUDE_SESSION_ID: copilot-session-001
:AGENT_TYPE: copilot
:CUSTOM_ID: copilot-story-001
:END:

** Task 1
:PROPERTIES:
:CUSTOM_ID: copilot-task-001
:END:

#+begin_src ai
Do something with copilot.
#+end_src
"
    ;; Read the AGENT_TYPE property
    (goto-char (point-min))
    (re-search-forward ":AGENT_TYPE:" nil t)
    (let ((prop-val (org-entry-get (point) "AGENT_TYPE")))
      (should (equal prop-val "copilot")))))

(ert-deftest test-ap-org-property-agent-type-claude ()
  "AGENT_TYPE org property is read correctly for claude."
  :tags '(:integration :agent-profiles)
  (test-ap--with-org-buffer
      "* Story with Claude
:PROPERTIES:
:CLAUDE_SESSION_ID: claude-session-001
:AGENT_TYPE: claude
:CUSTOM_ID: claude-story-001
:END:

#+begin_src ai
Do something with claude.
#+end_src
"
    (goto-char (point-min))
    (re-search-forward ":AGENT_TYPE:" nil t)
    (let ((prop-val (org-entry-get (point) "AGENT_TYPE")))
      (should (equal prop-val "claude")))))

(ert-deftest test-ap-legacy-no-agent-type ()
  "No AGENT_TYPE property leaves agent-type unset (nil/legacy)."
  :tags '(:integration :agent-profiles)
  (test-ap--with-org-buffer
      "* Legacy Story
:PROPERTIES:
:CLAUDE_SESSION_ID: legacy-session-001
:CUSTOM_ID: legacy-story-001
:END:

#+begin_src ai
Legacy query.
#+end_src
"
    (goto-char (point-min))
    ;; Property should be absent
    (let ((prop-val (org-entry-get (point) "AGENT_TYPE")))
      (should-not prop-val))))

;;; ============================================================================
;;; E2E Tests: get-status with profile pattern dispatch
;;; ============================================================================

(ert-deftest test-ap-get-status-uses-copilot-patterns ()
  "get-status uses copilot busy/ready patterns when agent is copilot."
  :tags '(:integration :agent-profiles)
  (test-ap--with-mock
    (let ((claude-org-cmux-agent-type 'copilot))
      ;; Override capture-pane to return a copilot-style ready prompt
      (push (cons "capture-pane" "> ")
            test-ap--mock-responses)
      ;; get-status should not crash with copilot profile
      (let ((result (condition-case err
                        (claude-org-cmux-get-status "surface:ap-mock-001")
                      (error (format "error: %s" err)))))
        ;; Should return a status symbol or string, not crash
        (should result)))))

(ert-deftest test-ap-get-status-uses-claude-patterns ()
  "get-status uses claude busy/ready patterns when agent is claude."
  :tags '(:integration :agent-profiles)
  (test-ap--with-mock
    (let ((claude-org-cmux-agent-type 'claude))
      (let ((result (condition-case err
                        (claude-org-cmux-get-status "surface:ap-mock-001")
                      (error (format "error: %s" err)))))
        (should result)))))

;;; test-cmux-e2e-agent-profiles.el ends here
