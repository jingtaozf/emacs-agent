;;; test-cmux-e2e-simulated.el --- E2E tests for cmux backend -*- lexical-binding: t -*-

;; Strategy: Mock ONLY the cmux CLI gateway (claude-org-cmux--call).
;; Everything else — org buffer, properties, dispatch, session lookup —
;; uses real code against real org buffers.
;;
;; Uses real org buffers with mock cmux CLI calls.

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
     ((string= subcommand "tree")
      "workspace workspace:mock-1 \"Test\"\n  pane pane:1\n    surface surface:existing-123 [terminal]")
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
:CMUX_WORKSPACE_ID: mock-workspace-uuid-123
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
  "Org content with existing CMUX_SURFACE_ID and CMUX_WORKSPACE_ID.")

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
    (let ((sid (claude-org-terminal--find-session-property "CLAUDE_SESSION_ID")))
      (should (equal sid "test-cmux-session-001")))))

(ert-deftest test-cmux-find-session-property-missing ()
  "Returns nil for missing property."
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (should (null (claude-org-terminal--find-session-property "NONEXISTENT_PROP")))))

;;; ============================================================================
;;; Tests: Tab Title
;;; ============================================================================

(ert-deftest test-cmux-tab-title-format ()
  "Tab title uses ACTIVE_STORY or heading name (no session ID suffix)."
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (let ((title (claude-org-terminal--tab-title)))
      ;; Must contain heading text (fallback when no ACTIVE_STORY)
      (should (stringp title))
      (should (> (length title) 0))
      ;; No session ID suffix in new format
      (should-not (string-match-p "\\[" title)))))

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
        ;; Should have called tree to check workspace liveness
        (should (test-cmux--mock-calls-for "tree"))))))

(ert-deftest test-cmux-ensure-session-relaunches-dead ()
  "Ensure-session relaunches when existing surface is dead."
  (test-cmux--with-mock
    (let ((ready-screen (test-cmux--read-fixture "capture-pane-ready.txt")))
      (cl-letf (((symbol-function 'claude-org-cmux--call)
                 (lambda (subcmd &rest args)
                   (push (cons subcmd args) test-cmux--mock-calls)
                   (cond
                    ;; tree on dead workspace UUID → error
                    ((and (string= subcmd "tree")
                          (member "mock-workspace-uuid-123" args))
                     (error "cmux tree failed: invalid workspace handle"))
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
        (let ((req-id (claude-org-terminal--read-request-id "test-cmux-session-001")))
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
        (let ((req-id (claude-org-terminal--read-request-id "test-cmux-session-001")))
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
      (let ((req-id (claude-org-terminal--read-request-id "test-cmux-session-002")))
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
      (let ((req-id (claude-org-terminal--read-request-id "test-cmux-session-001")))
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

(ert-deftest test-cmux-execute-sets-backend ()
  "Execute sets :backend to \"cmux\" on session so generic cancel can dispatch."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (claude-org-cmux--execute-ai-block)
      (let* ((session-key (claude-org--current-session-key))
             (backend (claude-org--session-get session-key :backend)))
        (should (equal backend "cmux"))
        ;; Clean up
        (let ((req-id (claude-org-terminal--read-request-id "test-cmux-session-001")))
          (when req-id
            (claude-agent--unregister-query req-id)))))))

(ert-deftest test-cmux-generic-cancel-dispatches-to-cmux ()
  "Generic claude-org-cancel dispatches to claude-org-cmux-cancel for cmux sessions."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      ;; Set up session state as if execute had run
      (let ((session-key (claude-org--current-session-key)))
        (claude-org--session-put session-key :backend "cmux")
        (claude-org--session-put session-key :busy t)
        ;; Mock cleanup functions
        (cl-letf (((symbol-function 'claude-org--cleanup-session) #'ignore)
                  ((symbol-function 'claude-org--queue-count) (lambda (_) 0)))
          (claude-org-cancel)
          ;; Should have sent escape via cmux cancel
          (let ((key-calls (test-cmux--mock-calls-for "send-key")))
            (should key-calls)
            (should (member "escape" (cdar key-calls)))))))))

(ert-deftest test-cmux-generic-cancel-noop-when-not-busy ()
  "Generic cancel does not error when session has :backend but is not :busy."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      (let ((session-key (claude-org--current-session-key)))
        (claude-org--session-put session-key :backend "cmux")
        ;; :busy is NOT set -- cancel should be a no-op message, not an error
        (claude-org-cancel)
        ;; No send-key calls should have been made
        (let ((key-calls (test-cmux--mock-calls-for "send-key")))
          (should-not key-calls))))))

;;; ============================================================================
;;; Tests: Launch Command Building
;;; ============================================================================

(ert-deftest test-cmux-build-launch-cmd-claude-workspace ()
  "Build launch command for claude-workspace mode."
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (let ((claude-org-cmux-launch-command 'claude-workspace)
          (claude-org-cmux-workspace-script "/path/to/claude-workspace"))
      (let ((cmd (claude-org-cmux--build-launch-command
                  "/tmp/test.org" "sid-001" "/tmp")))
        (should (string-match-p "/path/to/claude-workspace" cmd))
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
             claude-org-terminal--workspace-to-session-key)
    (puthash "sdd-perm-test" "mock-ws-id"
             claude-org-cmux--workspace-to-cmux-id)
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
        (remhash "sdd-perm-test" claude-org-terminal--workspace-to-session-key)
        (remhash "sdd-perm-test" claude-org-cmux--workspace-to-cmux-id)))))

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
             claude-org-terminal--workspace-to-session-key)
    (puthash "sdd-route-test" "mock-ws"
             claude-org-cmux--workspace-to-cmux-id)
    (let ((saved-alerts claude-agent-pending-alerts))
      (unwind-protect
          (progn
            (claude-org--terminal-permission-needed "sdd-route-test" "Edit")
            ;; Should have used cmux path (select-workspace called)
            (should (test-cmux--mock-calls-for "select-workspace"))
            ;; Should have registered alert via cmux handler
            (should (assq (intern "sdd-route-test") claude-agent-pending-alerts)))
        (setq claude-agent-pending-alerts saved-alerts)
        (remhash "sdd-route-test" claude-org-terminal--workspace-to-session-key)
        (remhash "sdd-route-test" claude-org-cmux--workspace-to-cmux-id)))))

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
          (remhash "test-cmux-session-003" claude-org-terminal--workspace-to-session-key)
          (remhash "test-cmux-session-003" claude-org-cmux--workspace-to-surface)
          ;; Try recovery
          (let ((result (claude-org-cmux--recover-session "test-cmux-session-003")))
            (should result)
            (should (gethash "test-cmux-session-003" claude-org-terminal--workspace-to-session-key))
            (should (equal "surface:existing-123"
                           (gethash "test-cmux-session-003" claude-org-cmux--workspace-to-surface))))
          ;; Cleanup
          (remhash "test-cmux-session-003" claude-org-terminal--workspace-to-session-key)
          (remhash "test-cmux-session-003" claude-org-cmux--workspace-to-surface)
          (kill-buffer buf))
      (delete-file file))))

(ert-deftest test-cmux-recover-session-not-found ()
  "Session recovery returns nil for unknown session IDs."
  :tags '(:unit :stable)
  (should-not (claude-org-cmux--recover-session "nonexistent-session-999")))

;;; ============================================================================
;;; Tests: Focus Terminal (P1)
;;; ============================================================================

;;; ============================================================================
;;; Tests: File-level CLAUDE_BACKEND dispatch (T52)
;;; ============================================================================

(defvar test-cmux--org-file-level-backend
  "#+PROPERTY: CLAUDE_BACKEND cmux
* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-session-file-backend
:CUSTOM_ID: test-cmux-file-backend-story
:END:

** Instruction 1
:PROPERTIES:
:CUSTOM_ID: test-cmux-file-backend-instr-1
:END:

#+begin_src ai
What is 3+3?
#+end_src
"
  "Org content with file-level CLAUDE_BACKEND (no section-level property).")

(ert-deftest test-cmux-file-level-backend-dispatch ()
  "File-level #+PROPERTY: CLAUDE_BACKEND cmux dispatches to cmux backend.
T52: Regression — section-level CLAUDE_BACKEND was always tested, but
file-level #+PROPERTY must also dispatch correctly."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-file-level-backend
      (test-cmux--goto-ai-block)
      ;; Verify the file-level property is accessible
      (let ((backend (claude-org--get-org-property "CLAUDE_BACKEND" t)))
        (should (equal backend "cmux")))
      ;; Execute should dispatch to cmux backend
      (claude-org-execute)
      ;; Verify cmux calls were made
      (should (or (test-cmux--mock-calls-for "new-workspace")
                  (test-cmux--mock-calls-for "identify")))
      ;; Verify prompt was sent
      (should (test-cmux--mock-calls-for "send"))
      ;; Clean up
      (let ((req-id (claude-org-terminal--read-request-id "test-cmux-session-file-backend")))
        (when req-id
          (claude-agent--unregister-query req-id)
          (ignore-errors
            (delete-file (expand-file-name
                          "test-cmux-session-file-backend.request-id"
                          "/tmp/claude-agent-status")))
          (ignore-errors
            (delete-file (expand-file-name
                          "test-cmux-session-file-backend.from-emacs"
                          "/tmp/claude-agent-status"))))))))

(ert-deftest test-cmux-file-level-backend-sets-backend-property ()
  "File-level CLAUDE_BACKEND=cmux sets :backend on session after execute.
T52b: Ensures generic cancel works for file-level backend dispatch."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-file-level-backend
      (test-cmux--goto-ai-block)
      (claude-org-execute)
      (let* ((session-key (claude-org--current-session-key))
             (backend (claude-org--session-get session-key :backend)))
        (should (equal backend "cmux"))
        ;; Clean up
        (let ((req-id (claude-org-terminal--read-request-id "test-cmux-session-file-backend")))
          (when req-id
            (claude-agent--unregister-query req-id)
            (ignore-errors
              (delete-file (expand-file-name
                            "test-cmux-session-file-backend.request-id"
                            "/tmp/claude-agent-status")))
            (ignore-errors
              (delete-file (expand-file-name
                            "test-cmux-session-file-backend.from-emacs"
                            "/tmp/claude-agent-status")))))))))

;;; ============================================================================
;;; Tests: Ensure-session hash table restore on reconnect (T53)
;;; ============================================================================

(ert-deftest test-cmux-ensure-session-restores-hash-tables ()
  "Ensure-session restores hash table mappings when workspace is alive.
T53: Simulates Emacs restart — hash tables cleared but org properties intact.
On reconnect, ensure-session must repopulate all three hash tables."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      ;; Verify properties exist
      (should (equal "surface:existing-123"
                     (org-entry-get nil "CMUX_SURFACE_ID" t)))
      (should (equal "mock-workspace-uuid-123"
                     (org-entry-get nil "CMUX_WORKSPACE_ID" t)))
      ;; Clear all hash tables to simulate Emacs restart
      (remhash "test-cmux-session-003" claude-org-terminal--workspace-to-session-key)
      (remhash "test-cmux-session-003" claude-org-cmux--workspace-to-surface)
      (remhash "test-cmux-session-003" claude-org-cmux--workspace-to-cmux-id)
      ;; Verify cleared
      (should-not (gethash "test-cmux-session-003" claude-org-terminal--workspace-to-session-key))
      (should-not (gethash "test-cmux-session-003" claude-org-cmux--workspace-to-surface))
      (should-not (gethash "test-cmux-session-003" claude-org-cmux--workspace-to-cmux-id))
      ;; Call ensure-session — should restore mappings from org properties
      (let ((surface (claude-org-cmux--ensure-session)))
        (should (equal surface "surface:existing-123"))
        ;; All three hash tables should be repopulated
        (should (gethash "test-cmux-session-003" claude-org-terminal--workspace-to-session-key))
        (should (equal "surface:existing-123"
                       (gethash "test-cmux-session-003" claude-org-cmux--workspace-to-surface)))
        (should (equal "mock-workspace-uuid-123"
                       (gethash "test-cmux-session-003" claude-org-cmux--workspace-to-cmux-id)))))))

;;; ============================================================================
;;; Tests: Permission mode display with file-level property (T54)
;;; ============================================================================

(defvar test-cmux--org-file-level-permission
  "#+PROPERTY: CLAUDE_PERMISSION_MODE bypass
#+PROPERTY: CLAUDE_BACKEND cmux
* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-session-perm
:CUSTOM_ID: test-cmux-perm-story
:END:

** Instruction 1
:PROPERTIES:
:CUSTOM_ID: test-cmux-perm-instr-1
:END:

#+begin_src ai
What is 4+4?
#+end_src
"
  "Org content with file-level CLAUDE_PERMISSION_MODE bypass.")

(defvar test-cmux--org-section-override-permission
  "#+PROPERTY: CLAUDE_PERMISSION_MODE bypass
#+PROPERTY: CLAUDE_BACKEND cmux
* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-session-perm-override
:CLAUDE_PERMISSION_MODE: readonly
:CUSTOM_ID: test-cmux-perm-override-story
:END:

** Instruction 1
:PROPERTIES:
:CUSTOM_ID: test-cmux-perm-override-instr-1
:END:

#+begin_src ai
What is 5+5?
#+end_src
"
  "Org content where section-level permission overrides file-level.")

(ert-deftest test-cmux-permission-mode-from-file-level ()
  "Permission mode reads file-level #+PROPERTY: CLAUDE_PERMISSION_MODE.
T54: Ensures cmux sessions show correct permission mode in header-line
when mode is set at file level."
  :tags '(:unit :stable)
  (test-cmux--with-org-buffer test-cmux--org-file-level-permission
    (test-cmux--goto-ai-block)
    ;; Should read file-level permission
    (should (equal "bypass" (claude-org--get-permission-mode-property)))
    (should (equal "BP" (claude-org--permission-mode-short)))
    (should (equal "bypassPermissions" (claude-org--get-permission-mode)))))

(ert-deftest test-cmux-permission-section-overrides-file ()
  "Section-level CLAUDE_PERMISSION_MODE overrides file-level.
T54b: Org inheritance — section property takes priority over #+PROPERTY."
  :tags '(:unit :stable)
  (test-cmux--with-org-buffer test-cmux--org-section-override-permission
    (test-cmux--goto-ai-block)
    ;; Section-level readonly should override file-level bypass
    (should (equal "readonly" (claude-org--get-permission-mode-property)))
    (should (equal "RO" (claude-org--permission-mode-short)))
    (should (equal "default" (claude-org--get-permission-mode)))))

;;; ============================================================================
;;; Tests: Archive Workflow (T55)
;;; ============================================================================

(defvar test-cmux--org-archive-workflow
  "* Test Workspace
:PROPERTIES:
:CLAUDE_SESSION_ID: sdd-archive-test
:CLAUDE_CLI_SESSION: old-session-uuid-123
:CMUX_WORKSPACE: test-archive
:CUSTOM_ID: test-archive-ws
:END:

** Test Story
:PROPERTIES:
:CUSTOM_ID: test-archive-story
:END:

*** System Prompt :system_prompt:
:PROPERTIES:
:CUSTOM_ID: test-archive-sysprompt
:END:

You are a test assistant.

*** Workflow :sdd:
:PROPERTIES:
:CUSTOM_ID: test-archive-workflow
:END:

**** Instruction 1 :claude_chat:
:PROPERTIES:
:CUSTOM_ID: test-archive-instr-1
:END:

#+begin_src ai
What is 2+2?
#+end_src

**** Response 1 :ai_output:
:PROPERTIES:
:QUERY_ID: test-q-archive
:END:

4
"
  "Org content for archive-workflow test with CLI session and response.")

(ert-deftest test-cmux-archive-workflow-clears-cli-session ()
  "Archive-workflow clears CLAUDE_CLI_SESSION on workspace heading.
T55: When archiving a workflow, the CLI session must be cleared so the
next terminal launch starts a fresh conversation. Verifies the archive
function removes CLAUDE_CLI_SESSION from the workspace heading."
  :tags '(:unit :stable)
  (test-cmux--with-org-buffer test-cmux--org-archive-workflow
    ;; Verify CLI session exists before archive
    (goto-char (point-min))
    (re-search-forward ":CLAUDE_SESSION_ID: sdd-archive-test")
    (org-back-to-heading t)
    (should (equal "old-session-uuid-123"
                   (org-entry-get nil "CLAUDE_CLI_SESSION")))
    ;; Navigate into the workflow (archive-workflow needs point inside workspace)
    (goto-char (point-min))
    (re-search-forward "What is 2\\+2")
    ;; Mock org-archive-subtree to avoid actually archiving
    (cl-letf (((symbol-function 'org-archive-subtree)
               (lambda ()
                 ;; Simulate: delete the workflow subtree at point
                 (let ((beg (save-excursion (org-back-to-heading t) (point)))
                       (end (save-excursion (org-end-of-subtree t t) (point))))
                   (delete-region beg end)))))
      (claude-org-workspace-archive-workflow))
    ;; CLI session should be cleared
    (goto-char (point-min))
    (re-search-forward ":CLAUDE_SESSION_ID: sdd-archive-test")
    (org-back-to-heading t)
    (should-not (org-entry-get nil "CLAUDE_CLI_SESSION"))))

(ert-deftest test-cmux-archive-workflow-creates-fresh-workflow ()
  "Archive-workflow inserts a new Workflow section with empty AI block.
T55b: After archiving, a fresh Workflow heading with :sdd: tag and an
empty Instruction 1 AI block must be present at the correct level."
  :tags '(:unit :stable)
  (test-cmux--with-org-buffer test-cmux--org-archive-workflow
    ;; Navigate into the workflow
    (goto-char (point-min))
    (re-search-forward "What is 2\\+2")
    ;; Mock org-archive-subtree
    (cl-letf (((symbol-function 'org-archive-subtree)
               (lambda ()
                 (let ((beg (save-excursion (org-back-to-heading t) (point)))
                       (end (save-excursion (org-end-of-subtree t t) (point))))
                   (delete-region beg end)))))
      (claude-org-workspace-archive-workflow))
    ;; Verify new Workflow heading exists with :sdd: tag
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\*\\* Workflow.*:sdd:" nil t))
    ;; Verify new Workflow has CUSTOM_ID
    (org-back-to-heading t)
    (should (org-entry-get nil "CUSTOM_ID"))
    ;; Verify new Instruction 1 with AI block
    (should (re-search-forward "Instruction 1" nil t))
    (should (re-search-forward "#\\+begin_src ai" nil t))
    ;; Verify old response is gone (it was in the archived subtree)
    (goto-char (point-min))
    (should-not (re-search-forward "Response 1.*:ai_output:" nil t))))

;;; ============================================================================
;;; Tests: Loop Cancel Guard (T56)
;;; ============================================================================

(ert-deftest test-cmux-loop-cancel-guard-skips-iteration ()
  "Cancelled session's loop iteration is skipped.
T56: When a loop session is cancelled between iterations, the next
execute-loop-iteration call should silently return nil, not execute.
Guards against firing queued timers after user cancels."
  :tags '(:unit :stable)
  (let* ((buf (generate-new-buffer "*test-loop-cancel*"))
         (session-key nil)
         (send-called nil))
    (unwind-protect
        (with-current-buffer buf
          (org-mode)
          (setq buffer-file-name (make-temp-file "test-loop-cancel-" nil ".org"))
          (insert "* Test\n:PROPERTIES:\n:CUSTOM_ID: test-lc\n:END:\n\n")
          (insert "** Instruction 1 :claude_chat:\n\n")
          (insert "#+begin_src ai :loop 3\ntest\n#+end_src\n")
          (write-region (point-min) (point-max) buffer-file-name nil 'silent)
          (set-buffer-modified-p nil)

          (setq session-key (concat buffer-file-name "::test-lc"))
          ;; Set up loop state as if iteration 1 completed
          (claude-org--session-put session-key :loop-current 2)
          (claude-org--session-put session-key :loop-max 3)
          (claude-org--session-put session-key :marker (point-marker))
          (claude-org--session-put session-key :original-prompt "test")
          (claude-org--session-put session-key :instruction-num 1)
          (claude-org--session-put session-key :custom-id "test-lc")
          (claude-org--session-put session-key :busy nil)

          ;; Simulate: session was cancelled
          (cl-letf (((symbol-function 'claude-org--get-exec-status-for-session)
                     (lambda (&rest _) "cancelled"))
                    ((symbol-function 'claude-org--send-request)
                     (lambda (&rest _) (setq send-called t)))
                    ((symbol-function 'claude-org--start-spinner) #'ignore)
                    ((symbol-function 'claude-org--set-exec-status) #'ignore))
            ;; Call execute-loop-iteration directly (as a timer would)
            (claude-org--execute-loop-iteration
             session-key 2 3 "test" 1 "test-lc" 0)
            ;; send-request should NOT have been called
            (should-not send-called)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when buffer-file-name
            (ignore-errors (delete-file buffer-file-name))))
        (kill-buffer buf)))))

(ert-deftest test-cmux-loop-error-guard-skips-iteration ()
  "Errored session's loop iteration is skipped.
T56b: Same as T56 but for error status. An errored session should not
continue its loop."
  :tags '(:unit :stable)
  (let* ((buf (generate-new-buffer "*test-loop-error*"))
         (session-key nil)
         (send-called nil))
    (unwind-protect
        (with-current-buffer buf
          (org-mode)
          (setq buffer-file-name (make-temp-file "test-loop-error-" nil ".org"))
          (insert "* Test\n:PROPERTIES:\n:CUSTOM_ID: test-le\n:END:\n\n")
          (insert "** Instruction 1 :claude_chat:\n\n")
          (insert "#+begin_src ai :loop 3\ntest\n#+end_src\n")
          (write-region (point-min) (point-max) buffer-file-name nil 'silent)
          (set-buffer-modified-p nil)

          (setq session-key (concat buffer-file-name "::test-le"))
          (claude-org--session-put session-key :loop-current 2)
          (claude-org--session-put session-key :loop-max 3)
          (claude-org--session-put session-key :marker (point-marker))
          (claude-org--session-put session-key :original-prompt "test")

          (cl-letf (((symbol-function 'claude-org--get-exec-status-for-session)
                     (lambda (&rest _) "error"))
                    ((symbol-function 'claude-org--send-request)
                     (lambda (&rest _) (setq send-called t)))
                    ((symbol-function 'claude-org--start-spinner) #'ignore)
                    ((symbol-function 'claude-org--set-exec-status) #'ignore))
            (claude-org--execute-loop-iteration
             session-key 2 3 "test" 1 "test-le" 0)
            (should-not send-called)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when buffer-file-name
            (ignore-errors (delete-file buffer-file-name))))
        (kill-buffer buf)))))

(provide 'test-cmux-e2e-simulated)

;;; test-cmux-e2e-simulated.el ends here
