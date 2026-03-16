;;; test-claude-org-native.el --- TDD Tests for Native Claude Code Backend -*- lexical-binding: t; -*-

;; TDD tests for the native terminal backend.
;; Tests define expected behavior BEFORE implementation.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-agent)

;;; ============================================================
;;; Helpers
;;; ============================================================

(defun test-native--make-mock-eat-buffer ()
  "Create a buffer simulating an eat terminal with a ready prompt."
  (let ((buf (generate-new-buffer " *test-native-eat*")))
    (with-current-buffer buf
      (set (make-local-variable 'eat-terminal) 'mock-terminal)
      (set (make-local-variable 'claude-org--native-type) 'eat)
      ;; Insert a fake prompt so ready-check passes
      (insert "Claude Code\n❯ "))
    buf))

(defmacro test-native--with-mock-eat (&rest body)
  "Execute BODY with eat functions mocked.
Provides mock-buf and eat-sends for tracking sent strings.
Binds terminal backend to eat since only eat functions are mocked."
  (declare (indent 0))
  `(let ((mock-buf (test-native--make-mock-eat-buffer))
         (eat-sends nil)
         (claude-org-native-terminal-backend 'eat))
     (unwind-protect
         (let ((featurep-orig (symbol-function 'featurep)))
           (cl-letf (((symbol-function 'eat-make)
                      (lambda (&rest _args) mock-buf))
                     ((symbol-function 'featurep)
                      (lambda (f &rest args)
                        (if (eq f 'eat) t
                          (apply featurep-orig f args))))
                     ((symbol-function 'eat-term-send-string)
                      (lambda (_term str) (push str eat-sends))))
             ,@body))
       (when (buffer-live-p mock-buf)
         (kill-buffer mock-buf)))))

(defmacro test-native--with-org-buffer (content &rest body)
  "Execute BODY in a temp org buffer with CONTENT.
Sets up claude-org-mode and ensures cleanup."
  (declare (indent 1))
  `(let ((temp-file (make-temp-file "test-native-org-" nil ".org"))
         (claude-org-auto-start-mcp-server nil)
         test-buf)
     (unwind-protect
         (progn
           (with-temp-file temp-file
             (insert ,content))
           (setq test-buf (find-file-noselect temp-file))
           (with-current-buffer test-buf
             (claude-org-mode 1)
             ,@body))
       (when (and test-buf (buffer-live-p test-buf))
         (with-current-buffer test-buf
           (set-buffer-modified-p nil))
         (kill-buffer test-buf))
       (ignore-errors (delete-file temp-file)))))

;;; ============================================================
;;; Phase 1: Function and Command Existence
;;; ============================================================

(ert-deftest test-native-open-terminal-command-exists ()
  "claude-org-open-native-terminal should be a defined interactive command."
  :tags '(:unit :native :phase-1)
  (should (fboundp 'claude-org-open-native-terminal))
  (should (commandp 'claude-org-open-native-terminal)))

(ert-deftest test-native-minor-mode-exists ()
  "claude-org-native-mode should be a defined minor mode."
  :tags '(:unit :native :phase-1)
  (should (fboundp 'claude-org-native-mode)))

(ert-deftest test-native-send-prompt-exists ()
  "claude-org--native-send-prompt should be defined."
  :tags '(:unit :native :phase-1)
  (should (fboundp 'claude-org--native-send-prompt)))

(ert-deftest test-native-buffer-name-exists ()
  "claude-org--native-buffer-name should be defined."
  :tags '(:unit :native :phase-1)
  (should (fboundp 'claude-org--native-buffer-name)))

(ert-deftest test-native-display-function-defcustom ()
  "claude-org-native-display-function should be a defined variable."
  :tags '(:unit :native :phase-1)
  (should (boundp 'claude-org-native-display-function)))

;;; ============================================================
;;; Phase 2: Buffer Naming
;;; ============================================================

(ert-deftest test-native-buffer-name-format ()
  "Buffer name should follow *claude-native<session-key>* format."
  :tags '(:unit :native :phase-2)
  (should (equal "*claude-native<test-key>*"
                 (claude-org--native-buffer-name "test-key")))
  (should (equal "*claude-native<my/session>*"
                 (claude-org--native-buffer-name "my/session"))))

;;; ============================================================
;;; Phase 3: Backend Dispatch
;;; ============================================================

(ert-deftest test-native-backend-dispatch-returns-nil ()
  "make-default-backend should return nil for native backend type."
  :tags '(:unit :native :phase-3)
  (test-native--with-org-buffer
      "#+PROPERTY: CLAUDE_BACKEND native\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (goto-char (point-min))
    (re-search-forward "begin_src ai")
    (let ((session-key (claude-org--current-session-key)))
      (should (null (claude-org--make-default-backend session-key nil))))))

(ert-deftest test-native-backend-dispatch-sets-native-mode ()
  "make-default-backend should set :native-mode flag on session for native."
  :tags '(:unit :native :phase-3)
  (test-native--with-org-buffer
      "#+PROPERTY: CLAUDE_BACKEND native\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (goto-char (point-min))
    (re-search-forward "begin_src ai")
    (let ((session-key (claude-org--current-session-key)))
      (claude-org--make-default-backend session-key nil)
      (should (eq t (claude-org--session-get session-key :native-mode))))))

(ert-deftest test-native-backend-dispatch-other-types-unchanged ()
  "make-default-backend should still work for json-stream."
  :tags '(:unit :native :phase-3)
  (test-native--with-org-buffer
      "#+PROPERTY: CLAUDE_BACKEND json-stream\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (goto-char (point-min))
    (re-search-forward "begin_src ai")
    (let* ((session-key (claude-org--current-session-key))
           (backend (claude-org--make-default-backend session-key nil)))
      (should (claude-agent-json-backend-p backend)))))

;;; ============================================================
;;; Phase 4: Terminal Creation
;;; ============================================================

(ert-deftest test-native-open-terminal-creates-eat-buffer ()
  "open-native-terminal should create an eat terminal buffer and store in session."
  :tags '(:unit :native :phase-4)
  (test-native--with-mock-eat
    (test-native--with-org-buffer
        "#+PROPERTY: CLAUDE_BACKEND native\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
      (goto-char (point-min))
      (re-search-forward "begin_src ai")
      (let* ((session-key (claude-org--current-session-key))
             (displayed-buf nil))
        ;; Mock display function to capture which buffer is displayed
        (let ((claude-org-native-display-function
               (lambda (buf) (setq displayed-buf buf))))
          (claude-org-open-native-terminal)
          ;; Buffer should have been created and displayed
          (should displayed-buf)
          (should (buffer-live-p displayed-buf))
          ;; Session should have the buffer reference
          (should (eq displayed-buf
                      (claude-org--session-get session-key :native-buffer)))
          ;; Session should have native-mode flag
          (should (claude-org--session-get session-key :native-mode))
          ;; Clean up
          (kill-buffer displayed-buf))))))

(ert-deftest test-native-open-terminal-reuses-live-buffer ()
  "open-native-terminal should reuse existing live terminal buffer."
  :tags '(:unit :native :phase-4)
  (test-native--with-mock-eat
    (test-native--with-org-buffer
        "#+PROPERTY: CLAUDE_BACKEND native\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
      (goto-char (point-min))
      (re-search-forward "begin_src ai")
      (let* ((displayed-bufs nil)
             (claude-org-native-display-function
              (lambda (buf) (push buf displayed-bufs))))
        ;; Open twice
        (claude-org-open-native-terminal)
        (claude-org-open-native-terminal)
        ;; Should be the same buffer both times
        (should (= 2 (length displayed-bufs)))
        (should (eq (nth 0 displayed-bufs) (nth 1 displayed-bufs)))
        ;; Clean up
        (kill-buffer (car displayed-bufs))))))

;;; ============================================================
;;; Phase 5: Prompt Sending
;;; ============================================================

(ert-deftest test-native-send-prompt-uses-bracketed-paste ()
  "send-prompt should wrap text in bracketed paste escape sequences."
  :tags '(:unit :native :phase-5)
  (test-native--with-mock-eat
    (let ((buf mock-buf))
      ;; Simulate a live process
      (let ((proc (start-process "test-proc" buf "cat")))
        (unwind-protect
            (progn
              (claude-org--native-send-prompt buf "test query")
              ;; Should have sent bracketed paste sequence
              (should (cl-some (lambda (s)
                                 (string-match-p "\e\\[200~test query\e\\[201~" s))
                               eat-sends)))
          (delete-process proc))))))

;;; ============================================================
;;; Phase 6: Execute Dispatch
;;; ============================================================

(ert-deftest test-native-execute-dispatches-to-terminal ()
  "C-c C-c should dispatch to native terminal when :native-mode is set."
  :tags '(:unit :native :phase-6)
  (test-native--with-mock-eat
    ;; Pre-attach a dummy process to mock-buf so buffer-alive-p passes
    ;; when open-native-terminal stores it as the native buffer.
    (let ((proc (start-process "test-native-proc" mock-buf "cat")))
      (unwind-protect
          (test-native--with-org-buffer
              "#+PROPERTY: CLAUDE_BACKEND native\n* Test\n#+begin_src ai\nhello world\n#+end_src\n"
            (goto-char (point-min))
            (re-search-forward "hello world")
            (let* ((displayed-buf nil)
                   (claude-org-native-display-function
                    (lambda (buf) (setq displayed-buf buf)))
                   (claude-org-native-prompt-timeout 1))
              ;; Execute should open terminal and send prompt
              (claude-org-execute)
              ;; Terminal buffer should have been created
              (should displayed-buf)
              (should (buffer-live-p displayed-buf))
              ;; Prompt should have been sent (bracketed paste)
              (should (cl-some (lambda (s)
                                 (string-match-p "hello world" s))
                               eat-sends))))
        (ignore-errors (delete-process proc))))))

;;; ============================================================
;;; Phase 7: Menu Integration
;;; ============================================================

(ert-deftest test-native-terminal-in-menu ()
  "claude-org-menu transient should reference the unified terminal command.
The \"I\" Open terminal entry dispatches to native/cmux/iterm2 based on
CLAUDE_BACKEND. Verifies claude-org-open-terminal-tab is in the layout."
  :tags '(:unit :native :phase-7)
  (let ((layout (get 'claude-org-menu 'transient--layout)))
    (should layout)
    (let ((found nil))
      (cl-labels ((walk (obj)
                    (cond
                     ((eq obj 'claude-org-open-terminal-tab) (setq found t))
                     ((consp obj) (walk (car obj)) (walk (cdr obj)))
                     ((vectorp obj)
                      (cl-loop for elt across obj do (walk elt))))))
        (walk layout))
      (should found))))

;;; ============================================================
;;; Phase 8: Cleanup
;;; ============================================================

(ert-deftest test-native-kill-buffer-cleans-session ()
  "Killing a native terminal buffer should clear session :native-buffer."
  :tags '(:unit :native :phase-8)
  (test-native--with-mock-eat
    (test-native--with-org-buffer
        "#+PROPERTY: CLAUDE_BACKEND native\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
      (goto-char (point-min))
      (re-search-forward "begin_src ai")
      (let* ((session-key (claude-org--current-session-key))
             (displayed-buf nil)
             (claude-org-native-display-function
              (lambda (buf) (setq displayed-buf buf))))
        (claude-org-open-native-terminal)
        ;; Session should have native buffer reference
        (should (claude-org--session-get session-key :native-buffer))
        ;; Kill the terminal buffer
        (kill-buffer displayed-buf)
        ;; Session should no longer reference the dead buffer
        (let ((ref (claude-org--session-get session-key :native-buffer)))
          (should (or (null ref)
                      (not (buffer-live-p ref)))))))))

;;; ============================================================
;;; Phase 9: Terminal Backend Selection (eat/vterm)
;;; ============================================================

(ert-deftest test-native-terminal-type-function-exists ()
  "claude-org--native-terminal-type should be defined."
  :tags '(:unit :native :phase-9)
  (should (fboundp 'claude-org--native-terminal-type)))

(ert-deftest test-native-terminal-backend-defcustom ()
  "claude-org-native-terminal-backend should be a defined variable."
  :tags '(:unit :native :phase-9)
  (should (boundp 'claude-org-native-terminal-backend)))

(ert-deftest test-native-terminal-type-reads-defcustom ()
  "Terminal type should respect defcustom value when no property is set."
  :tags '(:unit :native :phase-9)
  (test-native--with-org-buffer
      "* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (goto-char (point-min))
    (re-search-forward "begin_src ai")
    (let ((claude-org-native-terminal-backend 'eat))
      (should (eq 'eat (claude-org--native-terminal-type))))))

(ert-deftest test-native-terminal-type-from-property ()
  "CLAUDE_NATIVE_TERMINAL org property should override defcustom."
  :tags '(:unit :native :phase-9)
  (test-native--with-org-buffer
      "#+PROPERTY: CLAUDE_NATIVE_TERMINAL vterm\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (goto-char (point-min))
    (re-search-forward "begin_src ai")
    (let ((claude-org-native-terminal-backend 'eat))
      (should (eq 'vterm (claude-org--native-terminal-type))))))

(ert-deftest test-native-terminal-type-defcustom-vterm ()
  "Defcustom set to vterm should be respected when no property."
  :tags '(:unit :native :phase-9)
  (test-native--with-org-buffer
      "* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (goto-char (point-min))
    (re-search-forward "begin_src ai")
    (let ((claude-org-native-terminal-backend 'vterm))
      (should (eq 'vterm (claude-org--native-terminal-type))))))

(ert-deftest test-native-terminal-type-property-eat-explicit ()
  "CLAUDE_NATIVE_TERMINAL=eat should override vterm defcustom."
  :tags '(:unit :native :phase-9)
  (test-native--with-org-buffer
      "#+PROPERTY: CLAUDE_NATIVE_TERMINAL eat\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (goto-char (point-min))
    (re-search-forward "begin_src ai")
    (let ((claude-org-native-terminal-backend 'vterm))
      (should (eq 'eat (claude-org--native-terminal-type))))))

(ert-deftest test-native-vterm-send-prompt ()
  "send-prompt in a vterm buffer should use vterm-send-string with paste-p."
  :tags '(:unit :native :phase-9)
  (let* ((vterm-sends nil)
         (mock-buf (generate-new-buffer " *test-native-vterm*")))
    (unwind-protect
        (progn
          ;; Set up mock vterm buffer
          (with-current-buffer mock-buf
            (set (make-local-variable 'vterm--term) 'mock-vterm-terminal)
            (set (make-local-variable 'claude-org--native-type) 'vterm)
            (insert "Claude Code\n❯ "))
          ;; Start a dummy process
          (let ((proc (start-process "test-vterm-proc" mock-buf "cat")))
            (unwind-protect
                (let ((featurep-orig (symbol-function 'featurep)))
                  (cl-letf (((symbol-function 'featurep)
                             (lambda (f &rest args)
                               (if (eq f 'vterm) t
                                 (apply featurep-orig f args))))
                            ((symbol-function 'vterm-send-string)
                             (lambda (str &optional paste-p)
                               (push (list str paste-p) vterm-sends)))
                            ((symbol-function 'vterm-send-return)
                             (lambda () (push '(return) vterm-sends))))
                    (claude-org--native-send-prompt mock-buf "test vterm query")
                    ;; Should have called vterm-send-string with paste-p=t
                    (should (cl-some (lambda (entry)
                                       (and (listp entry)
                                            (= (length entry) 2)
                                            (equal (car entry) "test vterm query")
                                            (eq (cadr entry) t)))
                                     vterm-sends))))
              (ignore-errors (delete-process proc)))))
      (when (buffer-live-p mock-buf)
        (kill-buffer mock-buf)))))

;;; ============================================================
;;; Phase 10: Fixes from code review
;;; ============================================================

(ert-deftest test-native-default-terminal-is-vterm ()
  "Default value of claude-org-native-terminal-backend should be vterm."
  :tags '(:unit :native :phase-10)
  (should (eq 'vterm (default-value 'claude-org-native-terminal-backend))))

(ert-deftest test-native-unknown-terminal-property-warns ()
  "Unknown CLAUDE_NATIVE_TERMINAL value should warn and use defcustom default."
  :tags '(:unit :native :phase-10)
  (test-native--with-org-buffer
      "#+PROPERTY: CLAUDE_NATIVE_TERMINAL typo\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (goto-char (point-min))
    (re-search-forward "begin_src ai")
    (let ((claude-org-native-terminal-backend 'vterm)
          (messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (should (eq 'vterm (claude-org--native-terminal-type)))
        (should (cl-some (lambda (m) (string-match-p "unknown CLAUDE_NATIVE_TERMINAL" m))
                         messages))))))

(ert-deftest test-native-send-prompt-on-dead-buffer-errors ()
  "send-prompt should signal error when buffer is not alive."
  :tags '(:unit :native :phase-10)
  (let ((dead-buf (generate-new-buffer " *test-dead*")))
    (kill-buffer dead-buf)
    (should-error (claude-org--native-send-prompt dead-buf "test")
                  :type 'error)))

(ert-deftest test-native-schedule-enter-cancels-pending ()
  "Scheduling a new enter should cancel any pending timer."
  :tags '(:unit :native :phase-10)
  (let ((buf (generate-new-buffer " *test-timer*"))
        (call-count 0))
    (unwind-protect
        (progn
          ;; Schedule first timer with very long delay
          (claude-org--native-schedule-enter buf
            (lambda () (cl-incf call-count)))
          (let ((first-timer (buffer-local-value 'claude-org--native-pending-timer buf)))
            (should (timerp first-timer))
            ;; Schedule second timer - should cancel first
            (claude-org--native-schedule-enter buf
              (lambda () (cl-incf call-count)))
            ;; First timer should have been cancelled
            (should-not (memq first-timer timer-list))))
      (when (buffer-live-p buf)
        (let ((timer (buffer-local-value 'claude-org--native-pending-timer buf)))
          (when (timerp timer) (cancel-timer timer)))
        (kill-buffer buf)))))

(ert-deftest test-native-buffer-local-type-set ()
  "create-terminal should set claude-org--native-type buffer-local."
  :tags '(:unit :native :phase-10)
  (test-native--with-mock-eat
    (let ((buf (claude-org--native-create-terminal 'eat "*test-type*" "cat" nil)))
      (unwind-protect
          (should (eq 'eat (buffer-local-value 'claude-org--native-type buf)))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;; ============================================================
;;; Phase 11: Session Resumption
;;; ============================================================

(ert-deftest test-native-session-start-hook-exists ()
  "claude-agent-claude-backend-session-start-functions should be a defined variable."
  :tags '(:unit :native :phase-11)
  (should (boundp 'claude-agent-claude-backend-session-start-functions)))

(ert-deftest test-native-session-id-stored-on-session-start ()
  "Native session-start handler should store session-id in org session state."
  :tags '(:unit :native :phase-11)
  (test-native--with-org-buffer
      "#+PROPERTY: CLAUDE_BACKEND native\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (goto-char (point-min))
    (re-search-forward "begin_src ai")
    (let* ((session-key (claude-org--current-session-key))
           (cwd (claude-agent-claude-backend--normalize-cwd
                 (or (claude-org--get-project-root) default-directory))))
      ;; Register cwd → (session-key) list (simulating what open-native-terminal does)
      (puthash cwd (list session-key) claude-org--native-cwd-to-session)
      (unwind-protect
          (progn
            ;; Simulate SessionStart hook firing
            (claude-org--native-on-session-start "test-session-abc" cwd)
            ;; Session should have the session-id stored
            (should (equal "test-session-abc"
                           (claude-org--session-get session-key :native-session-id))))
        (remhash cwd claude-org--native-cwd-to-session)))))

(ert-deftest test-native-session-id-cleared-from-registry ()
  "After session-start handler fires, cwd entry should be removed from registry."
  :tags '(:unit :native :phase-11)
  (test-native--with-org-buffer
      "#+PROPERTY: CLAUDE_BACKEND native\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
    (goto-char (point-min))
    (re-search-forward "begin_src ai")
    (let* ((session-key (claude-org--current-session-key))
           (cwd (claude-agent-claude-backend--normalize-cwd
                 (or (claude-org--get-project-root) default-directory))))
      (puthash cwd (list session-key) claude-org--native-cwd-to-session)
      (claude-org--native-on-session-start "test-session-xyz" cwd)
      ;; cwd entry should be consumed (removed) since only one key
      (should-not (gethash cwd claude-org--native-cwd-to-session)))))

(ert-deftest test-native-resume-switch-in-build-switches ()
  "build-switches should include --resume <id> when :resume-session-id is set."
  :tags '(:unit :native :phase-11)
  (let ((switches (claude-agent-claude-backend--build-switches
                   '(:resume-session-id "sess-123"))))
    (should (member "--resume" switches))
    ;; The session id should follow --resume in the switches list
    (let ((pos (cl-position "--resume" switches :test #'equal)))
      (should pos)
      (should (equal "sess-123" (nth (1+ pos) switches))))))

(ert-deftest test-native-no-resume-on-fresh-start ()
  "build-switches should NOT include --resume when no :resume-session-id."
  :tags '(:unit :native :phase-11)
  (let ((switches (claude-agent-claude-backend--build-switches
                   '(:system-prompt "test prompt"))))
    (should-not (member "--resume" switches))))

(ert-deftest test-native-cwd-registered-before-launch ()
  "Opening native terminal should register cwd in native-cwd-to-session."
  :tags '(:unit :native :phase-11)
  (test-native--with-mock-eat
    (test-native--with-org-buffer
        "#+PROPERTY: CLAUDE_BACKEND native\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
      (goto-char (point-min))
      (re-search-forward "begin_src ai")
      (let* ((session-key (claude-org--current-session-key))
             (displayed-buf nil)
             (claude-org-native-display-function
              (lambda (buf) (setq displayed-buf buf))))
        (claude-org-open-native-terminal)
        (let* ((cwd (claude-agent-claude-backend--normalize-cwd
                     (or (claude-org--get-project-root) default-directory)))
               (registered (gethash cwd claude-org--native-cwd-to-session)))
          ;; cwd should be registered pointing to our session-key
          (should (member session-key registered)))
        (when (and displayed-buf (buffer-live-p displayed-buf))
          (kill-buffer displayed-buf))))))

(ert-deftest test-native-resume-passed-on-reopen ()
  "Re-opening a killed terminal should pass --resume with stored session-id."
  :tags '(:unit :native :phase-11)
  (test-native--with-mock-eat
    (test-native--with-org-buffer
        "#+PROPERTY: CLAUDE_BACKEND native\n* Test\n#+begin_src ai\nhello\n#+end_src\n"
      (goto-char (point-min))
      (re-search-forward "begin_src ai")
      (let* ((session-key (claude-org--current-session-key))
             (displayed-buf nil)
             (captured-switches nil)
             (claude-org-native-display-function
              (lambda (buf) (setq displayed-buf buf)))
             ;; Store a previous session-id in org session state
             (_ (claude-org--session-put session-key
                                         :native-session-id "prev-session-42")))
        ;; Capture the switches passed to create-terminal
        (cl-letf (((symbol-function 'claude-org--native-create-terminal)
                   (lambda (_type _name _cli switches)
                     (setq captured-switches switches)
                     mock-buf)))
          (claude-org-open-native-terminal)
          ;; Switches should contain --resume prev-session-42
          (should (member "--resume" captured-switches))
          (let ((pos (cl-position "--resume" captured-switches :test #'equal)))
            (should pos)
            (should (equal "prev-session-42"
                           (nth (1+ pos) captured-switches)))))
        (when (and displayed-buf (buffer-live-p displayed-buf))
          (kill-buffer displayed-buf))))))

(ert-deftest test-native-on-session-start-hooked ()
  "on-session-start should run session-start-functions hook."
  :tags '(:unit :native :phase-11)
  (let ((hook-called nil)
        (received-args nil))
    (cl-letf (((symbol-value 'claude-agent-claude-backend-session-start-functions)
               (list (lambda (sid cwd)
                       (setq hook-called t
                             received-args (list sid cwd))))))
      ;; Call on-session-start with no matching backend (falls through to hook)
      (claude-agent-claude-backend--on-session-start "hook-test-id" "/tmp/hook-test")
      (should hook-called)
      (should (equal "hook-test-id" (car received-args)))
      (should (equal "/tmp/hook-test" (cadr received-args))))))

(ert-deftest test-native-handler-registered-on-hook ()
  "claude-org--native-on-session-start should be on session-start-functions."
  :tags '(:unit :native :phase-11)
  (should (memq #'claude-org--native-on-session-start
                claude-agent-claude-backend-session-start-functions)))

(ert-deftest test-native-same-cwd-multi-story ()
  "Two stories sharing a cwd should each get their own session-id."
  :tags '(:unit :native :phase-11)
  (let ((cwd "/tmp/shared-project"))
    ;; Simulate two stories registering the same cwd
    (puthash cwd (list "session-key-A" "session-key-B")
             claude-org--native-cwd-to-session)
    (unwind-protect
        (progn
          ;; First SessionStart → pops session-key-A
          (claude-org--native-on-session-start "sid-111" cwd)
          (should (equal "sid-111"
                         (claude-org--session-get "session-key-A" :native-session-id)))
          ;; session-key-B should still be waiting
          (should (equal '("session-key-B")
                         (gethash cwd claude-org--native-cwd-to-session)))
          ;; Second SessionStart → pops session-key-B
          (claude-org--native-on-session-start "sid-222" cwd)
          (should (equal "sid-222"
                         (claude-org--session-get "session-key-B" :native-session-id)))
          ;; Registry should be empty now
          (should-not (gethash cwd claude-org--native-cwd-to-session)))
      (remhash cwd claude-org--native-cwd-to-session))))

(provide 'test-claude-org-native)
;;; test-claude-org-native.el ends here
