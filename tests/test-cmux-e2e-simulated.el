;;; test-cmux-e2e-simulated.el --- E2E tests for cmux backend -*- lexical-binding: t -*-

;; Strategy: Mock ONLY the cmux CLI gateway (claude-org-cmux--call).
;; Everything else — org buffer, properties, dispatch, session lookup —
;; uses real code against real org buffers.
;;
;; Mirrors test-iterm2-e2e-simulated.el patterns for consistency.

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
  (literate-elisp-load (expand-file-name "claude-org-iterm2.org" project-root))
  (literate-elisp-load (expand-file-name "claude-org-cmux.org" project-root)))

(defvar test-cmux--project-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Project root directory.")

(defvar test-cmux--fixture-dir
  (expand-file-name "tests/fixtures/cmux/e2e/" test-cmux--project-root)
  "Directory containing E2E fixture data.")

;;; ============================================================================
;;; Mock Infrastructure
;;; ============================================================================

(defvar test-cmux--mock-calls nil
  "Alist of (subcommand . args) for each cmux CLI call in current test.")

(defvar test-cmux--mock-responses nil
  "Alist of (subcommand . response-string) for mock responses.")

(defvar test-cmux--mock-surface-id "surface:mock-001"
  "Mock surface ID returned by new-workspace / identify.")

(defun test-cmux--read-fixture (name)
  "Read fixture file NAME from the cmux e2e fixtures directory."
  (let ((path (expand-file-name name test-cmux--fixture-dir)))
    (with-temp-buffer
      (insert-file-contents path)
      (buffer-string))))

(defun test-cmux--mock-call (subcommand &rest args)
  "Mock implementation of `claude-org-cmux--call'.
Records the call and returns fixture-based responses."
  ;; Record the call
  (push (cons subcommand args) test-cmux--mock-calls)
  ;; Return appropriate response
  (let ((override (cdr (assoc subcommand test-cmux--mock-responses))))
    (cond
     (override override)
     ((string= subcommand "ping") "pong")
     ((string= subcommand "new-workspace") "OK workspace:mock-1")
     ((string= subcommand "list-pane-surfaces")
      (format "* %s  ~  [selected]" test-cmux--mock-surface-id))
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
      (test-cmux--read-fixture "capture-pane-ready.txt"))
     (t (format "mock-response-for-%s" subcommand)))))

(defun test-cmux--mock-calls-for (subcommand)
  "Return all recorded calls for SUBCOMMAND."
  (cl-remove-if-not (lambda (c) (string= (car c) subcommand))
                     test-cmux--mock-calls))

(defmacro test-cmux--with-mock (&rest body)
  "Execute BODY with cmux CLI gateway mocked."
  (declare (indent 0))
  `(let ((test-cmux--mock-calls nil)
         (test-cmux--mock-responses nil))
     (cl-letf (((symbol-function 'claude-org-cmux--call) #'test-cmux--mock-call))
       ,@body)))

;;; ============================================================================
;;; Org Buffer Helpers
;;; ============================================================================

(defvar test-cmux--org-content-basic
  "* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-session-001
:CUSTOM_ID: test-cmux-story
:END:

** Instruction 1
:PROPERTIES:
:CUSTOM_ID: test-cmux-instr-1
:END:

#+begin_src ai
What is 2+2?
#+end_src
"
  "Basic org content with one AI block for cmux tests.")

(defvar test-cmux--org-content-with-backend
  "* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-session-002
:CLAUDE_BACKEND: cmux
:CUSTOM_ID: test-cmux-story-backend
:END:

** Instruction 1
:PROPERTIES:
:CUSTOM_ID: test-cmux-instr-1b
:END:

#+begin_src ai
What is 2+2?
#+end_src
"
  "Org content with CLAUDE_BACKEND set to cmux.")

(defvar test-cmux--org-content-with-surface
  "* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-session-003
:CMUX_SURFACE_ID: surface:existing-123
:CUSTOM_ID: test-cmux-story-existing
:END:

** Instruction 1
:PROPERTIES:
:CUSTOM_ID: test-cmux-instr-1c
:END:

#+begin_src ai
Explain Emacs.
#+end_src
"
  "Org content with existing CMUX_SURFACE_ID.")

(defmacro test-cmux--with-org-buffer (content &rest body)
  "Create a temp org buffer with CONTENT and execute BODY.
Returns values from BODY. Cleans up buffer afterwards."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer "*test-cmux-org*"))
         (inhibit-message t))
     (unwind-protect
         (with-current-buffer buf
           (org-mode)
           (insert ,content)
           (goto-char (point-min))
           ;; Set buffer-file-name for property storage
           (setq buffer-file-name (make-temp-file "test-cmux-" nil ".org"))
           ;; Write initial content for save-buffer
           (write-region (point-min) (point-max) buffer-file-name nil 'silent)
           (set-buffer-modified-p nil)
           ,@body)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (when buffer-file-name
             (ignore-errors (delete-file buffer-file-name))))
         (kill-buffer buf)))))

(defun test-cmux--goto-ai-block ()
  "Move point into the first #+begin_src ai block."
  (goto-char (point-min))
  (re-search-forward "#\\+begin_src ai")
  (forward-line 1))

;;; ============================================================================
;;; Tests: CLI Gateway
;;; ============================================================================

(ert-deftest test-cmux-gateway-records-calls ()
  "Gateway records subcommand and args."
  (test-cmux--with-mock
    (test-cmux--mock-call "ping")
    (test-cmux--mock-call "send" "--surface" "s:1" "hello")
    (should (= 2 (length test-cmux--mock-calls)))
    (should (equal (caar test-cmux--mock-calls) "send"))
    (should (equal (cadr (car test-cmux--mock-calls)) "--surface"))))

(ert-deftest test-cmux-gateway-returns-fixture ()
  "Gateway returns fixture data for capture-pane."
  (test-cmux--with-mock
    (let ((result (test-cmux--mock-call "capture-pane")))
      (should (string-match-p "INSERT" result)))))

(ert-deftest test-cmux-gateway-override-responses ()
  "Custom mock responses override defaults."
  (test-cmux--with-mock
    (push '("ping" . "custom-pong") test-cmux--mock-responses)
    (should (equal "custom-pong" (test-cmux--mock-call "ping")))))

;;; ============================================================================
;;; Tests: Surface Ref Parsing
;;; ============================================================================

(ert-deftest test-cmux-parse-surface-ref-from-json ()
  "Parse surface ref from identify JSON output."
  (let ((json "{\n  \"focused\" : {\n    \"surface_ref\" : \"surface:1\"\n  }\n}"))
    (should (equal "surface:1" (claude-org-cmux--parse-surface-ref json)))))

(ert-deftest test-cmux-parse-surface-ref-from-new-workspace ()
  "Parse workspace ref from new-workspace output."
  (should (equal "workspace:3"
                 (claude-org-cmux--parse-surface-ref "OK workspace:3"))))

(ert-deftest test-cmux-parse-surface-ref-from-list-panes ()
  "Parse surface ref from list-pane-surfaces output."
  (should (equal "surface:5"
                 (claude-org-cmux--parse-surface-ref
                  "* surface:5  ~  [selected]"))))

(ert-deftest test-cmux-parse-surface-ref-clean ()
  "Already clean ref passes through."
  (should (equal "surface:1"
                 (claude-org-cmux--parse-surface-ref "surface:1"))))

;;; ============================================================================
;;; Tests: Session Property Lookup
;;; ============================================================================

(ert-deftest test-cmux-find-session-property ()
  "Can find CLAUDE_SESSION_ID from within AI block."
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (let ((sid (claude-org-cmux--find-session-property "CLAUDE_SESSION_ID")))
      (should (equal sid "test-cmux-session-001")))))

(ert-deftest test-cmux-find-session-property-missing ()
  "Returns nil for missing property."
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (should (null (claude-org-cmux--find-session-property "NONEXISTENT_PROP")))))

;;; ============================================================================
;;; Tests: Tab Title
;;; ============================================================================

(ert-deftest test-cmux-tab-title-format ()
  "Tab title contains session ID and a heading name."
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (let ((title (claude-org-cmux--tab-title)))
      ;; Must contain session ID
      (should (string-match-p "test-cmux-session-001" title))
      ;; Must contain some heading text (the heading that has the property)
      (should (string-match-p "\\[test-cmux-session-001\\]" title)))))

;;; ============================================================================
;;; Tests: Ensure Session
;;; ============================================================================

(ert-deftest test-cmux-ensure-session-new ()
  "Ensure-session creates new workspace when no CMUX_SURFACE_ID exists."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (let ((surface-id (claude-org-cmux--ensure-session)))
        ;; Should return the mock surface ID
        (should (equal surface-id test-cmux--mock-surface-id))
        ;; Should have called new-workspace
        (should (test-cmux--mock-calls-for "new-workspace"))
        ;; Should have stored CMUX_SURFACE_ID as org property
        (let ((stored (org-entry-get nil "CMUX_SURFACE_ID" t)))
          (should (equal stored test-cmux--mock-surface-id)))))))

(ert-deftest test-cmux-ensure-session-reuse ()
  "Ensure-session reuses existing surface when CMUX_SURFACE_ID exists and alive."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      (let ((surface-id (claude-org-cmux--ensure-session)))
        ;; Should return existing surface ID
        (should (equal surface-id "surface:existing-123"))
        ;; Should NOT have called new-workspace
        (should-not (test-cmux--mock-calls-for "new-workspace"))
        ;; Should have called capture-pane to check liveness
        (should (test-cmux--mock-calls-for "capture-pane"))))))

(ert-deftest test-cmux-ensure-session-relaunches-dead ()
  "Ensure-session relaunches when existing surface is dead."
  (test-cmux--with-mock
    (let ((ready-screen (test-cmux--read-fixture "capture-pane-ready.txt")))
      (cl-letf (((symbol-function 'claude-org-cmux--call)
                 (lambda (subcmd &rest args)
                   (push (cons subcmd args) test-cmux--mock-calls)
                   (cond
                    ;; capture-pane on dead surface → error
                    ((and (string= subcmd "capture-pane")
                          (member "surface:existing-123" args))
                     (error "cmux capture-pane failed: surface not found"))
                    ;; capture-pane on new surface → ready screen
                    ((string= subcmd "capture-pane") ready-screen)
                    ((string= subcmd "new-workspace") "OK workspace:mock-1")
                    ((string= subcmd "list-pane-surfaces")
                     (format "* %s  ~  [selected]" test-cmux--mock-surface-id))
                    (t "ok")))))
        (test-cmux--with-org-buffer test-cmux--org-content-with-surface
          (test-cmux--goto-ai-block)
          (let ((surface-id (claude-org-cmux--ensure-session)))
            ;; Should have launched new workspace
            (should (test-cmux--mock-calls-for "new-workspace"))
            ;; Should return new surface ID
            (should (equal surface-id test-cmux--mock-surface-id))))))))

;;; ============================================================================
;;; Tests: Status Detection
;;; ============================================================================

(ert-deftest test-cmux-status-ready-from-screen ()
  "Detects ready state from capture-pane output."
  (test-cmux--with-mock
    (push (cons "capture-pane"
                (test-cmux--read-fixture "capture-pane-ready.txt"))
          test-cmux--mock-responses)
    (let ((status (claude-org-cmux--get-status "test-sid" "surface:1")))
      (should (equal status "ready")))))

(ert-deftest test-cmux-status-busy-from-screen ()
  "Detects busy state from capture-pane output."
  (test-cmux--with-mock
    (push (cons "capture-pane"
                (test-cmux--read-fixture "capture-pane-busy.txt"))
          test-cmux--mock-responses)
    (let ((status (claude-org-cmux--get-status "test-sid" "surface:1")))
      (should (equal status "busy")))))

(ert-deftest test-cmux-status-from-hook-file ()
  "Uses hook file status when available."
  (let* ((dir "/tmp/claude-agent-status")
         (file (expand-file-name "test-hook-sid" dir)))
    (unwind-protect
        (progn
          (make-directory dir t)
          (with-temp-file file (insert "ready"))
          (let ((status (claude-org-cmux--get-status "test-hook-sid" "surface:1")))
            (should (equal status "ready"))))
      (ignore-errors (delete-file file)))))

;;; ============================================================================
;;; Tests: Execute AI Block
;;; ============================================================================

(ert-deftest test-cmux-execute-sends-prompt ()
  "Execute sends prompt text to cmux via send + enter."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (claude-org-cmux--execute-ai-block)
      ;; Should have sent text via "send" command
      (let ((send-calls (test-cmux--mock-calls-for "send")))
        (should send-calls)
        (should (member "--surface" (cdar send-calls))))
      ;; Should have sent Enter to submit
      (should (test-cmux--mock-calls-for "send-key")))))

(ert-deftest test-cmux-execute-registers-query ()
  "Execute registers query in active-queries."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (let ((initial-count (hash-table-count claude-agent--active-queries)))
        (claude-org-cmux--execute-ai-block)
        ;; Should have registered one new query
        (should (> (hash-table-count claude-agent--active-queries) initial-count))
        ;; Clean up: unregister
        (let ((req-id (claude-org-cmux--read-request-id "test-cmux-session-001")))
          (when req-id
            (claude-agent--unregister-query req-id)))))))

(ert-deftest test-cmux-execute-writes-from-emacs-flag ()
  "Execute writes from-emacs flag file."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (claude-org-cmux--execute-ai-block)
      ;; Check that flag file was written
      (let ((flag-path (expand-file-name
                        "test-cmux-session-001.from-emacs"
                        "/tmp/claude-agent-status")))
        (should (file-exists-p flag-path))
        ;; Clean up
        (delete-file flag-path)
        (let ((req-id (claude-org-cmux--read-request-id "test-cmux-session-001")))
          (when req-id
            (claude-agent--unregister-query req-id)
            (delete-file (expand-file-name
                          "test-cmux-session-001.request-id"
                          "/tmp/claude-agent-status")
                         t)))))))

(ert-deftest test-cmux-execute-rejects-busy ()
  "Execute errors when Claude is busy."
  (test-cmux--with-mock
    ;; Make capture-pane return busy content
    (push (cons "capture-pane"
                (test-cmux--read-fixture "capture-pane-busy.txt"))
          test-cmux--mock-responses)
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      (should-error (claude-org-cmux--execute-ai-block)
                    :type 'user-error))))

;;; ============================================================================
;;; Tests: Backend Dispatch
;;; ============================================================================

(ert-deftest test-cmux-dispatch-from-property ()
  "CLAUDE_BACKEND=cmux dispatches to cmux backend."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-backend
      (test-cmux--goto-ai-block)
      ;; Verify the property is accessible
      (let ((backend (claude-org--get-org-property "CLAUDE_BACKEND" t)))
        (should (equal backend "cmux")))
      ;; Execute should dispatch to cmux
      (claude-org-execute)
      ;; Verify cmux calls were made (new-workspace or identify)
      (should (or (test-cmux--mock-calls-for "new-workspace")
                  (test-cmux--mock-calls-for "identify")))
      ;; Verify prompt was sent via send command
      (should (test-cmux--mock-calls-for "send"))
      ;; Clean up active query
      (let ((req-id (claude-org-cmux--read-request-id "test-cmux-session-002")))
        (when req-id
          (claude-agent--unregister-query req-id)
          (ignore-errors
            (delete-file (expand-file-name
                          "test-cmux-session-002.request-id"
                          "/tmp/claude-agent-status")))
          (ignore-errors
            (delete-file (expand-file-name
                          "test-cmux-session-002.from-emacs"
                          "/tmp/claude-agent-status"))))))))

;;; ============================================================================
;;; Tests: Query Completion
;;; ============================================================================

(ert-deftest test-cmux-query-completed ()
  "Query completion unregisters from active queries."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (claude-org-cmux--execute-ai-block)
      (let ((req-id (claude-org-cmux--read-request-id "test-cmux-session-001")))
        (should req-id)
        ;; Verify query is registered
        (should (claude-agent--get-active-query req-id))
        ;; Complete the query
        (claude-org-cmux--query-completed "test-cmux-session-001")
        ;; Should be unregistered
        (should-not (claude-agent--get-active-query req-id))
        ;; Clean up files
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-001.request-id"
                        "/tmp/claude-agent-status")))
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-001.from-emacs"
                        "/tmp/claude-agent-status")))))))

;;; ============================================================================
;;; Tests: Cancel
;;; ============================================================================

(ert-deftest test-cmux-cancel-sends-escape ()
  "Cancel sends escape key to cmux surface."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      (claude-org-cmux-cancel)
      (let ((key-calls (test-cmux--mock-calls-for "send-key")))
        (should key-calls)
        (should (member "escape" (cdar key-calls)))))))

(ert-deftest test-cmux-cancel-errors-without-surface ()
  "Cancel errors when no CMUX_SURFACE_ID is set."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (should-error (claude-org-cmux-cancel) :type 'user-error))))

;;; ============================================================================
;;; Tests: Launch Command Building
;;; ============================================================================

(ert-deftest test-cmux-build-launch-cmd-claude-sdd ()
  "Build launch command for claude-sdd mode."
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (let ((claude-org-cmux-launch-command 'claude-sdd)
          (claude-org-cmux-sdd-script "/path/to/claude-sdd"))
      (let ((cmd (claude-org-cmux--build-launch-command
                  "/tmp/test.org" "sid-001" "/tmp")))
        (should (string-match-p "/path/to/claude-sdd" cmd))
        (should (string-match-p "sid-001" cmd))))))

(ert-deftest test-cmux-build-launch-cmd-custom ()
  "Build launch command for custom string mode."
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (let ((claude-org-cmux-launch-command "my-custom-command"))
      (let ((cmd (claude-org-cmux--build-launch-command
                  "/tmp/test.org" "sid-001" "/tmp")))
        (should (equal cmd "my-custom-command"))))))

;;; ============================================================================
;;; Tests: Sidebar Feedback (cmux-specific features)
;;; ============================================================================

(ert-deftest test-cmux-sidebar-set-status ()
  "set-status calls cmux CLI."
  (test-cmux--with-mock
    (claude-org-cmux-set-status "task" "Running...")
    (let ((calls (test-cmux--mock-calls-for "set-status")))
      (should calls)
      (should (member "task" (cdar calls)))
      (should (member "Running..." (cdar calls))))))

(ert-deftest test-cmux-sidebar-notify ()
  "notify calls cmux CLI."
  (test-cmux--with-mock
    (claude-org-cmux-notify "Done" "Query complete")
    (let ((calls (test-cmux--mock-calls-for "notify")))
      (should calls)
      (should (member "--title" (cdar calls)))
      (should (member "Done" (cdar calls))))))

;;; ============================================================================
;;; Tests: CLI Session Isolation
;;; ============================================================================

(defvar test-cmux--org-two-stories
  "* Story A
:PROPERTIES:
:CLAUDE_SESSION_ID: sdd-story-a
:CLAUDE_BACKEND: cmux
:CUSTOM_ID: test-story-a
:CLAUDE_CLI_SESSION: uuid-story-a-cli
:END:

** Instruction 1 :claude_chat:
:PROPERTIES:
:CUSTOM_ID: test-instr-a1
:END:

#+begin_src ai
Query A
#+end_src

* Story B
:PROPERTIES:
:CLAUDE_SESSION_ID: sdd-story-b
:CLAUDE_BACKEND: cmux
:CUSTOM_ID: test-story-b
:END:

** Instruction 1 :claude_chat:
:PROPERTIES:
:CUSTOM_ID: test-instr-b1
:END:

#+begin_src ai
Query B
#+end_src
"
  "Two sibling stories — A has CLI session, B does not.")

(defvar test-cmux--org-file-level-cli
  "#+PROPERTY: CLAUDE_CLI_SESSION stale-file-level-uuid
* Story C
:PROPERTIES:
:CLAUDE_SESSION_ID: sdd-story-c
:CLAUDE_BACKEND: cmux
:CUSTOM_ID: test-story-c
:END:

** Instruction 1 :claude_chat:
:PROPERTIES:
:CUSTOM_ID: test-instr-c1
:END:

#+begin_src ai
Query C
#+end_src
"
  "Story with file-level CLAUDE_CLI_SESSION — the contamination case.")

(ert-deftest test-cmux-build-launch-no-cli-session ()
  "build-launch-command does not crash when CLAUDE_CLI_SESSION is missing."
  :tags '(:unit :stable)
  (test-cmux--with-org-buffer test-cmux--org-two-stories
    (goto-char (point-min))
    (re-search-forward "Query B")
    (let ((cmd (claude-org-cmux--build-launch-command
                (buffer-file-name) "sdd-story-b" default-directory)))
      (should (stringp cmd))
      (should-not (string-match-p "--resume" cmd)))))

(ert-deftest test-cmux-build-launch-with-cli-session ()
  "build-launch-command includes --resume when CLAUDE_CLI_SESSION is on the session heading."
  :tags '(:unit :stable)
  (test-cmux--with-org-buffer test-cmux--org-two-stories
    ;; Position at Story A's AI block — property is on the parent heading
    (goto-char (point-min))
    (re-search-forward "Query A")
    (let ((cmd (claude-org-cmux--build-launch-command
                (buffer-file-name) "sdd-story-a" default-directory)))
      (should (stringp cmd))
      (should (string-match-p "--resume" cmd))
      (should (string-match-p "uuid-story-a-cli" cmd)))))

(ert-deftest test-cmux-build-launch-ignores-file-level-cli-session ()
  "build-launch-command must NOT use file-level #+PROPERTY: CLAUDE_CLI_SESSION.
Regression: stale file-level property caused all new stories to resume
the same session."
  :tags '(:unit :stable)
  (test-cmux--with-org-buffer test-cmux--org-file-level-cli
    (goto-char (point-min))
    (re-search-forward "Query C")
    (let ((cmd (claude-org-cmux--build-launch-command
                (buffer-file-name) "sdd-story-c" default-directory)))
      (should (stringp cmd))
      ;; Must NOT contain --resume from the file-level property
      (should-not (string-match-p "--resume" cmd)))))

(ert-deftest test-cmux-cli-session-no-cross-contamination ()
  "Story B must not inherit Story A's CLAUDE_CLI_SESSION."
  :tags '(:unit :stable)
  (test-cmux--with-org-buffer test-cmux--org-two-stories
    (goto-char (point-min))
    (re-search-forward "Query B")
    (should-not (org-entry-get nil "CLAUDE_CLI_SESSION" nil))))

;;; ============================================================================
;;; Tests: Permission Routing (P0 fix)
;;; ============================================================================

(ert-deftest test-cmux-permission-needed-calls-select-workspace ()
  "claude-org-cmux--permission-needed focuses the cmux workspace and adds alert."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (puthash "sdd-perm-test" "mock-session-key"
             claude-org-cmux--sdd-to-session-key)
    (puthash "sdd-perm-test" "mock-ws-id"
             claude-org-cmux--sdd-to-workspace)
    (let ((saved-alerts claude-agent-pending-alerts))
      (unwind-protect
          (progn
            (claude-org-cmux--permission-needed "sdd-perm-test" "Bash")
            ;; Should have called select-workspace to focus the terminal
            (let ((calls (test-cmux--mock-calls-for "select-workspace")))
              (should calls)
              (should (member "mock-ws-id" (cdar calls))))
            ;; Should be registered as a mode-line alert
            (should (assq (intern "sdd-perm-test") claude-agent-pending-alerts)))
        ;; Cleanup
        (setq claude-agent-pending-alerts saved-alerts)
        (remhash "sdd-perm-test" claude-org-cmux--sdd-to-session-key)
        (remhash "sdd-perm-test" claude-org-cmux--sdd-to-workspace)))))

(ert-deftest test-cmux-permission-resolved-clears-state ()
  "claude-org-cmux--permission-resolved clears pending alert."
  :tags '(:unit :stable)
  (let ((saved-alerts claude-agent-pending-alerts))
    ;; Add a pending alert
    (claude-agent-add-alert (intern "sdd-resolve-test") :label "test")
    (unwind-protect
        (progn
          (claude-org-cmux--permission-resolved "sdd-resolve-test")
          (should-not (assq (intern "sdd-resolve-test") claude-agent-pending-alerts)))
      (setq claude-agent-pending-alerts saved-alerts))))

(ert-deftest test-cmux-terminal-permission-routes-to-cmux ()
  "Terminal permission dispatcher routes cmux sessions to cmux handler."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (puthash "sdd-route-test" "mock-key"
             claude-org-cmux--sdd-to-session-key)
    (puthash "sdd-route-test" "mock-ws"
             claude-org-cmux--sdd-to-workspace)
    (let ((saved-alerts claude-agent-pending-alerts))
      (unwind-protect
          (progn
            (claude-org--terminal-permission-needed "sdd-route-test" "Edit")
            ;; Should have used cmux path (select-workspace called)
            (should (test-cmux--mock-calls-for "select-workspace"))
            ;; Should have registered alert via cmux handler
            (should (assq (intern "sdd-route-test") claude-agent-pending-alerts)))
        (setq claude-agent-pending-alerts saved-alerts)
        (remhash "sdd-route-test" claude-org-cmux--sdd-to-session-key)
        (remhash "sdd-route-test" claude-org-cmux--sdd-to-workspace)))))

;;; ============================================================================
;;; Tests: Session Recovery (P1)
;;; ============================================================================

(ert-deftest test-cmux-recover-session-from-org-buffer ()
  "Session recovery finds CMUX_SURFACE_ID from org buffer properties."
  :tags '(:unit :stable)
  ;; Use file-backed buffer with claude-org-mode (recovery checks this)
  (let ((file (make-temp-file "test-recover-" nil ".org")))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (with-current-buffer buf
            (org-mode)
            (let ((claude-org-auto-start-mcp-server nil))
              (claude-org-mode 1))
            (insert test-cmux--org-content-with-surface)
            (save-buffer))
          ;; Clear hash tables to simulate Emacs restart
          (remhash "test-cmux-session-003" claude-org-cmux--sdd-to-session-key)
          (remhash "test-cmux-session-003" claude-org-cmux--sdd-to-surface)
          ;; Try recovery
          (let ((result (claude-org-cmux--recover-session "test-cmux-session-003")))
            (should result)
            (should (gethash "test-cmux-session-003" claude-org-cmux--sdd-to-session-key))
            (should (equal "surface:existing-123"
                           (gethash "test-cmux-session-003" claude-org-cmux--sdd-to-surface))))
          ;; Cleanup
          (remhash "test-cmux-session-003" claude-org-cmux--sdd-to-session-key)
          (remhash "test-cmux-session-003" claude-org-cmux--sdd-to-surface)
          (kill-buffer buf))
      (delete-file file))))

(ert-deftest test-cmux-recover-session-not-found ()
  "Session recovery returns nil for unknown session IDs."
  :tags '(:unit :stable)
  (should-not (claude-org-cmux--recover-session "nonexistent-session-999")))

;;; ============================================================================
;;; Tests: Focus Terminal (P1)
;;; ============================================================================

(defvar test-cmux--org-content-with-workspace
  "* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-session-focus
:CMUX_SURFACE_ID: surface:focus-1
:CMUX_WORKSPACE_ID: workspace:focus-99
:CUSTOM_ID: test-cmux-story-focus
:END:

** Instruction 1
:PROPERTIES:
:CUSTOM_ID: test-cmux-focus-instr
:END:

#+begin_src ai
focus test
#+end_src
"
  "Org content with both CMUX_SURFACE_ID and CMUX_WORKSPACE_ID.")

(ert-deftest test-cmux-focus-terminal ()
  "Focus terminal calls select-workspace with the correct workspace ID."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-workspace
      (goto-char (point-min))
      (re-search-forward "focus test")
      (claude-org-cmux-focus-terminal)
      (let ((calls (test-cmux--mock-calls-for "select-workspace")))
        (should calls)
        (should (member "workspace:focus-99" (cdar calls)))))))

(provide 'test-cmux-e2e-simulated)

;;; test-cmux-e2e-simulated.el ends here
