;;; test-claude-agent-pi-backend.el --- Smoke tests for Pi backend -*- lexical-binding: t; -*-

;;; Commentary:

;; Load + structural smoke tests for claude-agent-pi-backend.org.
;; No subprocess is spawned (that's covered by E2E tests under
;; tests/test-e2e-pi-backend.el). These tests just verify the module
;; loads, the struct constructs, and the protocol methods dispatch.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'map)

;; --- Load dependencies (works both batch + standalone) ---
;;
;; In batch invocations `test-claude-agent-project-root' is set by the
;; Makefile; standalone (M-x ert) we derive the project root from this
;; file's path.  Either way we load backend + pi-backend exactly once.

(let* ((root (or (and (boundp 'test-claude-agent-project-root)
                      test-claude-agent-project-root)
                 (expand-file-name
                  ".."
                  (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path root)
  (require 'literate-elisp)
  (unless (featurep 'claude-agent-backend)
    (literate-elisp-load (expand-file-name "claude-agent-backend.org" root)))
  (unless (featurep 'claude-agent-pi-backend)
    (literate-elisp-load
     (expand-file-name "claude-agent-pi-backend.org" root))))

(require 'claude-agent-backend)
(require 'claude-agent-pi-backend)


;; --- Smoke: module load + symbols exist ---

(ert-deftest claude-agent-pi-smoke--symbols ()
  "Required public symbols are defined after load."
  :tags '(:smoke :pi-backend)
  (should (fboundp 'claude-agent-pi-backend-create))
  (should (fboundp 'claude-agent-pi-backend-p))
  (should (boundp 'claude-agent-pi-spawn-default))
  (should (boundp 'claude-agent-pi-show-thinking))
  (should (boundp 'claude-agent-pi-handshake-timeout)))


(ert-deftest claude-agent-pi-smoke--methods-defined ()
  "All 8 backend protocol methods specialize on claude-agent-pi-backend."
  :tags '(:smoke :pi-backend)
  (dolist (generic '(claude-agent-backend-query
                     claude-agent-backend-cancel
                     claude-agent-backend-cleanup
                     claude-agent-backend-active-p
                     claude-agent-backend-session-id
                     claude-agent-backend-ready-p
                     claude-agent-backend-verbose-buffer
                     claude-agent-backend-supports-p
                     claude-agent-backend-classify-error))
    (should-not (null (cl--generic generic)))))


(ert-deftest claude-agent-pi-smoke--struct-construct ()
  "Factory creates a struct with sensible defaults (no spawn)."
  :tags '(:smoke :pi-backend)
  (let ((b (claude-agent-pi-backend-create
            :session-key "smoke-test"
            :cwd "/tmp")))
    (should (claude-agent-pi-backend-p b))
    (should (equal "smoke-test" (claude-agent-pi-backend-session-key b)))
    (should (equal "/tmp" (claude-agent-pi-backend-cwd b)))
    (should (null (claude-agent-pi-backend-process b)))
    (should-not (claude-agent-pi-backend-handshake-done b))
    (should (hash-table-p (claude-agent-pi-backend-pending-by-id b)))))


(ert-deftest claude-agent-pi-smoke--protocol-state ()
  "Generics behave correctly on a freshly-constructed (un-spawned) backend."
  :tags '(:smoke :pi-backend)
  (let ((b (claude-agent-pi-backend-create :session-key "smoke")))
    (should-not (claude-agent-backend-active-p b))
    (should-not (claude-agent-backend-ready-p b))
    (should (null (claude-agent-backend-session-id b)))
    (should (null (claude-agent-backend-verbose-buffer b)))))


(ert-deftest claude-agent-pi-smoke--supports-capabilities ()
  "Pi advertises the capabilities its RPC protocol actually supports."
  :tags '(:smoke :pi-backend)
  (let ((b (claude-agent-pi-backend-create :session-key "smoke")))
    (dolist (cap '(:streaming-tokens :session-resume :session-fork
                   :images :extension-ui :compact :model-switch
                   :abort :steer :follow-up))
      (should (claude-agent-backend-supports-p b cap)))
    (should-not (claude-agent-backend-supports-p b :no-such-capability))))


(ert-deftest claude-agent-pi-smoke--classify-error ()
  "Error classifier maps representative Pi error strings to known categories."
  :tags '(:smoke :pi-backend)
  (let ((b (claude-agent-pi-backend-create :session-key "smoke")))
    (should (eq 'context-limit
                (claude-agent-backend-classify-error
                 b "Request exceeds the context limit of 64000 tokens.")))
    (should (eq 'session-expired
                (claude-agent-backend-classify-error
                 b "session expired or not found")))
    (should (eq 'auth
                (claude-agent-backend-classify-error
                 b "401 Unauthorized: invalid api key")))
    (should (eq 'network
                (claude-agent-backend-classify-error
                 b "ENOTFOUND api.deepseek.com")))
    (should (eq 'unknown
                (claude-agent-backend-classify-error
                 b "something completely unexpected happened")))))


(ert-deftest claude-agent-pi-smoke--spawn-command-builder ()
  "The spawn-command builder appends --mode rpc + session flags correctly.

Persistence-on (default) means NO `--no-session` is appended; Pi
uses its default sessions store and the registry captures the
fresh session-id.  Persistence-off restores legacy ephemeral mode."
  :tags '(:smoke :pi-backend)
  ;; With --session-dir + resume id — both flags should appear
  (let* ((b (claude-agent-pi-backend-create
             :session-key "s1"
             :spawn-args '("/bin/echo")
             :session-dir "/tmp/sessions"
             :session-id "session-abc")))
    (let ((cmd (claude-agent-pi--spawn-command b)))
      (should (member "--mode" cmd))
      (should (member "rpc" cmd))
      (should (member "--session-dir" cmd))
      (should (member (expand-file-name "/tmp/sessions") cmd))
      (should (member "--session" cmd))
      (should (member "session-abc" cmd))
      (should-not (member "--no-session" cmd))))
  ;; Default persistence (no flags, no override) — NO --no-session,
  ;; Pi will use its default sessions dir.
  (let ((claude-agent-pi-persist-sessions t))
    (let* ((b (claude-agent-pi-backend-create
               :session-key "s2"
               :spawn-args '("/bin/echo"))))
      (let ((cmd (claude-agent-pi--spawn-command b)))
        (should-not (member "--no-session" cmd))
        (should-not (member "--session-dir" cmd))
        (should-not (member "--session" cmd)))))
  ;; Persistence disabled and no overrides — legacy ephemeral mode.
  (let ((claude-agent-pi-persist-sessions nil))
    (let* ((b (claude-agent-pi-backend-create
               :session-key "s3"
               :spawn-args '("/bin/echo"))))
      (let ((cmd (claude-agent-pi--spawn-command b)))
        (should (member "--no-session" cmd))
        (should-not (member "--session-dir" cmd))))))


(ert-deftest claude-agent-pi-smoke--jsonl-feed-chunk ()
  "The LF-only chunk splitter correctly handles partial + multi-line input
and survives a U+2028 inside a JSON string (which legacy readers would
incorrectly treat as a record boundary)."
  :tags '(:smoke :pi-backend)
  (let* ((b (claude-agent-pi-backend-create :session-key "split"))
         (dispatched '()))
    ;; Stub the dispatcher to just collect parsed lines.
    (cl-letf (((symbol-function 'claude-agent-pi--dispatch-line)
               (lambda (_backend line) (push line dispatched))))
      ;; Partial: no newline → nothing dispatched, buffer accumulates.
      (claude-agent-pi--feed-chunk b "{\"a\":")
      (should (null dispatched))
      ;; Finish first record + start of second.
      (claude-agent-pi--feed-chunk b "1}\n{\"b\":2}\n{\"c\":\"x y\"")
      (should (equal '("{\"a\":1}" "{\"b\":2}")
                     (nreverse dispatched)))
      ;; Final newline closes the U+2028-bearing record.
      (setq dispatched nil)
      (claude-agent-pi--feed-chunk b "}\n")
      (should (equal 1 (length dispatched)))
      (should (string-search " " (car dispatched))))))


;; --- Live: real subprocess against the user's Pi install ---
;;
;; These tests spawn `pi --mode rpc' and exchange real JSON-RPC.
;; They require:
;;   - `pi' on PATH (the npm-installed @earendil-works/pi-coding-agent)
;;   - Pi already configured with a default provider/model + API key
;;     (~/.pi/agent/settings.json + ~/.pi/agent/auth.json)
;; They are tagged `:pi-backend-live' so the smoke suite stays
;; hermetic — `make test-pi-backend' does NOT include them.
;;
;; Helpers live in tests/support/pi-test-helpers.el so the e2e runner
;; (tests/test-e2e-pi-backend.el) can reuse them.

(require 'pi-test-helpers)


(ert-deftest claude-agent-pi-live--handshake ()
  "Spawn pi --mode rpc, complete handshake, read model from get_state."
  :tags '(:pi-backend-live)
  (skip-unless (test-pi--available-p))
  (test-pi--with-backend b
    (let (result)
      (claude-agent-pi--ensure-spawn-and-handshake
       b
       (lambda () (setq result :ok))
       (lambda (msg) (setq result (cons :err msg))))
      (should (test-pi--wait-until (lambda () result) 12))
      (should (eq result :ok))
      (should (claude-agent-backend-ready-p b))
      (should (claude-agent-backend-session-id b))
      ;; The state alist proves we round-tripped Pi's get_state response.
      (let ((state (claude-agent-pi-backend-state b)))
        (should state)
        (should (alist-get 'model state))))))


(ert-deftest claude-agent-pi-live--simple-query ()
  "Send a prompt; collect text tokens; assert on-complete fires.
Uses an explicit deterministic reply target so the test is robust
across providers / temperatures."
  :tags '(:pi-backend-live)
  (skip-unless (test-pi--available-p))
  (test-pi--with-backend b
    (let ((collected "")
          (complete nil)
          (errored nil))
      (claude-agent-backend-query
       b
       "Reply with the exact text MARKER_ALPHA and nothing else. No punctuation."
       (list
        :on-token (lambda (delta)
                    (setq collected (concat collected delta)))
        :on-complete (lambda (_messages) (setq complete t))
        :on-error (lambda (msg) (setq errored msg))))
      ;; 45s is generous — DeepSeek deepseek-v4-pro with thinking
      ;; on routinely emits 5-10s of `thinking_*' events before
      ;; the actual text reply.
      (should (test-pi--wait-until (lambda () (or complete errored)) 45))
      (should (null errored))
      (should complete)
      ;; The token stream should contain our marker; thinking
      ;; events are filtered out by default so `collected'
      ;; should be the assistant text only.
      (should (string-match-p "MARKER_ALPHA" collected)))))


(ert-deftest claude-agent-pi-live--extension-roundtrip ()
  "End-to-end: Pi LLM calls emacs_buffer_list, MCP routes to Emacs,
result flows back into the LLM context.  This is the dual-direction
loop that makes the Pi backend valuable — without the extension, the
LLM can only produce text; with it, the LLM can introspect Emacs."
  :tags '(:pi-backend-live)
  (skip-unless (and (test-pi--available-p)
                    (test-pi--mcp-available-p)
                    (test-pi--extension-installed-p)))
  (test-pi--with-backend b
    ;; The extension reads ALLOW_EVAL from env at Pi spawn; we don't
    ;; need eval here (just buffer_list) so the gate is irrelevant,
    ;; but setting it keeps the test robust if the LLM decides to
    ;; reach for emacs_eval instead.
    (setf (claude-agent-pi-backend-environment b)
          '("EMACS_MCP_ALLOW_EVAL=1"))
    (let ((collected "")
          (complete nil)
          (errored nil))
      (claude-agent-backend-query
       b
       (concat "Call the emacs_buffer_list tool with pattern=\"scratch\". "
               "Once you have the result, reply with exactly: FOUND_BUFFERS")
       (list
        :on-token (lambda (delta) (setq collected (concat collected delta)))
        :on-complete (lambda (_msgs) (setq complete t))
        :on-error (lambda (msg) (setq errored msg))))
      (should (test-pi--wait-until (lambda () (or complete errored)) 90))
      (should (null errored))
      (should complete)
      (should (string-match-p "FOUND_BUFFERS" collected)))))


(ert-deftest claude-agent-pi-live--cleanup-kills-process ()
  "After backend-cleanup, the subprocess is no longer live."
  :tags '(:pi-backend-live)
  (skip-unless (test-pi--available-p))
  (let ((b (claude-agent-pi-backend-create
            :session-key (format "cleanup-%d" (random 100000)))))
    (claude-agent-pi--ensure-spawn-and-handshake
     b (lambda () nil) (lambda (_msg) nil))
    (test-pi--wait-until (lambda () (claude-agent-backend-ready-p b)) 12)
    (let ((proc (claude-agent-pi-backend-process b)))
      (should (process-live-p proc))
      (claude-agent-backend-cleanup b)
      ;; Graceful shutdown sleeps `claude-agent-pi-cleanup-grace' between
      ;; EOF and SIGTERM, so allow ~3x the grace before asserting death.
      (test-pi--wait-until
       (lambda () (not (process-live-p proc)))
       (* 4 claude-agent-pi-cleanup-grace))
      (should-not (process-live-p proc))
      (should-not (claude-agent-backend-ready-p b)))))


(provide 'test-claude-agent-pi-backend)
;;; test-claude-agent-pi-backend.el ends here
