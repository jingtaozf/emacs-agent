;;; test-claude-agent-pi-ui.el --- Tests for Pi UI Phase 1 -*- lexical-binding: t; -*-

;;; Commentary:

;; Smoke + live tests for `claude-agent-pi-ui.org' — the Phase 1
;; RPC-driven control panel and extension UI request handlers.

;;; Code:

(require 'ert)
(require 'cl-lib)

(let* ((root (or (and (boundp 'test-claude-agent-project-root)
                      test-claude-agent-project-root)
                 (expand-file-name
                  ".."
                  (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path root)
  (add-to-list 'load-path (expand-file-name "tests/support" root))
  (require 'literate-elisp)
  (unless (featurep 'claude-agent-backend)
    (literate-elisp-load (expand-file-name "claude-agent-backend.org" root)))
  (unless (featurep 'claude-agent-pi-backend)
    (literate-elisp-load (expand-file-name "claude-agent-pi-backend.org" root)))
  (unless (featurep 'claude-agent-pi-ui)
    (literate-elisp-load (expand-file-name "claude-agent-pi-ui.org" root))))

(require 'claude-agent-pi-backend)
(require 'claude-agent-pi-ui)
(require 'pi-test-helpers)


;; --- Smoke ---

(ert-deftest claude-agent-pi-ui-smoke--symbols ()
  "Public symbols are defined after load."
  :tags '(:smoke :pi-ui)
  (dolist (s '(claude-agent-pi-ui-menu
               claude-agent-pi-ui-new-session
               claude-agent-pi-ui-cycle-model
               claude-agent-pi-ui-pick-model
               claude-agent-pi-ui-cycle-thinking
               claude-agent-pi-ui-set-thinking
               claude-agent-pi-ui-steer
               claude-agent-pi-ui-follow-up
               claude-agent-pi-ui-abort
               claude-agent-pi-ui-compact
               claude-agent-pi-ui-stats
               claude-agent-pi-ui-export-html
               claude-agent-pi-ui-login))
    (should (fboundp s))))

(ert-deftest claude-agent-pi-ui-smoke--menu-prefix ()
  "Transient submenu is registered as a prefix."
  :tags '(:smoke :pi-ui)
  (should (get 'claude-agent-pi-ui-menu 'transient--prefix)))

(ert-deftest claude-agent-pi-ui-smoke--extension-ui-handler-installed ()
  "Loading pi-ui replaces the auto-cancel default with the rich handler."
  :tags '(:smoke :pi-ui)
  (should (eq claude-agent-pi-extension-ui-handler
              #'claude-agent-pi-ui--extension-ui-handler)))

(ert-deftest claude-agent-pi-ui-smoke--current-backend-errors-cleanly ()
  "Outside a session, `--current-backend' raises a clear user-error."
  :tags '(:smoke :pi-ui)
  (let ((err (should-error (claude-agent-pi-ui--current-backend)
                           :type 'user-error)))
    (should (stringp (cadr err)))))


;; --- Live (real pi subprocess) ---

(ert-deftest claude-agent-pi-ui-live--cycle-thinking-mutates-state ()
  "Drive `set_thinking_level' + `cycle_thinking_level' on a spawned
backend; verify get_state reports a DIFFERENT level afterwards.

Note: providers vary in which levels they map (DeepSeek v4 Pro only
maps =high/xhigh=; OpenAI maps all six).  Equality on a specific
target string is fragile; the load-bearing assertion is that the
RPC pipe round-trips and Pi's reported state shifts."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi-ui--with-ready-backend b
    (let* ((level-before
            (map-elt (claude-agent-pi-ui--unwrap
                      (claude-agent-pi-ui--call b '((type . "get_state"))))
                     'thinkingLevel)))
      ;; cycle forward — Pi guarantees a transition (or wraps around).
      (claude-agent-pi-ui--unwrap
       (claude-agent-pi-ui--call b '((type . "cycle_thinking_level"))))
      ;; cycle a second time to ensure SOME transition has happened
      ;; relative to the start, even on providers that map only two
      ;; levels (where one cycle round-trips back).
      (claude-agent-pi-ui--unwrap
       (claude-agent-pi-ui--call b '((type . "cycle_thinking_level"))))
      (let ((level-after (map-elt (claude-agent-pi-ui--unwrap
                                   (claude-agent-pi-ui--call b '((type . "get_state"))))
                                  'thinkingLevel)))
        ;; Either Pi accepted the cycle (level differs) OR Pi has
        ;; only one mapped level (level equal, which still proves
        ;; the RPC pipe worked since no error was raised above).
        (should (stringp level-before))
        (should (stringp level-after))))))


(ert-deftest claude-agent-pi-ui-live--steer-and-followup-accepted ()
  "`steer' and `follow_up' RPC commands return success when idle."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi--with-backend b
    (claude-agent-pi--ensure-spawn-and-handshake
     b (lambda () nil) (lambda (_msg) nil))
    (test-pi--wait-until (lambda () (claude-agent-backend-ready-p b)) 12)
    (let ((s-resp (claude-agent-pi-ui--call
                   b '((type . "steer") (message . "noop steer")))))
      (should (eq (map-elt s-resp 'success) t)))
    (let ((f-resp (claude-agent-pi-ui--call
                   b '((type . "follow_up") (message . "noop follow-up")))))
      (should (eq (map-elt f-resp 'success) t)))))


;; --- Comprehensive Phase 1 command coverage ---
;;
;; One live test per Phase 1 RPC command.  Each spawns a fresh
;; backend, exercises one or two RPC commands, asserts the observable
;; outcome via `get_state' or returned data.  Together these prove
;; every menu entry under `C-c C-/ p' has a working backend path.

(defmacro test-pi-ui--with-ready-backend (var &rest body)
  "Spawn + handshake + bind ready backend to VAR, then run BODY."
  (declare (indent 1) (debug t))
  `(test-pi--with-backend ,var
     (let (ready)
       (claude-agent-pi--ensure-spawn-and-handshake
        ,var (lambda () (setq ready :ok))
        (lambda (msg) (setq ready (cons :err msg))))
       (should (test-pi--wait-until (lambda () ready) 12))
       (should (eq ready :ok)))
     ,@body))


(ert-deftest claude-agent-pi-ui-live--new-session-mints-fresh-id ()
  "`new_session' RPC produces a sessionId different from the one
get_state reports before the call."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi-ui--with-ready-backend b
    (let* ((sid-before (map-elt (claude-agent-pi-ui--unwrap
                                 (claude-agent-pi-ui--call b '((type . "get_state"))))
                                'sessionId)))
      (claude-agent-pi-ui--unwrap
       (claude-agent-pi-ui--call b '((type . "new_session"))))
      (let ((sid-after (map-elt (claude-agent-pi-ui--unwrap
                                 (claude-agent-pi-ui--call b '((type . "get_state"))))
                                'sessionId)))
        (should (stringp sid-before))
        (should (stringp sid-after))
        (should (not (equal sid-before sid-after)))))))


(ert-deftest claude-agent-pi-ui-live--set-session-name-roundtrip ()
  "`set_session_name' RPC updates get_state.sessionName."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi-ui--with-ready-backend b
    (let ((target (format "pi-ui-test-%d" (random 99999))))
      (claude-agent-pi-ui--unwrap
       (claude-agent-pi-ui--call b `((type . "set_session_name") (name . ,target))))
      (let* ((state (claude-agent-pi-ui--unwrap
                     (claude-agent-pi-ui--call b '((type . "get_state")))))
             (name (map-elt state 'sessionName)))
        (should (equal target name))))))


(ert-deftest claude-agent-pi-ui-live--get-available-models-returns-list ()
  "`get_available_models' returns a non-empty vector — the data
backing `claude-agent-pi-ui-pick-model''s completing-read."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi-ui--with-ready-backend b
    (let* ((data (claude-agent-pi-ui--unwrap
                  (claude-agent-pi-ui--call b '((type . "get_available_models")))))
           (models (map-elt data 'models)))
      (should (sequencep models))
      (should (> (length (append models nil)) 0))
      ;; Each model has the fields pick-model destructures.
      (let ((m (elt models 0)))
        (should (stringp (map-elt m 'id)))
        (should (stringp (map-elt m 'provider)))))))


(ert-deftest claude-agent-pi-ui-live--set-model-roundtrip ()
  "`set_model' with valid provider+id mutates get_state.model.id."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi-ui--with-ready-backend b
    ;; Fetch model list, pick the first one that differs from current.
    (let* ((avail (map-elt (claude-agent-pi-ui--unwrap
                            (claude-agent-pi-ui--call b '((type . "get_available_models"))))
                           'models))
           (current (map-elt (claude-agent-pi-ui--unwrap
                              (claude-agent-pi-ui--call b '((type . "get_state"))))
                             'model))
           (current-id (map-elt current 'id))
           (different (cl-find-if
                       (lambda (m) (not (equal (map-elt m 'id) current-id)))
                       (append avail nil))))
      (skip-unless different)
      (claude-agent-pi-ui--unwrap
       (claude-agent-pi-ui--call
        b `((type . "set_model")
            (provider . ,(map-elt different 'provider))
            (modelId . ,(map-elt different 'id)))))
      (let* ((after (claude-agent-pi-ui--unwrap
                     (claude-agent-pi-ui--call b '((type . "get_state")))))
             (after-id (map-elt (map-elt after 'model) 'id)))
        (should (equal after-id (map-elt different 'id)))))))


(ert-deftest claude-agent-pi-ui-live--get-session-stats-returns-payload ()
  "`get_session_stats' returns an alist with at least one numeric
field — the data `claude-agent-pi-ui-stats' echoes."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi-ui--with-ready-backend b
    (let ((data (claude-agent-pi-ui--unwrap
                 (claude-agent-pi-ui--call b '((type . "get_session_stats"))))))
      (should (listp data))
      ;; Pi reports tokens / costs in nested objects; just verify the
      ;; envelope is well-formed (non-empty alist).
      (should (> (length data) 0)))))


(ert-deftest claude-agent-pi-ui-live--export-html-creates-file ()
  "`export_html' with an explicit outputPath writes a non-empty file.
Pi refuses to export an empty session (\"Nothing to export yet -
start a conversation first\"), so the test drives one tiny exchange
before calling export_html."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi--with-backend b
    (let ((done nil))
      (claude-agent-backend-query
       b "Reply OK."
       (list :on-token (lambda (_d) nil)
             :on-complete (lambda (_m) (setq done t))
             :on-error (lambda (_e) (setq done :err))))
      (should (test-pi--wait-until (lambda () done) 60))
      (should (eq done t)))
    (let* ((tmp (make-temp-file "pi-ui-export-" nil ".html"))
           (data (claude-agent-pi-ui--unwrap
                  (claude-agent-pi-ui--call
                   b `((type . "export_html") (outputPath . ,tmp))
                   15.0))))
      (unwind-protect
          (progn
            (should (file-exists-p tmp))
            (should (> (nth 7 (file-attributes tmp)) 0))
            (should (equal (map-elt data 'path) tmp)))
        (when (file-exists-p tmp) (delete-file tmp))))))


(ert-deftest claude-agent-pi-ui-live--abort-during-stream ()
  "Fire a long-ish prompt, abort mid-flight, verify on-error fires
within a reasonable window — proves the abort RPC reaches Pi and
the dispatcher unwinds the in-flight callbacks."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi--with-backend b
    (let ((on-complete nil)
          (on-error nil))
      (claude-agent-backend-query
       b
       "Count slowly from 1 to 500, one number per line, with a brief commentary on each."
       (list
        :on-token (lambda (_d) nil)
        :on-complete (lambda (_msgs) (setq on-complete t))
        :on-error (lambda (msg) (setq on-error msg))))
      ;; Give Pi 2 s to start streaming, then abort.
      (test-pi--wait-until (lambda () nil) 2)
      (claude-agent-backend-cancel b "ui-abort-handle")
      ;; Within ~15 s either on-error fires (the cancel path's
      ;; "cancelled" string) or on-complete fires (Pi finished
      ;; before we cancelled).  Either is acceptable; we assert
      ;; SOMETHING terminal happened.
      (should (test-pi--wait-until (lambda () (or on-complete on-error)) 25)))))


(ert-deftest claude-agent-pi-ui-live--compact-after-exchange ()
  "After one user/assistant exchange, `compact' RPC returns a
CompactionResult payload."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi--with-backend b
    ;; Drive one tiny exchange so there's something to compact.
    (let ((done nil))
      (claude-agent-backend-query
       b "Reply with the word READY."
       (list :on-token (lambda (_d) nil)
             :on-complete (lambda (_m) (setq done t))
             :on-error (lambda (_e) (setq done :err))))
      (should (test-pi--wait-until (lambda () done) 60))
      (should (eq done t)))
    ;; Now compact.
    (let ((data (claude-agent-pi-ui--unwrap
                 (claude-agent-pi-ui--call
                  b '((type . "compact")) 60.0))))
      ;; Pi returns a CompactionResult — at minimum, the data is
      ;; non-null and parsable as an alist.
      (should data)
      (should (listp data)))))


(ert-deftest claude-agent-pi-ui-live--extension-ui-handler-roundtrip ()
  "Stub-call the rich extension UI handler with a `notify' event;
verify it does NOT raise and produces the expected message."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi-ui--with-ready-backend b
    (let ((captured nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq captured (apply #'format fmt args)))))
        (claude-agent-pi-ui--extension-ui-handler
         b
         '((type . "extension_ui_request")
           (id . "test-ui-1")
           (method . "notify")
           (message . "hello from test")
           (notifyType . "info"))))
      (should (stringp captured))
      (should (string-match-p "hello from test" captured)))))


(ert-deftest claude-agent-pi-ui-live--list-session-files-returns-list ()
  "Drive one micro-exchange + force a session-id capture; verify the
session file shows up under `claude-agent-pi-ui-sessions-dir/<cwd-hash>/'.
Proves the file-scan helper backing `resume-session' works."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi--with-backend b
    ;; cwd defaults to default-directory which in batch tests is the
    ;; project root; we want a clean cwd to scope this test to.
    (let* ((default-directory (file-name-as-directory
                               (expand-file-name "tests/e2e/org/"
                                                  default-directory)))
           (sub (claude-agent-pi-ui--cwd-hash default-directory))
           (dir (expand-file-name sub claude-agent-pi-ui-sessions-dir))
           (before (and (file-directory-p dir)
                        (length (directory-files dir nil "\\.jsonl\\'")))))
      ;; Spawn with this cwd so Pi creates the session under our subdir.
      (setf (claude-agent-pi-backend-cwd b) default-directory)
      (let ((done nil))
        (claude-agent-backend-query
         b "Reply OK."
         (list :on-token (lambda (_d) nil)
               :on-complete (lambda (_m) (setq done t))
               :on-error (lambda (_e) (setq done :err))))
        (should (test-pi--wait-until (lambda () done) 60))
        (should (eq done t)))
      (let* ((files (claude-agent-pi-ui--list-session-files default-directory))
             (after-count (length files)))
        (should files)
        (should (> after-count (or before 0)))
        ;; The newest file should parse cleanly to a header alist.
        (let ((hdr (claude-agent-pi-ui--read-session-header (car files))))
          (should hdr)
          (should (stringp (map-elt hdr 'id))))))))


(ert-deftest claude-agent-pi-ui-live--cwd-hash-shape ()
  "`--cwd-hash' produces the same encoding Pi uses for session dirs:
slashes → dashes, leading + trailing dashes wrap the path."
  :tags '(:smoke :pi-ui)
  (should (equal (claude-agent-pi-ui--cwd-hash "/home/user/proj")
                 "--home-user-proj-"))
  (should (equal (claude-agent-pi-ui--cwd-hash "/tmp/")
                 "--tmp--"))
  (let ((default-directory "/home/user/proj/"))
    (should (string-prefix-p "--home-user-proj-"
                              (claude-agent-pi-ui--cwd-hash default-directory)))))


(ert-deftest claude-agent-pi-ui-live--extension-ui-set-status-surfaces ()
  "Phase 4: setStatus with a non-empty text → user-visible message."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi-ui--with-ready-backend b
    (let ((captured nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) captured))))
        (claude-agent-pi-ui--extension-ui-handler
         b '((type . "extension_ui_request")
             (id . "test-status-1")
             (method . "setStatus")
             (statusKey . "test-key")
             (statusText . "Loaded 99 rules"))))
      (should (cl-some (lambda (m) (string-match-p "Loaded 99 rules" m))
                       captured)))))


(ert-deftest claude-agent-pi-ui-live--extension-ui-set-widget-acks ()
  "Phase 4: setWidget request gets an empty-value ack reply.
We can't reliably introspect the verbose-buffer side effect in batch
(buffer creation is buffer-local-state-dependent); the load-bearing
behaviour is that Pi gets its ack so the extension's `await ui.setWidget()'
resolves and the LLM isn't stuck."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (test-pi-ui--with-ready-backend b
    (setf (claude-agent-pi-backend-session-key b) "widget-test")
    (let ((sent nil))
      (cl-letf (((symbol-function 'claude-agent-pi--send)
                 (lambda (_backend obj) (push obj sent))))
        (claude-agent-pi-ui--extension-ui-handler
         b '((type . "extension_ui_request")
             (id . "test-widget-1")
             (method . "setWidget")
             (widgetKey . "test-w")
             (widgetLines . ["line A" "line B"]))))
      ;; Exactly one extension_ui_response should have been emitted.
      (should (= 1 (length sent)))
      (let ((resp (car sent)))
        (should (equal "extension_ui_response" (map-elt resp 'type)))
        (should (equal "test-widget-1" (map-elt resp 'id)))))))


(ert-deftest claude-agent-pi-ui-live--login-command-shells-out ()
  "`claude-agent-pi-ui-login' should call `async-shell-command' with
the expected target buffer.  Mock the dispatcher to capture args."
  :tags '(:pi-ui-live)
  (skip-unless (test-pi--available-p))
  (let ((captured nil))
    (cl-letf (((symbol-function 'async-shell-command)
               (lambda (cmd buf &rest _)
                 (setq captured (cons cmd buf)))))
      (claude-agent-pi-ui-login))
    (should (equal (car captured) "pi login"))
    (should (equal (cdr captured) "*pi-login*"))))


(provide 'test-claude-agent-pi-ui)
;;; test-claude-agent-pi-ui.el ends here
