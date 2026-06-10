;;; test-cmux-e2e-simulated.el --- E2E tests for cmux backend -*- lexical-binding: t -*-

;; Strategy: Mock ONLY the cmux CLI gateway (code-agent-org-cmux--call).
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
  (literate-elisp-load (expand-file-name "lp/chat/code-agent.org" project-root))
  (literate-elisp-load (expand-file-name "lp/org/code-agent-org.org" project-root))
  (literate-elisp-load (expand-file-name "lp/org/code-agent-org-cmux.org" project-root)))

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
  "Mock implementation of `code-agent-org-cmux--call'.
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
     ;; Name-based workspace lookup — default returns a non-matching
     ;; workspace so `find-workspace-by-name' returns nil and tests
     ;; default to the LAUNCH path.  Tests that want RESTORE push a
     ;; matching response via `test-cmux--mock-responses'.
     ((string= subcommand "list-workspaces")
      "  workspace:unrelated-1  Other Workspace\n")
     ;; UUID resolution — default returns a stable UUID so tests
     ;; asserting hash-table contents keep working.
     ((string= subcommand "sidebar-state")
      "tab=AABBCCDD-1111-2222-3333-444455556677\ncolor=#1565C0\n")
     (t (format "mock-response-for-%s" subcommand)))))

(defun test-cmux--mock-calls-for (subcommand)
  "Return all recorded calls for SUBCOMMAND."
  (cl-remove-if-not (lambda (c) (string= (car c) subcommand))
                     test-cmux--mock-calls))

(defmacro test-cmux--with-mock (&rest body)
  "Execute BODY with cmux CLI gateway mocked.

Also stubs `code-agent-org-cmux--wait-for-shell' (→ t) and `sleep-for'
(→ no-op): the default capture fixture is a live Claude TUI, and the real
wait-for-shell now correctly refuses to treat a Claude `❯' input line as a
shell prompt — so any incidental restart pre-flight (e.g. the execute path
relaunching when bridge hooks look missing) would otherwise loop to a 15s
timeout and abort.  These tests assert on the mock CALL stream, not on the
exit-polling; the polling logic has dedicated pure-function regressions
(`--surface-state' / `--shell-ready-p')."
  (declare (indent 0))
  `(let ((test-cmux--mock-calls nil)
         (test-cmux--mock-responses nil))
     (cl-letf (((symbol-function 'code-agent-org-cmux--call) #'test-cmux--mock-call)
               ((symbol-function 'code-agent-org-cmux--wait-for-shell)
                (lambda (&rest _) t))
               ((symbol-function 'sleep-for) (lambda (&rest _) nil)))
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
    (should (equal "surface:1" (code-agent-org-cmux--parse-surface-ref json)))))

(ert-deftest test-cmux-parse-surface-ref-from-new-workspace ()
  "Parse workspace ref from new-workspace output."
  (should (equal "workspace:3"
                 (code-agent-org-cmux--parse-surface-ref "OK workspace:3"))))

(ert-deftest test-cmux-parse-surface-ref-from-list-panes ()
  "Parse surface ref from list-pane-surfaces output."
  (should (equal "surface:5"
                 (code-agent-org-cmux--parse-surface-ref
                  "* surface:5  ~  [selected]"))))

(ert-deftest test-cmux-parse-surface-ref-clean ()
  "Already clean ref passes through."
  (should (equal "surface:1"
                 (code-agent-org-cmux--parse-surface-ref "surface:1"))))

;;; ============================================================================
;;; Tests: Session Property Lookup
;;; ============================================================================

(ert-deftest test-cmux-find-session-property ()
  "Can find CLAUDE_SESSION_ID from within AI block."
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (let ((sid (code-agent-org-terminal-find-session-property "CLAUDE_SESSION_ID")))
      (should (equal sid "test-cmux-session-001")))))

(ert-deftest test-cmux-find-session-property-missing ()
  "Returns nil for missing property."
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (should (null (code-agent-org-terminal-find-session-property "NONEXISTENT_PROP")))))

;;; ============================================================================
;;; Tests: Tab Title
;;; ============================================================================

(ert-deftest test-cmux-tab-title-format ()
  "Tab title uses ACTIVE_STORY or heading name (no session ID suffix)."
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (let ((title (code-agent-org-terminal--tab-title)))
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
      (let ((surface-id (code-agent-org-cmux--ensure-session)))
        ;; Should return the mock surface ID
        (should (equal surface-id test-cmux--mock-surface-id))
        ;; Should have called new-workspace
        (should (test-cmux--mock-calls-for "new-workspace"))
        ;; Should have stored CMUX_SURFACE_ID as org property
        (let ((stored (org-entry-get nil "CMUX_SURFACE_ID" t)))
          (should (equal stored test-cmux--mock-surface-id)))))))

(ert-deftest test-cmux-ensure-session-reuse ()
  "Ensure-session reuses existing workspace resolved by heading name."
  (test-cmux--with-mock
    ;; Workspace exists under the fixture heading title ("Test Story")
    (push (cons "list-workspaces" "  workspace:mock-1  Test Story\n")
          test-cmux--mock-responses)
    ;; Mock the workspace's fresh surface (matches the fixture's saved one)
    (push (cons "list-pane-surfaces" "* surface:existing-123  ~  [selected]")
          test-cmux--mock-responses)
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      (let ((surface-id (code-agent-org-cmux--ensure-session)))
        ;; Should return existing surface ID (fresh == saved)
        (should (equal surface-id "surface:existing-123"))
        ;; Should NOT have called new-workspace
        (should-not (test-cmux--mock-calls-for "new-workspace"))
        ;; Should have looked up the workspace by heading name
        (should (test-cmux--mock-calls-for "list-workspaces"))))))

(ert-deftest test-cmux-ensure-session-relaunches-dead ()
  "Ensure-session relaunches when existing surface is dead."
  (test-cmux--with-mock
    (let ((ready-screen (test-cmux--read-fixture "capture-pane-ready.txt")))
      (cl-letf (((symbol-function 'code-agent-org-cmux--call)
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
          (let ((surface-id (code-agent-org-cmux--ensure-session)))
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
    (let ((status (code-agent-org-cmux--get-status "test-sid" "surface:1")))
      (should (equal status "ready")))))

(ert-deftest test-cmux-status-busy-from-screen ()
  "Detects busy state from capture-pane output."
  (test-cmux--with-mock
    (push (cons "capture-pane"
                (test-cmux--read-fixture "capture-pane-busy.txt"))
          test-cmux--mock-responses)
    (let ((status (code-agent-org-cmux--get-status "test-sid" "surface:1")))
      (should (equal status "busy")))))

(ert-deftest test-cmux-status-from-hook-file ()
  "Uses hook file status when available."
  (let* ((dir code-agent-org-terminal-status-dir)
         (file (expand-file-name "test-hook-sid" dir)))
    (unwind-protect
        (progn
          (make-directory dir t)
          (with-temp-file file (insert "ready"))
          (let ((status (code-agent-org-cmux--get-status "test-hook-sid" "surface:1")))
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
      (code-agent-org-cmux--execute-ai-block)
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
      (let ((initial-count (hash-table-count code-agent--active-queries)))
        (code-agent-org-cmux--execute-ai-block)
        ;; Should have registered one new query
        (should (> (hash-table-count code-agent--active-queries) initial-count))
        ;; Clean up: unregister
        (let ((req-id (code-agent-org-terminal--read-request-id "test-cmux-session-001")))
          (when req-id
            (code-agent--unregister-query req-id)))))))

(ert-deftest test-cmux-execute-writes-from-emacs-flag ()
  "Execute writes from-emacs flag file."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (code-agent-org-cmux--execute-ai-block)
      ;; Check that flag file was written
      (let ((flag-path (expand-file-name
                        "test-cmux-session-001.from-emacs"
                        code-agent-org-terminal-status-dir)))
        (should (file-exists-p flag-path))
        ;; Clean up
        (delete-file flag-path)
        (let ((req-id (code-agent-org-terminal--read-request-id "test-cmux-session-001")))
          (when req-id
            (code-agent--unregister-query req-id)
            (delete-file (expand-file-name
                          "test-cmux-session-001.request-id"
                          code-agent-org-terminal-status-dir)
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
      (should-error (code-agent-org-cmux--execute-ai-block)
                    :type 'user-error))))

;;; ============================================================================
;;; Tests: Backend Dispatch
;;; ============================================================================

(ert-deftest test-cmux-dispatch-from-property ()
  "CLAUDE_BACKEND=cmux dispatches to cmux backend."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-backend
      (test-cmux--goto-ai-block)
      ;; Verify the property is accessible (still a plain string from org)
      (let ((backend (code-agent-org-get-org-property "CLAUDE_BACKEND" t)))
        (should (equal backend "cmux")))
      ;; Execute should dispatch to cmux
      (code-agent-org-execute)
      ;; Verify cmux calls were made (new-workspace or identify)
      (should (or (test-cmux--mock-calls-for "new-workspace")
                  (test-cmux--mock-calls-for "identify")))
      ;; Verify prompt was sent via send command
      (should (test-cmux--mock-calls-for "send"))
      ;; Clean up active query
      (let ((req-id (code-agent-org-terminal--read-request-id "test-cmux-session-002")))
        (when req-id
          (code-agent--unregister-query req-id)
          (ignore-errors
            (delete-file (expand-file-name
                          "test-cmux-session-002.request-id"
                          code-agent-org-terminal-status-dir)))
          (ignore-errors
            (delete-file (expand-file-name
                          "test-cmux-session-002.from-emacs"
                          code-agent-org-terminal-status-dir))))))))

;;; ============================================================================
;;; Tests: Query Completion
;;; ============================================================================

(ert-deftest test-cmux-query-completed ()
  "Query completion unregisters from active queries."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (code-agent-org-cmux--execute-ai-block)
      (let ((req-id (code-agent-org-terminal--read-request-id "test-cmux-session-001")))
        (should req-id)
        ;; Verify query is registered
        (should (code-agent--get-active-query req-id))
        ;; Complete the query
        (code-agent-org-cmux--query-completed "test-cmux-session-001")
        ;; Should be unregistered
        (should-not (code-agent--get-active-query req-id))
        ;; Clean up files
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-001.request-id"
                        code-agent-org-terminal-status-dir)))
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-001.from-emacs"
                        code-agent-org-terminal-status-dir)))))))

;;; ============================================================================
;;; Tests: Cancel
;;; ============================================================================

(ert-deftest test-cmux-cancel-sends-escape ()
  "Cancel sends escape key to cmux surface."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      (code-agent-org-cmux-cancel)
      (let ((key-calls (test-cmux--mock-calls-for "send-key")))
        (should key-calls)
        (should (member "escape" (cdar key-calls)))))))

(ert-deftest test-cmux-cancel-errors-without-surface ()
  "Cancel errors when no CMUX_SURFACE_ID is set."
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (should-error (code-agent-org-cmux-cancel) :type 'user-error))))

(ert-deftest test-cmux-execute-busy-lifecycle ()
  "E05: Full busy lifecycle: execute sets busy → complete clears busy.
The :busy flag is set synchronously by execute-ai-block so the
immediate cancel/queue/loop paths see the right state.  The Python
workspace bridge hook can refresh it later, but execute MUST be the
primary setter — otherwise A4/A5/A6 regress: cancel returns 'No
active query' before the hook arrives, queue check skips, and loops
do not continue past iteration 1."
  :tags '(:unit :stable :e2e)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (let ((session-key (code-agent-org-current-session-key)))
        ;; Before execute: not busy
        (should-not (code-agent-org-session-get session-key :busy))
        ;; Execute sets :busy t synchronously so subsequent cancel/queue
        ;; paths see the active query.
        (code-agent-org-cmux--execute-ai-block)
        (should (code-agent-org-session-get session-key :busy))
        ;; Bridge UserPromptSubmit hook can re-affirm idempotently.
        (code-agent-org-session-put session-key :busy t)
        (should (code-agent-org-session-get session-key :busy))
        ;; Complete clears busy
        (code-agent-org-cmux--query-completed "test-cmux-session-001")
        (should-not (code-agent-org-session-get session-key :busy))
        ;; Clean up files
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-001.request-id"
                        code-agent-org-terminal-status-dir)))
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-001.from-emacs"
                        code-agent-org-terminal-status-dir)))))))

(ert-deftest test-cmux-execute-sets-backend ()
  "Execute sets :backend to \"cmux\" on session so generic cancel can dispatch."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (code-agent-org-cmux--execute-ai-block)
      (let* ((session-key (code-agent-org-current-session-key))
             (backend (code-agent-org-session-get session-key :backend)))
        (should (code-agent-cmux-backend-p backend))
        ;; Clean up
        (let ((req-id (code-agent-org-terminal--read-request-id "test-cmux-session-001")))
          (when req-id
            (code-agent--unregister-query req-id)))))))

(ert-deftest test-cmux-cancel-during-active-query ()
  "E06: Cancel during active query sends escape and clears state.
Full lifecycle: execute → bridge sets busy → cancel sends escape →
query-completed clears busy and unregisters query."
  :tags '(:unit :stable :e2e)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      ;; 1. Execute sets up the query
      (code-agent-org-cmux--execute-ai-block)
      (let ((session-key (code-agent-org-current-session-key))
            (req-id (code-agent-org-terminal--read-request-id "test-cmux-session-003")))
        ;; Query should be registered
        (should req-id)
        (should (code-agent--get-active-query req-id))
        ;; 2. Simulate bridge setting busy (as hook would)
        (code-agent-org-session-put session-key :busy t)
        (should (code-agent-org-session-get session-key :busy))
        ;; 3. Cancel sends escape
        (code-agent-org-cmux-cancel)
        (let ((key-calls (test-cmux--mock-calls-for "send-key")))
          (should key-calls)
          (should (member "escape" (cdar key-calls))))
        ;; 4. query-completed fires (Python hook detects agent stopped)
        (code-agent-org-cmux--query-completed "test-cmux-session-003")
        ;; 5. Verify clean state: not busy, query unregistered
        (should-not (code-agent-org-session-get session-key :busy))
        (should-not (code-agent--get-active-query req-id))
        ;; Clean up files
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-003.request-id"
                        code-agent-org-terminal-status-dir)))
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-003.from-emacs"
                        code-agent-org-terminal-status-dir)))))))

(ert-deftest test-cmux-generic-cancel-dispatches-to-cmux ()
  "Generic code-agent-org-cancel dispatches to code-agent-org-cmux-cancel for cmux sessions."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      ;; Set up session state as if execute had run
      (let ((session-key (code-agent-org-current-session-key)))
        (code-agent-org-session-put session-key :backend (code-agent-cmux-backend-create :session-key session-key))
        (code-agent-org-session-put session-key :busy t)
        ;; Mock cleanup functions
        (cl-letf (((symbol-function 'code-agent-org--cleanup-session) #'ignore)
                  ((symbol-function 'code-agent-org--queue-count) (lambda (_) 0)))
          (code-agent-org-cancel)
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
      (let ((session-key (code-agent-org-current-session-key)))
        (code-agent-org-session-put session-key :backend (code-agent-cmux-backend-create :session-key session-key))
        ;; :busy is NOT set -- cancel should be a no-op message, not an error
        (code-agent-org-cancel)
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
    (let ((code-agent-org-cmux-launch-command 'claude-workspace)
          (code-agent-org-cmux-workspace-script "/path/to/claude-workspace"))
      (let ((cmd (code-agent-org-cmux--build-launch-command
                  "/tmp/test.org" "sid-001" "/tmp")))
        (should (string-match-p "/path/to/claude-workspace" cmd))
        (should (string-match-p "sid-001" cmd))))))

(ert-deftest test-cmux-build-launch-cmd-custom ()
  "Build launch command for custom string mode.

The always-on `unset VIRTUAL_ENV;' guard (added 2026-05-26 to suppress
uv's stale-venv warning under cmux process ancestry) prefixes every
launch command — see test-cmux-env-injection.el for the rationale."
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (let ((code-agent-org-cmux-launch-command "my-custom-command"))
      (let ((cmd (code-agent-org-cmux--build-launch-command
                  "/tmp/test.org" "sid-001" "/tmp")))
        (should (equal cmd "unset VIRTUAL_ENV; my-custom-command"))))))

;;; ============================================================================
;;; E19: Claude bare launch command
;;; ============================================================================

(ert-deftest test-cmux-build-launch-cmd-claude-bare ()
  "E19: Build launch command for bare 'claude mode includes --system-prompt.

Matches `claude ` *anywhere* in the command (no `\\`' anchor) because
the always-on `unset VIRTUAL_ENV;' guard now prefixes the launcher
— see test-cmux-env-injection.el and the 2026-05-26 rename-incident
notes in code-agent-org-cmux.org § --build-env-prefix."
  :tags '(:unit :stable :e2e)
  (test-cmux--with-org-buffer test-cmux--org-content-basic
    (test-cmux--goto-ai-block)
    (let ((code-agent-org-cmux-launch-command 'claude)
          (code-agent-org-cmux-extra-args nil))
      (cl-letf (((symbol-function 'code-agent-org-workspace-bridge-system-prompt)
                 (lambda (&rest _) "test system prompt"))
                ((symbol-function 'code-agent-org-workspace-bridge-get-cli-session)
                 (lambda (&rest _) nil)))
        (let ((cmd (code-agent-org-cmux--build-launch-command
                    "/tmp/test.org" "sid-001" "/tmp")))
          (should (stringp cmd))
          ;; `claude ` appears after the env-prefix guard.
          (should (string-match-p "\\bclaude " cmd))
          ;; Has --system-prompt
          (should (string-match-p "--system-prompt" cmd)))))))

;;; ============================================================================
;;; Tests: Sidebar Feedback (cmux-specific features)
;;; ============================================================================

(ert-deftest test-cmux-sidebar-set-status ()
  "set-status calls cmux CLI."
  (test-cmux--with-mock
    (code-agent-org-cmux-set-status "task" "Running...")
    (let ((calls (test-cmux--mock-calls-for "set-status")))
      (should calls)
      (should (member "task" (cdar calls)))
      (should (member "Running..." (cdar calls))))))

(ert-deftest test-cmux-sidebar-notify ()
  "notify calls cmux CLI."
  (test-cmux--with-mock
    (code-agent-org-cmux-notify "Done" "Query complete")
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
    (let ((cmd (code-agent-org-cmux--build-launch-command
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
    (let ((cmd (code-agent-org-cmux--build-launch-command
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
    (let ((cmd (code-agent-org-cmux--build-launch-command
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

(ert-deftest test-cmux-resume-lifecycle-first-then-second ()
  "E07: First query has no --resume; bridge saves CLI session; second query resumes.
Simulates the full session continuity lifecycle: first execution launches
without --resume, workspace bridge saves CLAUDE_CLI_SESSION on the session
heading (as the Python hook would), and the second launch command includes
--resume with the saved session ID."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-resume-" nil ".org"))
        (org-content "* Resume Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-resume-001
:CLAUDE_BACKEND: cmux
:CUSTOM_ID: test-cmux-resume-story
:END:

** Instruction 1
:PROPERTIES:
:CUSTOM_ID: test-cmux-resume-instr-1
:END:

#+begin_src ai
First query.
#+end_src
"))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (unwind-protect
              (with-current-buffer buf
                (org-mode)
                (let ((code-agent-org-auto-start-mcp-server nil))
                  (code-agent-org-mode 1))
                (insert org-content)
                (save-buffer)
                (test-cmux--goto-ai-block)
                ;; 1. First launch: no CLAUDE_CLI_SESSION → no --resume
                (let ((cmd1 (code-agent-org-cmux--build-launch-command
                             (buffer-file-name) "test-cmux-resume-001"
                             default-directory)))
                  (should (stringp cmd1))
                  (should-not (string-match-p "--resume" cmd1)))
                ;; 2. Simulate bridge saving CLI session (what Python hook does)
                (save-excursion
                  (code-agent-org-terminal-goto-session-heading)
                  (org-set-property "CLAUDE_CLI_SESSION" "saved-cli-session-uuid"))
                ;; 3. Verify property persisted
                (should (equal "saved-cli-session-uuid"
                               (org-entry-get nil "CLAUDE_CLI_SESSION" t)))
                ;; 4. Second launch: has CLAUDE_CLI_SESSION → --resume
                (let ((cmd2 (code-agent-org-cmux--build-launch-command
                             (buffer-file-name) "test-cmux-resume-001"
                             default-directory)))
                  (should (stringp cmd2))
                  (should (string-match-p "--resume" cmd2))
                  (should (string-match-p "saved-cli-session-uuid" cmd2))))
            (kill-buffer buf)))
      (delete-file file))))

;;; ============================================================================
;;; Tests: Permission Routing (P0 fix)
;;; ============================================================================

(ert-deftest test-cmux-permission-needed-calls-select-workspace ()
  "code-agent-org-cmux--permission-needed focuses the cmux workspace and adds alert."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (puthash "sdd-perm-test" "mock-session-key"
             code-agent-org-terminal--workspace-to-session-key)
    (puthash "sdd-perm-test" "mock-ws-id"
             code-agent-org-cmux--workspace-to-cmux-id)
    (let ((saved-alerts code-agent-pending-alerts))
      (unwind-protect
          (progn
            (code-agent-org-cmux--permission-needed "sdd-perm-test" "Bash")
            ;; Should have called select-workspace to focus the terminal
            (let ((calls (test-cmux--mock-calls-for "select-workspace")))
              (should calls)
              (should (member "mock-ws-id" (cdar calls))))
            ;; Should be registered as a mode-line alert
            (should (assq (intern "sdd-perm-test") code-agent-pending-alerts)))
        ;; Cleanup
        (setq code-agent-pending-alerts saved-alerts)
        (remhash "sdd-perm-test" code-agent-org-terminal--workspace-to-session-key)
        (remhash "sdd-perm-test" code-agent-org-cmux--workspace-to-cmux-id)))))

(ert-deftest test-cmux-permission-resolved-clears-state ()
  "code-agent-org-cmux--permission-resolved clears pending alert."
  :tags '(:unit :stable)
  (let ((saved-alerts code-agent-pending-alerts))
    ;; Add a pending alert
    (code-agent-add-alert (intern "sdd-resolve-test") :label "test")
    (unwind-protect
        (progn
          (code-agent-org-cmux--permission-resolved "sdd-resolve-test")
          (should-not (assq (intern "sdd-resolve-test") code-agent-pending-alerts)))
      (setq code-agent-pending-alerts saved-alerts))))

(ert-deftest test-cmux-terminal-permission-routes-to-cmux ()
  "Terminal permission dispatcher routes cmux sessions to cmux handler."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (puthash "sdd-route-test" "mock-key"
             code-agent-org-terminal--workspace-to-session-key)
    (puthash "sdd-route-test" "mock-ws"
             code-agent-org-cmux--workspace-to-cmux-id)
    (let ((saved-alerts code-agent-pending-alerts))
      (unwind-protect
          (progn
            (code-agent-org--terminal-permission-needed "sdd-route-test" "Edit")
            ;; Should have used cmux path (select-workspace called)
            (should (test-cmux--mock-calls-for "select-workspace"))
            ;; Should have registered alert via cmux handler
            (should (assq (intern "sdd-route-test") code-agent-pending-alerts)))
        (setq code-agent-pending-alerts saved-alerts)
        (remhash "sdd-route-test" code-agent-org-terminal--workspace-to-session-key)
        (remhash "sdd-route-test" code-agent-org-cmux--workspace-to-cmux-id)))))

;;; ============================================================================
;;; Tests: Session Recovery (P1)
;;; ============================================================================

(ert-deftest test-cmux-recover-session-from-org-buffer ()
  "Session recovery finds the heading via CLAUDE_SESSION_ID, resolves the
cmux workspace by heading name, and repopulates hash tables."
  :tags '(:unit :stable)
  ;; Use file-backed buffer with code-agent-org-mode (recovery checks this)
  (let ((file (make-temp-file "test-recover-" nil ".org")))
    (unwind-protect
        (test-cmux--with-mock
          ;; Workspace exists under the fixture heading title ("Test Story")
          (push (cons "list-workspaces" "  workspace:mock-1  Test Story\n")
                test-cmux--mock-responses)
          (let ((buf (find-file-noselect file)))
            (with-current-buffer buf
              (org-mode)
              (let ((code-agent-org-auto-start-mcp-server nil))
                (code-agent-org-mode 1))
              (insert test-cmux--org-content-with-surface)
              (save-buffer))
            ;; Clear all 3 hash tables to simulate Emacs restart
            (remhash "test-cmux-session-003" code-agent-org-terminal--workspace-to-session-key)
            (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-surface)
            (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-cmux-id)
            ;; Try recovery — list-workspaces resolves "Test Story" → mock-1;
            ;; sidebar-state returns mock-workspace-uuid-123.
            (let ((result (code-agent-org-cmux--recover-session "test-cmux-session-003")))
              (should result)
              (should (gethash "test-cmux-session-003" code-agent-org-terminal--workspace-to-session-key))
              ;; Surface comes from the CMUX_SURFACE_ID property on the heading
              (should (equal "surface:existing-123"
                             (gethash "test-cmux-session-003" code-agent-org-cmux--workspace-to-surface)))
              ;; UUID comes from name-based resolution (not an org property)
              (should (equal "AABBCCDD-1111-2222-3333-444455556677"
                             (gethash "test-cmux-session-003" code-agent-org-cmux--workspace-to-cmux-id))))
            ;; Cleanup
            (remhash "test-cmux-session-003" code-agent-org-terminal--workspace-to-session-key)
            (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-surface)
            (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-cmux-id)
            (kill-buffer buf)))
      (delete-file file))))

(ert-deftest test-cmux-recover-session-not-found ()
  "Session recovery returns nil for unknown session IDs."
  :tags '(:unit :stable)
  (should-not (code-agent-org-cmux--recover-session "nonexistent-session-999")))

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
      ;; Verify the file-level property is accessible (plain string from org)
      (let ((backend (code-agent-org-get-org-property "CLAUDE_BACKEND" t)))
        (should (equal backend "cmux")))
      ;; Execute should dispatch to cmux backend
      (code-agent-org-execute)
      ;; Verify cmux calls were made
      (should (or (test-cmux--mock-calls-for "new-workspace")
                  (test-cmux--mock-calls-for "identify")))
      ;; Verify prompt was sent
      (should (test-cmux--mock-calls-for "send"))
      ;; Clean up
      (let ((req-id (code-agent-org-terminal--read-request-id "test-cmux-session-file-backend")))
        (when req-id
          (code-agent--unregister-query req-id)
          (ignore-errors
            (delete-file (expand-file-name
                          "test-cmux-session-file-backend.request-id"
                          code-agent-org-terminal-status-dir)))
          (ignore-errors
            (delete-file (expand-file-name
                          "test-cmux-session-file-backend.from-emacs"
                          code-agent-org-terminal-status-dir))))))))

(ert-deftest test-cmux-file-level-backend-sets-backend-property ()
  "File-level CLAUDE_BACKEND=cmux sets :backend on session after execute.
T52b: Ensures generic cancel works for file-level backend dispatch."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-file-level-backend
      (test-cmux--goto-ai-block)
      (code-agent-org-execute)
      (let* ((session-key (code-agent-org-current-session-key))
             (backend (code-agent-org-session-get session-key :backend)))
        (should (code-agent-cmux-backend-p backend))
        ;; Clean up
        (let ((req-id (code-agent-org-terminal--read-request-id "test-cmux-session-file-backend")))
          (when req-id
            (code-agent--unregister-query req-id)
            (ignore-errors
              (delete-file (expand-file-name
                            "test-cmux-session-file-backend.request-id"
                            code-agent-org-terminal-status-dir)))
            (ignore-errors
              (delete-file (expand-file-name
                            "test-cmux-session-file-backend.from-emacs"
                            code-agent-org-terminal-status-dir)))))))))

;;; ============================================================================
;;; Tests: Ensure-session hash table restore on reconnect (T53)
;;; ============================================================================

(ert-deftest test-cmux-ensure-session-restores-hash-tables ()
  "Ensure-session restores hash table mappings when workspace name is alive.
T53: Simulates Emacs restart — hash tables cleared but CMUX_SURFACE_ID
property intact.  On reconnect, ensure-session must resolve the cmux
workspace by heading name and repopulate all three hash tables."
  :tags '(:unit :stable)
  (test-cmux--with-mock
    ;; Workspace exists under the fixture heading title ("Test Story")
    (push (cons "list-workspaces" "  workspace:mock-1  Test Story\n")
          test-cmux--mock-responses)
    ;; Mock returns fresh surface matching the fixture's saved value
    (push (cons "list-pane-surfaces" "* surface:existing-123  ~  [selected]")
          test-cmux--mock-responses)
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      ;; Verify CMUX_SURFACE_ID property exists (the only persisted cmux id)
      (should (equal "surface:existing-123"
                     (org-entry-get nil "CMUX_SURFACE_ID" t)))
      ;; Clear all hash tables to simulate Emacs restart
      (remhash "test-cmux-session-003" code-agent-org-terminal--workspace-to-session-key)
      (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-surface)
      (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-cmux-id)
      ;; Verify cleared
      (should-not (gethash "test-cmux-session-003" code-agent-org-terminal--workspace-to-session-key))
      (should-not (gethash "test-cmux-session-003" code-agent-org-cmux--workspace-to-surface))
      (should-not (gethash "test-cmux-session-003" code-agent-org-cmux--workspace-to-cmux-id))
      ;; Call ensure-session — resolves workspace by heading name
      (let ((surface (code-agent-org-cmux--ensure-session)))
        (should (equal surface "surface:existing-123"))
        ;; All three hash tables should be repopulated
        (should (gethash "test-cmux-session-003" code-agent-org-terminal--workspace-to-session-key))
        (should (equal "surface:existing-123"
                       (gethash "test-cmux-session-003" code-agent-org-cmux--workspace-to-surface)))
        ;; UUID resolved via sidebar-state (default mock returns a UUID)
        (should (equal "AABBCCDD-1111-2222-3333-444455556677"
                       (gethash "test-cmux-session-003" code-agent-org-cmux--workspace-to-cmux-id)))))))

(ert-deftest test-cmux-restore-workspace-verbose-and-color ()
  "E02: Restore workspace after Emacs restart starts verbose and reapplies color.
Extends T53: verifies that restore-workspace (called by ensure-session phase 1)
starts the verbose timer, reapplies sidebar color, renames the tab, and does NOT
call new-workspace."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-restore-" nil ".org"))
        (calls nil))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (unwind-protect
              (progn
                (with-current-buffer buf
                  (org-mode)
                  (let ((code-agent-org-auto-start-mcp-server nil))
                    (code-agent-org-mode 1))
                  (insert test-cmux--org-content-with-surface)
                  (save-buffer))
                ;; Clear hash tables to simulate Emacs restart
                (remhash "test-cmux-session-003"
                         code-agent-org-terminal--workspace-to-session-key)
                (remhash "test-cmux-session-003"
                         code-agent-org-cmux--workspace-to-surface)
                (remhash "test-cmux-session-003"
                         code-agent-org-cmux--workspace-to-cmux-id)
                ;; Mock with call recording
                (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                           (lambda (subcmd &rest args)
                             (push (cons subcmd args) calls)
                             (cond
                              ((string= subcmd "list-workspaces")
                               "  workspace:mock-1  Test Story\n")
                              ((string= subcmd "list-pane-surfaces")
                               "* surface:existing-123  ~  [selected]")
                              ((string= subcmd "sidebar-state")
                               "tab=AABBCCDD-1111-2222-3333-444455556677\ncolor=#1565C0\n")
                              ((string= subcmd "capture-pane")
                               (test-cmux--read-fixture "capture-pane-ready.txt"))
                              (t "ok")))))
                  (with-current-buffer buf
                    (test-cmux--goto-ai-block)
                    (let ((surface (code-agent-org-cmux--ensure-session)))
                      ;; Returns existing surface (not a new one)
                      (should (equal surface "surface:existing-123"))
                      ;; No new-workspace was called
                      (should-not (cl-find "new-workspace" calls
                                           :key #'car :test #'equal))
                      ;; Tab renamed
                      (should (cl-find "rename-tab" calls
                                       :key #'car :test #'equal))
                      ;; Verbose timer started
                      (let ((sk (code-agent-org-current-session-key)))
                        (should (code-agent-org-session-get sk :verbose-follow-process)))))))
            ;; Cleanup: stop verbose, clear state, kill buffer
            (let ((sk (with-current-buffer buf
                        (code-agent-org-current-session-key))))
              (when sk (code-agent-org-cmux--stop-verbose sk)))
            (remhash "test-cmux-session-003"
                     code-agent-org-terminal--workspace-to-session-key)
            (remhash "test-cmux-session-003"
                     code-agent-org-cmux--workspace-to-surface)
            (remhash "test-cmux-session-003"
                     code-agent-org-cmux--workspace-to-cmux-id)
            (kill-buffer buf)))
      (delete-file file))))

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
    (should (equal "bypass" (code-agent-org--get-permission-mode-property)))
    (should (equal "BP" (code-agent-org--permission-mode-short)))
    (should (equal "bypassPermissions" (code-agent-org--get-permission-mode)))))

(ert-deftest test-cmux-permission-section-overrides-file ()
  "Section-level CLAUDE_PERMISSION_MODE overrides file-level.
T54b: Org inheritance — section property takes priority over #+PROPERTY."
  :tags '(:unit :stable)
  (test-cmux--with-org-buffer test-cmux--org-section-override-permission
    (test-cmux--goto-ai-block)
    ;; Section-level readonly should override file-level bypass
    (should (equal "readonly" (code-agent-org--get-permission-mode-property)))
    (should (equal "RO" (code-agent-org--permission-mode-short)))
    (should (equal "default" (code-agent-org--get-permission-mode)))))

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

(ert-deftest test-cmux-archive-workflow-preserves-cli-session ()
  "Archive-workflow preserves CLAUDE_CLI_SESSION on workspace heading.
T55: Archiving a Workflow folds the old transcript into the archive file
but is NOT a session reset. The CLI session id (and Copilot's) must
survive so the next \"Open terminal\" still resumes the same Claude
conversation. Regression test for the user-reported behaviour where
opening a terminal after archive started a brand-new chat."
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
      (code-agent-org-workspace-archive-workflow))
    ;; CLI session must STILL be present so resume keeps working.
    (goto-char (point-min))
    (re-search-forward ":CLAUDE_SESSION_ID: sdd-archive-test")
    (org-back-to-heading t)
    (should (equal "old-session-uuid-123"
                   (org-entry-get nil "CLAUDE_CLI_SESSION")))))

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
      (code-agent-org-workspace-archive-workflow))
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
          (code-agent-org-session-put session-key :loop-current 2)
          (code-agent-org-session-put session-key :loop-max 3)
          (code-agent-org-session-put session-key :marker (point-marker))
          (code-agent-org-session-put session-key :original-prompt "test")
          (code-agent-org-session-put session-key :instruction-num 1)
          (code-agent-org-session-put session-key :custom-id "test-lc")
          (code-agent-org-session-put session-key :busy nil)

          ;; Simulate: session was cancelled
          (cl-letf (((symbol-function 'code-agent-org--get-exec-status-for-session)
                     (lambda (&rest _) "cancelled"))
                    ((symbol-function 'code-agent-org--send-request)
                     (lambda (&rest _) (setq send-called t)))
                    ((symbol-function 'code-agent-org--start-spinner) #'ignore)
                    ((symbol-function 'code-agent-org--set-exec-status) #'ignore))
            ;; Call execute-loop-iteration directly (as a timer would)
            (code-agent-org--execute-loop-iteration
             session-key 2 3 "test" 1 "test-lc" 0)
            ;; send-request should NOT have been called
            (should-not send-called)
            ;; E25: :busy stays nil (not set by cancelled iteration)
            (should-not (code-agent-org-session-get session-key :busy))
            ;; E25: :loop-current unchanged (still 2, not incremented)
            (should (equal 2 (code-agent-org-session-get session-key :loop-current)))))
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
          (code-agent-org-session-put session-key :loop-current 2)
          (code-agent-org-session-put session-key :loop-max 3)
          (code-agent-org-session-put session-key :marker (point-marker))
          (code-agent-org-session-put session-key :original-prompt "test")

          (cl-letf (((symbol-function 'code-agent-org--get-exec-status-for-session)
                     (lambda (&rest _) "error"))
                    ((symbol-function 'code-agent-org--send-request)
                     (lambda (&rest _) (setq send-called t)))
                    ((symbol-function 'code-agent-org--start-spinner) #'ignore)
                    ((symbol-function 'code-agent-org--set-exec-status) #'ignore))
            (code-agent-org--execute-loop-iteration
             session-key 2 3 "test" 1 "test-le" 0)
            (should-not send-called)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when buffer-file-name
            (ignore-errors (delete-file buffer-file-name))))
        (kill-buffer buf)))))

;;; ============================================================================
;;; T57: Special characters in workspace/story names
;;; ============================================================================

(ert-deftest test-cmux-special-chars-in-story-name ()
  "T57a: Story names with unicode, emoji, org-special chars work correctly.
Verifies session-key resolution and property lookup work with special chars."
  :tags '(:e2e :simulated :unit :fast :stable)
  (test-cmux--with-org-buffer
      (concat
       "* Workspace: 日本語テスト 🚀\n"
       ":PROPERTIES:\n"
       ":CLAUDE_SESSION_ID: sdd-unicode-001\n"
       ":CLAUDE_BACKEND: cmux\n"
       ":ACTIVE_STORY: データベース設計\n"
       ":CUSTOM_ID: test-unicode-workspace\n"
       ":END:\n\n"
       "** データベース設計\n"
       "*** Workflow :sdd:\n"
       ":PROPERTIES:\n"
       ":CUSTOM_ID: test-unicode-wf\n"
       ":END:\n\n"
       "**** Unicode Query :claude_chat:\n"
       ":PROPERTIES:\n"
       ":CUSTOM_ID: test-unicode-instr-1\n"
       ":END:\n\n"
       "#+begin_src ai\n"
       "What is 2+2?\n"
       "#+end_src\n")
    ;; Session key resolves correctly with unicode
    (save-excursion
      (goto-char (point-min))
      (re-search-forward ":CUSTOM_ID: test-unicode-instr-1" nil t)
      (let ((sk (code-agent-org-current-session-key)))
        (should (stringp sk))
        (should (string-match-p "sdd-unicode-001" sk))))
    ;; ACTIVE_STORY with CJK chars reads correctly
    (save-excursion
      (goto-char (point-min))
      (re-search-forward ":CUSTOM_ID: test-unicode-workspace" nil t)
      (org-back-to-heading t)
      (should (equal "データベース設計" (org-entry-get nil "ACTIVE_STORY"))))
    ;; Heading with emoji is readable
    (save-excursion
      (goto-char (point-min))
      (re-search-forward ":CUSTOM_ID: test-unicode-workspace" nil t)
      (org-back-to-heading t)
      (let ((heading (org-get-heading t t t t)))
        (should (string-match-p "日本語テスト" heading))
        (should (string-match-p "🚀" heading))))))

(ert-deftest test-cmux-special-chars-org-metachars ()
  "T57b: Story names containing org meta-characters (* # : |) handled safely."
  :tags '(:e2e :simulated :unit :fast :stable)
  (test-cmux--with-org-buffer
      (concat
       "* Test Workspace\n"
       ":PROPERTIES:\n"
       ":CLAUDE_SESSION_ID: sdd-metachars-001\n"
       ":CLAUDE_BACKEND: cmux\n"
       ":ACTIVE_STORY: fix bug #123\n"
       ":CUSTOM_ID: test-metachar-workspace\n"
       ":END:\n\n"
       "** fix bug #123\n"
       "*** Workflow :sdd:\n"
       ":PROPERTIES:\n"
       ":CUSTOM_ID: test-metachar-wf\n"
       ":END:\n\n"
       "**** Bug fix query :claude_chat:\n"
       ":PROPERTIES:\n"
       ":CUSTOM_ID: test-metachar-instr-1\n"
       ":END:\n\n"
       "#+begin_src ai\n"
       "Fix the bug.\n"
       "#+end_src\n")
    ;; ACTIVE_STORY with # char reads correctly
    (save-excursion
      (goto-char (point-min))
      (re-search-forward ":CUSTOM_ID: test-metachar-workspace" nil t)
      (org-back-to-heading t)
      (should (equal "fix bug #123" (org-entry-get nil "ACTIVE_STORY"))))))

;;; ============================================================================
;;; T58: Slug generation with special characters
;;; ============================================================================

(ert-deftest test-cmux-slug-unicode-and-special ()
  "T58: slug generation handles unicode, CJK, emoji, RTL, and special chars.
Verifies that non-ASCII characters are stripped and only alphanum + hyphens remain."
  :tags '(:e2e :simulated :unit :fast :stable)
  ;; CJK characters stripped
  (should (equal "" (code-agent-org--workspace-name-to-slug "日本語")))
  ;; Emoji stripped
  (should (equal "" (code-agent-org--workspace-name-to-slug "🚀🔥💡")))
  ;; Mixed ASCII and unicode: ASCII preserved, unicode stripped
  (should (equal "api-design" (code-agent-org--workspace-name-to-slug "API Design 🎯")))
  ;; Org-mode special chars: * # : |
  (should (equal "fix-bug-123" (code-agent-org--workspace-name-to-slug "fix bug *#123*")))
  (should (equal "table-col-a-col-b" (code-agent-org--workspace-name-to-slug "table: col-a | col-b")))
  ;; Plain ASCII passthrough
  (should (equal "hello-world" (code-agent-org--workspace-name-to-slug "Hello World")))
  ;; Leading/trailing special chars stripped
  (should (equal "test" (code-agent-org--workspace-name-to-slug "---test---")))
  ;; Empty string
  (should (equal "" (code-agent-org--workspace-name-to-slug ""))))

(ert-deftest test-cmux-custom-id-generation-unicode ()
  "T58b: CUSTOM_ID generation handles unicode in section names.
Non-ASCII chars are replaced with hyphens and collapsed."
  :tags '(:e2e :simulated :unit :fast :stable)
  ;; CJK section name: [:alnum:] includes unicode letters, so CJK chars preserved
  (let ((id (code-agent-org-generate-custom-id "sdd-001" "データベース設計")))
    (should (stringp id))
    (should (string-match-p "sdd-001" id))
    ;; CJK chars ARE alphanumeric in Emacs regex — preserved in CUSTOM_ID
    (should (string-match-p "データベース設計" id)))
  ;; Emoji section name: emoji are NOT [:alnum:], so stripped
  (let ((id (code-agent-org-generate-custom-id "sdd-002" "Deploy 🚀 Pipeline")))
    (should (stringp id))
    (should (string-match-p "deploy" id))
    (should (string-match-p "pipeline" id))
    ;; Emoji should be stripped (replaced by hyphens and collapsed)
    (should-not (string-match-p "🚀" id)))
  ;; Plain ASCII
  (let ((id (code-agent-org-generate-custom-id "sdd-003" "Research Output")))
    (should (equal "sdd-003-research-output" id))))

;;; ============================================================================
;;; T59: Tab title and cmux operations with special characters
;;; ============================================================================

(ert-deftest test-cmux-tab-title-with-unicode ()
  "T59: Tab title (ACTIVE_STORY) with unicode passed correctly to tab-title fn."
  :tags '(:e2e :simulated :unit :fast :stable)
  (test-cmux--with-org-buffer
      (concat
       "* Unicode Workspace\n"
       ":PROPERTIES:\n"
       ":CLAUDE_SESSION_ID: sdd-tab-unicode-001\n"
       ":CLAUDE_BACKEND: cmux\n"
       ":CMUX_SURFACE_ID: surface:existing-123\n"
       ":CMUX_WORKSPACE_ID: mock-workspace-uuid-123\n"
       ":ACTIVE_STORY: résumé review\n"
       ":CUSTOM_ID: test-tab-unicode-ws\n"
       ":END:\n\n"
       "** résumé review\n"
       "*** Workflow :sdd:\n"
       ":PROPERTIES:\n"
       ":CUSTOM_ID: test-tab-unicode-wf\n"
       ":END:\n\n"
       "**** Query :claude_chat:\n"
       ":PROPERTIES:\n"
       ":CUSTOM_ID: test-tab-unicode-instr-1\n"
       ":END:\n\n"
       "#+begin_src ai\n"
       "What is 2+2?\n"
       "#+end_src\n")
    (save-excursion
      (goto-char (point-min))
      (re-search-forward ":CUSTOM_ID: test-tab-unicode-ws" nil t)
      (org-back-to-heading t)
      ;; Tab title function reads ACTIVE_STORY
      (let ((title (code-agent-org-terminal--tab-title)))
        (should (stringp title))
        ;; Title should contain the story name with accented chars
        (should (string-match-p "résumé review" title))))))

;;; ============================================================================
;;; T60: Open tab / focus workspace
;;; ============================================================================

(ert-deftest test-cmux-open-tab-focuses-workspace ()
  "T60: open-tab calls select-workspace and set-app-focus for existing workspace.
The workspace is resolved by heading name; select-workspace receives the
fresh workspace ref."
  :tags '(:e2e :simulated :unit :fast :stable)
  (test-cmux--with-mock
    ;; Workspace exists under the fixture heading title ("Test Story")
    (push (cons "list-workspaces" "  workspace:mock-1  Test Story\n")
          test-cmux--mock-responses)
    (push (cons "list-pane-surfaces" "* surface:existing-123  ~  [selected]")
          test-cmux--mock-responses)
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (save-excursion
        (goto-char (point-min))
        (re-search-forward ":CUSTOM_ID: test-cmux-story-existing" nil t)
        (org-back-to-heading t)
        (code-agent-org-cmux-open-tab)
        ;; Should have called select-workspace with the ref from name lookup
        (let ((select-calls (test-cmux--mock-calls-for "select-workspace")))
          (should select-calls)
          (should (member "workspace:mock-1" (cdar select-calls))))
        ;; Should have called set-app-focus
        (should (test-cmux--mock-calls-for "set-app-focus"))))))

;;; ============================================================================
;;; T61: Stale workspace UUID recovery after cmux restart
;;; ============================================================================

(defvar test-cmux--org-stale-workspace
  "* Restart Recovery Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-session-recover-001
:CMUX_SURFACE_ID: surface:stale-999
:CMUX_WORKSPACE_ID: 00000000-57A1-0000-0000-000000000000
:CUSTOM_ID: test-cmux-recover-story
:END:

** Instruction 1
:PROPERTIES:
:CUSTOM_ID: test-cmux-recover-instr-1
:END:

#+begin_src ai
Recover me.
#+end_src
"
  "Org content with stale CMUX_WORKSPACE_ID and CMUX_SURFACE_ID simulating
cmux restart: the UUID no longer exists in cmux but a workspace with
the same name has been restored by cmux persistence.")

(ert-deftest test-cmux-ensure-session-resolves-by-name-after-cmux-restart ()
  "Ensure-session always resolves the workspace by heading name.
T61: After cmux restart, refs and UUIDs are regenerated but cmux
persists workspaces by name.  CMUX_SURFACE_ID on the heading is stale
and CMUX_WORKSPACE_ID has never been written (deprecated property).
ensure-session finds the live workspace by heading title, refreshes
the surface property, and returns the fresh surface-id — without
calling new-workspace."
  :tags '(:unit :stable)
  (let ((file (make-temp-file "test-cmux-recover-" nil ".org"))
        (calls nil)
        (new-workspace-count 0))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (with-current-buffer buf
            (org-mode)
            (let ((code-agent-org-auto-start-mcp-server nil))
              (code-agent-org-mode 1))
            (insert test-cmux--org-stale-workspace)
            (save-buffer))
          ;; Clear hash tables (simulate Emacs restart too — worst case)
          (remhash "test-cmux-session-recover-001"
                   code-agent-org-terminal--workspace-to-session-key)
          (remhash "test-cmux-session-recover-001"
                   code-agent-org-cmux--workspace-to-surface)
          (remhash "test-cmux-session-recover-001"
                   code-agent-org-cmux--workspace-to-cmux-id)
          ;; Argument-aware cmux mock that simulates a cmux restart:
          ;; - old UUID returns "not_found"
          ;; - list-workspaces shows a workspace with the matching name
          ;; - sidebar-state returns the fresh UUID
          ;; - list-pane-surfaces returns the fresh surface
          (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                     (lambda (subcmd &rest args)
                       (push (cons subcmd args) calls)
                       (cond
                        ;; tree with stale UUID → error (cmux restart)
                        ((and (string= subcmd "tree")
                              (member "00000000-57A1-0000-0000-000000000000"
                                      args))
                         (error "not_found: Workspace not found"))
                        ;; tree with fresh workspace/UUID → alive
                        ((and (string= subcmd "tree")
                              (or (member "workspace:7" args)
                                  (member "11111111-FE51-0000-0000-000000000000"
                                          args)))
                         "workspace workspace:7 \"Restart Recovery Story\"")
                        ;; list-workspaces → has matching name
                        ((string= subcmd "list-workspaces")
                         (concat "  workspace:1  Other Workspace\n"
                                 "* workspace:7  Restart Recovery Story  [selected]\n"
                                 "  workspace:9  Another\n"))
                        ;; sidebar-state for workspace:7 → fresh UUID
                        ((and (string= subcmd "sidebar-state")
                              (member "workspace:7" args))
                         (concat "tab=11111111-FE51-0000-0000-000000000000\n"
                                 "color=#1565C0\n"))
                        ;; list-pane-surfaces for workspace:7 → fresh surface
                        ((and (string= subcmd "list-pane-surfaces")
                              (member "workspace:7" args))
                         "* surface:42  Restart Recovery Story  [selected]")
                        ;; capture-pane (verbose start) → ready screen
                        ((string= subcmd "capture-pane")
                         "claude-code-ready")
                        ;; new-workspace must NOT be called
                        ((string= subcmd "new-workspace")
                         (cl-incf new-workspace-count)
                         "OK workspace:UNEXPECTED")
                        (t "ok")))))
            (with-current-buffer buf
              (test-cmux--goto-ai-block)
              (let ((surface (code-agent-org-cmux--ensure-session)))
                ;; Returns the fresh surface, not the stale one
                (should (equal surface "surface:42"))
                ;; No new workspace was created
                (should (zerop new-workspace-count))
                ;; CMUX_SURFACE_ID refreshed to the fresh value (only
                ;; property we persist; workspace identity lives in
                ;; the heading title)
                (save-excursion
                  (code-agent-org-terminal-goto-session-heading)
                  (should (equal "surface:42"
                                 (org-entry-get nil "CMUX_SURFACE_ID"))))
                ;; Hash tables point to fresh workspace
                (should (equal "surface:42"
                               (gethash "test-cmux-session-recover-001"
                                        code-agent-org-cmux--workspace-to-surface)))
                (should (equal "11111111-FE51-0000-0000-000000000000"
                               (gethash "test-cmux-session-recover-001"
                                        code-agent-org-cmux--workspace-to-cmux-id)))
                ;; E03 extensions: verify restore-workspace side effects
                ;; after phase 2 recovery
                ;; Verbose timer started
                (let ((sk (code-agent-org-current-session-key)))
                  (should (code-agent-org-session-get sk :verbose-follow-process)))
                ;; list-workspaces was queried for name lookup
                (should (cl-find "list-workspaces" calls
                                 :key #'car :test #'equal))
                ;; rename-tab was called (restore-workspace renames)
                (should (cl-find "rename-tab" calls
                                 :key #'car :test #'equal)))))
          ;; Cleanup
          (let ((sk (with-current-buffer buf
                      (code-agent-org-current-session-key))))
            (when sk (code-agent-org-cmux--stop-verbose sk)))
          (remhash "test-cmux-session-recover-001"
                   code-agent-org-terminal--workspace-to-session-key)
          (remhash "test-cmux-session-recover-001"
                   code-agent-org-cmux--workspace-to-surface)
          (remhash "test-cmux-session-recover-001"
                   code-agent-org-cmux--workspace-to-cmux-id)
          (kill-buffer buf))
      (delete-file file))))

(ert-deftest test-cmux-find-workspace-by-name-parses-list ()
  "T61b: code-agent-org-cmux--find-workspace-by-name parses list-workspaces output.
Handles selected marker, leading whitespace, and multi-word names."
  :tags '(:unit :stable)
  (cl-letf (((symbol-function 'code-agent-org-cmux--call)
             (lambda (subcmd &rest _args)
               (when (string= subcmd "list-workspaces")
                 (concat "  workspace:1  deployment\n"
                         "  workspace:9  PCR dev1\n"
                         "  workspace:11  PCR dev2\n"
                         "* workspace:13  Emacs-claude dev1  [selected]\n")))))
    ;; Exact match wins
    (should (equal "workspace:9"
                   (code-agent-org-cmux--find-workspace-by-name "PCR dev1")))
    (should (equal "workspace:11"
                   (code-agent-org-cmux--find-workspace-by-name "PCR dev2")))
    ;; Selected workspace parses correctly (strips [selected])
    (should (equal "workspace:13"
                   (code-agent-org-cmux--find-workspace-by-name "Emacs-claude dev1")))
    ;; Single-word name
    (should (equal "workspace:1"
                   (code-agent-org-cmux--find-workspace-by-name "deployment")))
    ;; Missing name
    (should-not (code-agent-org-cmux--find-workspace-by-name "nonexistent"))))


;;; ============================================================================
;;; E01: Launch fresh workspace — full call sequence verification
;;; ============================================================================

(defvar test-cmux--org-launch-with-color
  "* Launch Color Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-session-launch-001
:CLAUDE_BACKEND: cmux
:WORKSPACE_COLOR: Blue
:CUSTOM_ID: test-cmux-launch-color
:END:

** Instruction 1
:PROPERTIES:
:CUSTOM_ID: test-cmux-launch-instr-1
:END:

#+begin_src ai
Hello world.
#+end_src
"
  "Org content for E01: fresh workspace launch with color.")

(ert-deftest test-cmux-launch-workspace-full-sequence ()
  "E01: Fresh workspace launch verifies the complete call sequence.
Color and verbose must be applied BEFORE wait-for-ready."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-launch-" nil ".org"))
        (calls nil)
        (call-order nil))
    (unwind-protect
        (progn
          (let ((buf (find-file-noselect file)))
            (unwind-protect
                (progn
                  (with-current-buffer buf
                    (org-mode)
                    (let ((code-agent-org-auto-start-mcp-server nil))
                      (code-agent-org-mode 1))
                    (insert test-cmux--org-launch-with-color)
                    (save-buffer))
                  ;; Mock cmux CLI, tracking call order
                  (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                             (lambda (subcmd &rest args)
                               (push (cons subcmd args) calls)
                               (push subcmd call-order)
                               (cond
                                ((string= subcmd "new-workspace") "OK workspace:mock-42")
                                ((string= subcmd "list-pane-surfaces")
                                 "* surface:mock-77  Launch Color Story  [selected]")
                                ((string= subcmd "sidebar-state")
                                 "tab=AABB1122-3344-5566-7788-99AABBCCDDEE\ncolor=#1565C0")
                                ((string= subcmd "capture-pane")
                                 (test-cmux--read-fixture "capture-pane-ready.txt"))
                                ((string= subcmd "tree")
                                 "workspace workspace:mock-42 \"Launch Color Story\"")
                                (t "ok")))))
                    (with-current-buffer buf
                      (test-cmux--goto-ai-block)
                      (let ((surface (code-agent-org-cmux--ensure-session)))
                        ;; 1. Returns the correct surface
                        (should (equal surface "surface:mock-77"))
                        ;; 2. new-workspace was called
                        (should (cl-find "new-workspace" calls :key #'car :test #'equal))
                        ;; 3. CMUX_SURFACE_ID persisted (only property we write;
                        ;; workspace identity = heading title, not a UUID)
                        (save-excursion
                          (code-agent-org-terminal-goto-session-heading)
                          (should (equal "surface:mock-77"
                                         (org-entry-get nil "CMUX_SURFACE_ID"))))
                        ;; 4. Hash tables populated (UUID resolved from ref)
                        (should (equal "surface:mock-77"
                                       (gethash "test-cmux-session-launch-001"
                                                code-agent-org-cmux--workspace-to-surface)))
                        (should (gethash "test-cmux-session-launch-001"
                                         code-agent-org-terminal--workspace-to-session-key))
                        (should (equal "AABB1122-3344-5566-7788-99AABBCCDDEE"
                                       (gethash "test-cmux-session-launch-001"
                                                code-agent-org-cmux--workspace-to-cmux-id)))
                        ;; 5. rename-workspace and rename-tab called
                        (should (cl-find "rename-workspace" calls :key #'car :test #'equal))
                        (should (cl-find "rename-tab" calls :key #'car :test #'equal))
                        ;; 6. Color applied (set-status called)
                        (should (cl-find "set-status" calls :key #'car :test #'equal))
                        ;; 7. Color applied BEFORE wait-for-ready (capture-pane)
                        (let* ((order (nreverse call-order))
                               (color-pos (cl-position "set-status" order :test #'equal))
                               (wait-pos (cl-position "capture-pane" order :test #'equal)))
                          (when (and color-pos wait-pos)
                            (should (< color-pos wait-pos))))))))
              ;; Inner cleanup: stop verbose, clear hash tables, kill buffer
              (let ((sk (with-current-buffer buf (code-agent-org-current-session-key))))
                (when sk (code-agent-org-cmux--stop-verbose sk)))
              (remhash "test-cmux-session-launch-001" code-agent-org-terminal--workspace-to-session-key)
              (remhash "test-cmux-session-launch-001" code-agent-org-cmux--workspace-to-surface)
              (remhash "test-cmux-session-launch-001" code-agent-org-cmux--workspace-to-cmux-id)
              (kill-buffer buf))))
      ;; Outer cleanup: delete temp file
      (delete-file file))))

;;; ============================================================================
;;; E04: Restart Claude Code in existing tab
;;; ============================================================================

(ert-deftest test-cmux-restart-sends-exit-then-relaunches ()
  "E04: code-agent-org-cmux-restart sends /exit, waits for shell, relaunches.
Verifies the restart sequence: ensure-session refreshes surface, /exit sent
to running Claude Code, shell prompt detected via capture-pane, fresh
launch command sent, verbose timer restarted."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-restart-" nil ".org"))
        (calls nil)
        (capture-count 0))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (unwind-protect
              (progn
                (with-current-buffer buf
                  (org-mode)
                  (let ((code-agent-org-auto-start-mcp-server nil))
                    (code-agent-org-mode 1))
                  (insert test-cmux--org-content-with-surface)
                  (save-buffer))
                ;; Mock: capture-pane returns Claude Code screen first,
                ;; then shell prompt on retry (simulating /exit completing).
                ;; sleep-for is no-op to avoid 15s wait.
                ;; run-at-time is no-op to avoid /ide timer firing.
                (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                           (lambda (subcmd &rest args)
                             (push (cons subcmd args) calls)
                             (cond
                              ;; tree: workspace is alive
                              ((string= subcmd "tree")
                               "workspace workspace:mock-1 \"Test\"")
                              ;; capture-pane: first call = Claude Code running,
                              ;; subsequent = shell prompt ($ at end)
                              ((string= subcmd "capture-pane")
                               (setq capture-count (1+ capture-count))
                               (if (<= capture-count 1)
                                   "  Claude Code\n  -- INSERT --"
                                 "jingtao@mac ~/projects $ "))
                              (t "ok"))))
                          ((symbol-function 'sleep-for) (lambda (&rest _) nil)))
                  (with-current-buffer buf
                    (test-cmux--goto-ai-block)
                    (code-agent-org-cmux-restart)
                    ;; 1. /exit was sent (Claude Code was running, not at shell)
                    (should (cl-find "send" calls
                                     :test (lambda (key cell)
                                             (and (string= (car cell) key)
                                                  (member "/exit" (cdr cell))))))
                    ;; 2. Return key sent after /exit
                    (should (cl-find "send-key" calls
                                     :test (lambda (key cell)
                                             (and (string= (car cell) key)
                                                  (member "Return" (cdr cell))))))
                    ;; 3. Launch command sent (contains newline = enter)
                    (let ((send-calls (cl-remove-if-not
                                       (lambda (c) (string= (car c) "send"))
                                       calls)))
                      ;; At least 2 send calls: /exit + launch-cmd
                      (should (>= (length send-calls) 2)))
                    ;; 4. Verbose timer restarted
                    (let ((sk (code-agent-org-current-session-key)))
                      (should (code-agent-org-session-get sk :verbose-follow-process))))))
            ;; Cleanup
            (let ((sk (with-current-buffer buf (code-agent-org-current-session-key))))
              (when sk (code-agent-org-cmux--stop-verbose sk)))
            (remhash "test-cmux-session-003" code-agent-org-terminal--workspace-to-session-key)
            (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-surface)
            (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-cmux-id)
            (kill-buffer buf)))
      (delete-file file))))

;;; ============================================================================
;;; Restart helpers — pure-function tests (no cmux)
;;; ============================================================================

(ert-deftest test-cmux-claude-has-bridge-hooks-p-matches-launcher-argv ()
  "`--claude-has-bridge-hooks-p' returns truthy when the surface's claude
process argv contains `workspace-hooks.json' — the marker our launcher
appends but cmux's session-restore strips.  This is the 2026-05-26
pre-flight that decides whether to auto-relaunch before sending a
prompt."
  :tags '(:unit :stable)
  ;; Mock the surface-tty lookup + ps call.  The function returns nil
  ;; on any introspection failure (so the caller defaults to restart),
  ;; so we exercise the three branches: missing tty / no claude /
  ;; claude-with-hooks / claude-without-hooks.
  (cl-letf (((symbol-function 'code-agent-org-cmux--surface-tty)
             (lambda (sid) (cond ((string= sid "with-hooks") "ttys001")
                                  ((string= sid "no-hooks")   "ttys002")
                                  ((string= sid "no-claude")  "ttys003")
                                  (t nil)))))
    ;; ttys001 → claude with workspace-hooks.json
    (cl-letf (((symbol-function 'call-process)
               (lambda (_program _infile _destination _display &rest args)
                 (let ((tty (cadr args)))
                   (cond
                    ((string= tty "ttys001")
                     (insert "~/.local/bin/claude --settings "
                             "~/projects/emacs-agent/workspace-hooks.json "
                             "--resume foo --name bar\n"))
                    ((string= tty "ttys002")
                     (insert "~/.local/bin/claude --resume foo\n"))
                    ((string= tty "ttys003")
                     (insert "/bin/zsh\n"))
                    (t (insert "")))
                   0))))
      (should (code-agent-org-cmux--claude-has-bridge-hooks-p "with-hooks"))
      (should-not (code-agent-org-cmux--claude-has-bridge-hooks-p "no-hooks"))
      (should-not (code-agent-org-cmux--claude-has-bridge-hooks-p "no-claude"))
      ;; surface-tty returned nil → entire function falls through to nil
      ;; (the caller then restarts as the safe fallback).
      (should-not (code-agent-org-cmux--claude-has-bridge-hooks-p "missing-surface")))))

(ert-deftest test-cmux-ensure-hooks-wired-noop-when-hooks-present ()
  "`--ensure-hooks-wired' is a no-op when the claude process is already
correctly wired.  Critically: it does NOT call `code-agent-org-cmux-restart'
in this case — that would interrupt a healthy session."
  :tags '(:unit :stable)
  (let ((restart-called nil))
    (cl-letf (((symbol-function 'code-agent-org-cmux--claude-has-bridge-hooks-p)
               (lambda (_) t))
              ((symbol-function 'code-agent-org-cmux-restart)
               (lambda () (setq restart-called t))))
      (code-agent-org-cmux--ensure-hooks-wired "surface:42")
      (should-not restart-called))))

(ert-deftest test-cmux-ensure-hooks-wired-restarts-when-hooks-missing ()
  "When the running claude lacks workspace-bridge hooks, the pre-flight
calls restart + waits for the freshly-launched claude to be ready.
This closes the recurring `cmux session-restore drops hooks → prompts
silently vanish' failure mode."
  :tags '(:unit :stable)
  (let ((restart-called nil)
        (wait-called nil)
        (code-agent-org-cmux-auto-relaunch-on-missing-hooks t))
    (cl-letf (((symbol-function 'code-agent-org-cmux--claude-has-bridge-hooks-p)
               (lambda (_) nil))
              ((symbol-function 'code-agent-org-cmux-restart)
               (lambda () (setq restart-called t)))
              ((symbol-function 'code-agent-org-cmux--wait-for-ready)
               (lambda (_) (setq wait-called t) t)))
      (code-agent-org-cmux--ensure-hooks-wired "surface:42")
      (should restart-called)
      (should wait-called))))

(ert-deftest test-cmux-ensure-hooks-wired-opt-out-via-defcustom ()
  "Setting `code-agent-org-cmux-auto-relaunch-on-missing-hooks' to nil
disables the auto-fix.  The function then just warns and lets the
prompt go through (matching the pre-2026-05-26 behaviour for users
who prefer to relaunch manually)."
  :tags '(:unit :stable)
  (let ((restart-called nil)
        (code-agent-org-cmux-auto-relaunch-on-missing-hooks nil))
    (cl-letf (((symbol-function 'code-agent-org-cmux--claude-has-bridge-hooks-p)
               (lambda (_) nil))
              ((symbol-function 'code-agent-org-cmux-restart)
               (lambda () (setq restart-called t))))
      (code-agent-org-cmux--ensure-hooks-wired "surface:42")
      (should-not restart-called))))

(ert-deftest test-cmux-shell-prompt-p-recognises-common-prompts ()
  "Regression: the original restart code used `\\s*$` (bare backslash-s)
which never matches anything in elisp regex.  The fix uses `\\s-*$`
(syntax-class whitespace).  Without this, every restart silently
skipped the `at-shell` shortcut and always went through send /exit."
  :tags '(:unit :stable)
  (should (code-agent-org-cmux--shell-prompt-p "stuff\n$ "))
  (should (code-agent-org-cmux--shell-prompt-p "stuff\n$"))
  (should (code-agent-org-cmux--shell-prompt-p "stuff\n❯ "))
  (should (code-agent-org-cmux--shell-prompt-p "stuff\n% "))
  (should-not (code-agent-org-cmux--shell-prompt-p "stuff\n> "))
  (should-not (code-agent-org-cmux--shell-prompt-p "Claude Code running"))
  (should-not (code-agent-org-cmux--shell-prompt-p nil))
  (should-not (code-agent-org-cmux--shell-prompt-p "")))

(ert-deftest test-cmux-surface-state-classifies-three-cases ()
  "`--surface-state' returns 'claude / 'shell / 'unknown based on screen
markers — the restart command relies on this to decide whether to
send /exit before launching a fresh agent."
  :tags '(:unit :stable)
  ;; Claude TUI in foreground — any of the three markers wins.
  (should (eq (code-agent-org-cmux--surface-state
               "Some output\n-- INSERT --\n? for shortcuts")
              'claude))
  (should (eq (code-agent-org-cmux--surface-state
               "Some output\nbypass permissions on")
              'claude))
  (should (eq (code-agent-org-cmux--surface-state
               "✻ Welcome to Claude Code")
              'claude))
  ;; Shell prompt at end of screen.
  (should (eq (code-agent-org-cmux--surface-state
               "jingtao@mac ~/p $ ")
              'shell))
  (should (eq (code-agent-org-cmux--surface-state
               "stuff\n❯ ")
              'shell))
  ;; Claude markers WIN over a trailing shell-looking line — important
  ;; for the freshly-launched-on-top-of-old-prompt edge case where
  ;; both markers might appear on the same captured screen.
  (should (eq (code-agent-org-cmux--surface-state
               "old shell $\n-- INSERT --\nclaude is here")
              'claude))
  ;; Neither — fall back to unknown so restart picks the safe path.
  (should (eq (code-agent-org-cmux--surface-state
               "")
              'unknown))
  (should (eq (code-agent-org-cmux--surface-state
               "running vim or something")
              'unknown)))

(ert-deftest test-cmux-launch-cmd-without-resume-strips-flag-and-value ()
  "`--launch-cmd-without-resume' removes `--resume <id>' but preserves
everything else, including env prefix, plugin dirs, and trailing args."
  :tags '(:unit :stable)
  (should (equal
           (code-agent-org-cmux--launch-cmd-without-resume
            "env A=1 claude --plugin-dir /p --resume 12d9 -- --foo bar")
           "env A=1 claude --plugin-dir /p -- --foo bar"))
  ;; No --resume present → no-op.
  (should (equal
           (code-agent-org-cmux--launch-cmd-without-resume
            "env A=1 claude --plugin-dir /p -- --foo")
           "env A=1 claude --plugin-dir /p -- --foo"))
  ;; --resume with shell-quoted UUID containing dashes still stripped.
  (should (equal
           (code-agent-org-cmux--launch-cmd-without-resume
            "claude --resume 12d99ebd-8976-41bc -- --x")
           "claude -- --x")))

;;; ============================================================================
;;; E04b: Restart — resume-failure fallback
;;; ============================================================================

(ert-deftest test-cmux-restart-recovers-from-stale-cli-session ()
  "When --resume <id> fails (Claude prints `No conversation found'),
restart MUST: drop the stale :CLAUDE_CLI_SESSION: property and
re-send a fresh launch command without --resume.  This closes the
2026-05-21 bug where the user was stranded at a bare shell after
pressing R on a workspace whose CLAUDE_CLI_SESSION had drifted."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-restart-resume-" nil ".org"))
        (calls nil)
        (capture-count 0)
        (resume-launched nil)
        (fresh-launched nil)
        (org-content
         "* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-session-resume-001
:CMUX_SURFACE_ID: surface:existing-456
:CMUX_WORKSPACE_ID: mock-workspace-uuid-456
:CUSTOM_ID: test-cmux-story-resume
:CLAUDE_CLI_SESSION: stale-uuid-deadbeef
:END:

** Instruction 1
:PROPERTIES:
:CUSTOM_ID: test-cmux-resume-instr-1
:END:

,#+begin_src ai
Test
,#+end_src
"))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (unwind-protect
              (progn
                (with-current-buffer buf
                  (org-mode)
                  (let ((code-agent-org-auto-start-mcp-server nil))
                    (code-agent-org-mode 1))
                  (erase-buffer)
                  ;; The string literal above used `,#+begin_src' to
                  ;; escape the comma-protected form; strip those
                  ;; commas so the actual buffer has the bare form
                  ;; the test fixtures use.
                  (insert (replace-regexp-in-string "^,#" "#" org-content))
                  (save-buffer))
                ;; capture-pane returns:
                ;;   1st call  — Claude Code running (forces /exit path)
                ;;   2nd call  — shell prompt after /exit
                ;;   3rd call  — "No conversation found" after launch (triggers fallback)
                ;;   4th+ call — shell prompt during fallback wait
                (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                           (lambda (subcmd &rest args)
                             (push (cons subcmd args) calls)
                             ;; Track launch sends so capture-pane is
                             ;; content-driven, not coupled to an exact poll
                             ;; count (wait-for-shell's poll count is an
                             ;; implementation detail that changed in 2026-06).
                             (when (string= subcmd "send")
                               (let ((txt (car (last args))))
                                 (when (and (stringp txt)
                                            (string-match-p "--resume[ ]+stale-uuid-deadbeef" txt))
                                   (setq resume-launched t))
                                 (when (and (stringp txt)
                                            (string-match-p "claude-workspace\\|claude " txt)
                                            (not (string-match-p "--resume" txt)))
                                   (setq fresh-launched t))))
                             (cond
                              ((string= subcmd "tree")
                               "workspace workspace:mock-1 \"Test\"")
                              ((string= subcmd "capture-pane")
                               (setq capture-count (1+ capture-count))
                               (cond
                                ;; Initial state detection: Claude running.
                                ((= capture-count 1) "  Claude Code\n  -- INSERT --")
                                ;; After the stale --resume launch but before the
                                ;; recovery relaunch: Claude bounced off the bad
                                ;; id, printing the banner above the shell.
                                ((and resume-launched (not fresh-launched))
                                 "No conversation found with session ID: stale-uuid-deadbeef\njingtao@mac ~/p $ ")
                                ;; Otherwise a plain shell prompt.
                                (t "jingtao@mac ~/p $ ")))
                              (t "ok"))))
                          ((symbol-function 'sleep-for) (lambda (&rest _) nil))
                          ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
                  (with-current-buffer buf
                    (test-cmux--goto-ai-block)
                    (code-agent-org-cmux-restart)
                    ;; The send calls in order:
                    ;;   1. "/exit"
                    ;;   2. launch-cmd (contains --resume stale-uuid-deadbeef)
                    ;;   3. fresh launch-cmd (no --resume)
                    (let* ((send-calls (cl-remove-if-not
                                        (lambda (c) (string= (car c) "send"))
                                        (reverse calls)))
                           (send-texts (mapcar (lambda (c)
                                                 ;; last positional arg = sent text
                                                 (car (last (cdr c))))
                                               send-calls)))
                      ;; 1. /exit was sent
                      (should (member "/exit" send-texts))
                      ;; 2. The first launch command carried --resume
                      (let ((with-resume
                             (cl-find-if (lambda (s)
                                           (string-match-p
                                            "--resume[ ]+stale-uuid-deadbeef" s))
                                         send-texts)))
                        (should with-resume))
                      ;; 3. A SECOND launch command was sent WITHOUT --resume
                      ;;    after the resume-failure was detected.  The launch
                      ;;    text comes from the active agent profile builder
                      ;;    (claude-workspace by default) which produces
                      ;;    ``uv run … claude-workspace …'' — match the script
                      ;;    name rather than the bare ``claude'' binary.
                      (let ((without-resume
                             (cl-find-if
                              (lambda (s)
                                (and (string-match-p "claude-workspace\\|claude " s)
                                     (not (string-match-p "--resume" s))
                                     (string-match-p "\n\\'" s)))
                              send-texts)))
                        (should without-resume)))
                    ;; 4. Stale CLAUDE_CLI_SESSION property dropped.
                    (save-excursion
                      (goto-char (point-min))
                      (re-search-forward "test-cmux-story-resume")
                      (org-back-to-heading t)
                      (should-not (org-entry-get nil "CLAUDE_CLI_SESSION"))))))
            ;; Cleanup
            (let ((sk (with-current-buffer buf
                        (code-agent-org-current-session-key))))
              (when sk (code-agent-org-cmux--stop-verbose sk)))
            (remhash "test-cmux-session-resume-001"
                     code-agent-org-terminal--workspace-to-session-key)
            (remhash "test-cmux-session-resume-001"
                     code-agent-org-cmux--workspace-to-surface)
            (remhash "test-cmux-session-resume-001"
                     code-agent-org-cmux--workspace-to-cmux-id)
            (kill-buffer buf)))
      (delete-file file))))

(ert-deftest test-cmux-restart-skips-fallback-when-resume-succeeds ()
  "Symmetric guard: when capture-pane shows a normal Claude TUI
(no `No conversation found' banner) the restart MUST NOT clear
:CLAUDE_CLI_SESSION: nor send a second launch command."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-restart-good-" nil ".org"))
        (calls nil)
        (capture-count 0)
        (launched nil)
        (org-content
         "* Test Story
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-session-good-001
:CMUX_SURFACE_ID: surface:existing-789
:CMUX_WORKSPACE_ID: mock-workspace-uuid-789
:CUSTOM_ID: test-cmux-story-good
:CLAUDE_CLI_SESSION: healthy-uuid-cafebabe
:END:

** Instruction 1
:PROPERTIES:
:CUSTOM_ID: test-cmux-good-instr-1
:END:

,#+begin_src ai
Test
,#+end_src
"))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (unwind-protect
              (progn
                (with-current-buffer buf
                  (org-mode)
                  (let ((code-agent-org-auto-start-mcp-server nil))
                    (code-agent-org-mode 1))
                  (erase-buffer)
                  (insert (replace-regexp-in-string "^,#" "#" org-content))
                  (save-buffer))
                (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                           (lambda (subcmd &rest args)
                             (push (cons subcmd args) calls)
                             ;; Content-driven (not poll-count-coupled): the
                             ;; post-launch screen depends on whether the launch
                             ;; command has been sent, not on an exact capture #.
                             (when (and (string= subcmd "send")
                                        (let ((txt (car (last args))))
                                          (and (stringp txt)
                                               (string-match-p "claude-workspace\\|claude " txt))))
                               (setq launched t))
                             (cond
                              ((string= subcmd "tree")
                               "workspace workspace:mock-1 \"Test\"")
                              ((string= subcmd "capture-pane")
                               (setq capture-count (1+ capture-count))
                               (cond
                                ;; Initial state detection: Claude running.
                                ((= capture-count 1) "  Claude Code\n  -- INSERT --")
                                ;; Post-launch: resume SUCCEEDED → healthy Claude
                                ;; TUI, no "No conversation found" banner.
                                (launched "  Claude Code\n  -- INSERT -- bypass permissions on")
                                ;; Between /exit and launch: a shell prompt.
                                (t "jingtao@mac ~/p $ ")))
                              (t "ok"))))
                          ((symbol-function 'sleep-for) (lambda (&rest _) nil))
                          ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
                  (with-current-buffer buf
                    (test-cmux--goto-ai-block)
                    (code-agent-org-cmux-restart)
                    ;; Only ONE launch command sent (the original with --resume).
                    ;; No second send without --resume.
                    (let* ((send-calls (cl-remove-if-not
                                        (lambda (c) (string= (car c) "send"))
                                        calls))
                           (launch-calls (cl-remove-if-not
                                          (lambda (c)
                                            (let ((txt (car (last (cdr c)))))
                                              (and (stringp txt)
                                                   (string-match-p
                                                    "claude-workspace\\|claude "
                                                    txt))))
                                          send-calls)))
                      (should (= (length launch-calls) 1)))
                    ;; :CLAUDE_CLI_SESSION: still present.
                    (save-excursion
                      (goto-char (point-min))
                      (re-search-forward "test-cmux-story-good")
                      (org-back-to-heading t)
                      (should (equal (org-entry-get nil "CLAUDE_CLI_SESSION")
                                     "healthy-uuid-cafebabe"))))))
            (let ((sk (with-current-buffer buf
                        (code-agent-org-current-session-key))))
              (when sk (code-agent-org-cmux--stop-verbose sk)))
            (remhash "test-cmux-session-good-001"
                     code-agent-org-terminal--workspace-to-session-key)
            (remhash "test-cmux-session-good-001"
                     code-agent-org-cmux--workspace-to-surface)
            (remhash "test-cmux-session-good-001"
                     code-agent-org-cmux--workspace-to-cmux-id)
            (kill-buffer buf)))
      (delete-file file))))

;;; ============================================================================
;;; E09: Verbose buffer created on session start
;;; ============================================================================

(ert-deftest test-cmux-verbose-buffer-created-with-header ()
  "E09: ensure-session creates verbose buffer named *cmux: <session-id>*
with header-line containing the session ID and keybinding hints."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-verbose-" nil ".org")))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (unwind-protect
              (progn
                (with-current-buffer buf
                  (org-mode)
                  (let ((code-agent-org-auto-start-mcp-server nil))
                    (code-agent-org-mode 1))
                  (insert test-cmux--org-content-with-surface)
                  (save-buffer))
                (remhash "test-cmux-session-003"
                         code-agent-org-terminal--workspace-to-session-key)
                (remhash "test-cmux-session-003"
                         code-agent-org-cmux--workspace-to-surface)
                (remhash "test-cmux-session-003"
                         code-agent-org-cmux--workspace-to-cmux-id)
                (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                           (lambda (subcmd &rest _args)
                             (cond
                              ((string= subcmd "tree")
                               "workspace workspace:mock-1 \"Test\"")
                              ((string= subcmd "capture-pane")
                               (test-cmux--read-fixture "capture-pane-ready.txt"))
                              (t "ok")))))
                  (with-current-buffer buf
                    (test-cmux--goto-ai-block)
                    (code-agent-org-cmux--ensure-session)
                    (let* ((sk (code-agent-org-current-session-key))
                           (vbuf (gethash sk code-agent--session-verbose-buffers)))
                      ;; Buffer exists and is live
                      (should vbuf)
                      (should (buffer-live-p vbuf))
                      ;; Buffer name contains session ID
                      (should (string-match-p "test-cmux-session-003"
                                              (buffer-name vbuf)))
                      ;; Header-line is set
                      (with-current-buffer vbuf
                        (should header-line-format))
                      ;; Timer is running
                      (should (code-agent-org-session-get sk :verbose-follow-process))))))
            ;; Cleanup
            (let ((sk (with-current-buffer buf (code-agent-org-current-session-key))))
              (when sk
                (code-agent-org-cmux--stop-verbose sk)
                (let ((vbuf (gethash sk code-agent--session-verbose-buffers)))
                  (when (and vbuf (buffer-live-p vbuf))
                    (kill-buffer vbuf)))))
            (remhash "test-cmux-session-003"
                     code-agent-org-terminal--workspace-to-session-key)
            (remhash "test-cmux-session-003"
                     code-agent-org-cmux--workspace-to-surface)
            (remhash "test-cmux-session-003"
                     code-agent-org-cmux--workspace-to-cmux-id)
            (kill-buffer buf)))
      (delete-file file))))

;;; ============================================================================
;;; E08: Sequential execution — cmux sends both, no Emacs-level queue
;;; ============================================================================

(ert-deftest test-cmux-sequential-execute-sends-both-prompts ()
  "E08: Two execute calls send both prompts — cmux has no Emacs-level queue.
Unlike the JSON stream backend which queues Block B when :busy, the cmux
backend sends both prompts directly to the terminal. Claude Code processes
them sequentially via its own input buffer."
  :tags '(:unit :stable :e2e)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      ;; Execute Block A
      (code-agent-org-cmux--execute-ai-block)
      (let ((send-count-after-a (length (test-cmux--mock-calls-for "send"))))
        ;; Execute again (Block B in same session) — should NOT error,
        ;; just send another prompt
        (code-agent-org-cmux--execute-ai-block)
        (let ((send-count-after-b (length (test-cmux--mock-calls-for "send"))))
          ;; Both prompts should have been sent (2 "send" calls total
          ;; for prompt text, plus initial sends from ensure-session)
          (should (> send-count-after-b send-count-after-a))
          ;; No queue was used — cmux sends directly
          (let ((sk (code-agent-org-current-session-key)))
            (should (zerop (code-agent-org--queue-count sk)))))))))

;;; ============================================================================
;;; E10: Verbose tick diff-based dedup
;;; ============================================================================

(ert-deftest test-cmux-verbose-tick-dedup ()
  "E10: Verbose buffer only updates when capture-pane content changes.
The prev-text variable prevents redundant buffer rewrites when the
terminal screen hasn't changed between ticks."
  :tags '(:unit :stable :e2e)
  (let ((vbuf (generate-new-buffer "*test-verbose-dedup*")))
    (unwind-protect
        (with-current-buffer vbuf
          (code-agent-org-cmux-verbose-mode)
          (setq-local code-agent-org-cmux--verbose-prev-text "")
          ;; Simulate first tick: new content → buffer updates
          (let ((content-v1 "Claude Code\n  -- INSERT --\n❯ hello"))
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert content-v1))
            (setq code-agent-org-cmux--verbose-prev-text content-v1)
            (should (equal (buffer-string) content-v1))
            ;; Simulate second tick: same content → should NOT rewrite
            ;; (we verify by checking prev-text is still the same)
            (should (string= code-agent-org-cmux--verbose-prev-text content-v1))
            ;; Simulate third tick: different content → updates
            (let ((content-v2 "Claude Code\n  -- INSERT --\n❯ world"))
              (should-not (string= code-agent-org-cmux--verbose-prev-text content-v2))
              ;; Apply the update (what verbose-tick sentinel does)
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert content-v2))
              (setq code-agent-org-cmux--verbose-prev-text content-v2)
              (should (equal (buffer-string) content-v2))
              (should (string= code-agent-org-cmux--verbose-prev-text content-v2)))))
      (kill-buffer vbuf))))

;;; ============================================================================
;;; E10b: verbose-workspace-uuid resolves via session-state + hash cache
;;; ============================================================================

(ert-deftest test-cmux-verbose-workspace-uuid-cache ()
  "Regression for PCR dev1 stale-verbose bug.

The verbose-tick reads the workspace UUID from the in-memory
`workspace-to-cmux-id' hash — populated by `restore-workspace' /
`launch-workspace' / `recover-session' when the workspace is resolved
by heading name (stable cmux/emacs identity).  The helper must return
nil on cache miss so `verbose-tick' skips the tick instead of passing a
stale surface ref to `cmux capture-pane --workspace', which freezes the
buffer forever with \"not_found: Workspace not found\"."
  :tags '(:unit :stable :e2e)
  (let* ((session-id "sdd-resolve-test-12345")
         (hash-uuid "TEST-HASH-UUID-0001")
         (session-key (format "/tmp/any.org::%s" session-id))
         (sessions-backup code-agent-org--sessions)
         (hash-backup (copy-hash-table code-agent-org-cmux--workspace-to-cmux-id)))
    (unwind-protect
        (progn
          ;; Clean slate
          (setq code-agent-org--sessions (make-hash-table :test 'equal))
          (remhash session-id code-agent-org-cmux--workspace-to-cmux-id)
          ;; Cache miss: no session-state, no hash entry → nil.
          (should-not (code-agent-org-cmux--verbose-workspace-uuid session-key))
          ;; Populate the hash (what restore-workspace / recover-session do
          ;; after name-based lookup) → helper returns it via session-id
          ;; parsed out of session-key.
          (puthash session-id hash-uuid code-agent-org-cmux--workspace-to-cmux-id)
          (should (equal (code-agent-org-cmux--verbose-workspace-uuid session-key)
                         hash-uuid))
          ;; Session-state slot populated → same lookup via different path.
          (remhash session-id code-agent-org-cmux--workspace-to-cmux-id)
          (should-not (code-agent-org-cmux--verbose-workspace-uuid session-key))
          (code-agent-org-session-put session-key :workspace-session-id session-id)
          (puthash session-id hash-uuid code-agent-org-cmux--workspace-to-cmux-id)
          (should (equal (code-agent-org-cmux--verbose-workspace-uuid session-key)
                         hash-uuid))
          ;; Nil session-key must not crash (defensive).
          (should-not (code-agent-org-cmux--verbose-workspace-uuid nil))
          ;; Session-key without "::" separator → no session-id, return nil.
          (should-not (code-agent-org-cmux--verbose-workspace-uuid "/tmp/no-sep.org")))
      ;; Cleanup
      (setq code-agent-org--sessions sessions-backup)
      (clrhash code-agent-org-cmux--workspace-to-cmux-id)
      (maphash (lambda (k v)
                 (puthash k v code-agent-org-cmux--workspace-to-cmux-id))
               hash-backup))))

;;; ============================================================================
;;; E11: Verbose restart on surface change
;;; ============================================================================

(ert-deftest test-cmux-verbose-restarts-on-surface-change ()
  "E11: start-verbose stops old timer and starts new when surface changes.
When a workspace is relaunched (new surface), calling start-verbose with
the new surface-id must cancel the old timer and create a fresh one
tracking the new surface."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-vrestart-" nil ".org")))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (unwind-protect
              (progn
                (with-current-buffer buf
                  (org-mode)
                  (let ((code-agent-org-auto-start-mcp-server nil))
                    (code-agent-org-mode 1))
                  (insert test-cmux--org-content-with-surface)
                  (save-buffer))
                ;; Seed the workspace→UUID cache so --start-verbose can
                ;; resolve the workspace and actually spawn a follow process.
                (puthash "test-cmux-session-003" "mock-uuid-123"
                         code-agent-org-cmux--workspace-to-cmux-id)
                (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                           (lambda (subcmd &rest _args)
                             (cond
                              ((string= subcmd "tree")
                               "workspace workspace:mock-1 \"Test\"")
                              ((string= subcmd "capture-pane") "screen v1")
                              (t "ok"))))
                          ;; Keep the follow-process harmless — spawn a
                          ;; long-lived no-op instead of real cmux.
                          ;; Keep the follow-process harmless — spawn a
                          ;; long-lived no-op via the UNMOCKED start-process.
                          ;; Binding start-process via cl-letf then recursing
                          ;; into it would blow the nesting limit.
                          ((symbol-function 'start-process)
                           (let ((orig (symbol-function 'start-process)))
                             (lambda (_name _buffer _program &rest _args)
                               (funcall orig "cmux-follow-mock" nil "sleep" "60")))))
                  (with-current-buffer buf
                    (test-cmux--goto-ai-block)
                    (let ((sk (code-agent-org-current-session-key)))
                      ;; Start verbose with surface-A
                      (code-agent-org-cmux--start-verbose "surface:A" sk)
                      (let ((proc-a (code-agent-org-session-get sk :verbose-follow-process)))
                        (should proc-a)
                        (should (equal "surface:A"
                                       (code-agent-org-session-get sk :verbose-surface-id)))
                        ;; Start verbose with surface-B (surface changed)
                        (code-agent-org-cmux--start-verbose "surface:B" sk)
                        (let ((proc-b (code-agent-org-session-get sk :verbose-follow-process)))
                          ;; Process replaced (not the same object)
                          (should proc-b)
                          (should-not (eq proc-a proc-b))
                          (should (equal "surface:B"
                                         (code-agent-org-session-get sk :verbose-surface-id)))
                          ;; Start verbose with SAME surface-B — no restart
                          (code-agent-org-cmux--start-verbose "surface:B" sk)
                          (let ((proc-b2 (code-agent-org-session-get sk :verbose-follow-process)))
                            (should (eq proc-b proc-b2)))))))))
            ;; Cleanup
            (let ((sk (with-current-buffer buf (code-agent-org-current-session-key))))
              (when sk (code-agent-org-cmux--stop-verbose sk)))
            (remhash "test-cmux-session-003" code-agent-org-terminal--workspace-to-session-key)
            (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-surface)
            (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-cmux-id)
            (kill-buffer buf)))
      (delete-file file))))

;;; ============================================================================
;;; E12: Stop verbose on session cleanup
;;; ============================================================================

(ert-deftest test-cmux-stop-verbose-cancels-timer ()
  "E12: stop-verbose cancels timer and clears :verbose-follow-process session state.
Ensures no orphan timers remain after cleanup."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-vstop-" nil ".org")))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (unwind-protect
              (progn
                (with-current-buffer buf
                  (org-mode)
                  (let ((code-agent-org-auto-start-mcp-server nil))
                    (code-agent-org-mode 1))
                  (insert test-cmux--org-content-with-surface)
                  (save-buffer))
                (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                           (lambda (subcmd &rest _args)
                             (cond
                              ((string= subcmd "tree")
                               "workspace workspace:mock-1 \"Test\"")
                              ((string= subcmd "capture-pane") "screen")
                              (t "ok")))))
                  (with-current-buffer buf
                    (test-cmux--goto-ai-block)
                    (let ((sk (code-agent-org-current-session-key)))
                      ;; Start verbose
                      (code-agent-org-cmux--start-verbose "surface:test" sk)
                      (should (code-agent-org-session-get sk :verbose-follow-process))
                      ;; Stop verbose
                      (code-agent-org-cmux--stop-verbose sk)
                      ;; Timer cleared
                      (should-not (code-agent-org-session-get sk :verbose-follow-process))
                      ;; Stopping again is safe (no error)
                      (code-agent-org-cmux--stop-verbose sk)
                      (should-not (code-agent-org-session-get sk :verbose-follow-process))))))
            ;; Cleanup
            (let ((sk (with-current-buffer buf (code-agent-org-current-session-key))))
              (when sk (code-agent-org-cmux--stop-verbose sk)))
            (remhash "test-cmux-session-003" code-agent-org-terminal--workspace-to-session-key)
            (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-surface)
            (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-cmux-id)
            (kill-buffer buf)))
      (delete-file file))))

;;; ============================================================================
;;; E13: Verbose buffer self-heals when user kills it
;;; ============================================================================

(ert-deftest test-cmux-verbose-buffer-self-heals-after-kill ()
  "E13: `--create-verbose-buffer' is idempotent — killing the
verbose buffer and calling the helper again returns a fresh live
buffer with the registry pointing at it.

Historical: earlier versions ran a 1 Hz timer that relied on this
helper being re-called each tick for self-healing.  After the
follow-process refactor (2026-04-22) there is no tick, so the test
now only asserts the helper's idempotency — that's what the rest
of the code (restart paths, recovery) depends on."
  :tags '(:unit :stable :e2e)
  (puthash "test-cmux-session-003" "mock-uuid-123"
           code-agent-org-cmux--workspace-to-cmux-id)
  (unwind-protect
      (let ((sk "/tmp/test-vheal.org::test-cmux-session-003")
            (buf1 (code-agent-org-cmux--create-verbose-buffer
                   "/tmp/test-vheal.org::test-cmux-session-003"
                   "surface:heal")))
        (should buf1)
        (should (buffer-live-p buf1))
        (kill-buffer buf1)
        (should-not (buffer-live-p buf1))
        (let ((buf2 (code-agent-org-cmux--create-verbose-buffer sk "surface:heal")))
          (should buf2)
          (should (buffer-live-p buf2))
          (should-not (eq buf1 buf2))
          (should (eq buf2 (gethash sk code-agent--session-verbose-buffers)))
          (kill-buffer buf2)))
    (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-cmux-id)
    (remhash "/tmp/test-vheal.org::test-cmux-session-003"
             code-agent--session-verbose-buffers)))

;;; ============================================================================
;;; E13b: Verbose buffer memory cap (regression for 1f016b8 leak)
;;; ============================================================================
;;
;; The --follow stream filter must bound the buffer size.  Before the fix,
;; the filter appended forever, so an active session would accumulate
;; megabytes of terminal scrollback in `*cmux: <id>*'.  Live Emacs
;; inspection on 2026-04-24 showed 3.47 MB in one such buffer.

(ert-deftest test-cmux-verbose-filter-caps-buffer-size ()
  "Filter bounds the verbose buffer at
`code-agent-multiplexer-verbose-buffer-max-size'.  Regression test: the
--follow stream filter (introduced in 1f016b8) appended forever."
  :tags '(:unit :stable :e2e)
  (let* ((code-agent-multiplexer-verbose-buffer-max-size 1024)
         (buf (get-buffer-create " *test-cmux-verbose-cap*"))
         (proc-buf (generate-new-buffer " *test-proc*"))
         (proc (start-process "test-cmux-cap" proc-buf "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'verbose-buffer buf)
          ;; Pump 5000 bytes through a 1024-byte cap.
          (dotimes (i 10)
            (let ((chunk (concat (make-string 499 (+ ?a i)) "\n")))
              (code-agent-org-cmux--verbose-follow-filter proc chunk)))
          (should (<= (buffer-size buf) code-agent-multiplexer-verbose-buffer-max-size))
          ;; Most recent content is retained.
          (should (with-current-buffer buf
                    (goto-char (point-max))
                    (search-backward (string (+ ?a 9)) nil t))))
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p proc-buf) (kill-buffer proc-buf))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest test-cmux-verbose-filter-trims-whole-lines ()
  "Filter trims whole lines from the start — no half-truncated
line at `point-min' after the cap triggers."
  :tags '(:unit :stable :e2e)
  (let* ((code-agent-multiplexer-verbose-buffer-max-size 100)
         (buf (get-buffer-create " *test-cmux-whole-lines*"))
         (proc-buf (generate-new-buffer " *test-proc2*"))
         (proc (start-process "test-cmux-whole" proc-buf "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'verbose-buffer buf)
          (dotimes (i 30)
            (code-agent-org-cmux--verbose-follow-filter
             proc (format "line-%02d-content\n" i)))
          (with-current-buffer buf
            (should (<= (buffer-size) code-agent-multiplexer-verbose-buffer-max-size))
            (goto-char (point-min))
            (should (looking-at "^line-"))))
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p proc-buf) (kill-buffer proc-buf))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest test-cmux-verbose-buffer-kill-stops-follow-process ()
  "Killing the *cmux: ...* buffer cleans up the follow subprocess.
Regression test: an orphan subprocess keeps streaming into
nothing, wasting ~34 MB RSS and a pipe per killed buffer."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-vkill-" nil ".org")))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (unwind-protect
              (progn
                (with-current-buffer buf
                  (org-mode)
                  (let ((code-agent-org-auto-start-mcp-server nil))
                    (code-agent-org-mode 1))
                  (insert test-cmux--org-content-with-surface)
                  (save-buffer))
                (puthash "test-cmux-session-003" "mock-uuid-123"
                         code-agent-org-cmux--workspace-to-cmux-id)
                (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                           (lambda (_s &rest _a) "ok"))
                          ((symbol-function 'start-process)
                           (let ((orig (symbol-function 'start-process)))
                             (lambda (_n _b _p &rest _a)
                               (funcall orig "cmux-kill-test" nil "sleep" "60")))))
                  (with-current-buffer buf
                    (test-cmux--goto-ai-block)
                    (let ((sk (code-agent-org-current-session-key)))
                      (code-agent-org-cmux--start-verbose "surface:test" sk)
                      (let ((proc (code-agent-org-session-get sk :verbose-follow-process))
                            (vbuf (gethash sk code-agent--session-verbose-buffers)))
                        (should (process-live-p proc))
                        (should (buffer-live-p vbuf))
                        (kill-buffer vbuf)
                        (should-not (process-live-p proc))
                        (should-not (code-agent-org-session-get sk :verbose-follow-process)))))))
            (let ((sk (with-current-buffer buf (code-agent-org-current-session-key))))
              (when sk (code-agent-org-cmux--stop-verbose sk)))
            (remhash "test-cmux-session-003" code-agent-org-cmux--workspace-to-cmux-id)
            (kill-buffer buf)))
      (delete-file file))))

;;; ============================================================================
;;; E14: Story switch updates ACTIVE_STORY and renames tab
;;; ============================================================================

(defvar test-cmux--org-workspace-with-stories
  "* Test Workspace
:PROPERTIES:
:CLAUDE_SESSION_ID: test-cmux-story-switch-001
:CMUX_WORKSPACE: test-switch
:CMUX_WORKSPACE_ID: mock-ws-uuid-switch
:CUSTOM_ID: test-cmux-ws-switch
:END:

** Story Alpha
:PROPERTIES:
:CUSTOM_ID: test-cmux-story-alpha
:END:

*** Workflow :sdd:
:PROPERTIES:
:CUSTOM_ID: test-cmux-story-alpha-wf
:END:

**** Instruction :claude_chat:
:PROPERTIES:
:CUSTOM_ID: test-cmux-story-alpha-instr
:END:

#+begin_src ai
Alpha query.
#+end_src
"
  "Org content with CMUX_WORKSPACE property for story-switch test.")

(ert-deftest test-cmux-story-switch-sets-active-and-renames-tab ()
  "E14: set-active-story updates ACTIVE_STORY property and fires hook
which calls rename-tab on the cmux workspace."
  :tags '(:unit :stable :e2e)
  (test-cmux--with-mock
    ;; Set up workspace-to-cmux-id so on-story-changed can find the UUID
    (puthash "test-cmux-story-switch-001" "mock-ws-uuid-switch"
             code-agent-org-cmux--workspace-to-cmux-id)
    (unwind-protect
        (test-cmux--with-org-buffer test-cmux--org-workspace-with-stories
          ;; Navigate inside the workspace
          (goto-char (point-min))
          (re-search-forward ":CUSTOM_ID: test-cmux-story-alpha-instr" nil t)
          (forward-line 1)
          ;; Verify workspace heading found
          (should (code-agent-org--find-workspace-heading))
          ;; No ACTIVE_STORY initially
          (should-not (save-excursion
                        (let ((ws (code-agent-org--find-workspace-heading)))
                          (goto-char (cdr ws))
                          (org-entry-get nil "ACTIVE_STORY"))))
          ;; Set active story
          (code-agent-org--set-active-story "Story Alpha")
          ;; ACTIVE_STORY property set
          (let ((active (save-excursion
                          (let ((ws (code-agent-org--find-workspace-heading)))
                            (goto-char (cdr ws))
                            (org-entry-get nil "ACTIVE_STORY")))))
            (should (equal active "Story Alpha")))
          ;; rename-tab was called via the hook
          (let ((tab-calls (test-cmux--mock-calls-for "rename-tab")))
            (should tab-calls)
            ;; Called with the workspace UUID
            (should (member "mock-ws-uuid-switch" (cdar tab-calls)))
            ;; Called with the story name
            (should (member "Story Alpha" (cdar tab-calls)))))
      ;; Cleanup
      (remhash "test-cmux-story-switch-001" code-agent-org-cmux--workspace-to-cmux-id))))

;;; ============================================================================
;;; E15: Apply named color
;;; ============================================================================

(ert-deftest test-cmux-resolve-color-named-presets ()
  "E15: resolve-color maps named colors to hex and passes hex through."
  :tags '(:unit :stable :e2e)
  ;; Named colors (case-insensitive)
  (should (equal "#C0392B" (code-agent-org-cmux--resolve-color "Red")))
  (should (equal "#1565C0" (code-agent-org-cmux--resolve-color "blue")))
  (should (equal "#006B6B" (code-agent-org-cmux--resolve-color "Teal")))
  (should (equal "#6A1B9A" (code-agent-org-cmux--resolve-color "PURPLE")))
  ;; Hex passthrough
  (should (equal "#C0392B" (code-agent-org-cmux--resolve-color "#C0392B")))
  ;; Unknown returns nil
  (should-not (code-agent-org-cmux--resolve-color "unknown-color"))
  ;; Nil returns nil
  (should-not (code-agent-org-cmux--resolve-color nil)))

(ert-deftest test-cmux-apply-color-calls-set-status ()
  "E15b: apply-color calls set-status with resolved hex color and icon."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-color-" nil ".org"))
        (calls nil))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (unwind-protect
              (progn
                (with-current-buffer buf
                  (org-mode)
                  (insert "* Color Test
:PROPERTIES:
:CLAUDE_SESSION_ID: test-color-001
:WORKSPACE_COLOR: Blue
:WORKSPACE_ICON: bolt.fill
:CUSTOM_ID: test-color-story
:END:

#+begin_src ai
test
#+end_src
")
                  (save-buffer))
                (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                           (lambda (subcmd &rest args)
                             (push (cons subcmd args) calls)
                             "ok")))
                  (with-current-buffer buf
                    (goto-char (point-min))
                    (re-search-forward "#+begin_src ai" nil t)
                    (forward-line 1)
                    (code-agent-org-cmux--apply-color "workspace:test")
                    ;; set-status called with hex color
                    (let ((status-call (cl-find "set-status" calls
                                               :key #'car :test #'equal)))
                      (should status-call)
                      (should (member "#1565C0" (cdr status-call)))
                      ;; Icon passed
                      (should (member "bolt.fill" (cdr status-call)))))))
            (kill-buffer buf)))
      (delete-file file))))

;;; ============================================================================
;;; E24: Loop send dispatches prompt
;;; ============================================================================

(ert-deftest test-cmux-loop-send-writes-flag-and-sends ()
  "E24: loop-send writes from-emacs flag, registers query, and sends prompt."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-loop-" nil ".org"))
        (calls nil))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (unwind-protect
              (progn
                (with-current-buffer buf
                  (org-mode)
                  (let ((code-agent-org-auto-start-mcp-server nil))
                    (code-agent-org-mode 1))
                  (insert test-cmux--org-content-with-surface)
                  (save-buffer))
                (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                           (lambda (subcmd &rest args)
                             (push (cons subcmd args) calls)
                             (cond
                              ((string= subcmd "tree")
                               "workspace workspace:mock-1 \"Test\"")
                              ((string= subcmd "capture-pane") "screen")
                              (t "ok")))))
                  (with-current-buffer buf
                    (test-cmux--goto-ai-block)
                    (let ((sk (code-agent-org-current-session-key)))
                      ;; Set up loop state
                      (code-agent-org-session-put sk :loop-org-buffer buf)
                      (code-agent-org-session-put sk :loop-block-marker
                                               (copy-marker (point)))
                      (code-agent-org-session-put sk :loop-current 2)
                      (code-agent-org-session-put sk :loop-max 5)
                      ;; Send
                      (code-agent-org-cmux--loop-send
                       "test-cmux-session-003" "surface:existing-123"
                       "loop iteration prompt" sk)
                      ;; from-emacs flag written
                      (let ((flag-path (expand-file-name
                                        "test-cmux-session-003.from-emacs"
                                        code-agent-org-terminal-status-dir)))
                        (should (file-exists-p flag-path))
                        (ignore-errors (delete-file flag-path)))
                      ;; Prompt sent via "send"
                      (should (cl-find "send" calls :key #'car :test #'equal))
                      ;; Enter pressed via "send-key"
                      (should (cl-find "send-key" calls :key #'car :test #'equal))
                      ;; Clean up request-id file
                      (ignore-errors
                        (delete-file (expand-file-name
                                      "test-cmux-session-003.request-id"
                                      code-agent-org-terminal-status-dir)))))))
            (kill-buffer buf)))
      (delete-file file))))

;;; ============================================================================
;;; E28: Wait-for-ready detects INSERT mode
;;; ============================================================================

(ert-deftest test-cmux-wait-for-ready-detects-insert-mode ()
  "E28: wait-for-ready-poll returns quickly when capture-pane shows INSERT mode."
  :tags '(:unit :stable :e2e)
  (let ((poll-count 0))
    (cl-letf (((symbol-function 'code-agent-org-cmux--call)
               (lambda (subcmd &rest _args)
                 (when (string= subcmd "capture-pane")
                   (setq poll-count (1+ poll-count)))
                 "Claude Code v2.1\n❯\n  -- INSERT --"))
              ((symbol-function 'sleep-for) (lambda (&rest _) nil)))
      ;; Should return t immediately (first poll matches)
      (should (code-agent-org-cmux--wait-for-ready-poll "surface:test" 10))
      ;; Only 1 poll needed (INSERT found on first capture)
      (should (= 1 poll-count)))))

(ert-deftest test-cmux-wait-for-ready-poll-timeout ()
  "E28b: wait-for-ready-poll errors on timeout when screen never shows ready."
  :tags '(:unit :stable :e2e)
  (cl-letf (((symbol-function 'code-agent-org-cmux--call)
             (lambda (subcmd &rest _args)
               (when (string= subcmd "capture-pane")
                 "Loading Claude Code...")))
            ((symbol-function 'sleep-for) (lambda (&rest _) nil))
            ;; Make float-time always exceed deadline after first check
            ((symbol-function 'float-time)
             (let ((call-count 0))
               (lambda ()
                 (setq call-count (1+ call-count))
                 (if (= call-count 1) 0.0 999.0)))))
    (should-error (code-agent-org-cmux--wait-for-ready-poll "surface:test" 1)
                  :type 'error)))

;;; ============================================================================
;;; E33-E37: Edge cases and sidebar API
;;; ============================================================================

(ert-deftest test-cmux-tabmanager-recovery ()
  "E33: launch-workspace retries with new-window when TabManager unavailable."
  :tags '(:unit :stable :e2e)
  (let ((file (make-temp-file "test-cmux-tabmgr-" nil ".org"))
        (calls nil)
        (new-workspace-attempt 0))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (unwind-protect
              (progn
                (with-current-buffer buf
                  (org-mode)
                  (let ((code-agent-org-auto-start-mcp-server nil))
                    (code-agent-org-mode 1))
                  (insert test-cmux--org-content-with-backend)
                  (save-buffer))
                (cl-letf (((symbol-function 'code-agent-org-cmux--call)
                           (lambda (subcmd &rest args)
                             (push (cons subcmd args) calls)
                             (cond
                              ;; First new-workspace → TabManager error
                              ((string= subcmd "new-workspace")
                               (setq new-workspace-attempt (1+ new-workspace-attempt))
                               (if (= new-workspace-attempt 1)
                                   (error "TabManager not available")
                                 "OK workspace:mock-recovery"))
                              ((string= subcmd "new-window") "ok")
                              ((string= subcmd "list-pane-surfaces")
                               "* surface:mock-rcv  Test  [selected]")
                              ((string= subcmd "sidebar-state")
                               "tab=MOCK-UUID\ncolor=#000")
                              ((string= subcmd "capture-pane")
                               (test-cmux--read-fixture "capture-pane-ready.txt"))
                              (t "ok"))))
                          ((symbol-function 'sleep-for) (lambda (&rest _) nil)))
                  (with-current-buffer buf
                    (test-cmux--goto-ai-block)
                    (let ((surface (code-agent-org-cmux--ensure-session)))
                      ;; Should succeed after retry
                      (should (equal surface "surface:mock-rcv"))
                      ;; new-window was called (recovery)
                      (should (cl-find "new-window" calls :key #'car :test #'equal))
                      ;; Two new-workspace attempts
                      (should (= 2 new-workspace-attempt))))))
            ;; Cleanup
            (let ((sk (with-current-buffer buf (code-agent-org-current-session-key))))
              (when sk (code-agent-org-cmux--stop-verbose sk)))
            (remhash "test-cmux-session-002" code-agent-org-terminal--workspace-to-session-key)
            (remhash "test-cmux-session-002" code-agent-org-cmux--workspace-to-surface)
            (remhash "test-cmux-session-002" code-agent-org-cmux--workspace-to-cmux-id)
            (kill-buffer buf)))
      (delete-file file))))

(ert-deftest test-cmux-set-status-clear-status-round-trip ()
  "E36: set-status then clear-status calls correct cmux commands."
  :tags '(:unit :stable :e2e)
  (test-cmux--with-mock
    (code-agent-org-cmux-set-status "test_key" "test_value")
    (code-agent-org-cmux-clear-status "test_key")
    ;; set-status called
    (let ((set-calls (test-cmux--mock-calls-for "set-status")))
      (should set-calls)
      (should (member "test_key" (cdar set-calls)))
      (should (member "test_value" (cdar set-calls))))
    ;; clear-status called
    (let ((clear-calls (test-cmux--mock-calls-for "clear-status")))
      (should clear-calls)
      (should (member "test_key" (cdar clear-calls))))))

(ert-deftest test-cmux-set-progress-bar ()
  "E37: set-progress calls cmux with value and optional label."
  :tags '(:unit :stable :e2e)
  (test-cmux--with-mock
    (code-agent-org-cmux-set-progress "0.5" "Building...")
    (let ((calls (test-cmux--mock-calls-for "set-progress")))
      (should calls)
      (should (member "0.5" (cdar calls)))
      (should (member "Building..." (cdar calls))))))

;;; ============================================================================
;;; Restart robustness regressions (2026-06 edo-dev2 failure)
;;; ============================================================================

(ert-deftest test-cmux-surface-call-includes-workspace ()
  "`--surface-call' MUST pass --workspace.

Root cause of the 2026-06 edo-dev2 restart failure: send/send-key with
only --surface fail (\"Surface is not a terminal\") on a workspace cmux
is not currently rendering, so the /exit Return never submitted and the
launch command piled into the running agent's input."
  :tags '(:cmux-e2e :fast)
  (test-cmux--with-mock
    (code-agent-org-cmux--surface-call "workspace:6" "send-key" "surface:9" "Return")
    (let* ((call (car test-cmux--mock-calls))
           (subcommand (car call))
           (args (cdr call)))
      (should (equal subcommand "send-key"))
      (should (member "--workspace" args))
      (should (member "workspace:6" args))
      (should (member "--surface" args))
      (should (member "surface:9" args))
      (should (member "Return" args)))))

(ert-deftest test-cmux-surface-state-stale-frame-reads-as-shell ()
  "After Claude exits, its TUI frame lingers in the buffer above the shell
prompt.  Classifying the LIVE BOTTOM (short capture) must read 'shell, not
'claude — the 2026-06 false-abort came from an 8-line capture re-including
the lingering `bypass permissions' line."
  :tags '(:cmux-e2e :fast)
  ;; Live bottom after /exit: exit banner + shell prompt, no TUI markers.
  (should (eq 'shell
              (code-agent-org-cmux--surface-state
               "Resume this session with:\nclaude --resume \"x\"\n  ~/p  on  jt   ❯ ")))
  ;; Live Claude TUI bottom -> 'claude.
  (should (eq 'claude
              (code-agent-org-cmux--surface-state
               "  5h[..]\n  -- INSERT -- ⏵⏵ bypass permissions on · 1 shell"))))

(ert-deftest test-cmux-shell-ready-p-via-exit-banner ()
  "`--shell-ready-p' recognises Claude's exit banner as a shell signal even
when the starship `❯' input line is trimmed from the capture; and never
reports a live Claude TUI as shell-ready."
  :tags '(:cmux-e2e :fast)
  (should (code-agent-org-cmux--shell-ready-p
           "❯ /exit\n  ⎿  Bye!\nResume this session with:\nclaude --resume \"x\""))
  (should-not (code-agent-org-cmux--shell-ready-p
               "  -- INSERT -- ⏵⏵ bypass permissions on · 1 shell")))

(provide 'test-cmux-e2e-simulated)

;;; test-cmux-e2e-simulated.el ends here
