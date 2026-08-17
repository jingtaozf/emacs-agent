;;; test-pi-topic-chat.el --- Tests for the pi-topic chat layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for lp/org/pi-topic-chat.org — the engine layer of
;; pi-topics.
;;
;; Two rules shape this file:
;;
;; 1. Real org buffers backed by real temp files (the `test-pi-topic--run'
;;    fixture from test-pi-topic.el), because the code walks the outline
;;    and writes property drawers.
;; 2. Every pi-coding-agent symbol is a stub.  No Pi process is started,
;;    and pi-coding-agent itself is not installed in the test Emacs —
;;    which is also the point of `test-pi-topic-chat-ensure-engine-...'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'pi-topic)
(require 'pi-topic-chat)
(require 'test-pi-topic)

(defvar pi-coding-agent--input-buffer)
(defvar pi-coding-agent--state)

(defvar test-pi-topic-chat--input-owner nil
  "Buffer-local back-link from a fake input buffer to its chat buffer.")

(defvar test-pi-topic-chat--buffers nil
  "Fake session buffers created during one stubbed run.")

(defvar test-pi-topic-chat--sent nil
  "List of (CHAT-BUFFER . TEXT) the fake `pi-coding-agent-send' saw.")

(defvar test-pi-topic-chat--created nil
  "List of (DIR . SESSION) the fake `pi-coding-agent--setup-session' saw.")

(defvar test-pi-topic-chat--spawn-env nil
  "List of PI_TOPIC_ID values visible to the fake `--setup-session'.
Upstream spawns pi with no `:env', so what `getenv' answers inside the
session-creating call is exactly what the pi process would inherit.")

(defvar test-pi-topic-chat--opened nil
  "List of session files the fake `pi-coding-agent-open-session-file' saw.")

(defvar test-pi-topic-chat--aborted nil
  "List of chat buffers the fake `pi-coding-agent-abort' saw.")

(defvar test-pi-topic-chat--find-result nil
  "What the fake `pi-coding-agent--find-session' returns.")

(defvar test-pi-topic-chat--process nil
  "An inert but genuine process object the fake `--get-process' returns.
`pi-topic--switch-session' insists on `processp', so a symbol will not do.")

(defvar test-pi-topic-chat--rpc nil
  "List of command plists the fake `pi-coding-agent--rpc-async' saw.")

(defvar test-pi-topic-chat--rpc-response '(:success t)
  "Response the fake `pi-coding-agent--rpc-async' hands to its callback.")

(defvar test-pi-topic-chat--refreshed nil
  "List of session files the fake `pi-coding-agent--refresh-session-state' saw.")

(defvar test-pi-topic-chat--history-loads nil
  "List of chat buffers the fake `pi-coding-agent--load-session-history' saw.")

(defmacro test-pi-topic-chat--with-feature (&rest body)
  "Run BODY with the `pi-coding-agent' feature faked as already loaded.
`features' is not a `special-variable-p', so a plain `let' on it under
lexical binding is invisible to `require'; bind the symbol value."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-value 'features) (cons 'pi-coding-agent features)))
     ,@body))

(defun test-pi-topic-chat--new-session ()
  "Create a fake chat buffer linked to a fake input buffer."
  (let ((chat (generate-new-buffer "*fake-pi-chat*"))
        (input (generate-new-buffer "*fake-pi-input*")))
    (with-current-buffer chat
      (setq-local pi-coding-agent--input-buffer input))
    (with-current-buffer input
      (setq-local test-pi-topic-chat--input-owner chat))
    (push chat test-pi-topic-chat--buffers)
    (push input test-pi-topic-chat--buffers)
    chat))

(defun test-pi-topic-chat--with-engine (fn)
  "Call FN with every pi-coding-agent symbol stubbed out.
The `pi-coding-agent' feature is faked too, so `pi-topic--ensure-engine'
passes without the package being installed."
  (setq test-pi-topic-chat--buffers nil
        test-pi-topic-chat--sent nil
        test-pi-topic-chat--created nil
        test-pi-topic-chat--opened nil
        test-pi-topic-chat--aborted nil
        test-pi-topic-chat--find-result nil
        test-pi-topic-chat--spawn-env nil
        test-pi-topic-chat--rpc nil
        test-pi-topic-chat--rpc-response '(:success t)
        test-pi-topic-chat--refreshed nil
        test-pi-topic-chat--history-loads nil
        test-pi-topic-chat--process (make-pipe-process :name "fake-pi"
                                                       :noquery t))
  (clrhash pi-topic--chat-topics)
  (delete-other-windows)
  (unwind-protect
      (test-pi-topic-chat--with-feature
        (cl-letf (((symbol-function 'pi-coding-agent--find-session)
                   (lambda (_dir &optional _session)
                     test-pi-topic-chat--find-result))
                  ((symbol-function 'pi-coding-agent--setup-session)
                   (lambda (dir &optional session)
                     (push (cons dir session) test-pi-topic-chat--created)
                     (push (getenv "PI_TOPIC_ID") test-pi-topic-chat--spawn-env)
                     (test-pi-topic-chat--new-session)))
                  ((symbol-function 'pi-coding-agent-open-session-file)
                   (lambda (file)
                     (push file test-pi-topic-chat--opened)
                     (test-pi-topic-chat--new-session)))
                  ((symbol-function 'pi-coding-agent-send)
                   (lambda ()
                     (push (cons test-pi-topic-chat--input-owner (buffer-string))
                           test-pi-topic-chat--sent)))
                  ((symbol-function 'pi-coding-agent-abort)
                   (lambda ()
                     (push (current-buffer) test-pi-topic-chat--aborted)))
                  ((symbol-function 'pi-coding-agent--get-process)
                   (lambda () test-pi-topic-chat--process))
                  ((symbol-function 'pi-coding-agent--rpc-async)
                   (lambda (_proc command callback)
                     (push command test-pi-topic-chat--rpc)
                     (funcall callback test-pi-topic-chat--rpc-response)))
                  ((symbol-function 'pi-coding-agent--refresh-session-state)
                   (lambda (_proc _chat-buf &optional session-file
                                   _generation _completion)
                     (push session-file test-pi-topic-chat--refreshed)))
                  ((symbol-function 'pi-coding-agent--load-session-history)
                   (lambda (_proc callback &optional chat-buf _completion)
                     (push chat-buf test-pi-topic-chat--history-loads)
                     (funcall callback 0))))
          (funcall fn)))
    (dolist (buffer test-pi-topic-chat--buffers)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (when (process-live-p test-pi-topic-chat--process)
      (delete-process test-pi-topic-chat--process))
    (clrhash pi-topic--chat-topics)
    (delete-other-windows)))

(defun test-pi-topic-chat--set-session-file (chat-buf path)
  "Fake pi having published PATH as CHAT-BUF's session file."
  (with-current-buffer chat-buf
    (setq-local pi-coding-agent--state (list :session-file path))))

(defun test-pi-topic-chat--property-at (buffer regexp property)
  "Return PROPERTY of the topic in BUFFER whose heading matches REGEXP."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (re-search-forward regexp)
      (beginning-of-line)
      (pi-topic--property property))))

(defun test-pi-topic-chat--state-at (buffer regexp)
  "Return the PI_STATE of the topic in BUFFER whose heading matches REGEXP."
  (test-pi-topic-chat--property-at buffer regexp "PI_STATE"))

;;; Test 1: the topic id is minted once and then stable

(ert-deftest test-pi-topic-chat-id-generated-once ()
  "`pi-topic--id' mints an id on first call and reuses it afterwards."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   ""
   (lambda ()
     (goto-char (point-max))
     (pi-topic-new)
     (should-not (pi-topic--property "PI_TOPIC_ID"))
     (let ((id (pi-topic--id)))
       (should (string-match-p "\\`pi-[0-9]+-[a-z0-9]\\{4\\}\\'" id))
       (should (equal id (pi-topic--property "PI_TOPIC_ID")))
       (should (equal id (pi-topic--id)))))))

;;; Test 2: cwd falls back to the project root, PI_CWD wins

(ert-deftest test-pi-topic-chat-cwd-property-overrides-project-root ()
  "`pi-topic--cwd' defaults to the project root and honours PI_CWD."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   test-pi-topic--topic
   (lambda ()
     (goto-char (point-min))
     (should-not (pi-topic--property "PI_CWD"))
     (should (file-equal-p (pi-topic--cwd) (pi-topic--project-root)))
     (pi-topic--set-property "PI_CWD" temporary-file-directory)
     (should (file-equal-p (pi-topic--cwd) temporary-file-directory))
     ;; Half of the session key: macOS answers /var/… here and
     ;; /private/var/… once a session exists, and the two spellings make
     ;; `pi-coding-agent--find-session' miss the topic's own session.
     (should (equal (pi-topic--cwd) (file-truename (pi-topic--cwd)))))))

;;; Test 3: the engine guard names what is missing

(ert-deftest test-pi-topic-chat-ensure-engine-names-missing-symbol ()
  "`pi-topic--ensure-engine' errors naming the feature or the symbol."
  :tags '(:unit :pi-topic)
  ;; pi-coding-agent is genuinely absent from the test Emacs.
  (should-not (featurep 'pi-coding-agent))
  (should (string-match-p
           "pi-coding-agent"
           (cadr (should-error (pi-topic--ensure-engine) :type 'user-error))))
  ;; Feature present, but the private entry point has moved or been renamed.
  (test-pi-topic-chat--with-feature
    (should-not (fboundp 'pi-coding-agent--setup-session))
    (should (string-match-p
             "pi-coding-agent--setup-session"
             (cadr (should-error (pi-topic--ensure-engine) :type 'user-error))))))

;;; Test 4: a fresh topic sends its Goal and lands in waiting

(ert-deftest test-pi-topic-chat-fresh-topic-sends-goal ()
  "`pi-topic-chat' creates a session, sends the Goal, sets waiting."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   ""
   (lambda ()
     (let ((org-buf (current-buffer)))
       (goto-char (point-max))
       (pi-topic-new)
       (delete-region (line-beginning-position) (line-end-position))
       (insert "Compare pgvector and qdrant.")
       (goto-char (point-min))
       (test-pi-topic-chat--with-engine
        (lambda ()
          (let ((chat (with-current-buffer org-buf (pi-topic-chat))))
            (should (buffer-live-p chat))
            ;; The Goal went out exactly once, on this session.
            (should (equal 1 (length test-pi-topic-chat--sent)))
            (should (eq chat (car (car test-pi-topic-chat--sent))))
            (should (equal "Compare pgvector and qdrant."
                           (cdr (car test-pi-topic-chat--sent))))
            ;; The session was created with the topic's cwd and id.
            (should (equal 1 (length test-pi-topic-chat--created)))
            (should (null test-pi-topic-chat--opened))
            (with-current-buffer org-buf
              (should (file-equal-p (car (car test-pi-topic-chat--created))
                                    (pi-topic--cwd)))
              (should (equal (cdr (car test-pi-topic-chat--created))
                             (pi-topic--property "PI_TOPIC_ID")))
              (should (equal "waiting" (pi-topic-state)))))))))))

;;; Test 5: a resumed topic must not re-send its Goal

(ert-deftest test-pi-topic-chat-existing-session-does-not-resend-goal ()
  "A topic with a PI_SESSION file resumes it and sends nothing."
  :tags '(:unit :pi-topic)
  (let ((session (make-temp-file "pi-topic-session-" nil ".jsonl" "{}\n")))
    (unwind-protect
        (test-pi-topic--run
         test-pi-topic--topic
         (lambda ()
           (let ((org-buf (current-buffer)))
             (goto-char (point-min))
             (pi-topic--set-property "PI_SESSION" session)
             (test-pi-topic-chat--with-engine
              (lambda ()
                (let ((chat (with-current-buffer org-buf (pi-topic-chat))))
                  (should (buffer-live-p chat))
                  ;; Resume happens inside the named session, not beside it.
                  (should (null test-pi-topic-chat--opened))
                  (should (equal 1 (length test-pi-topic-chat--created)))
                  (should (null test-pi-topic-chat--sent))
                  (with-current-buffer org-buf
                    (should (equal "waiting" (pi-topic-state))))))))))
      (delete-file session))))

;;; Test 6: idle flips exactly the owning topic

(ert-deftest test-pi-topic-chat-phase-handler-flips-owning-topic ()
  "The activity handler reviews only the topic owning the idle buffer."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   (concat test-pi-topic--topic
           "* Second topic\n:PROPERTIES:\n:PI_STATE: todo\n:END:\n"
           "** Goal\nSecond goal.\n** Result\n")
   (lambda ()
     (let ((org-buf (current-buffer)))
       (test-pi-topic-chat--with-engine
        (lambda ()
          (let ((chat-a (with-current-buffer org-buf
                          (goto-char (point-min))
                          (pi-topic-chat)))
                (chat-b (with-current-buffer org-buf
                          (goto-char (point-min))
                          (re-search-forward "^\\* Second topic$")
                          (beginning-of-line)
                          (pi-topic-chat))))
            (should-not (eq chat-a chat-b))
            (should (equal "waiting"
                           (test-pi-topic-chat--state-at
                            org-buf "^\\* Untitled topic$")))
            (should (equal "waiting"
                           (test-pi-topic-chat--state-at
                            org-buf "^\\* Second topic$")))
            ;; Idle on A reviews A and leaves B alone.
            (pi-topic--on-activity-phase chat-a nil "replying" "idle"
                                         'phase-change)
            (should (equal "review"
                           (test-pi-topic-chat--state-at
                            org-buf "^\\* Untitled topic$")))
            (should (equal "waiting"
                           (test-pi-topic-chat--state-at
                            org-buf "^\\* Second topic$")))
            ;; A lifecycle event that merely reapplies idle is ignored.
            (pi-topic--on-activity-phase chat-b nil "idle" "idle" 'input-link)
            (should (equal "waiting"
                           (test-pi-topic-chat--state-at
                            org-buf "^\\* Second topic$")))
            ;; So is any phase that is not idle.
            (pi-topic--on-activity-phase chat-b nil "idle" "replying"
                                         'phase-change)
            (should (equal "waiting"
                           (test-pi-topic-chat--state-at
                            org-buf "^\\* Second topic$"))))))))))

;;; Test 7: any phase event stamps the session path

(ert-deftest test-pi-topic-chat-phase-change-stamps-session ()
  "The activity hook records PI_SESSION from the state plist."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   test-pi-topic--topic
   (lambda ()
     (let ((org-buf (current-buffer)))
       (goto-char (point-min))
       (test-pi-topic-chat--with-engine
        (lambda ()
          (let ((chat (with-current-buffer org-buf (pi-topic-chat))))
            ;; Pi has published nothing yet, so the chat left no stamp.
            (should-not (test-pi-topic-chat--property-at
                         org-buf "^\\* Untitled topic$" "PI_SESSION"))
            (test-pi-topic-chat--set-session-file chat "/tmp/pi/session-a.jsonl")
            ;; A non-idle event is enough — the stamp is not gated on idle.
            (pi-topic--on-activity-phase chat nil "idle" "thinking" 'phase-change)
            (should (equal "/tmp/pi/session-a.jsonl"
                           (test-pi-topic-chat--property-at
                            org-buf "^\\* Untitled topic$" "PI_SESSION")))
            ;; And that event was not mistaken for a finished turn.
            (should (equal "waiting"
                           (test-pi-topic-chat--state-at
                            org-buf "^\\* Untitled topic$"))))))))))

;;; Test 8: no state, no path, no noise

(ert-deftest test-pi-topic-chat-missing-state-leaves-property-absent ()
  "A missing, nil or dead-buffer state stamps nothing and signals nothing."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   test-pi-topic--topic
   (lambda ()
     (let ((org-buf (current-buffer)))
       (goto-char (point-min))
       (test-pi-topic-chat--with-engine
        (lambda ()
          (let ((chat (with-current-buffer org-buf (pi-topic-chat))))
            ;; The variable was never set in this buffer.
            (should-not (pi-topic--session-file chat))
            (pi-topic--on-activity-phase chat nil "thinking" "idle" 'phase-change)
            (should-not (test-pi-topic-chat--property-at
                         org-buf "^\\* Untitled topic$" "PI_SESSION"))
            ;; An explicitly empty state is equally harmless.
            (with-current-buffer chat
              (setq-local pi-coding-agent--state nil))
            (should-not (pi-topic--session-file chat))
            (pi-topic--on-activity-phase chat nil "idle" "replying" 'phase-change)
            (should-not (test-pi-topic-chat--property-at
                         org-buf "^\\* Untitled topic$" "PI_SESSION"))
            ;; So is a chat buffer the user has killed.
            (kill-buffer chat)
            (should-not (pi-topic--session-file chat)))))))))

;;; Test 9: an existing stamp survives a pathless state

(ert-deftest test-pi-topic-chat-stamp-does-not-clobber-existing ()
  "A stamp with no path available leaves PI_SESSION untouched."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   test-pi-topic--topic
   (lambda ()
     (let ((org-buf (current-buffer)))
       (goto-char (point-min))
       (pi-topic--set-property "PI_SESSION" "/gone/session-old.jsonl")
       (test-pi-topic-chat--with-engine
        (lambda ()
          (let ((chat (with-current-buffer org-buf (pi-topic-chat))))
            ;; The recorded file no longer exists, so a new session was made.
            (should (equal 1 (length test-pi-topic-chat--created)))
            (pi-topic--on-activity-phase chat nil "thinking" "idle" 'phase-change)
            (should (equal "/gone/session-old.jsonl"
                           (test-pi-topic-chat--property-at
                            org-buf "^\\* Untitled topic$" "PI_SESSION"))))))))))

;;; Test 10: once stamped, the Goal is never sent twice

(ert-deftest test-pi-topic-chat-stamped-topic-does-not-resend-goal ()
  "After the stamp lands, a second `pi-topic-chat' resumes silently."
  :tags '(:unit :pi-topic)
  (let ((session (make-temp-file "pi-topic-stamped-" nil ".jsonl" "{}\n")))
    (unwind-protect
        (test-pi-topic--run
         test-pi-topic--topic
         (lambda ()
           (let ((org-buf (current-buffer)))
             (goto-char (point-min))
             (test-pi-topic-chat--with-engine
              (lambda ()
                (let ((chat (with-current-buffer org-buf (pi-topic-chat))))
                  ;; First chat: no PI_SESSION, so the Goal goes out once.
                  (should (equal 1 (length test-pi-topic-chat--sent)))
                  ;; Pi publishes the transcript; the next event records it.
                  (test-pi-topic-chat--set-session-file chat session)
                  (pi-topic--on-activity-phase chat nil "replying" "idle"
                                               'phase-change)
                  (should (equal session
                                 (test-pi-topic-chat--property-at
                                  org-buf "^\\* Untitled topic$" "PI_SESSION")))
                  ;; Second chat resumes that file and sends nothing.
                  (with-current-buffer org-buf (pi-topic-chat))
                  (should (equal 1 (length test-pi-topic-chat--sent)))
                  (should (null test-pi-topic-chat--opened))))))))
      (delete-file session))))

;;; Regression: resume must keep the per-topic session identity

(defun test-pi-topic-chat--switch-paths ()
  "Return the :sessionPath of every switch_session RPC seen, oldest first."
  (delq nil
        (mapcar (lambda (command)
                  (and (equal "switch_session" (plist-get command :type))
                       (plist-get command :sessionPath)))
                (reverse test-pi-topic-chat--rpc))))

(ert-deftest test-pi-topic-chat-resume-switches-inside-named-session ()
  "Resume creates the topic's own named session and switches it.
`pi-coding-agent-open-session-file' would attach the transcript to the
unnamed buffer for the directory, losing the topic's session forever."
  :tags '(:unit :pi-topic)
  (let ((session (make-temp-file "pi-topic-resume-" nil ".jsonl" "{}\n")))
    (unwind-protect
        (test-pi-topic--run
         test-pi-topic--topic
         (lambda ()
           (let ((org-buf (current-buffer)))
             (goto-char (point-min))
             (pi-topic--set-property "PI_SESSION" session)
             (test-pi-topic-chat--with-engine
              (lambda ()
                (with-current-buffer org-buf (pi-topic-chat))
                ;; The session is the topic's own (cwd, id) — never the
                ;; unnamed one.
                (should (null test-pi-topic-chat--opened))
                (should (equal 1 (length test-pi-topic-chat--created)))
                (with-current-buffer org-buf
                  (should (equal (pi-topic--cwd)
                                 (car (car test-pi-topic-chat--created))))
                  (should (equal (pi-topic--property "PI_TOPIC_ID")
                                 (cdr (car test-pi-topic-chat--created)))))
                ;; The transcript arrives through switch_session.
                (should (equal (list session)
                               (test-pi-topic-chat--switch-paths)))
                ;; …and a successful switch refreshes state and history.
                (should (equal (list session) test-pi-topic-chat--refreshed))
                (should (equal 1 (length test-pi-topic-chat--history-loads))))))))
      (delete-file session))))

(ert-deftest test-pi-topic-chat-fresh-topic-does-not-switch-session ()
  "A topic with no PI_SESSION issues no switch_session RPC."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   test-pi-topic--topic
   (lambda ()
     (let ((org-buf (current-buffer)))
       (goto-char (point-min))
       (test-pi-topic-chat--with-engine
        (lambda ()
          (with-current-buffer org-buf (pi-topic-chat))
          (should (null (test-pi-topic-chat--switch-paths)))
          (should (null test-pi-topic-chat--refreshed))
          (should (null test-pi-topic-chat--history-loads))))))))

(ert-deftest test-pi-topic-chat-failed-switch-does-not-load-history ()
  "A rejected switch_session leaves the old conversation unpainted."
  :tags '(:unit :pi-topic)
  (let ((session (make-temp-file "pi-topic-resume-fail-" nil ".jsonl" "{}\n")))
    (unwind-protect
        (test-pi-topic--run
         test-pi-topic--topic
         (lambda ()
           (let ((org-buf (current-buffer)))
             (goto-char (point-min))
             (pi-topic--set-property "PI_SESSION" session)
             (test-pi-topic-chat--with-engine
              (lambda ()
                (setq test-pi-topic-chat--rpc-response
                      '(:success :json-false :error "no such session"))
                (with-current-buffer org-buf (pi-topic-chat))
                ;; The RPC went out…
                (should (equal (list session)
                               (test-pi-topic-chat--switch-paths)))
                ;; …but nothing was rebuilt from it.
                (should (null test-pi-topic-chat--refreshed))
                (should (null test-pi-topic-chat--history-loads)))))))
      (delete-file session))))

;;; Regression: the spawned process is told which topic it serves

(ert-deftest test-pi-topic-chat-spawn-inherits-topic-id ()
  "The session-creating call runs with PI_TOPIC_ID in `process-environment'.
Upstream's `make-process' has no `:env', so whatever `getenv' answers
there is what the pi process inherits."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   test-pi-topic--topic
   (lambda ()
     (let ((org-buf (current-buffer)))
       (goto-char (point-min))
       (should-not (getenv "PI_TOPIC_ID"))
       (test-pi-topic-chat--with-engine
        (lambda ()
          (with-current-buffer org-buf (pi-topic-chat))
          (should (equal 1 (length test-pi-topic-chat--spawn-env)))
          (with-current-buffer org-buf
            (should (equal (pi-topic--property "PI_TOPIC_ID")
                           (car test-pi-topic-chat--spawn-env))))
          ;; The binding is scoped to the spawn, not leaked globally.
          (should-not (getenv "PI_TOPIC_ID"))))))))

;;; Refresh: the manual Result nudge

(ert-deftest test-pi-topic-chat-refresh-sends-nudge-not-goal ()
  "`pi-topic-refresh-result' sends the nudge and never the Goal."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   test-pi-topic--topic
   (lambda ()
     (let ((org-buf (current-buffer)))
       (goto-char (point-min))
       ;; Chatted once already: it has an id and a live session, but pi has
       ;; not published a transcript path yet — the state in which
       ;; `pi-topic-chat' would still send the Goal.
       (pi-topic--set-property "PI_TOPIC_ID" "pi-1000-live")
       (test-pi-topic-chat--with-engine
        (lambda ()
          (setq test-pi-topic-chat--find-result
                (test-pi-topic-chat--new-session))
          (with-current-buffer org-buf (pi-topic-refresh-result))
          (should (equal 1 (length test-pi-topic-chat--sent)))
          (should (equal pi-topic-refresh-result-prompt
                         (cdr (car test-pi-topic-chat--sent))))
          (should-not (equal "Compare pgvector and qdrant."
                             (cdr (car test-pi-topic-chat--sent))))))))))

(ert-deftest test-pi-topic-chat-refresh-resumes-recorded-session ()
  "With a PI_SESSION but no live buffer, refresh resumes before nudging."
  :tags '(:unit :pi-topic)
  (let ((session (make-temp-file "pi-topic-refresh-" nil ".jsonl" "{}\n")))
    (unwind-protect
        (test-pi-topic--run
         test-pi-topic--topic
         (lambda ()
           (let ((org-buf (current-buffer)))
             (goto-char (point-min))
             (pi-topic--set-property "PI_SESSION" session)
             (test-pi-topic-chat--with-engine
              (lambda ()
                (with-current-buffer org-buf (pi-topic-refresh-result))
                ;; A named session was created and switched onto the file.
                (should (equal 1 (length test-pi-topic-chat--created)))
                (should (null test-pi-topic-chat--opened))
                (should (equal (list session)
                               (test-pi-topic-chat--switch-paths)))
                ;; And only then did the nudge go out.
                (should (equal (list pi-topic-refresh-result-prompt)
                               (mapcar #'cdr test-pi-topic-chat--sent))))))))
      (delete-file session))))

(ert-deftest test-pi-topic-chat-refresh-registers-this-topic ()
  "Refresh leaves the topic waiting and owning the chat buffer."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   (concat test-pi-topic--topic
           "* Second topic\n:PROPERTIES:\n:PI_STATE: todo\n:END:\n"
           "** Goal\nSecond goal.\n** Result\n")
   (lambda ()
     (let ((org-buf (current-buffer)))
       (goto-char (point-min))
       (pi-topic--set-property "PI_TOPIC_ID" "pi-1000-live")
       (test-pi-topic-chat--with-engine
        (lambda ()
          (setq test-pi-topic-chat--find-result
                (test-pi-topic-chat--new-session))
          (let ((chat (with-current-buffer org-buf
                        (goto-char (point-min))
                        (pi-topic-refresh-result))))
            (should (equal "waiting"
                           (test-pi-topic-chat--state-at
                            org-buf "^\\* Untitled topic$")))
            ;; The registration is what lets the hook find its way back.
            (pi-topic--on-activity-phase chat nil "replying" "idle"
                                         'phase-change)
            (should (equal "review"
                           (test-pi-topic-chat--state-at
                            org-buf "^\\* Untitled topic$")))
            (should (equal "todo"
                           (test-pi-topic-chat--state-at
                            org-buf "^\\* Second topic$"))))))))))

(ert-deftest test-pi-topic-chat-refresh-refuses-undelegated-topic ()
  "Nudging a topic that was never chatted is an error, not a no-op."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   test-pi-topic--topic
   (lambda ()
     (let ((org-buf (current-buffer)))
       (goto-char (point-min))
       (test-pi-topic-chat--with-engine
        (lambda ()
          ;; No live session, no PI_SESSION.
          (should (null test-pi-topic-chat--find-result))
          (let ((err (should-error
                      (with-current-buffer org-buf (pi-topic-refresh-result))
                      :type 'user-error)))
            (should (string-match-p "pi-topic-chat" (cadr err))))
          ;; Nothing was created, nothing was sent, the state stands.
          (should (null test-pi-topic-chat--created))
          (should (null test-pi-topic-chat--sent))
          (should (equal "todo"
                         (test-pi-topic-chat--state-at
                          org-buf "^\\* Untitled topic$")))))))))

(provide 'test-pi-topic-chat)
;;; test-pi-topic-chat.el ends here
