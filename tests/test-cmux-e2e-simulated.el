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
  (let* ((dir claude-org-terminal-status-dir)
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
                        claude-org-terminal-status-dir)))
        (should (file-exists-p flag-path))
        ;; Clean up
        (delete-file flag-path)
        (let ((req-id (claude-org-terminal--read-request-id "test-cmux-session-001")))
          (when req-id
            (claude-agent--unregister-query req-id)
            (delete-file (expand-file-name
                          "test-cmux-session-001.request-id"
                          claude-org-terminal-status-dir)
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
                          claude-org-terminal-status-dir)))
          (ignore-errors
            (delete-file (expand-file-name
                          "test-cmux-session-002.from-emacs"
                          claude-org-terminal-status-dir))))))))

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
                        claude-org-terminal-status-dir)))
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-001.from-emacs"
                        claude-org-terminal-status-dir)))))))

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

(ert-deftest test-cmux-execute-busy-lifecycle ()
  "E05: Full busy lifecycle: execute → hook sets busy → complete clears busy.
The :busy flag is set by the Python workspace bridge hook (handle-prompt),
not by execute-ai-block directly. This test simulates the hook-driven
lifecycle: execute sends prompt, bridge sets :busy t, query-completed
clears :busy nil. The busy flag controls header-line display and prevents
duplicate execution."
  :tags '(:unit :stable :e2e)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-basic
      (test-cmux--goto-ai-block)
      (let ((session-key (claude-org--current-session-key)))
        ;; Before execute: not busy
        (should-not (claude-org--session-get session-key :busy))
        ;; Execute sends prompt (does NOT set :busy — that's the bridge's job)
        (claude-org-cmux--execute-ai-block)
        (should-not (claude-org--session-get session-key :busy))
        ;; Simulate Python workspace bridge hook: handle-prompt sets :busy t
        (claude-org--session-put session-key :busy t)
        (should (claude-org--session-get session-key :busy))
        ;; get-status should now prevent duplicate execution
        ;; (mock capture-pane doesn't show busy patterns, but :busy session flag
        ;; would cause execute-ai-block to reject with "busy" error)
        ;; Complete clears busy
        (claude-org-cmux--query-completed "test-cmux-session-001")
        (should-not (claude-org--session-get session-key :busy))
        ;; Clean up files
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-001.request-id"
                        claude-org-terminal-status-dir)))
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-001.from-emacs"
                        claude-org-terminal-status-dir)))))))

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

(ert-deftest test-cmux-cancel-during-active-query ()
  "E06: Cancel during active query sends escape and clears state.
Full lifecycle: execute → bridge sets busy → cancel sends escape →
query-completed clears busy and unregisters query."
  :tags '(:unit :stable :e2e)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (test-cmux--goto-ai-block)
      ;; 1. Execute sets up the query
      (claude-org-cmux--execute-ai-block)
      (let ((session-key (claude-org--current-session-key))
            (req-id (claude-org-terminal--read-request-id "test-cmux-session-003")))
        ;; Query should be registered
        (should req-id)
        (should (claude-agent--get-active-query req-id))
        ;; 2. Simulate bridge setting busy (as hook would)
        (claude-org--session-put session-key :busy t)
        (should (claude-org--session-get session-key :busy))
        ;; 3. Cancel sends escape
        (claude-org-cmux-cancel)
        (let ((key-calls (test-cmux--mock-calls-for "send-key")))
          (should key-calls)
          (should (member "escape" (cdar key-calls))))
        ;; 4. query-completed fires (Python hook detects agent stopped)
        (claude-org-cmux--query-completed "test-cmux-session-003")
        ;; 5. Verify clean state: not busy, query unregistered
        (should-not (claude-org--session-get session-key :busy))
        (should-not (claude-agent--get-active-query req-id))
        ;; Clean up files
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-003.request-id"
                        claude-org-terminal-status-dir)))
        (ignore-errors
          (delete-file (expand-file-name
                        "test-cmux-session-003.from-emacs"
                        claude-org-terminal-status-dir)))))))

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
                          claude-org-terminal-status-dir)))
          (ignore-errors
            (delete-file (expand-file-name
                          "test-cmux-session-file-backend.from-emacs"
                          claude-org-terminal-status-dir))))))))

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
                            claude-org-terminal-status-dir)))
            (ignore-errors
              (delete-file (expand-file-name
                            "test-cmux-session-file-backend.from-emacs"
                            claude-org-terminal-status-dir)))))))))

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
                  (let ((claude-org-auto-start-mcp-server nil))
                    (claude-org-mode 1))
                  (insert test-cmux--org-content-with-surface)
                  (save-buffer))
                ;; Clear hash tables to simulate Emacs restart
                (remhash "test-cmux-session-003"
                         claude-org-terminal--workspace-to-session-key)
                (remhash "test-cmux-session-003"
                         claude-org-cmux--workspace-to-surface)
                (remhash "test-cmux-session-003"
                         claude-org-cmux--workspace-to-cmux-id)
                ;; Mock with call recording
                (cl-letf (((symbol-function 'claude-org-cmux--call)
                           (lambda (subcmd &rest args)
                             (push (cons subcmd args) calls)
                             (cond
                              ((string= subcmd "tree")
                               "workspace workspace:mock-1 \"Test\"")
                              ((string= subcmd "capture-pane")
                               (test-cmux--read-fixture "capture-pane-ready.txt"))
                              (t "ok")))))
                  (with-current-buffer buf
                    (test-cmux--goto-ai-block)
                    (let ((surface (claude-org-cmux--ensure-session)))
                      ;; Returns existing surface (not a new one)
                      (should (equal surface "surface:existing-123"))
                      ;; No new-workspace was called
                      (should-not (cl-find "new-workspace" calls
                                           :key #'car :test #'equal))
                      ;; Tab renamed
                      (should (cl-find "rename-tab" calls
                                       :key #'car :test #'equal))
                      ;; Verbose timer started
                      (let ((sk (claude-org--current-session-key)))
                        (should (claude-org--session-get sk :verbose-timer)))))))
            ;; Cleanup: stop verbose, clear state, kill buffer
            (let ((sk (with-current-buffer buf
                        (claude-org--current-session-key))))
              (when sk (claude-org-cmux--stop-verbose sk)))
            (remhash "test-cmux-session-003"
                     claude-org-terminal--workspace-to-session-key)
            (remhash "test-cmux-session-003"
                     claude-org-cmux--workspace-to-surface)
            (remhash "test-cmux-session-003"
                     claude-org-cmux--workspace-to-cmux-id)
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
      (let ((sk (claude-org--current-session-key)))
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
  (should (equal "" (claude-org--workspace-name-to-slug "日本語")))
  ;; Emoji stripped
  (should (equal "" (claude-org--workspace-name-to-slug "🚀🔥💡")))
  ;; Mixed ASCII and unicode: ASCII preserved, unicode stripped
  (should (equal "api-design" (claude-org--workspace-name-to-slug "API Design 🎯")))
  ;; Org-mode special chars: * # : |
  (should (equal "fix-bug-123" (claude-org--workspace-name-to-slug "fix bug *#123*")))
  (should (equal "table-col-a-col-b" (claude-org--workspace-name-to-slug "table: col-a | col-b")))
  ;; Plain ASCII passthrough
  (should (equal "hello-world" (claude-org--workspace-name-to-slug "Hello World")))
  ;; Leading/trailing special chars stripped
  (should (equal "test" (claude-org--workspace-name-to-slug "---test---")))
  ;; Empty string
  (should (equal "" (claude-org--workspace-name-to-slug ""))))

(ert-deftest test-cmux-custom-id-generation-unicode ()
  "T58b: CUSTOM_ID generation handles unicode in section names.
Non-ASCII chars are replaced with hyphens and collapsed."
  :tags '(:e2e :simulated :unit :fast :stable)
  ;; CJK section name: [:alnum:] includes unicode letters, so CJK chars preserved
  (let ((id (claude-org--generate-custom-id "sdd-001" "データベース設計")))
    (should (stringp id))
    (should (string-match-p "sdd-001" id))
    ;; CJK chars ARE alphanumeric in Emacs regex — preserved in CUSTOM_ID
    (should (string-match-p "データベース設計" id)))
  ;; Emoji section name: emoji are NOT [:alnum:], so stripped
  (let ((id (claude-org--generate-custom-id "sdd-002" "Deploy 🚀 Pipeline")))
    (should (stringp id))
    (should (string-match-p "deploy" id))
    (should (string-match-p "pipeline" id))
    ;; Emoji should be stripped (replaced by hyphens and collapsed)
    (should-not (string-match-p "🚀" id)))
  ;; Plain ASCII
  (let ((id (claude-org--generate-custom-id "sdd-003" "Research Output")))
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
      (let ((title (claude-org-terminal--tab-title)))
        (should (stringp title))
        ;; Title should contain the story name with accented chars
        (should (string-match-p "résumé review" title))))))

;;; ============================================================================
;;; T60: Open tab / focus workspace
;;; ============================================================================

(ert-deftest test-cmux-open-tab-focuses-workspace ()
  "T60: open-tab calls select-workspace and set-app-focus for existing workspace."
  :tags '(:e2e :simulated :unit :fast :stable)
  (test-cmux--with-mock
    (test-cmux--with-org-buffer test-cmux--org-content-with-surface
      (save-excursion
        (goto-char (point-min))
        (re-search-forward ":CUSTOM_ID: test-cmux-story-existing" nil t)
        (org-back-to-heading t)
        (claude-org-cmux-open-tab)
        ;; Should have called select-workspace
        (let ((select-calls (test-cmux--mock-calls-for "select-workspace")))
          (should select-calls)
          (should (member "mock-workspace-uuid-123" (cdar select-calls))))
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

(ert-deftest test-cmux-ensure-session-recovers-stale-uuid-via-name ()
  "Ensure-session recovers stale workspace UUID by looking up workspace name.
T61: After cmux restart, CMUX_WORKSPACE_ID is a UUID that no longer exists
and CMUX_SURFACE_ID is also stale. cmux has restored the workspace under
the same name (from its own persistence), but with a new ref, UUID, and
surface. ensure-session must detect the stale UUID, find the live workspace
by heading title, refresh the org properties, and return the fresh
surface-id — without calling new-workspace."
  :tags '(:unit :stable)
  (let ((file (make-temp-file "test-cmux-recover-" nil ".org"))
        (calls nil)
        (new-workspace-count 0))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (with-current-buffer buf
            (org-mode)
            (let ((claude-org-auto-start-mcp-server nil))
              (claude-org-mode 1))
            (insert test-cmux--org-stale-workspace)
            (save-buffer))
          ;; Clear hash tables (simulate Emacs restart too — worst case)
          (remhash "test-cmux-session-recover-001"
                   claude-org-terminal--workspace-to-session-key)
          (remhash "test-cmux-session-recover-001"
                   claude-org-cmux--workspace-to-surface)
          (remhash "test-cmux-session-recover-001"
                   claude-org-cmux--workspace-to-cmux-id)
          ;; Argument-aware cmux mock that simulates a cmux restart:
          ;; - old UUID returns "not_found"
          ;; - list-workspaces shows a workspace with the matching name
          ;; - sidebar-state returns the fresh UUID
          ;; - list-pane-surfaces returns the fresh surface
          (cl-letf (((symbol-function 'claude-org-cmux--call)
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
              (let ((surface (claude-org-cmux--ensure-session)))
                ;; Returns the fresh surface, not the stale one
                (should (equal surface "surface:42"))
                ;; No new workspace was created
                (should (zerop new-workspace-count))
                ;; Org properties refreshed to fresh values
                (save-excursion
                  (claude-org-terminal--goto-session-heading)
                  (should (equal "surface:42"
                                 (org-entry-get nil "CMUX_SURFACE_ID")))
                  (should (equal "11111111-FE51-0000-0000-000000000000"
                                 (org-entry-get nil "CMUX_WORKSPACE_ID"))))
                ;; Hash tables point to fresh workspace
                (should (equal "surface:42"
                               (gethash "test-cmux-session-recover-001"
                                        claude-org-cmux--workspace-to-surface)))
                (should (equal "11111111-FE51-0000-0000-000000000000"
                               (gethash "test-cmux-session-recover-001"
                                        claude-org-cmux--workspace-to-cmux-id)))
                ;; E03 extensions: verify restore-workspace side effects
                ;; after phase 2 recovery
                ;; Verbose timer started
                (let ((sk (claude-org--current-session-key)))
                  (should (claude-org--session-get sk :verbose-timer)))
                ;; list-workspaces was queried for name lookup
                (should (cl-find "list-workspaces" calls
                                 :key #'car :test #'equal))
                ;; rename-tab was called (restore-workspace renames)
                (should (cl-find "rename-tab" calls
                                 :key #'car :test #'equal)))))
          ;; Cleanup
          (let ((sk (with-current-buffer buf
                      (claude-org--current-session-key))))
            (when sk (claude-org-cmux--stop-verbose sk)))
          (remhash "test-cmux-session-recover-001"
                   claude-org-terminal--workspace-to-session-key)
          (remhash "test-cmux-session-recover-001"
                   claude-org-cmux--workspace-to-surface)
          (remhash "test-cmux-session-recover-001"
                   claude-org-cmux--workspace-to-cmux-id)
          (kill-buffer buf))
      (delete-file file))))

(ert-deftest test-cmux-find-workspace-by-name-parses-list ()
  "T61b: claude-org-cmux--find-workspace-by-name parses list-workspaces output.
Handles selected marker, leading whitespace, and multi-word names."
  :tags '(:unit :stable)
  (cl-letf (((symbol-function 'claude-org-cmux--call)
             (lambda (subcmd &rest _args)
               (when (string= subcmd "list-workspaces")
                 (concat "  workspace:1  deployment\n"
                         "  workspace:9  PCR dev1\n"
                         "  workspace:11  PCR dev2\n"
                         "* workspace:13  Emacs-claude dev1  [selected]\n")))))
    ;; Exact match wins
    (should (equal "workspace:9"
                   (claude-org-cmux--find-workspace-by-name "PCR dev1")))
    (should (equal "workspace:11"
                   (claude-org-cmux--find-workspace-by-name "PCR dev2")))
    ;; Selected workspace parses correctly (strips [selected])
    (should (equal "workspace:13"
                   (claude-org-cmux--find-workspace-by-name "Emacs-claude dev1")))
    ;; Single-word name
    (should (equal "workspace:1"
                   (claude-org-cmux--find-workspace-by-name "deployment")))
    ;; Missing name
    (should-not (claude-org-cmux--find-workspace-by-name "nonexistent"))))


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
                    (let ((claude-org-auto-start-mcp-server nil))
                      (claude-org-mode 1))
                    (insert test-cmux--org-launch-with-color)
                    (save-buffer))
                  ;; Mock cmux CLI, tracking call order
                  (cl-letf (((symbol-function 'claude-org-cmux--call)
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
                      (let ((surface (claude-org-cmux--ensure-session)))
                        ;; 1. Returns the correct surface
                        (should (equal surface "surface:mock-77"))
                        ;; 2. new-workspace was called
                        (should (cl-find "new-workspace" calls :key #'car :test #'equal))
                        ;; 3. Both org properties persisted
                        (save-excursion
                          (claude-org-terminal--goto-session-heading)
                          (should (equal "surface:mock-77"
                                         (org-entry-get nil "CMUX_SURFACE_ID")))
                          (should (equal "AABB1122-3344-5566-7788-99AABBCCDDEE"
                                         (org-entry-get nil "CMUX_WORKSPACE_ID"))))
                        ;; 4. Hash tables populated
                        (should (equal "surface:mock-77"
                                       (gethash "test-cmux-session-launch-001"
                                                claude-org-cmux--workspace-to-surface)))
                        (should (gethash "test-cmux-session-launch-001"
                                         claude-org-terminal--workspace-to-session-key))
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
              (let ((sk (with-current-buffer buf (claude-org--current-session-key))))
                (when sk (claude-org-cmux--stop-verbose sk)))
              (remhash "test-cmux-session-launch-001" claude-org-terminal--workspace-to-session-key)
              (remhash "test-cmux-session-launch-001" claude-org-cmux--workspace-to-surface)
              (remhash "test-cmux-session-launch-001" claude-org-cmux--workspace-to-cmux-id)
              (kill-buffer buf))))
      ;; Outer cleanup: delete temp file
      (delete-file file))))

;;; ============================================================================
;;; E04: Restart Claude Code in existing tab
;;; ============================================================================

(ert-deftest test-cmux-restart-sends-exit-then-relaunches ()
  "E04: claude-org-cmux-restart sends /exit, waits for shell, relaunches.
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
                  (let ((claude-org-auto-start-mcp-server nil))
                    (claude-org-mode 1))
                  (insert test-cmux--org-content-with-surface)
                  (save-buffer))
                ;; Mock: capture-pane returns Claude Code screen first,
                ;; then shell prompt on retry (simulating /exit completing).
                ;; sleep-for is no-op to avoid 15s wait.
                ;; run-at-time is no-op to avoid /ide timer firing.
                (cl-letf (((symbol-function 'claude-org-cmux--call)
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
                    (claude-org-cmux-restart)
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
                    (let ((sk (claude-org--current-session-key)))
                      (should (claude-org--session-get sk :verbose-timer))))))
            ;; Cleanup
            (let ((sk (with-current-buffer buf (claude-org--current-session-key))))
              (when sk (claude-org-cmux--stop-verbose sk)))
            (remhash "test-cmux-session-003" claude-org-terminal--workspace-to-session-key)
            (remhash "test-cmux-session-003" claude-org-cmux--workspace-to-surface)
            (remhash "test-cmux-session-003" claude-org-cmux--workspace-to-cmux-id)
            (kill-buffer buf)))
      (delete-file file))))

(provide 'test-cmux-e2e-simulated)

;;; test-cmux-e2e-simulated.el ends here
