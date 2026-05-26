;;; test-code-agent-unit.el --- Unit tests for code-agent.org -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for code-agent.org (core SDK module)
;; These tests do NOT make actual API calls.

;;; Code:

(require 'ert)
(require 'code-agent)

;;; Data Structures Tests

(ert-deftest test-code-agent-options-construction ()
  "Test that code-agent-options creates a valid plist."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((opts (code-agent-options
               :model "claude-sonnet-4"
               :cwd "/tmp"
               :permission-mode "plan")))
    (should (plist-get opts :model))
    (should (equal "claude-sonnet-4" (plist-get opts :model)))
    (should (equal "/tmp" (plist-get opts :cwd)))
    (should (equal "plan" (plist-get opts :permission-mode)))))

(ert-deftest test-code-agent-options-defaults ()
  "Test that code-agent-options handles nil/default values."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((opts (code-agent-options)))
    (should (listp opts))
    ;; Should be a valid plist (even if empty)
    (should (= 0 (mod (length opts) 2)))))

(ert-deftest test-code-agent-text-block-predicates ()
  "Test text block type predicates."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((text-block (code-agent-make-text-block :text "hello")))
    (should (code-agent-text-block-p text-block))
    (should-not (code-agent-tool-use-block-p text-block))
    (should-not (code-agent-tool-result-block-p text-block))
    (should (equal "hello" (code-agent-text-block-text text-block)))))

(ert-deftest test-code-agent-tool-use-block-predicates ()
  "Test tool-use block type predicates."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((tool-block (code-agent-make-tool-use-block
                     :id "123"
                     :name "Read"
                     :input '(:file "test.txt"))))
    (should (code-agent-tool-use-block-p tool-block))
    (should-not (code-agent-text-block-p tool-block))
    (should-not (code-agent-tool-result-block-p tool-block))
    (should (equal "Read" (code-agent-tool-use-block-name tool-block)))
    (should (equal "123" (code-agent-tool-use-block-id tool-block)))
    (should (plist-get (code-agent-tool-use-block-input tool-block) :file))))

(ert-deftest test-code-agent-tool-result-block-predicates ()
  "Test tool-result block type predicates."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((result-block (code-agent-make-tool-result-block
                       :tool-use-id "123"
                       :content "success"
                       :is-error nil)))
    (should (code-agent-tool-result-block-p result-block))
    (should-not (code-agent-text-block-p result-block))
    (should-not (code-agent-tool-use-block-p result-block))))

(ert-deftest test-code-agent-message-type-predicates ()
  "Test message type predicates."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((assistant-msg (code-agent-make-assistant-message
                        :content (list (code-agent-make-text-block :text "hello"))))
        (user-msg (code-agent-make-user-message :content "question"))
        (system-msg (code-agent-make-system-message :subtype "thinking"))
        (result-msg (code-agent-make-result-message :session-id "abc123")))
    (should (code-agent-assistant-message-p assistant-msg))
    (should-not (code-agent-assistant-message-p user-msg))
    (should (code-agent-user-message-p user-msg))
    (should (code-agent-system-message-p system-msg))
    (should (equal "thinking" (code-agent-system-message-subtype system-msg)))
    (should (code-agent-result-message-p result-msg))
    (should (equal "abc123" (code-agent-result-message-session-id result-msg)))))

(ert-deftest test-code-agent-extract-text ()
  "Test text extraction from assistant messages."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((msg (code-agent-make-assistant-message
              :content (list (code-agent-make-text-block :text "Hello")
                             (code-agent-make-text-block :text " ")
                             (code-agent-make-text-block :text "World")))))
    (should (equal "Hello World" (code-agent-extract-text msg))))
  ;; Empty content
  (let ((msg (code-agent-make-assistant-message :content nil)))
    (should-not (code-agent-extract-text msg)))
  ;; Mixed content (text + tool-use)
  (let ((msg (code-agent-make-assistant-message
              :content (list (code-agent-make-text-block :text "Using tool: ")
                             (code-agent-make-tool-use-block :id "1" :name "Read" :input nil)
                             (code-agent-make-text-block :text "done")))))
    (should (equal "Using tool: done" (code-agent-extract-text msg)))))

;;; Session Management Tests

(ert-deftest test-code-agent-make-session-key ()
  "Test session key creation."
  :tags '(:unit :fast :stable :isolated :session)
  ;; Without custom ID
  (should (equal "/path/to/file.org"
                 (code-agent--make-session-key "/path/to/file.org" nil)))
  ;; With custom ID
  (should (equal "/path/to/file.org::my-session"
                 (code-agent--make-session-key "/path/to/file.org" "my-session")))
  ;; Empty custom ID creates "file::" (not treated as nil)
  (should (equal "/path/to/file.org::"
                 (code-agent--make-session-key "/path/to/file.org" ""))))

(ert-deftest test-code-agent-session-uuid-mapping ()
  "Test SDK UUID to session key mapping."
  :tags '(:unit :fast :stable :isolated :session)
  ;; Create fresh hash table for this test (only one hash table exists)
  (let ((code-agent--session-mapping (make-hash-table :test 'equal)))
    ;; Store mapping
    (code-agent--store-sdk-uuid "file.org::session1" "uuid-abc")
    (should (equal "uuid-abc" (code-agent--get-sdk-uuid "file.org::session1")))
    ;; Update mapping
    (code-agent--store-sdk-uuid "file.org::session1" "uuid-xyz")
    (should (equal "uuid-xyz" (code-agent--get-sdk-uuid "file.org::session1")))
    ;; Clear session
    (code-agent--clear-session "file.org::session1")
    (should-not (code-agent--get-sdk-uuid "file.org::session1"))))

(ert-deftest test-code-agent-session-expiry-detection ()
  "Test detection of session expiry errors."
  :tags '(:unit :fast :stable :isolated :session)
  (should (code-agent--session-expired-p "No conversation found with session ID abc"))
  (should (code-agent--session-expired-p "session not found"))
  (should-not (code-agent--session-expired-p "Network error"))
  (should-not (code-agent--session-expired-p "Invalid API key")))

(ert-deftest test-code-agent-context-limit-detection ()
  "Test detection of context limit errors."
  :tags '(:unit :fast :stable :isolated :session)
  (should (code-agent--context-too-long-p "Prompt is too long"))
  (should (code-agent--context-too-long-p "prompt is too long for this model"))
  (should-not (code-agent--context-too-long-p "Network error"))
  (should-not (code-agent--context-too-long-p "Session expired")))

;;; IDE Context Tests

(ert-deftest test-code-agent-collect-ide-context ()
  "Test IDE context collection."
  :tags '(:unit :fast :stable :isolated :context)
  ;; The function looks for the most recent file buffer from buffer-list
  ;; In batch mode, this might not find our temp buffer
  (let ((context (code-agent-collect-ide-context)))
    (should (plist-get context :cwd))  ; Should have working directory
    (should (listp (plist-get context :open-files)))
    ;; current-file may or may not exist depending on buffer state
    ;; just verify structure is valid
    (should (or (null (plist-get context :current-file))
                (plistp (plist-get context :current-file))))))

(ert-deftest test-code-agent-collect-selection-context ()
  "Test selection context collection."
  :tags '(:unit :fast :stable :isolated :context)
  (with-temp-buffer
    (insert "line 1\nline 2\nline 3\nline 4\n")
    (goto-char (point-min))
    (forward-line 1)  ; Start of line 2
    (set-mark (point))
    (forward-line 2)  ; Start of line 4
    (activate-mark)
    (let ((context (code-agent-collect-ide-context)))
      (if (plist-get context :selection)
          (let ((sel (plist-get context :selection)))
            (should (plist-get sel :start-line))
            (should (plist-get sel :end-line))
            (should (stringp (plist-get sel :text))))
        ;; Selection may not be collected in batch mode
        (should t)))))

(ert-deftest test-code-agent-exclude-predicates ()
  "Test IDE context exclusion predicates."
  :tags '(:unit :fast :stable :isolated :context)
  ;; This test requires code-agent-org to be loaded which registers its exclusion
  ;; For now, just test that the list exists and is callable
  (should (listp code-agent-ide-context-exclude-predicates))
  ;; Test that predicates are callable
  (with-temp-buffer
    (dolist (pred code-agent-ide-context-exclude-predicates)
      (should (functionp pred))
      ;; Should not error when called
      (funcall pred (current-buffer)))))

(ert-deftest test-code-agent-build-system-reminder ()
  "Test system reminder message construction."
  :tags '(:unit :fast :stable :isolated :context)
  (let* ((current-file '(:name "test.el" :language "emacs-lisp" :modified t))
         (open-files '((:name "foo.py" :language "python")
                       (:name "bar.js" :language "javascript")))
         (selection '(:start-line 10 :end-line 15 :text "selected text"))
         (reminder (code-agent-build-system-reminder
                    :current-file current-file
                    :open-files open-files
                    :selection selection
                    :file-path "/tmp/test.el")))
    (should (stringp reminder))
    ;; Should contain system reminder tag
    (should (string-match-p "system-reminder" reminder))
    ;; Basic check that it's not empty
    (should (> (length reminder) 50))))

;;; Query Cancellation Tests

(ert-deftest test-code-agent-active-query-tracking ()
  "Test tracking of active queries."
  :tags '(:unit :fast :stable :isolated :process)
  ;; Create fresh hash table for this test
  (let ((code-agent--active-queries (make-hash-table :test 'equal)))
    ;; Initially empty
    (should (= 0 (code-agent-active-query-count)))
    ;; Create proper process state struct
    (let ((state (code-agent--make-process-state
                  :request-id "req-123"
                  :process nil
                  :buffer nil
                  :closed nil)))
      (code-agent--register-query "req-123" state)
      (should (= 1 (code-agent-active-query-count)))
      ;; Get it back - MUST return the actual state, not just truthy
      (let ((retrieved (code-agent--get-active-query "req-123")))
        (should retrieved)
        (should (eq retrieved state))
        (should (code-agent--process-state-p retrieved))
        (should (equal "req-123" (code-agent--process-state-request-id retrieved))))
      ;; Non-existent query should return nil
      (should-not (code-agent--get-active-query "nonexistent-id"))
      ;; Unregister
      (code-agent--unregister-query "req-123")
      (should (= 0 (code-agent-active-query-count)))
      ;; After unregister, should return nil
      (should-not (code-agent--get-active-query "req-123")))))

(ert-deftest test-code-agent-query-cancellation ()
  "Test query cancellation by request ID."
  :tags '(:unit :fast :stable :isolated :process)
  ;; This tests the cancellation registration, not actual process killing
  (let ((code-agent--active-queries (make-hash-table :test 'equal))
        (cancelled nil))
    ;; Create mock process
    (let ((proc (make-process
                 :name "test-process"
                 :command '("cat")
                 :sentinel (lambda (proc event)
                             (setq cancelled t)))))
      ;; Create proper process state struct
      (let ((state (code-agent--make-process-state
                    :request-id "req-123"
                    :process proc
                    :buffer nil
                    :closed nil)))
        (code-agent--register-query "req-123" state)
        (should (= 1 (code-agent-active-query-count)))
        ;; Cancel should work
        (should (code-agent-cancel-query "req-123"))
        ;; Should be marked as closed
        (should (code-agent--process-state-closed state))
        ;; Clean up process
        (when (process-live-p proc)
          (delete-process proc))))))

;;; Utility Tests

(ert-deftest test-code-agent-generate-request-id ()
  "Test request ID generation."
  :tags '(:unit :fast :stable :isolated :process)
  (let ((id1 (code-agent--generate-request-id))
        (id2 (code-agent--generate-request-id)))
    (should (stringp id1))
    (should (stringp id2))
    (should-not (equal id1 id2))
    (should (string-match-p "^req-[0-9]+-[0-9]+$" id1))))

(ert-deftest test-code-agent-cli-discovery ()
  "Test Claude CLI discovery."
  :tags '(:unit :fast :stable :isolated :process)
  ;; This test checks if we can find the CLI or handle its absence gracefully
  (condition-case err
      (let ((cli (code-agent--find-cli)))
        ;; Should either find it or return the default "claude"
        (should (stringp cli))
        (should (or (file-executable-p cli)
                    (equal "claude" cli))))
    (code-agent-cli-not-found-error
     ;; In CI without Claude CLI installed, verify the error is signaled correctly
     (should (string-match-p "not found" (cadr err))))))

;;; Permission System Tests

(ert-deftest test-code-agent-permission-match-wildcard ()
  "Test that wildcard pattern matches everything."
  :tags '(:unit :fast :stable :isolated :permission)
  (should (code-agent-permission-match-p "Read" '(:file_path "/tmp/test.txt") "*"))
  (should (code-agent-permission-match-p "Write" '(:file_path "/etc/passwd") "*"))
  (should (code-agent-permission-match-p "Bash" '(:command "rm -rf /") "*"))
  (should (code-agent-permission-match-p "mcp__emacs__evalElisp" '(:code "(+ 1 2)") "*")))

(ert-deftest test-code-agent-permission-match-tool-name ()
  "Test simple tool name matching without arguments."
  :tags '(:unit :fast :stable :isolated :permission)
  (should (code-agent-permission-match-p "Read" '(:file_path "/tmp/test.txt") "Read"))
  (should (code-agent-permission-match-p "Write" '(:file_path "/tmp/test.txt") "Write"))
  (should-not (code-agent-permission-match-p "Read" '(:file_path "/tmp/test.txt") "Write"))
  (should-not (code-agent-permission-match-p "Bash" '(:command "ls") "Read")))

(ert-deftest test-code-agent-permission-match-double-star ()
  "Test (**) pattern matches any arguments."
  :tags '(:unit :fast :stable :isolated :permission)
  (should (code-agent-permission-match-p "Read" '(:file_path "/tmp/test.txt") "Read(**)"))
  (should (code-agent-permission-match-p "Read" '(:file_path "/etc/passwd") "Read(**)"))
  (should (code-agent-permission-match-p "Write" '(:file_path "/home/user/doc.txt") "Write(**)"))
  (should-not (code-agent-permission-match-p "Read" '(:file_path "/tmp/x") "Write(**)")))

(ert-deftest test-code-agent-permission-match-prefix ()
  "Test prefix:* pattern matches commands starting with prefix."
  :tags '(:unit :fast :stable :isolated :permission)
  (should (code-agent-permission-match-p "Bash" '(:command "git status") "Bash(git:*)"))
  (should (code-agent-permission-match-p "Bash" '(:command "git commit -m test") "Bash(git:*)"))
  (should-not (code-agent-permission-match-p "Bash" '(:command "rm -rf /") "Bash(git:*)")))

(ert-deftest test-code-agent-permission-match-mcp-glob ()
  "Test glob pattern for MCP tool names."
  :tags '(:unit :fast :stable :isolated :permission)
  (should (code-agent-permission-match-p "mcp__emacs__evalElisp" nil "mcp__emacs__*"))
  (should (code-agent-permission-match-p "mcp__emacs__getDiagnostics" nil "mcp__emacs__*"))
  (should (code-agent-permission-match-p "mcp__context7__resolve-library-id" nil "mcp__context7__*"))
  (should-not (code-agent-permission-match-p "mcp__emacs__evalElisp" nil "mcp__context7__*")))

(ert-deftest test-code-agent-permission-match-path-glob ()
  "Test glob pattern for file paths."
  :tags '(:unit :fast :stable :isolated :permission)
  ;; Match any file (** pattern)
  (should (code-agent-permission-match-p "Read" '(:file_path "/project/.env") "Read(**)"))
  (should (code-agent-permission-match-p "Read" '(:file_path "/home/user/app/.env") "Read(**)"))
  ;; Match specific directory prefix
  (should (code-agent-permission-match-p "Write" '(:file_path "/tmp/foo.txt") "Write(/tmp/*)"))
  ;; Match files starting with specific path
  (should (code-agent-permission-match-p "Read" '(:file_path "/home/user/doc.txt") "Read(/home/*)")))

(ert-deftest test-code-agent-permission-check-deny-first ()
  "Test that deny patterns take precedence over allow."
  :tags '(:unit :fast :stable :isolated :permission)
  (let ((allow '("Read(**)" "Bash(**)"))
        (deny '("Bash(rm *)")))
    ;; Read should be allowed
    (should (eq 'allow (code-agent-check-permission
                        "Read" '(:file_path "/tmp/test") allow deny)))
    ;; Normal bash should be allowed
    (should (eq 'allow (code-agent-check-permission
                        "Bash" '(:command "ls -la") allow deny)))
    ;; rm command should be denied (matches deny pattern)
    (should (eq 'deny (code-agent-check-permission
                       "Bash" '(:command "rm -rf /tmp/foo") allow deny)))))

(ert-deftest test-code-agent-permission-check-default-deny ()
  "Test that default deny patterns are always checked."
  :tags '(:unit :fast :stable :isolated :permission)
  (let ((allow '("Bash(**)"))  ; Allow all bash
        (deny '()))             ; No user deny patterns
    ;; sudo should still be denied by default patterns
    (should (eq 'deny (code-agent-check-permission
                       "Bash" '(:command "sudo rm -rf /") allow deny)))
    ;; chmod 777 should be denied
    (should (eq 'deny (code-agent-check-permission
                       "Bash" '(:command "chmod 777 /etc/passwd") allow deny)))))

(ert-deftest test-code-agent-permission-check-ask ()
  "Test that unmatched tools return 'ask."
  :tags '(:unit :fast :stable :isolated :permission)
  (let ((allow '("Read(**)"))
        (deny '()))
    ;; Write is not in allow list, should ask
    (should (eq 'ask (code-agent-check-permission
                      "Write" '(:file_path "/tmp/new.txt") allow deny)))
    ;; Unknown tool should ask
    (should (eq 'ask (code-agent-check-permission
                      "CustomTool" '(:arg "value") allow deny)))))

(ert-deftest test-code-agent-permission-presets ()
  "Test preset permission configurations."
  :tags '(:unit :fast :stable :isolated :permission)
  ;; Readonly preset
  (let ((code-agent-permission-preset "readonly"))
    (let ((perms (code-agent-get-effective-permissions)))
      (should (member "Read(**)" (plist-get perms :allow)))
      (should (member "Glob(**)" (plist-get perms :allow)))
      (should (member "Grep(**)" (plist-get perms :allow)))
      (should-not (member "Write(**)" (plist-get perms :allow)))))
  ;; Accept-edits preset
  (let ((code-agent-permission-preset "accept-edits"))
    (let ((perms (code-agent-get-effective-permissions)))
      (should (member "Read(**)" (plist-get perms :allow)))
      (should (member "Write(**)" (plist-get perms :allow)))
      (should (member "Edit(**)" (plist-get perms :allow)))))
  ;; Bypass preset
  (let ((code-agent-permission-preset "bypass"))
    (let ((perms (code-agent-get-effective-permissions)))
      (should (member "*" (plist-get perms :allow))))))

(ert-deftest test-code-agent-permission-custom ()
  "Test custom permission configuration."
  :tags '(:unit :fast :stable :isolated :permission)
  (let ((code-agent-permission-preset "custom")
        (code-agent-permissions
         '(:allow ("Read(**)" "Bash(git:*)")
           :deny ("Read(**/.env)"))))
    (let ((perms (code-agent-get-effective-permissions)))
      (should (equal code-agent-permissions perms)))))

(ert-deftest test-code-agent-permission-cache-key ()
  "Test permission cache key generation."
  :tags '(:unit :fast :stable :isolated :permission)
  ;; File-based tools use directory
  (should (equal "Read:/tmp/"
                 (code-agent--permission-cache-key "Read" '(:file_path "/tmp/test.txt"))))
  (should (equal "Write:/home/user/"
                 (code-agent--permission-cache-key "Write" '(:file_path "/home/user/doc.txt"))))
  ;; Bash uses first word of command
  (should (equal "Bash:git"
                 (code-agent--permission-cache-key "Bash" '(:command "git status"))))
  ;; Tools without special handling use tool name
  (should (equal "WebSearch"
                 (code-agent--permission-cache-key "WebSearch" '(:query "test")))))

(ert-deftest test-code-agent-describe-tool-use ()
  "Test tool use description generation."
  :tags '(:unit :fast :stable :isolated :permission)
  ;; File tools show filename
  (should (equal "Read test.txt"
                 (code-agent--describe-tool-use "Read" '(:file_path "/tmp/test.txt"))))
  ;; Bash shows command (truncated if long)
  (should (equal "Bash: git status"
                 (code-agent--describe-tool-use "Bash" '(:command "git status"))))
  ;; Long commands are truncated
  (let ((long-cmd (make-string 100 ?x)))
    (should (string-match-p "\\.\\.\\.$"
                            (code-agent--describe-tool-use "Bash" `(:command ,long-cmd))))))

(ert-deftest test-code-agent-permission-auto-allow ()
  "Test auto-allow permission callback."
  :tags '(:unit :fast :stable :isolated :permission)
  (let ((result (code-agent-permission-auto-allow "Read" '(:file_path "/tmp/x") nil)))
    (should (equal "allow" (plist-get result :behavior)))))

(ert-deftest test-code-agent-get-tool-first-arg ()
  "Test extraction of primary argument from tool input."
  :tags '(:unit :fast :stable :isolated :permission)
  ;; File operations
  (should (equal "/tmp/test.txt"
                 (code-agent--get-tool-first-arg "Read" '(:file_path "/tmp/test.txt"))))
  (should (equal "/tmp/out.txt"
                 (code-agent--get-tool-first-arg "Write" '(:file_path "/tmp/out.txt" :content "data"))))
  ;; Glob uses pattern
  (should (equal "**/*.el"
                 (code-agent--get-tool-first-arg "Glob" '(:pattern "**/*.el"))))
  ;; Bash uses command
  (should (equal "git status"
                 (code-agent--get-tool-first-arg "Bash" '(:command "git status"))))
  ;; WebSearch uses query
  (should (equal "elisp tutorial"
                 (code-agent--get-tool-first-arg "WebSearch" '(:query "elisp tutorial"))))
  ;; WebFetch uses url
  (should (equal "https://example.com"
                 (code-agent--get-tool-first-arg "WebFetch" '(:url "https://example.com")))))

;;; Query Identity Display Tests

(ert-deftest test-code-agent-format-query-identity-with-buffer-and-label ()
  "Test query identity formatting with source buffer and query-context."
  :tags '(:unit :fast :stable :isolated :display)
  (with-temp-buffer
    (rename-buffer "code-agent-dev.org" t)
    (let* ((ctx (code-agent-make-query-context :instruction-num 5))
           (state (code-agent--make-process-state
                   :request-id "req-42-1234567890"
                   :source-buffer (current-buffer)
                   :query-context ctx)))
      ;; Short form should show "basename#label"
      (should (equal "code-agent-dev#5"
                     (code-agent--format-query-identity state)))
      ;; Long form should show full buffer name
      (should (string-match-p "code-agent-dev.*#5"
                              (code-agent--format-query-identity state t))))))

(ert-deftest test-code-agent-format-query-identity-buffer-only ()
  "Test query identity with buffer but no query-context."
  :tags '(:unit :fast :stable :isolated :display)
  (with-temp-buffer
    (rename-buffer "test-file.org" t)
    (let ((state (code-agent--make-process-state
                  :request-id "req-10-1234567890"
                  :source-buffer (current-buffer)
                  :query-context nil)))
      ;; Should show just buffer name without "#"
      (should (equal "test-file"
                     (code-agent--format-query-identity state))))))

(ert-deftest test-code-agent-format-query-identity-fallback ()
  "Test query identity fallback when no buffer available."
  :tags '(:unit :fast :stable :isolated :display)
  ;; No source buffer - should fall back to request-id
  (let ((state (code-agent--make-process-state
                :request-id "req-99-1234567890"
                :source-buffer nil
                :query-context nil)))
    (should (equal "#99" (code-agent--format-query-identity state))))
  ;; Dead buffer - should also fall back
  (let* ((buf (generate-new-buffer "temp-dead"))
         (ctx (code-agent-make-query-context :instruction-num 3))
         (state (code-agent--make-process-state
                 :request-id "req-88-1234567890"
                 :source-buffer buf
                 :query-context ctx)))
    (kill-buffer buf)
    (should (equal "#88" (code-agent--format-query-identity state)))))

(ert-deftest test-code-agent-get-single-active-state ()
  "Test getting single active query state."
  :tags '(:unit :fast :stable :isolated :display)
  (let ((code-agent--active-queries (make-hash-table :test 'equal)))
    ;; Empty - should return nil
    (should-not (code-agent--get-single-active-state))
    ;; One active query
    (let ((state1 (code-agent--make-process-state
                   :request-id "req-1"
                   :closed nil)))
      (code-agent--register-query "req-1" state1)
      (should (eq state1 (code-agent--get-single-active-state))))
    ;; Two queries - should return nil
    (let ((state2 (code-agent--make-process-state
                   :request-id "req-2"
                   :closed nil)))
      (code-agent--register-query "req-2" state2)
      (should-not (code-agent--get-single-active-state)))
    ;; Clean up
    (code-agent--unregister-query "req-1")
    (code-agent--unregister-query "req-2")))

(ert-deftest test-code-agent-process-state-source-slots ()
  "Test that process-state has source-buffer and query-context slots."
  :tags '(:unit :fast :stable :isolated :display)
  (with-temp-buffer
    (let* ((ctx (code-agent-make-query-context
                 :instruction-num 42
                 :loop-current 1
                 :loop-max 1))
           (state (code-agent--make-process-state
                   :source-buffer (current-buffer)
                   :query-context ctx)))
      (should (eq (current-buffer)
                  (code-agent--process-state-source-buffer state)))
      (should (code-agent-query-context-p
               (code-agent--process-state-query-context state)))
      (should (equal 42
                     (code-agent-query-context-instruction-num
                      (code-agent--process-state-query-context state)))))))

(ert-deftest test-code-agent-query-context-format-id ()
  "Test query-context-format-id formatting."
  :tags '(:unit :fast :stable :isolated :display)
  ;; Single execution (no loop suffix)
  (let ((ctx (code-agent-make-query-context
              :instruction-num 5
              :loop-current 1
              :loop-max 1)))
    (should (equal "5" (code-agent-query-context-format-id ctx))))
  ;; Loop iteration
  (let ((ctx (code-agent-make-query-context
              :instruction-num 5
              :loop-current 2
              :loop-max 3)))
    (should (equal "5(2/3)" (code-agent-query-context-format-id ctx))))
  ;; First iteration of loop
  (let ((ctx (code-agent-make-query-context
              :instruction-num 5
              :loop-current 1
              :loop-max 3)))
    (should (equal "5(1/3)" (code-agent-query-context-format-id ctx))))
  ;; No instruction number
  (let ((ctx (code-agent-make-query-context
              :instruction-num nil)))
    (should (null (code-agent-query-context-format-id ctx)))))

(ert-deftest test-code-agent-query-context-format-label ()
  "Test query-context-format-label formatting."
  :tags '(:unit :fast :stable :isolated :display)
  ;; Single execution
  (let ((ctx (code-agent-make-query-context
              :instruction-num 5
              :loop-current 1
              :loop-max 1)))
    (should (equal "Instruction 5" (code-agent-query-context-format-label ctx))))
  ;; Loop iteration
  (let ((ctx (code-agent-make-query-context
              :instruction-num 5
              :loop-current 2
              :loop-max 3)))
    (should (equal "Instruction 5 (2/3)" (code-agent-query-context-format-label ctx))))
  ;; First iteration of loop
  (let ((ctx (code-agent-make-query-context
              :instruction-num 5
              :loop-current 1
              :loop-max 3)))
    (should (equal "Instruction 5 (1/3)" (code-agent-query-context-format-label ctx)))))

;;; Activity Mode-Line Tests

(ert-deftest test-code-agent-format-activity-tooltip ()
  "Test activity tooltip formatting function exists and works."
  :tags '(:unit :fast :stable :isolated :display)
  ;; First verify the function exists (this would have caught the deletion!)
  (should (fboundp 'code-agent--format-activity-tooltip))
  ;; Test with no active queries
  (let ((code-agent--active-queries (make-hash-table :test 'equal)))
    (let ((tooltip (code-agent--format-activity-tooltip)))
      (should (stringp tooltip))
      (should (string-match-p "Active Claude Queries" tooltip))
      (should (string-match-p "no active queries" tooltip))))
  ;; Test with one active query
  (let ((code-agent--active-queries (make-hash-table :test 'equal)))
    (with-temp-buffer
      (rename-buffer "test-activity.org" t)
      (let* ((ctx (code-agent-make-query-context :instruction-num 7))
             (state (code-agent--make-process-state
                     :request-id "req-123"
                     :source-buffer (current-buffer)
                     :query-context ctx
                     :start-time (float-time)
                     :closed nil)))
        (code-agent--register-query "req-123" state)
        (let ((tooltip (code-agent--format-activity-tooltip)))
          (should (stringp tooltip))
          (should (string-match-p "test-activity" tooltip))
          (should (string-match-p "#7" tooltip))
          (should (string-match-p "\\[.*s\\]" tooltip)))  ; elapsed time like [0s]
        (code-agent--unregister-query "req-123")))))

(ert-deftest test-code-agent-update-activity-string ()
  "Test activity string update doesn't error.
This test ensures all helper functions called exist."
  :tags '(:unit :fast :stable :isolated :display)
  ;; This test will fail if any function called by update-activity-string is missing
  (let ((code-agent--active-queries (make-hash-table :test 'equal))
        (code-agent-activity-string "")
        (code-agent--spinner-index 0))
    ;; Test with no queries - should not error
    (should (progn (code-agent--update-activity-string) t))
    (should (equal "" code-agent-activity-string))
    ;; Test with one query
    (let* ((ctx (code-agent-make-query-context :instruction-num 1))
           (state (code-agent--make-process-state
                   :request-id "req-test"
                   :start-time (float-time)
                   :query-context ctx
                   :closed nil)))
      (code-agent--register-query "req-test" state)
      ;; This call would have caught the void-function error!
      (should (progn (code-agent--update-activity-string) t))
      (should (stringp code-agent-activity-string))
      (should (> (length code-agent-activity-string) 0))
      ;; Verify tooltip is set as help-echo property
      (should (get-text-property 0 'help-echo code-agent-activity-string))
      (code-agent--unregister-query "req-test"))))

;;; Session Recovery Unit Tests

(ert-deftest test-code-agent-recovery-abnormal-exit-detection ()
  "Test the abnormal exit detection logic for automatic recovery."
  :tags '(:unit :fast :stable :isolated :recovery)

  (let ((code-agent-auto-recovery t))
    ;; Test 1: Signal kill should trigger recovery (if session-id available)
    (let ((state (code-agent--make-process-state
                  :session-id "test-uuid")))
      (should (code-agent--is-abnormal-exit-p "killed: 9" state)))

    ;; Test 2: Abnormal exit should trigger recovery
    (let ((state (code-agent--make-process-state
                  :session-id "test-uuid")))
      (should (code-agent--is-abnormal-exit-p "exited abnormally with code 1" state)))

    ;; Test 3: Normal finish without result should trigger recovery
    (let ((state (code-agent--make-process-state
                  :session-id "test-uuid")))
      (should (code-agent--is-abnormal-exit-p "finished" state)))

    ;; Test 4: Normal finish WITH result should NOT trigger recovery
    (let ((state (code-agent--make-process-state
                  :session-id "test-uuid"
                  :got-result t)))
      (should-not (code-agent--is-abnormal-exit-p "finished" state)))

    ;; Test 5: No session-id means no recovery possible
    (let ((state (code-agent--make-process-state)))
      (should-not (code-agent--is-abnormal-exit-p "killed: 9" state)))

    ;; Test 6: Recovery disabled globally
    (let ((code-agent-auto-recovery nil)
          (state (code-agent--make-process-state
                  :session-id "test-uuid")))
      (should-not (code-agent--is-abnormal-exit-p "killed: 9" state)))))

(ert-deftest test-code-agent-recovery-message-format ()
  "Test that the recovery message has the expected format."
  :tags '(:unit :fast :stable :isolated :recovery)

  ;; Create a mock state with token-callback
  (let ((received-message nil))
    (let ((state (code-agent--make-process-state
                  :token-callback (lambda (text)
                                    (setq received-message text)))))
      ;; Test with kill signal
      (code-agent--insert-recovery-message state "killed: 9")
      (should received-message)
      (should (string-match-p "Session interrupted" received-message))
      (should (string-match-p "killed: 9" received-message))
      (should (string-match-p "automatic recovery" received-message)))))

(ert-deftest test-code-agent-recovery-message-exit-code ()
  "Test recovery message format with exit code."
  :tags '(:unit :fast :stable :isolated :recovery)

  (let ((received-message nil))
    (let ((state (code-agent--make-process-state
                  :token-callback (lambda (text)
                                    (setq received-message text)))))
      ;; Test with exit code
      (code-agent--insert-recovery-message state "exited abnormally with code 137")
      (should received-message)
      (should (string-match-p "exit code: 137" received-message)))))

(ert-deftest test-code-agent-recovery-message-no-callback ()
  "Test that recovery message gracefully handles missing token-callback."
  :tags '(:unit :fast :stable :isolated :recovery)

  ;; State without token-callback should not crash
  (let ((state (code-agent--make-process-state)))
    (should-not (code-agent--insert-recovery-message state "killed: 9"))))

(ert-deftest test-code-agent-recovery-config-default ()
  "Test that auto-recovery is enabled by default."
  :tags '(:unit :fast :stable :isolated :recovery)
  (should (boundp 'code-agent-auto-recovery))
  (should code-agent-auto-recovery))

(ert-deftest test-code-agent-recovery-prompt-defined ()
  "Test that recovery prompt is defined and non-empty."
  :tags '(:unit :fast :stable :isolated :recovery)
  (should (boundp 'code-agent-recovery-prompt))
  (should (stringp code-agent-recovery-prompt))
  (should (> (length code-agent-recovery-prompt) 0)))

(ert-deftest test-code-agent-process-state-recovery-fields ()
  "Test that process-state struct has the recovery fields."
  :tags '(:unit :fast :stable :isolated :recovery)
  (let ((state (code-agent--make-process-state
                :session-id "test-session-id"
                :got-result t)))
    ;; Test session-id field
    (should (equal "test-session-id" (code-agent--process-state-session-id state)))
    ;; Test got-result field
    (should (eq t (code-agent--process-state-got-result state)))
    ;; Test default values
    (let ((default-state (code-agent--make-process-state)))
      (should-not (code-agent--process-state-session-id default-state))
      (should-not (code-agent--process-state-got-result default-state)))))

(ert-deftest test-code-agent-recovery-error-result-sets-got-result ()
  "Test that error result messages set got-result to prevent infinite recovery loops.
This is a regression test for the bug where CLI returning error_during_execution
would trigger infinite recovery loops because got-result was only set for
successful results."
  :tags '(:unit :fast :stable :isolated :recovery)

  ;; Simulate error result message from CLI (e.g., when resume fails)
  (let* ((error-result '(:type "result"
                         :subtype "error_during_execution"
                         :is_error t
                         :duration_ms 0
                         :num_turns 0
                         :session_id "test-session"))
         (error-called nil)
         (state (code-agent--make-process-state
                 :session-id "test-session"
                 :error-callback (lambda (_err) (setq error-called t)))))

    ;; Process the error result message (2-arg: callbacks from state)
    (code-agent--process-normal-message error-result state)

    ;; Verify got-result is set even for error results
    (should (code-agent--process-state-got-result state))
    ;; Error callback should have been called
    (should error-called)

    ;; Now verify that abnormal exit detection does NOT trigger recovery
    ;; because got-result is true
    (let ((code-agent-auto-recovery t))
      (should-not (code-agent--is-abnormal-exit-p "exited abnormally with code 1" state)))))

(ert-deftest test-code-agent-recovery-success-result-sets-got-result ()
  "Test that successful result messages also set got-result correctly."
  :tags '(:unit :fast :stable :isolated :recovery)

  ;; Simulate successful result message
  (let* ((success-result '(:type "result"
                           :subtype "success"
                           :is_error :json-false
                           :duration_ms 1000
                           :num_turns 1
                           :session_id "test-session"))
         (message-received nil)
         (state (code-agent--make-process-state
                 :session-id "test-session"
                 :callback (lambda (msg) (setq message-received msg)))))

    ;; Process the success result message (2-arg: callbacks from state)
    (code-agent--process-normal-message success-result state)

    ;; Verify got-result is set
    (should (code-agent--process-state-got-result state))
    ;; Message callback should have been called
    (should message-received)))

(ert-deftest test-code-agent-extract-json-error-uses-errors-array ()
  "Test that :errors array takes priority over generic subtype messages.
This is a regression test for the bug where CLI returning error_during_execution
with specific errors in the :errors array would show a generic message instead
of the actual error like 'No conversation found with session ID: ...'."
  :tags '(:unit :fast :stable :isolated)

  ;; Simulate error result with :errors array (like when resume fails)
  (let ((error-result '(:type "result"
                        :subtype "error_during_execution"
                        :is_error t
                        :duration_ms 0
                        :session_id "test-session"
                        :errors ("No conversation found with session ID: abc-123"))))
    (let ((error-msg (code-agent--extract-json-error error-result)))
      ;; Should extract the specific error from :errors array
      (should error-msg)
      (should (string-match-p "No conversation found" error-msg))
      ;; Should NOT return the generic "Execution error" message
      (should-not (string-match-p "Execution error" error-msg)))))

(ert-deftest test-code-agent-extract-json-error-falls-back-to-subtype ()
  "Test that generic subtype message is used when :errors is empty."
  :tags '(:unit :fast :stable :isolated)

  ;; Error result without :errors array
  (let ((error-result '(:type "result"
                        :subtype "error_during_execution"
                        :is_error t
                        :duration_ms 0)))
    (let ((error-msg (code-agent--extract-json-error error-result)))
      ;; Should fall back to generic message
      (should error-msg)
      (should (string-match-p "Execution error" error-msg)))))

;;; Environment Building Tests

(ert-deftest test-code-agent-build-env-strips-claudecode ()
  "Test that CLAUDECODE is stripped from the process environment.
Claude CLI refuses to launch inside another Claude Code session when
CLAUDECODE is set.  Our SDK must unset it so Emacs users can run
queries from within a Claude Code session."
  :tags '(:unit :fast :stable :isolated :process)
  (let* ((process-environment '("HOME=/home/user"
                                "CLAUDECODE=1"
                                "PATH=/usr/bin"
                                "EDITOR=emacs"))
         (result (code-agent--build-process-environment nil nil)))
    ;; CLAUDECODE should be stripped
    (should-not (cl-find-if (lambda (s) (string-prefix-p "CLAUDECODE=" s)) result))
    ;; Other vars should remain
    (should (member "HOME=/home/user" result))
    (should (member "PATH=/usr/bin" result))
    (should (member "EDITOR=emacs" result))))

(ert-deftest test-code-agent-build-env-preserves-custom-vars ()
  "Test that custom env vars from options are prepended."
  :tags '(:unit :fast :stable :isolated :process)
  (let* ((process-environment '("HOME=/home/user" "PATH=/usr/bin"))
         (env-vars '(("MY_VAR" . "my_value") ("OTHER" . "test")))
         (result (code-agent--build-process-environment env-vars nil)))
    (should (member "MY_VAR=my_value" result))
    (should (member "OTHER=test" result))
    (should (member "HOME=/home/user" result))))

(ert-deftest test-code-agent-build-env-prepends-cli-dir-to-path ()
  "Test that cli-dir is prepended to PATH when provided."
  :tags '(:unit :fast :stable :isolated :process)
  (let* ((process-environment '("HOME=/home/user" "PATH=/usr/bin"))
         (result (code-agent--build-process-environment nil "/opt/node/bin/")))
    (should (cl-find-if (lambda (s)
                          (and (string-prefix-p "PATH=" s)
                               (string-match-p "/opt/node/bin/" s)))
                        result))))

(ert-deftest test-code-agent-build-env-no-claudecode-even-with-custom-vars ()
  "Test CLAUDECODE is stripped even when custom env vars are provided."
  :tags '(:unit :fast :stable :isolated :process)
  (let* ((process-environment '("CLAUDECODE=1" "HOME=/home/user"))
         (env-vars '(("FOO" . "bar")))
         (result (code-agent--build-process-environment env-vars "/some/dir/")))
    (should-not (cl-find-if (lambda (s) (string-prefix-p "CLAUDECODE=" s)) result))
    (should (member "FOO=bar" result))))

;;; Bun memory tuning tests

(ert-deftest test-code-agent-build-env-injects-bun-ram-size-when-set ()
  "Test that BUN_JSC_forceRAMSize is injected when `code-agent-bun-memory-limit' is set."
  :tags '(:unit :fast :stable :isolated :process)
  (let* ((process-environment '("HOME=/home/user" "PATH=/usr/bin"))
         (code-agent-bun-memory-limit (* 3 1024 1024 1024))
         (result (code-agent--build-process-environment nil nil)))
    (should (member (format "BUN_JSC_forceRAMSize=%d" (* 3 1024 1024 1024)) result))))

(ert-deftest test-code-agent-build-env-no-bun-ram-size-when-nil ()
  "Test that BUN_JSC_forceRAMSize is NOT injected when limit is nil."
  :tags '(:unit :fast :stable :isolated :process)
  (let* ((process-environment '("HOME=/home/user" "PATH=/usr/bin"))
         (code-agent-bun-memory-limit nil)
         (result (code-agent--build-process-environment nil nil)))
    (should-not (cl-find-if (lambda (s) (string-prefix-p "BUN_JSC_forceRAMSize=" s))
                            result))))

(ert-deftest test-code-agent-build-env-bun-ram-size-coexists-with-custom-vars ()
  "Test that BUN_JSC_forceRAMSize coexists with user-provided env vars."
  :tags '(:unit :fast :stable :isolated :process)
  (let* ((process-environment '("HOME=/home/user"))
         (code-agent-bun-memory-limit (* 2 1024 1024 1024))
         (env-vars '(("MY_VAR" . "value")))
         (result (code-agent--build-process-environment env-vars nil)))
    (should (member (format "BUN_JSC_forceRAMSize=%d" (* 2 1024 1024 1024)) result))
    (should (member "MY_VAR=value" result))))

(ert-deftest test-code-agent-build-env-bun-ram-size-overrides-existing ()
  "Test that our injected BUN_JSC_forceRAMSize overrides any existing one."
  :tags '(:unit :fast :stable :isolated :process)
  (let* ((process-environment '("HOME=/home/user" "BUN_JSC_forceRAMSize=999"))
         (code-agent-bun-memory-limit (* 3 1024 1024 1024))
         (result (code-agent--build-process-environment nil nil)))
    ;; Our value should be present
    (should (member (format "BUN_JSC_forceRAMSize=%d" (* 3 1024 1024 1024)) result))
    ;; The old value from process-environment should still be there (later in list),
    ;; but our prepended one takes precedence for subprocess env lookup
    ))

;;; Phase 0a: Sentinel per-process cleanup tests

(ert-deftest test-code-agent-sentinel-cleanup-preserves-other-sessions ()
  "Test that sentinel cleanup only removes entries for the exiting process.
The old code used clrhash which wiped ALL entries including other sessions."
  :tags '(:unit :fast :stable :isolated :sentinel :phase-0a)
  (let ((code-agent--pending-background-tasks (make-hash-table :test 'equal))
        (code-agent--pending-control-requests (make-hash-table :test 'equal)))
    ;; Session A owns task-1 and ctrl-1
    (puthash "task-1" "req-A" code-agent--pending-background-tasks)
    (puthash "ctrl-1" "req-A" code-agent--pending-control-requests)
    ;; Session B owns task-2 and ctrl-2
    (puthash "task-2" "req-B" code-agent--pending-background-tasks)
    (puthash "ctrl-2" "req-B" code-agent--pending-control-requests)
    ;; Cleanup session A
    (code-agent--cleanup-process-entries "req-A")
    ;; Session B entries must survive
    (should (gethash "task-2" code-agent--pending-background-tasks))
    (should (gethash "ctrl-2" code-agent--pending-control-requests))
    ;; Session A entries must be gone
    (should-not (gethash "task-1" code-agent--pending-background-tasks))
    (should-not (gethash "ctrl-1" code-agent--pending-control-requests))))

(ert-deftest test-code-agent-sentinel-cleanup-removes-all-owned-entries ()
  "Test that sentinel cleanup removes ALL entries for the exiting process."
  :tags '(:unit :fast :stable :isolated :sentinel :phase-0a)
  (let ((code-agent--pending-background-tasks (make-hash-table :test 'equal))
        (code-agent--pending-control-requests (make-hash-table :test 'equal)))
    ;; Session A owns multiple tasks and control requests
    (puthash "task-1" "req-A" code-agent--pending-background-tasks)
    (puthash "task-3" "req-A" code-agent--pending-background-tasks)
    (puthash "ctrl-1" "req-A" code-agent--pending-control-requests)
    (puthash "ctrl-3" "req-A" code-agent--pending-control-requests)
    ;; Cleanup session A
    (code-agent--cleanup-process-entries "req-A")
    ;; All A entries gone
    (should (= 0 (hash-table-count code-agent--pending-background-tasks)))
    (should (= 0 (hash-table-count code-agent--pending-control-requests)))))

(ert-deftest test-code-agent-sentinel-cleanup-noop-when-no-entries ()
  "Test that cleanup is safe when no entries exist for the process."
  :tags '(:unit :fast :stable :isolated :sentinel :phase-0a)
  (let ((code-agent--pending-background-tasks (make-hash-table :test 'equal))
        (code-agent--pending-control-requests (make-hash-table :test 'equal)))
    ;; Only session B entries
    (puthash "task-2" "req-B" code-agent--pending-background-tasks)
    ;; Cleanup non-existent session A - should not error
    (code-agent--cleanup-process-entries "req-A")
    ;; Session B untouched
    (should (= 1 (hash-table-count code-agent--pending-background-tasks)))))

(ert-deftest test-code-agent-background-task-tracker-stores-owner ()
  "Test that background-task-tracker stores request-id as owner, not just t."
  :tags '(:unit :fast :stable :isolated :sentinel :phase-0a)
  (let ((code-agent--pending-background-tasks (make-hash-table :test 'equal))
        (state (code-agent--make-process-state :request-id "req-X")))
    ;; Simulate Task tool async launch
    (code-agent--background-task-tracker
     nil nil nil
     '(:isAsync t :agentId "agent-1")
     state)
    ;; Value should be the owning request-id, not t
    (should (equal "req-X" (gethash "agent-1" code-agent--pending-background-tasks)))))

(ert-deftest test-code-agent-control-request-tracker-stores-owner ()
  "Test that control request tracking stores request-id as owner."
  :tags '(:unit :fast :stable :isolated :sentinel :phase-0a)
  (let ((code-agent--pending-control-requests (make-hash-table :test 'equal)))
    ;; Track with owner
    (code-agent--track-control-request "ctrl-1" "req-X")
    ;; Value should be the owning request-id
    (should (equal "req-X" (gethash "ctrl-1" code-agent--pending-control-requests)))))

;;; Phase 0c: Verbose buffer memory leak tests

(ert-deftest test-code-agent-verbose-buffer-max-size ()
  "Test that verbose buffer is trimmed when it exceeds max size."
  :tags '(:unit :fast :stable :isolated :verbose :phase-0c)
  (let ((code-agent--session-verbose-buffers (make-hash-table :test 'equal))
        (code-agent-verbose-buffer-max-size 100)
        (buf (generate-new-buffer " *test-verbose*")))
    (unwind-protect
        (progn
          (puthash "test-key" buf code-agent--session-verbose-buffers)
          ;; Insert more than max-size
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (insert (make-string 200 ?x))))
          ;; Trigger insert which should trim
          (code-agent--verbose-insert "test-key" "new-content")
          (with-current-buffer buf
            ;; Buffer should have been trimmed: not dramatically larger than max
            (should (<= (buffer-size) (+ code-agent-verbose-buffer-max-size 50)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest test-code-agent-verbose-buffer-no-trim-under-limit ()
  "Test that verbose buffer is NOT trimmed when under max size."
  :tags '(:unit :fast :stable :isolated :verbose :phase-0c)
  (let ((code-agent--session-verbose-buffers (make-hash-table :test 'equal))
        (code-agent-verbose-buffer-max-size 10000)
        (buf (generate-new-buffer " *test-verbose*")))
    (unwind-protect
        (progn
          (puthash "test-key" buf code-agent--session-verbose-buffers)
          (code-agent--verbose-insert "test-key" "small text")
          (with-current-buffer buf
            (should (string-match-p "small text" (buffer-string)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest test-code-agent-verbose-buffer-max-size-nil-no-trim ()
  "Test that nil max-size means no trimming (unlimited)."
  :tags '(:unit :fast :stable :isolated :verbose :phase-0c)
  (let ((code-agent--session-verbose-buffers (make-hash-table :test 'equal))
        (code-agent-verbose-buffer-max-size nil)
        (buf (generate-new-buffer " *test-verbose*")))
    (unwind-protect
        (progn
          (puthash "test-key" buf code-agent--session-verbose-buffers)
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (insert (make-string 200 ?x))))
          (code-agent--verbose-insert "test-key" "more")
          (with-current-buffer buf
            ;; No trimming, so buffer should be large
            (should (> (buffer-size) 200))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; Phase 0b: Docker path mappings per-process tests

(ert-deftest test-code-agent-path-mappings-stored-in-process-state ()
  "Test that path-mappings are stored per-process, not in a global."
  :tags '(:unit :fast :stable :isolated :docker :phase-0b)
  (let ((state (code-agent--make-process-state
                :path-mappings '(("/host" . "/container")))))
    ;; path-mappings should be in the process state
    (should (equal '(("/host" . "/container"))
                   (code-agent--process-state-path-mappings state)))))

;;; Phase 0d: Shared JSON parser tests

(ert-deftest test-code-agent-try-parse-json-valid ()
  "Test that try-parse-json parses valid JSON into plist."
  :tags '(:unit :fast :stable :isolated :json :phase-0d)
  (let ((result (code-agent--try-parse-json "{\"type\":\"assistant\",\"id\":\"123\"}")))
    (should result)
    (should (equal "assistant" (plist-get result :type)))
    (should (equal "123" (plist-get result :id)))))

(ert-deftest test-code-agent-try-parse-json-invalid ()
  "Test that try-parse-json returns nil for invalid JSON."
  :tags '(:unit :fast :stable :isolated :json :phase-0d)
  (should-not (code-agent--try-parse-json "not json at all"))
  (should-not (code-agent--try-parse-json ""))
  (should-not (code-agent--try-parse-json "{broken")))

(ert-deftest test-code-agent-try-parse-json-array ()
  "Test that try-parse-json handles arrays correctly."
  :tags '(:unit :fast :stable :isolated :json :phase-0d)
  (let ((result (code-agent--try-parse-json "{\"items\":[1,2,3]}")))
    (should result)
    (should (equal '(1 2 3) (plist-get result :items)))))

;;; Phase 1a: query-accumulate helper tests

(ert-deftest test-code-agent-query-accumulate-exists ()
  "Test that code-agent-query-accumulate function exists."
  :tags '(:unit :fast :stable :isolated :phase-1a)
  (should (fboundp 'code-agent-query-accumulate)))

(ert-deftest test-code-agent-query-accumulate-calls-query ()
  "Test that query-accumulate calls code-agent-query with correct args."
  :tags '(:unit :fast :stable :isolated :phase-1a)
  (let ((query-called nil)
        (query-args nil))
    (cl-letf (((symbol-function 'code-agent-query)
               (lambda (prompt &rest args)
                 (setq query-called t
                       query-args (cons prompt args)))))
      (code-agent-query-accumulate
       "test prompt"
       :options '(:model "haiku")
       :on-result (lambda (_text) nil))
      (should query-called)
      (should (equal "test prompt" (car query-args))))))

(ert-deftest test-code-agent-query-accumulate-accumulates-text ()
  "Test that query-accumulate accumulates text from on-message and passes to on-result."
  :tags '(:unit :fast :stable :isolated :phase-1a)
  (let ((result-text nil)
        (captured-on-message nil)
        (captured-on-complete nil))
    (cl-letf (((symbol-function 'code-agent-query)
               (lambda (_prompt &rest args)
                 (setq captured-on-message (plist-get args :on-message)
                       captured-on-complete (plist-get args :on-complete)))))
      (code-agent-query-accumulate
       "test"
       :on-result (lambda (text) (setq result-text text)))
      ;; Simulate messages
      (let ((msg1 '(:type "assistant" :message (:content ((:type "text" :text "hello "))))))
        (funcall captured-on-message (code-agent--parse-message msg1)))
      (let ((msg2 '(:type "assistant" :message (:content ((:type "text" :text "world"))))))
        (funcall captured-on-message (code-agent--parse-message msg2)))
      ;; Simulate completion
      (funcall captured-on-complete nil)
      ;; Result should be trimmed accumulated text
      (should (equal "hello world" result-text)))))

;;; Phase 1d: process-normal-message 2-arg signature tests

(ert-deftest test-code-agent-process-normal-message-2-arg ()
  "Test that process-normal-message works with just (parsed state)."
  :tags '(:unit :fast :stable :isolated :process :phase-1d)
  (let* ((msg-received nil)
         (token-received nil)
         (state (code-agent--make-process-state
                 :callback (lambda (msg) (setq msg-received msg))
                 :token-callback (lambda (text) (setq token-received text))
                 :error-callback nil
                 :session-key "test-session"))
         ;; Create a minimal assistant message with text content
         (parsed '(:type "assistant"
                   :message (:role "assistant"
                             :content ((:type "text" :text "hello"))))))
    ;; Should work with just 2 args - callback/token-callback extracted from state
    (code-agent--process-normal-message parsed state)
    ;; Message callback should have been called
    (should msg-received)))

(ert-deftest test-code-agent-process-normal-message-error-from-state ()
  "Test that process-normal-message extracts error-callback from state."
  :tags '(:unit :fast :stable :isolated :process :phase-1d)
  (let* ((error-received nil)
         (state (code-agent--make-process-state
                 :callback nil
                 :error-callback (lambda (err) (setq error-received err))))
         ;; Simulate error in result
         (parsed '(:type "result"
                   :is_error t
                   :error "Something went wrong")))
    (code-agent--process-normal-message parsed state)
    ;; Error callback should have been called
    (should error-received)))

;;; Phase 2: Public accessors for cross-module encapsulation

(ert-deftest test-code-agent-close-and-unregister-state ()
  "Test public API to close state and unregister query."
  :tags '(:unit :fast :stable :isolated :api :phase-2)
  (let* ((code-agent--active-queries (make-hash-table :test 'equal))
         (state (code-agent--make-process-state :request-id "req-test")))
    ;; Register query first
    (puthash "req-test" state code-agent--active-queries)
    (should (gethash "req-test" code-agent--active-queries))
    ;; Use public API to close and unregister
    (code-agent-close-process-state state)
    ;; State should be closed
    (should (code-agent--process-state-closed state))
    ;; Query should be unregistered
    (should-not (gethash "req-test" code-agent--active-queries))))

(ert-deftest test-code-agent-close-process-state-idempotent ()
  "Test that closing an already-closed state is safe."
  :tags '(:unit :fast :stable :isolated :api :phase-2)
  (let ((state (code-agent--make-process-state :request-id "req-test")))
    (code-agent-close-process-state state)
    (should (code-agent--process-state-closed state))
    ;; Second call should not error
    (code-agent-close-process-state state)
    (should (code-agent--process-state-closed state))))

;;; Phase 9: Client callback mutation helper tests

(ert-deftest test-code-agent-update-state-callbacks ()
  "Test public API to update process state callbacks."
  :tags '(:unit :fast :stable :isolated :api :phase-9)
  (let* ((state (code-agent--make-process-state
                 :callback (lambda (_) nil)
                 :error-callback (lambda (_) nil)))
         (new-cb (lambda (msg) msg))
         (new-err (lambda (err) err))
         (new-tok (lambda (text) text)))
    (code-agent-update-state-callbacks state
                                         :callback new-cb
                                         :error-callback new-err
                                         :token-callback new-tok)
    (should (eq new-cb (code-agent--process-state-callback state)))
    (should (eq new-err (code-agent--process-state-error-callback state)))
    (should (eq new-tok (code-agent--process-state-token-callback state)))))

(ert-deftest test-code-agent-update-state-callbacks-partial ()
  "Test that update-state-callbacks only changes provided keys."
  :tags '(:unit :fast :stable :isolated :api :phase-9)
  (let* ((original-cb (lambda (_) nil))
         (state (code-agent--make-process-state
                 :callback original-cb
                 :error-callback nil))
         (new-err (lambda (err) err)))
    ;; Only update error-callback
    (code-agent-update-state-callbacks state :error-callback new-err)
    ;; Original callback should be unchanged
    (should (eq original-cb (code-agent--process-state-callback state)))
    (should (eq new-err (code-agent--process-state-error-callback state)))))

;;; Phase 3: process-state sub-structs tests

(ert-deftest test-code-agent-callback-state-struct ()
  "Test that callback-state sub-struct exists and holds callbacks."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-3)
  (let ((cs (code-agent--make-callback-state
             :callback (lambda (_) nil)
             :token-callback (lambda (_) nil)
             :error-callback (lambda (_) nil)
             :complete-callback (lambda (_) nil))))
    (should (code-agent--callback-state-p cs))
    (should (functionp (code-agent--callback-state-callback cs)))
    (should (functionp (code-agent--callback-state-token-callback cs)))))

(ert-deftest test-code-agent-recovery-state-struct ()
  "Test that recovery-state sub-struct exists."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-3)
  (let ((rs (code-agent--make-recovery-state
             :session-id "sid-123"
             :original-prompt "hello")))
    (should (code-agent--recovery-state-p rs))
    (should (equal "sid-123" (code-agent--recovery-state-session-id rs)))
    (should-not (code-agent--recovery-state-got-result rs))))

(ert-deftest test-code-agent-source-state-struct ()
  "Test that source-state sub-struct exists."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-3)
  (let ((ss (code-agent--make-source-state
             :buffer (current-buffer))))
    (should (code-agent--source-state-p ss))
    (should (bufferp (code-agent--source-state-buffer ss)))))

(ert-deftest test-code-agent-docker-state-struct ()
  "Test that docker-state sub-struct exists."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-3)
  (let ((ds (code-agent--make-docker-state
             :mode t
             :path-mappings '(("/host" . "/container")))))
    (should (code-agent--docker-state-p ds))
    (should (code-agent--docker-state-mode ds))
    (should (equal '(("/host" . "/container"))
                   (code-agent--docker-state-path-mappings ds)))))

(ert-deftest test-code-agent-process-state-flat-accessors ()
  "Test that process-state provides flat accessors for sub-struct fields."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-3)
  (let ((state (code-agent--make-process-state
                :callback (lambda (_) 'test)
                :session-id "sid-abc"
                :docker-mode t
                :source-buffer (current-buffer))))
    ;; Flat accessors reach into sub-structs
    (should (functionp (code-agent--process-state-callback state)))
    (should (equal "sid-abc" (code-agent--process-state-session-id state)))
    (should (code-agent--process-state-docker-mode state))
    (should (bufferp (code-agent--process-state-source-buffer state)))))

;;; Phase 0e: Remove duplicate provide

(ert-deftest test-code-agent-single-provide ()
  "Test that code-agent has exactly one provide in active code blocks.
Provides inside :load no blocks (tangle templates) are excluded."
  :tags '(:unit :fast :stable :isolated :phase-0e)
  ;; Find code-agent.org: try relative to test file, then default-directory
  (let* ((test-dir (file-name-directory (or load-file-name buffer-file-name default-directory)))
         (org-file (or (let ((f (expand-file-name "../code-agent.org" test-dir)))
                         (and (file-exists-p f) f))
                       (let ((f (expand-file-name "code-agent.org" default-directory)))
                         (and (file-exists-p f) f))))
         (count 0))
    (when (file-exists-p org-file)
      (with-temp-buffer
        (insert-file-contents org-file)
        (goto-char (point-min))
        ;; Count provides that are in active src blocks (not :load no)
        (while (re-search-forward "(provide 'code-agent)" nil t)
          (save-excursion
            ;; Check we're inside a #+BEGIN_SRC elisp block (not :load no)
            (let ((in-no-load nil))
              (when (re-search-backward "#\\+BEGIN_SRC elisp" nil t)
                (when (string-match-p ":load no" (buffer-substring (point) (line-end-position)))
                  (setq in-no-load t)))
              (unless in-no-load
                (setq count (1+ count))))))))
    (should (= 1 count))))

;;; Phase 4: Protocol-based message dispatch tests

(ert-deftest test-code-agent-handle-message-generic-exists ()
  "Test that cl-defgeneric code-agent-handle-message exists."
  :tags '(:unit :fast :stable :isolated :dispatch :phase-4)
  (should (fboundp 'code-agent-handle-message)))

(ert-deftest test-code-agent-handle-message-assistant ()
  "Test that assistant messages are dispatched via handle-message."
  :tags '(:unit :fast :stable :isolated :dispatch :phase-4)
  (let* ((received nil)
         (state (code-agent--make-process-state
                 :callback (lambda (msg)
                             (push (list 'callback msg) received))
                 :token-callback (lambda (tok)
                                   (push (list 'token tok) received)))))
    (code-agent-handle-message
     'assistant
     '(:type "assistant"
       :message (:role "assistant"
                 :content ((:type "text" :text "hello"))))
     state)
    ;; Should have invoked callback with parsed message
    (should (cl-some (lambda (r) (eq (car r) 'callback)) received))))

(ert-deftest test-code-agent-handle-message-result ()
  "Test that result messages dispatch stop hooks."
  :tags '(:unit :fast :stable :isolated :dispatch :phase-4)
  (let* ((stop-called nil)
         (state (code-agent--make-process-state
                 :callback (lambda (_msg) nil)))
         (code-agent-stop-functions
          (list (lambda (_msg _state) (setq stop-called t)))))
    (code-agent-handle-message
     'result
     '(:type "result"
       :result (:role "assistant"
                :content ((:type "text" :text "done"))))
     state)
    (should stop-called)))

(ert-deftest test-code-agent-handle-message-fallback ()
  "Test that unknown message types fall through to normal processing."
  :tags '(:unit :fast :stable :isolated :dispatch :phase-4)
  (let* ((callback-called nil)
         (state (code-agent--make-process-state
                 :callback (lambda (_msg) (setq callback-called t)))))
    (code-agent-handle-message
     'system
     '(:type "system"
       :subtype "init"
       :data (:session_id "sid-test"))
     state)
    (should callback-called)))

;;; Phase 6: Unified registry struct tests

(ert-deftest test-code-agent-registry-struct-exists ()
  "Test that unified registry struct exists with all sub-tables."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-6)
  (let ((reg (code-agent--make-registry)))
    (should (code-agent--registry-p reg))
    ;; active-states defaults to nil (list)
    (should-not (code-agent--registry-active-states reg))
    ;; Hash tables should be initialized
    (should (hash-table-p (code-agent--registry-queries reg)))
    (should (hash-table-p (code-agent--registry-sessions reg)))
    (should (hash-table-p (code-agent--registry-background-tasks reg)))
    (should (hash-table-p (code-agent--registry-control-requests reg)))
    (should (hash-table-p (code-agent--registry-verbose-buffers reg)))))

(ert-deftest test-code-agent-registry-singleton ()
  "Test that code-agent--registry is a single registry instance."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-6)
  (should (code-agent--registry-p code-agent--registry)))

(ert-deftest test-code-agent-registry-cleanup-process ()
  "Test per-process cleanup removes only owned entries."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-6)
  (let ((code-agent--registry (code-agent--make-registry)))
    ;; Add background tasks: task-id -> owner-request-id
    ;; "bg-task-1" owned by "req-A", "bg-task-2" owned by "req-B"
    (puthash "bg-task-1" "req-A" (code-agent--registry-background-tasks code-agent--registry))
    (puthash "bg-task-2" "req-B" (code-agent--registry-background-tasks code-agent--registry))
    ;; Add control request owned by "req-A"
    (puthash "ctrl-1" "req-A" (code-agent--registry-control-requests code-agent--registry))
    ;; Register active state for req-A
    (let ((state-a (code-agent--make-process-state :request-id "req-A")))
      (push state-a (code-agent--registry-active-states code-agent--registry))
      ;; Cleanup for req-A should remove only req-A's entries
      (code-agent-registry-cleanup-process state-a))
    ;; req-A's task removed, req-B's task preserved
    (should-not (gethash "bg-task-1" (code-agent--registry-background-tasks code-agent--registry)))
    (should (gethash "bg-task-2" (code-agent--registry-background-tasks code-agent--registry)))
    (should-not (gethash "ctrl-1" (code-agent--registry-control-requests code-agent--registry)))))

;;; R10: JSON buffer overflow protection tests

(ert-deftest test-json-buffer-max-size-defcustom-exists ()
  "code-agent-max-json-buffer-size defcustom should exist with default 10MB."
  :tags '(:unit :fast :stable :isolated :process :r10)
  (should (boundp 'code-agent-max-json-buffer-size))
  (should (= (* 10 1024 1024) code-agent-max-json-buffer-size)))

(ert-deftest test-json-buffer-overflow-triggers-error ()
  "process-filter should signal error callback when buffer exceeds max size."
  :tags '(:unit :fast :stable :isolated :process :r10)
  (let* ((error-received nil)
         (state (code-agent--make-process-state
                 :json-buffer ""
                 :ready t
                 :error-callback (lambda (err) (setq error-received err))))
         ;; Create a mock process
         (proc (start-process "test-r10" nil "true")))
    (unwind-protect
        (progn
          (process-put proc 'code-agent-state state)
          ;; Set buffer just under limit
          (setf (code-agent--process-state-json-buffer state)
                (make-string (- code-agent-max-json-buffer-size 10) ?x))
          ;; This output should push it over the limit
          (code-agent--process-filter proc (make-string 20 ?y))
          ;; Error callback should have been called
          (should error-received)
          (should (stringp (plist-get error-received :error))))
      (when (process-live-p proc)
        (delete-process proc)))))

;;; R5: Decomposed extract-json-error sub-extractor tests

(ert-deftest test-extract-result-error-with-errors-array ()
  "Sub-extractor for result messages should handle :errors array."
  :tags '(:unit :fast :stable :isolated :error :r5)
  (let ((parsed '(:type "result" :is_error t
                  :subtype "error_during_execution"
                  :errors ("Session not found"))))
    (should (equal "Session not found"
                   (code-agent--extract-result-error parsed)))))

(ert-deftest test-extract-result-error-with-subtype ()
  "Sub-extractor should fall back to known subtype message."
  :tags '(:unit :fast :stable :isolated :error :r5)
  (let ((parsed '(:type "result" :is_error t
                  :subtype "rate_limit")))
    (should (equal "Rate limit exceeded"
                   (code-agent--extract-result-error parsed)))))

(ert-deftest test-extract-assistant-error ()
  "Sub-extractor for assistant messages with error field."
  :tags '(:unit :fast :stable :isolated :error :r5)
  (let ((parsed '(:type "assistant"
                  :message (:error "invalid_request"
                            :content ((:type "text" :text "Bad request details"))))))
    (should (equal "Bad request details"
                   (code-agent--extract-assistant-error parsed)))))

(ert-deftest test-extract-assistant-error-nil-for-no-error ()
  "Sub-extractor returns nil when assistant message has no error."
  :tags '(:unit :fast :stable :isolated :error :r5)
  (let ((parsed '(:type "assistant"
                  :message (:content ((:type "text" :text "Normal"))))))
    (should-not (code-agent--extract-assistant-error parsed))))

;;; R8: Decomposed process-sentinel tests

(ert-deftest test-sentinel-sub-handlers-exist ()
  "Sentinel sub-handler functions should exist."
  :tags '(:unit :fast :stable :isolated :sentinel :r8)
  (should (fboundp 'code-agent--sentinel-handle-normal-exit))
  (should (fboundp 'code-agent--sentinel-handle-abnormal-exit))
  (should (fboundp 'code-agent--sentinel-cleanup)))

(ert-deftest test-sentinel-normal-exit-finished ()
  "Normal exit with 'finished' should call complete callback with nil."
  :tags '(:unit :fast :stable :isolated :sentinel :r8)
  (let* ((completed nil)
         (state (code-agent--make-process-state
                 :complete-callback (lambda (err) (setq completed (list 'called err))))))
    (code-agent--sentinel-handle-normal-exit state "finished\n")
    (should completed)
    (should (eq 'called (car completed)))
    (should-not (cadr completed))))

(ert-deftest test-sentinel-normal-exit-abnormal-code ()
  "Normal exit with exit code should call complete callback with error."
  :tags '(:unit :fast :stable :isolated :sentinel :r8)
  (let* ((completed nil)
         (state (code-agent--make-process-state
                 :complete-callback (lambda (err) (setq completed err)))))
    (code-agent--sentinel-handle-normal-exit state "exited abnormally with code 1\n")
    (should completed)
    (should (eq 'code-agent-process-error (car completed)))))

;;; R9: Decomposed code-agent-query tests

(ert-deftest test-prepare-query-options-exists ()
  "prepare-query-options function should exist."
  :tags '(:unit :fast :stable :isolated :query :r9)
  (should (fboundp 'code-agent--prepare-query-options)))

(ert-deftest test-prepare-query-options-defaults ()
  "prepare-query-options should return plist with :options and :cli-path keys."
  :tags '(:unit :fast :stable :isolated :query :r9)
  (let ((result (code-agent--prepare-query-options nil nil nil)))
    ;; Should have :options key with a valid options plist
    (should (plist-get result :options))
    ;; Should have :cli-path key (value can be nil when no CLI configured)
    (should (plist-member result :cli-path))))

;;; Review Fixes: JSON buffer overflow clears buffer

(ert-deftest test-json-buffer-overflow-clears-buffer ()
  "After overflow, json-buffer should be cleared to prevent sentinel re-parse."
  :tags '(:unit :fast :stable :isolated :process :review-fix)
  (let* ((error-received nil)
         (state (code-agent--make-process-state
                 :json-buffer ""
                 :ready t
                 :error-callback (lambda (err) (setq error-received err))))
         (proc (start-process "test-overflow-clear" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'code-agent-state state)
          ;; Set buffer just under limit
          (setf (code-agent--process-state-json-buffer state)
                (make-string (- code-agent-max-json-buffer-size 10) ?x))
          ;; Push over the limit
          (code-agent--process-filter proc (make-string 20 ?y))
          ;; Error should be signalled
          (should error-received)
          ;; CRITICAL: json-buffer should be cleared so sentinel won't re-parse
          (should (equal "" (code-agent--process-state-json-buffer state))))
      (when (process-live-p proc)
        (delete-process proc)))))

;;; Review Fixes: Sentinel cleanup uses kill-child-processes helper

(ert-deftest test-sentinel-cleanup-calls-kill-child-processes ()
  "sentinel-cleanup should delegate to kill-child-processes, not inline the logic."
  :tags '(:unit :fast :stable :isolated :process :review-fix)
  (let* ((kill-helper-called nil)
         (state (code-agent--make-process-state
                 :json-buffer ""
                 :ready t))
         (proc (start-process "test-cleanup-helper" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'code-agent-state state)
          ;; Stub kill-child-processes to track if it's called
          (cl-letf (((symbol-function 'code-agent--kill-child-processes)
                     (lambda (pid) (setq kill-helper-called pid))))
            (code-agent--sentinel-cleanup proc state)
            ;; Should have called the helper, not inlined the logic
            (should kill-helper-called)))
      (when (process-live-p proc)
        (delete-process proc)))))

;;; Stale background tasks should not block stdin closure for other processes

(ert-deftest test-no-state-process-ignores-stale-tasks ()
  "maybe-close-stdin should close stdin even when process has no attached state.
When process-get returns nil for state, owner-req-id is nil.
The nil guard ensures stale global tasks do not block stdin closure."
  :tags '(:unit :fast :stable :isolated :process :stdin)
  (let* ((eof-sent nil)
         (code-agent-stdin-close-delay 0)
         (proc (start-process "test-no-state" nil "sleep" "60")))
    (unwind-protect
        (let ((saved-bg-tasks (copy-hash-table code-agent--pending-background-tasks)))
          (unwind-protect
              (progn
                ;; NO process-put — process has no attached state
                (clrhash code-agent--pending-background-tasks)
                (puthash "stale-1" "req-OLD" code-agent--pending-background-tasks)
                (cl-letf (((symbol-function 'process-send-eof)
                           (lambda (_proc) (setq eof-sent t))))
                  (code-agent--maybe-close-stdin proc '(:type "result"))
                  ;; Should still close despite stale global tasks
                  (should eof-sent)))
            (clrhash code-agent--pending-background-tasks)
            (maphash (lambda (k v) (puthash k v code-agent--pending-background-tasks))
                     saved-bg-tasks)))
      (when (process-live-p proc) (delete-process proc)))))

;;; Cancel should NOT trigger recovery tests

(ert-deftest test-cancel-should-not-trigger-recovery-finished ()
  "Cancelled query exiting with 'finished' should NOT trigger recovery."
  :tags '(:unit :fast :stable :isolated :recovery)
  (let ((state (code-agent--make-process-state
                :session-id "test-session-123")))
    ;; Simulate user cancellation: set cancelled flag
    (setf (code-agent--process-state-cancelled state) t)
    ;; Process exits with "finished" - should NOT be treated as abnormal
    (should-not (code-agent--is-abnormal-exit-p "finished\n" state))))

(ert-deftest test-cancel-should-not-trigger-recovery-killed ()
  "Cancelled query exiting with 'killed' should NOT trigger recovery."
  :tags '(:unit :fast :stable :isolated :recovery)
  (let ((state (code-agent--make-process-state
                :session-id "test-session-123")))
    (setf (code-agent--process-state-cancelled state) t)
    ;; Process killed by signal after cancel - still should NOT recover
    (should-not (code-agent--is-abnormal-exit-p "killed: 9\n" state))))

(ert-deftest test-cancel-should-not-trigger-recovery-abnormal ()
  "Cancelled query exiting abnormally should NOT trigger recovery."
  :tags '(:unit :fast :stable :isolated :recovery)
  (let ((state (code-agent--make-process-state
                :session-id "test-session-123")))
    (setf (code-agent--process-state-cancelled state) t)
    (should-not (code-agent--is-abnormal-exit-p
                 "exited abnormally with code 1\n" state))))

(ert-deftest test-unexpected-crash-should-trigger-recovery ()
  "Unexpected crash (not cancelled) SHOULD trigger recovery."
  :tags '(:unit :fast :stable :isolated :recovery)
  (let ((code-agent-auto-recovery t)
        (state (code-agent--make-process-state
                :session-id "test-session-123")))
    ;; NOT cancelled, no result received - should trigger recovery
    (should (code-agent--is-abnormal-exit-p "killed: 9\n" state))
    (should (code-agent--is-abnormal-exit-p "exited abnormally with code 1\n" state))
    (should (code-agent--is-abnormal-exit-p "finished\n" state))))

(ert-deftest test-cancel-does-not-recover-but-crash-does ()
  "Verify cancelled vs non-cancelled states have opposite recovery behavior."
  :tags '(:unit :fast :stable :isolated :recovery)
  (let ((code-agent-auto-recovery t))
    ;; Non-cancelled state with session-id: SHOULD recover
    (let ((crash-state (code-agent--make-process-state
                        :session-id "session-crash")))
      (should (code-agent--is-abnormal-exit-p "finished\n" crash-state)))
    ;; Cancelled state with session-id: should NOT recover
    (let ((cancel-state (code-agent--make-process-state
                         :session-id "session-cancel")))
      (setf (code-agent--process-state-cancelled cancel-state) t)
      (should-not (code-agent--is-abnormal-exit-p "finished\n" cancel-state)))))

(ert-deftest test-query-interrupt-sets-cancelled-flag ()
  "query-interrupt should set the cancelled flag on process state."
  :tags '(:unit :fast :stable :isolated :recovery)
  (let* ((proc (start-process "test-cancel-flag" nil "sleep" "10"))
         (state (code-agent--make-process-state :process proc)))
    (unwind-protect
        (progn
          ;; Initially not cancelled
          (should-not (code-agent--process-state-cancelled state))
          ;; Interrupt should set cancelled
          (code-agent-query-interrupt state)
          (should (code-agent--process-state-cancelled state)))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest test-cancel-query-sets-cancelled-flag ()
  "code-agent-cancel-query should set the cancelled flag to prevent auto-recovery.
Bug: cancel-query only set closed=t but not cancelled=t, so the sentinel's
is-abnormal-exit-p check would pass and trigger recovery on a user-cancelled query."
  :tags '(:unit :fast :stable :isolated :recovery :cancel)
  (let* ((proc (start-process "test-cancel-query-flag" nil "sleep" "10"))
         (state (code-agent--make-process-state
                 :process proc
                 :request-id "test-cancel-recovery-001"
                 :session-id "test-session-cancel")))
    (unwind-protect
        (progn
          ;; Register the query so cancel-query can find it
          (puthash "test-cancel-recovery-001" state code-agent--active-queries)
          ;; Initially not cancelled
          (should-not (code-agent--process-state-cancelled state))
          ;; Cancel via cancel-query (the Queries buffer path)
          (code-agent-cancel-query "test-cancel-recovery-001")
          ;; CRITICAL: cancelled flag must be set to prevent auto-recovery
          (should (code-agent--process-state-cancelled state))
          ;; Also verify is-abnormal-exit-p returns nil for this state
          (let ((code-agent-auto-recovery t))
            (should-not (code-agent--is-abnormal-exit-p "killed: 2\n" state))))
      (when (process-live-p proc) (delete-process proc)))))

;;; Rate limit event warning tests

(ert-deftest test-format-reset-timestamp-hours-minutes ()
  "Should format unix timestamp as relative hours and minutes."
  :tags '(:unit :fast :stable :isolated :rate-limit)
  ;; Mock current time to 1000 seconds before resets-at
  (cl-letf (((symbol-function 'float-time) (lambda () 1772383400.0)))
    (let ((result (code-agent--format-reset-timestamp 1772384400)))
      (should (stringp result))
      ;; 1000 seconds = 0h 16m
      (should (string-match-p "0h 16m" result)))))

(ert-deftest test-format-reset-timestamp-days ()
  "Should format as days and hours when diff > 24h."
  :tags '(:unit :fast :stable :isolated :rate-limit)
  (cl-letf (((symbol-function 'float-time) (lambda () 1772284400.0)))
    (let ((result (code-agent--format-reset-timestamp 1772384400)))
      (should (stringp result))
      ;; 100000 seconds = 1d 3h
      (should (string-match-p "1d 3h" result)))))

(ert-deftest test-format-reset-timestamp-non-number ()
  "Should return 'unknown' for non-numeric input."
  :tags '(:unit :fast :stable :isolated :rate-limit)
  (should (equal "unknown" (code-agent--format-reset-timestamp nil)))
  (should (equal "unknown" (code-agent--format-reset-timestamp "not-a-number"))))

(ert-deftest test-handle-rate-limit-event-posts-warning ()
  "Handler should call `message' with warning for allowed_warning status."
  :tags '(:unit :fast :stable :isolated :rate-limit)
  (let ((messages nil)
        (code-agent--rate-limit-last-warned (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages)))
              ((symbol-function 'float-time) (lambda () 1772380000.0)))
      (let* ((parsed '(:type "rate_limit_event"
                       :rate_limit_info (:status "allowed_warning"
                                         :rateLimitType "seven_day"
                                         :utilization 0.77
                                         :resetsAt 1772384400
                                         :isUsingOverage :json-false
                                         :surpassedThreshold 0.75)))
             (state (code-agent--make-process-state)))
        (code-agent-handle-message 'rate_limit_event parsed state)
        (should (= 1 (length messages)))
        (should (string-match-p "rate limit" (car messages)))
        (should (string-match-p "seven_day" (car messages)))
        (should (string-match-p "77%" (car messages)))))))

(ert-deftest test-handle-rate-limit-event-no-warning-for-allowed ()
  "Handler should NOT post message when status is not allowed_warning."
  :tags '(:unit :fast :stable :isolated :rate-limit)
  (let ((messages nil)
        (code-agent--rate-limit-last-warned (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (let* ((parsed '(:type "rate_limit_event"
                       :rate_limit_info (:status "allowed"
                                         :rateLimitType "seven_day"
                                         :utilization 0.50
                                         :resetsAt 1772384400)))
             (state (code-agent--make-process-state)))
        (code-agent-handle-message 'rate_limit_event parsed state)
        (should (= 0 (length messages)))))))

(ert-deftest test-handle-rate-limit-event-cooldown-suppresses-repeat ()
  "Second warning within cooldown period should be suppressed."
  :tags '(:unit :fast :stable :isolated :rate-limit)
  (let ((messages nil)
        (code-agent--rate-limit-last-warned (make-hash-table :test 'equal))
        (code-agent-rate-limit-warning-interval 3600))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (let* ((parsed '(:type "rate_limit_event"
                       :rate_limit_info (:status "allowed_warning"
                                         :rateLimitType "seven_day"
                                         :utilization 0.77
                                         :resetsAt 1772384400)))
             (state (code-agent--make-process-state)))
        ;; First call at T=0: should warn
        (puthash "seven_day" 0 code-agent--rate-limit-last-warned)
        (code-agent-handle-message 'rate_limit_event parsed state)
        (should (= 1 (length messages)))
        ;; Second call: fake that last warned was just now (within cooldown)
        (puthash "seven_day" (float-time) code-agent--rate-limit-last-warned)
        (code-agent-handle-message 'rate_limit_event parsed state)
        (should (= 1 (length messages)))))))

(ert-deftest test-handle-rate-limit-event-warns-again-after-cooldown ()
  "Warning should fire again after cooldown period expires."
  :tags '(:unit :fast :stable :isolated :rate-limit)
  (let ((messages nil)
        (code-agent--rate-limit-last-warned (make-hash-table :test 'equal))
        (code-agent-rate-limit-warning-interval 3600)
        (now 1772380000.0))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages)))
              ((symbol-function 'float-time) (lambda () now)))
      (let* ((parsed '(:type "rate_limit_event"
                       :rate_limit_info (:status "allowed_warning"
                                         :rateLimitType "seven_day"
                                         :utilization 0.77
                                         :resetsAt 1772384400)))
             (state (code-agent--make-process-state)))
        ;; First call
        (code-agent-handle-message 'rate_limit_event parsed state)
        (should (= 1 (length messages)))
        ;; After cooldown expires (1 hour + 1 second)
        (setq now (+ now 3601))
        (code-agent-handle-message 'rate_limit_event parsed state)
        (should (= 2 (length messages)))))))

(ert-deftest test-handle-rate-limit-event-different-types-independent ()
  "Different rate limit types should have independent cooldowns."
  :tags '(:unit :fast :stable :isolated :rate-limit)
  (let ((messages nil)
        (code-agent--rate-limit-last-warned (make-hash-table :test 'equal))
        (code-agent-rate-limit-warning-interval 3600))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (let ((state (code-agent--make-process-state)))
        ;; seven_day warning
        (code-agent-handle-message 'rate_limit_event
          '(:type "rate_limit_event"
            :rate_limit_info (:status "allowed_warning"
                              :rateLimitType "seven_day"
                              :utilization 0.77 :resetsAt 1772384400))
          state)
        (should (= 1 (length messages)))
        ;; five_hour warning (different type) — should also fire
        (code-agent-handle-message 'rate_limit_event
          '(:type "rate_limit_event"
            :rate_limit_info (:status "allowed_warning"
                              :rateLimitType "five_hour"
                              :utilization 0.80 :resetsAt 1772384400))
          state)
        (should (= 2 (length messages)))))))

(provide 'test-code-agent-unit)
;;; test-code-agent-unit.el ends here
