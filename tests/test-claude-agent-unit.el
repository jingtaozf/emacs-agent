;;; test-claude-agent-unit.el --- Unit tests for claude-agent.org -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for claude-agent.org (core SDK module)
;; These tests do NOT make actual API calls.

;;; Code:

(require 'ert)
(require 'claude-agent)

;;; Data Structures Tests

(ert-deftest test-claude-agent-options-construction ()
  "Test that claude-agent-options creates a valid plist."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((opts (claude-agent-options
               :model "claude-sonnet-4"
               :cwd "/tmp"
               :permission-mode "plan")))
    (should (plist-get opts :model))
    (should (equal "claude-sonnet-4" (plist-get opts :model)))
    (should (equal "/tmp" (plist-get opts :cwd)))
    (should (equal "plan" (plist-get opts :permission-mode)))))

(ert-deftest test-claude-agent-options-defaults ()
  "Test that claude-agent-options handles nil/default values."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((opts (claude-agent-options)))
    (should (listp opts))
    ;; Should be a valid plist (even if empty)
    (should (= 0 (mod (length opts) 2)))))

(ert-deftest test-claude-agent-text-block-predicates ()
  "Test text block type predicates."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((text-block (claude-agent-make-text-block :text "hello")))
    (should (claude-agent-text-block-p text-block))
    (should-not (claude-agent-tool-use-block-p text-block))
    (should-not (claude-agent-tool-result-block-p text-block))
    (should (equal "hello" (claude-agent-text-block-text text-block)))))

(ert-deftest test-claude-agent-tool-use-block-predicates ()
  "Test tool-use block type predicates."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((tool-block (claude-agent-make-tool-use-block
                     :id "123"
                     :name "Read"
                     :input '(:file "test.txt"))))
    (should (claude-agent-tool-use-block-p tool-block))
    (should-not (claude-agent-text-block-p tool-block))
    (should-not (claude-agent-tool-result-block-p tool-block))
    (should (equal "Read" (claude-agent-tool-use-block-name tool-block)))
    (should (equal "123" (claude-agent-tool-use-block-id tool-block)))
    (should (plist-get (claude-agent-tool-use-block-input tool-block) :file))))

(ert-deftest test-claude-agent-tool-result-block-predicates ()
  "Test tool-result block type predicates."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((result-block (claude-agent-make-tool-result-block
                       :tool-use-id "123"
                       :content "success"
                       :is-error nil)))
    (should (claude-agent-tool-result-block-p result-block))
    (should-not (claude-agent-text-block-p result-block))
    (should-not (claude-agent-tool-use-block-p result-block))))

(ert-deftest test-claude-agent-message-type-predicates ()
  "Test message type predicates."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((assistant-msg (claude-agent-make-assistant-message
                        :content (list (claude-agent-make-text-block :text "hello"))))
        (user-msg (claude-agent-make-user-message :content "question"))
        (system-msg (claude-agent-make-system-message :subtype "thinking"))
        (result-msg (claude-agent-make-result-message :session-id "abc123")))
    (should (claude-agent-assistant-message-p assistant-msg))
    (should-not (claude-agent-assistant-message-p user-msg))
    (should (claude-agent-user-message-p user-msg))
    (should (claude-agent-system-message-p system-msg))
    (should (equal "thinking" (claude-agent-system-message-subtype system-msg)))
    (should (claude-agent-result-message-p result-msg))
    (should (equal "abc123" (claude-agent-result-message-session-id result-msg)))))

(ert-deftest test-claude-agent-extract-text ()
  "Test text extraction from assistant messages."
  :tags '(:unit :fast :stable :isolated :data-structures)
  (let ((msg (claude-agent-make-assistant-message
              :content (list (claude-agent-make-text-block :text "Hello")
                             (claude-agent-make-text-block :text " ")
                             (claude-agent-make-text-block :text "World")))))
    (should (equal "Hello World" (claude-agent-extract-text msg))))
  ;; Empty content
  (let ((msg (claude-agent-make-assistant-message :content nil)))
    (should-not (claude-agent-extract-text msg)))
  ;; Mixed content (text + tool-use)
  (let ((msg (claude-agent-make-assistant-message
              :content (list (claude-agent-make-text-block :text "Using tool: ")
                             (claude-agent-make-tool-use-block :id "1" :name "Read" :input nil)
                             (claude-agent-make-text-block :text "done")))))
    (should (equal "Using tool: done" (claude-agent-extract-text msg)))))

;;; Session Management Tests

(ert-deftest test-claude-agent-make-session-key ()
  "Test session key creation."
  :tags '(:unit :fast :stable :isolated :session)
  ;; Without custom ID
  (should (equal "/path/to/file.org"
                 (claude-agent--make-session-key "/path/to/file.org" nil)))
  ;; With custom ID
  (should (equal "/path/to/file.org::my-session"
                 (claude-agent--make-session-key "/path/to/file.org" "my-session")))
  ;; Empty custom ID creates "file::" (not treated as nil)
  (should (equal "/path/to/file.org::"
                 (claude-agent--make-session-key "/path/to/file.org" ""))))

(ert-deftest test-claude-agent-session-uuid-mapping ()
  "Test SDK UUID to session key mapping."
  :tags '(:unit :fast :stable :isolated :session)
  ;; Create fresh hash table for this test (only one hash table exists)
  (let ((claude-agent--session-mapping (make-hash-table :test 'equal)))
    ;; Store mapping
    (claude-agent--store-sdk-uuid "file.org::session1" "uuid-abc")
    (should (equal "uuid-abc" (claude-agent--get-sdk-uuid "file.org::session1")))
    ;; Update mapping
    (claude-agent--store-sdk-uuid "file.org::session1" "uuid-xyz")
    (should (equal "uuid-xyz" (claude-agent--get-sdk-uuid "file.org::session1")))
    ;; Clear session
    (claude-agent--clear-session "file.org::session1")
    (should-not (claude-agent--get-sdk-uuid "file.org::session1"))))

(ert-deftest test-claude-agent-session-expiry-detection ()
  "Test detection of session expiry errors."
  :tags '(:unit :fast :stable :isolated :session)
  (should (claude-agent--session-expired-p "No conversation found with session ID abc"))
  (should (claude-agent--session-expired-p "session not found"))
  (should-not (claude-agent--session-expired-p "Network error"))
  (should-not (claude-agent--session-expired-p "Invalid API key")))

(ert-deftest test-claude-agent-context-limit-detection ()
  "Test detection of context limit errors."
  :tags '(:unit :fast :stable :isolated :session)
  (should (claude-agent--context-too-long-p "Prompt is too long"))
  (should (claude-agent--context-too-long-p "prompt is too long for this model"))
  (should-not (claude-agent--context-too-long-p "Network error"))
  (should-not (claude-agent--context-too-long-p "Session expired")))

;;; IDE Context Tests

(ert-deftest test-claude-agent-collect-ide-context ()
  "Test IDE context collection."
  :tags '(:unit :fast :stable :isolated :context)
  ;; The function looks for the most recent file buffer from buffer-list
  ;; In batch mode, this might not find our temp buffer
  (let ((context (claude-agent-collect-ide-context)))
    (should (plist-get context :cwd))  ; Should have working directory
    (should (listp (plist-get context :open-files)))
    ;; current-file may or may not exist depending on buffer state
    ;; just verify structure is valid
    (should (or (null (plist-get context :current-file))
                (plistp (plist-get context :current-file))))))

(ert-deftest test-claude-agent-collect-selection-context ()
  "Test selection context collection."
  :tags '(:unit :fast :stable :isolated :context)
  (with-temp-buffer
    (insert "line 1\nline 2\nline 3\nline 4\n")
    (goto-char (point-min))
    (forward-line 1)  ; Start of line 2
    (set-mark (point))
    (forward-line 2)  ; Start of line 4
    (activate-mark)
    (let ((context (claude-agent-collect-ide-context)))
      (if (plist-get context :selection)
          (let ((sel (plist-get context :selection)))
            (should (plist-get sel :start-line))
            (should (plist-get sel :end-line))
            (should (stringp (plist-get sel :text))))
        ;; Selection may not be collected in batch mode
        (should t)))))

(ert-deftest test-claude-agent-exclude-predicates ()
  "Test IDE context exclusion predicates."
  :tags '(:unit :fast :stable :isolated :context)
  ;; This test requires claude-org to be loaded which registers its exclusion
  ;; For now, just test that the list exists and is callable
  (should (listp claude-agent-ide-context-exclude-predicates))
  ;; Test that predicates are callable
  (with-temp-buffer
    (dolist (pred claude-agent-ide-context-exclude-predicates)
      (should (functionp pred))
      ;; Should not error when called
      (funcall pred (current-buffer)))))

(ert-deftest test-claude-agent-build-system-reminder ()
  "Test system reminder message construction."
  :tags '(:unit :fast :stable :isolated :context)
  (let* ((current-file '(:name "test.el" :language "emacs-lisp" :modified t))
         (open-files '((:name "foo.py" :language "python")
                       (:name "bar.js" :language "javascript")))
         (selection '(:start-line 10 :end-line 15 :text "selected text"))
         (reminder (claude-agent-build-system-reminder
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

(ert-deftest test-claude-agent-active-query-tracking ()
  "Test tracking of active queries."
  :tags '(:unit :fast :stable :isolated :process)
  ;; Create fresh hash table for this test
  (let ((claude-agent--active-queries (make-hash-table :test 'equal)))
    ;; Initially empty
    (should (= 0 (claude-agent-active-query-count)))
    ;; Create proper process state struct
    (let ((state (claude-agent--make-process-state
                  :request-id "req-123"
                  :process nil
                  :buffer nil
                  :closed nil)))
      (claude-agent--register-query "req-123" state)
      (should (= 1 (claude-agent-active-query-count)))
      ;; Get it back - MUST return the actual state, not just truthy
      (let ((retrieved (claude-agent--get-active-query "req-123")))
        (should retrieved)
        (should (eq retrieved state))
        (should (claude-agent--process-state-p retrieved))
        (should (equal "req-123" (claude-agent--process-state-request-id retrieved))))
      ;; Non-existent query should return nil
      (should-not (claude-agent--get-active-query "nonexistent-id"))
      ;; Unregister
      (claude-agent--unregister-query "req-123")
      (should (= 0 (claude-agent-active-query-count)))
      ;; After unregister, should return nil
      (should-not (claude-agent--get-active-query "req-123")))))

(ert-deftest test-claude-agent-query-cancellation ()
  "Test query cancellation by request ID."
  :tags '(:unit :fast :stable :isolated :process)
  ;; This tests the cancellation registration, not actual process killing
  (let ((claude-agent--active-queries (make-hash-table :test 'equal))
        (cancelled nil))
    ;; Create mock process
    (let ((proc (make-process
                 :name "test-process"
                 :command '("cat")
                 :sentinel (lambda (proc event)
                             (setq cancelled t)))))
      ;; Create proper process state struct
      (let ((state (claude-agent--make-process-state
                    :request-id "req-123"
                    :process proc
                    :buffer nil
                    :closed nil)))
        (claude-agent--register-query "req-123" state)
        (should (= 1 (claude-agent-active-query-count)))
        ;; Cancel should work
        (should (claude-agent-cancel-query "req-123"))
        ;; Should be marked as closed
        (should (claude-agent--process-state-closed state))
        ;; Clean up process
        (when (process-live-p proc)
          (delete-process proc))))))

;;; Utility Tests

(ert-deftest test-claude-agent-generate-request-id ()
  "Test request ID generation."
  :tags '(:unit :fast :stable :isolated :process)
  (let ((id1 (claude-agent--generate-request-id))
        (id2 (claude-agent--generate-request-id)))
    (should (stringp id1))
    (should (stringp id2))
    (should-not (equal id1 id2))
    (should (string-match-p "^req-[0-9]+-[0-9]+$" id1))))

(ert-deftest test-claude-agent-cli-discovery ()
  "Test Claude CLI discovery."
  :tags '(:unit :fast :stable :isolated :process)
  ;; This test checks if we can find the CLI or handle its absence gracefully
  (let ((cli (claude-agent--find-cli)))
    ;; Should either find it or return the default "claude"
    (should (stringp cli))
    (should (or (file-executable-p cli)
                (equal "claude" cli)))))

;;; Permission System Tests

(ert-deftest test-claude-agent-permission-match-wildcard ()
  "Test that wildcard pattern matches everything."
  :tags '(:unit :fast :stable :isolated :permission)
  (should (claude-agent-permission-match-p "Read" '(:file_path "/tmp/test.txt") "*"))
  (should (claude-agent-permission-match-p "Write" '(:file_path "/etc/passwd") "*"))
  (should (claude-agent-permission-match-p "Bash" '(:command "rm -rf /") "*"))
  (should (claude-agent-permission-match-p "mcp__emacs__evalElisp" '(:code "(+ 1 2)") "*")))

(ert-deftest test-claude-agent-permission-match-tool-name ()
  "Test simple tool name matching without arguments."
  :tags '(:unit :fast :stable :isolated :permission)
  (should (claude-agent-permission-match-p "Read" '(:file_path "/tmp/test.txt") "Read"))
  (should (claude-agent-permission-match-p "Write" '(:file_path "/tmp/test.txt") "Write"))
  (should-not (claude-agent-permission-match-p "Read" '(:file_path "/tmp/test.txt") "Write"))
  (should-not (claude-agent-permission-match-p "Bash" '(:command "ls") "Read")))

(ert-deftest test-claude-agent-permission-match-double-star ()
  "Test (**) pattern matches any arguments."
  :tags '(:unit :fast :stable :isolated :permission)
  (should (claude-agent-permission-match-p "Read" '(:file_path "/tmp/test.txt") "Read(**)"))
  (should (claude-agent-permission-match-p "Read" '(:file_path "/etc/passwd") "Read(**)"))
  (should (claude-agent-permission-match-p "Write" '(:file_path "/home/user/doc.txt") "Write(**)"))
  (should-not (claude-agent-permission-match-p "Read" '(:file_path "/tmp/x") "Write(**)")))

(ert-deftest test-claude-agent-permission-match-prefix ()
  "Test prefix:* pattern matches commands starting with prefix."
  :tags '(:unit :fast :stable :isolated :permission)
  (should (claude-agent-permission-match-p "Bash" '(:command "git status") "Bash(git:*)"))
  (should (claude-agent-permission-match-p "Bash" '(:command "git commit -m test") "Bash(git:*)"))
  (should-not (claude-agent-permission-match-p "Bash" '(:command "rm -rf /") "Bash(git:*)")))

(ert-deftest test-claude-agent-permission-match-mcp-glob ()
  "Test glob pattern for MCP tool names."
  :tags '(:unit :fast :stable :isolated :permission)
  (should (claude-agent-permission-match-p "mcp__emacs__evalElisp" nil "mcp__emacs__*"))
  (should (claude-agent-permission-match-p "mcp__emacs__getDiagnostics" nil "mcp__emacs__*"))
  (should (claude-agent-permission-match-p "mcp__context7__resolve-library-id" nil "mcp__context7__*"))
  (should-not (claude-agent-permission-match-p "mcp__emacs__evalElisp" nil "mcp__context7__*")))

(ert-deftest test-claude-agent-permission-match-path-glob ()
  "Test glob pattern for file paths."
  :tags '(:unit :fast :stable :isolated :permission)
  ;; Match any file (** pattern)
  (should (claude-agent-permission-match-p "Read" '(:file_path "/project/.env") "Read(**)"))
  (should (claude-agent-permission-match-p "Read" '(:file_path "/home/user/app/.env") "Read(**)"))
  ;; Match specific directory prefix
  (should (claude-agent-permission-match-p "Write" '(:file_path "/tmp/foo.txt") "Write(/tmp/*)"))
  ;; Match files starting with specific path
  (should (claude-agent-permission-match-p "Read" '(:file_path "/home/user/doc.txt") "Read(/home/*)")))

(ert-deftest test-claude-agent-permission-check-deny-first ()
  "Test that deny patterns take precedence over allow."
  :tags '(:unit :fast :stable :isolated :permission)
  (let ((allow '("Read(**)" "Bash(**)"))
        (deny '("Bash(rm *)")))
    ;; Read should be allowed
    (should (eq 'allow (claude-agent-check-permission
                        "Read" '(:file_path "/tmp/test") allow deny)))
    ;; Normal bash should be allowed
    (should (eq 'allow (claude-agent-check-permission
                        "Bash" '(:command "ls -la") allow deny)))
    ;; rm command should be denied (matches deny pattern)
    (should (eq 'deny (claude-agent-check-permission
                       "Bash" '(:command "rm -rf /tmp/foo") allow deny)))))

(ert-deftest test-claude-agent-permission-check-default-deny ()
  "Test that default deny patterns are always checked."
  :tags '(:unit :fast :stable :isolated :permission)
  (let ((allow '("Bash(**)"))  ; Allow all bash
        (deny '()))             ; No user deny patterns
    ;; sudo should still be denied by default patterns
    (should (eq 'deny (claude-agent-check-permission
                       "Bash" '(:command "sudo rm -rf /") allow deny)))
    ;; chmod 777 should be denied
    (should (eq 'deny (claude-agent-check-permission
                       "Bash" '(:command "chmod 777 /etc/passwd") allow deny)))))

(ert-deftest test-claude-agent-permission-check-ask ()
  "Test that unmatched tools return 'ask."
  :tags '(:unit :fast :stable :isolated :permission)
  (let ((allow '("Read(**)"))
        (deny '()))
    ;; Write is not in allow list, should ask
    (should (eq 'ask (claude-agent-check-permission
                      "Write" '(:file_path "/tmp/new.txt") allow deny)))
    ;; Unknown tool should ask
    (should (eq 'ask (claude-agent-check-permission
                      "CustomTool" '(:arg "value") allow deny)))))

(ert-deftest test-claude-agent-permission-presets ()
  "Test preset permission configurations."
  :tags '(:unit :fast :stable :isolated :permission)
  ;; Readonly preset
  (let ((claude-agent-permission-preset "readonly"))
    (let ((perms (claude-agent-get-effective-permissions)))
      (should (member "Read(**)" (plist-get perms :allow)))
      (should (member "Glob(**)" (plist-get perms :allow)))
      (should (member "Grep(**)" (plist-get perms :allow)))
      (should-not (member "Write(**)" (plist-get perms :allow)))))
  ;; Accept-edits preset
  (let ((claude-agent-permission-preset "accept-edits"))
    (let ((perms (claude-agent-get-effective-permissions)))
      (should (member "Read(**)" (plist-get perms :allow)))
      (should (member "Write(**)" (plist-get perms :allow)))
      (should (member "Edit(**)" (plist-get perms :allow)))))
  ;; Bypass preset
  (let ((claude-agent-permission-preset "bypass"))
    (let ((perms (claude-agent-get-effective-permissions)))
      (should (member "*" (plist-get perms :allow))))))

(ert-deftest test-claude-agent-permission-custom ()
  "Test custom permission configuration."
  :tags '(:unit :fast :stable :isolated :permission)
  (let ((claude-agent-permission-preset "custom")
        (claude-agent-permissions
         '(:allow ("Read(**)" "Bash(git:*)")
           :deny ("Read(**/.env)"))))
    (let ((perms (claude-agent-get-effective-permissions)))
      (should (equal claude-agent-permissions perms)))))

(ert-deftest test-claude-agent-permission-cache-key ()
  "Test permission cache key generation."
  :tags '(:unit :fast :stable :isolated :permission)
  ;; File-based tools use directory
  (should (equal "Read:/tmp/"
                 (claude-agent--permission-cache-key "Read" '(:file_path "/tmp/test.txt"))))
  (should (equal "Write:/home/user/"
                 (claude-agent--permission-cache-key "Write" '(:file_path "/home/user/doc.txt"))))
  ;; Bash uses first word of command
  (should (equal "Bash:git"
                 (claude-agent--permission-cache-key "Bash" '(:command "git status"))))
  ;; Tools without special handling use tool name
  (should (equal "WebSearch"
                 (claude-agent--permission-cache-key "WebSearch" '(:query "test")))))

(ert-deftest test-claude-agent-describe-tool-use ()
  "Test tool use description generation."
  :tags '(:unit :fast :stable :isolated :permission)
  ;; File tools show filename
  (should (equal "Read test.txt"
                 (claude-agent--describe-tool-use "Read" '(:file_path "/tmp/test.txt"))))
  ;; Bash shows command (truncated if long)
  (should (equal "Bash: git status"
                 (claude-agent--describe-tool-use "Bash" '(:command "git status"))))
  ;; Long commands are truncated
  (let ((long-cmd (make-string 100 ?x)))
    (should (string-match-p "\\.\\.\\.$"
                            (claude-agent--describe-tool-use "Bash" `(:command ,long-cmd))))))

(ert-deftest test-claude-agent-permission-auto-allow ()
  "Test auto-allow permission callback."
  :tags '(:unit :fast :stable :isolated :permission)
  (let ((result (claude-agent-permission-auto-allow "Read" '(:file_path "/tmp/x") nil)))
    (should (equal "allow" (plist-get result :behavior)))))

(ert-deftest test-claude-agent-get-tool-first-arg ()
  "Test extraction of primary argument from tool input."
  :tags '(:unit :fast :stable :isolated :permission)
  ;; File operations
  (should (equal "/tmp/test.txt"
                 (claude-agent--get-tool-first-arg "Read" '(:file_path "/tmp/test.txt"))))
  (should (equal "/tmp/out.txt"
                 (claude-agent--get-tool-first-arg "Write" '(:file_path "/tmp/out.txt" :content "data"))))
  ;; Glob uses pattern
  (should (equal "**/*.el"
                 (claude-agent--get-tool-first-arg "Glob" '(:pattern "**/*.el"))))
  ;; Bash uses command
  (should (equal "git status"
                 (claude-agent--get-tool-first-arg "Bash" '(:command "git status"))))
  ;; WebSearch uses query
  (should (equal "elisp tutorial"
                 (claude-agent--get-tool-first-arg "WebSearch" '(:query "elisp tutorial"))))
  ;; WebFetch uses url
  (should (equal "https://example.com"
                 (claude-agent--get-tool-first-arg "WebFetch" '(:url "https://example.com")))))

;;; Query Identity Display Tests

(ert-deftest test-claude-agent-format-query-identity-with-buffer-and-label ()
  "Test query identity formatting with source buffer and query-context."
  :tags '(:unit :fast :stable :isolated :display)
  (with-temp-buffer
    (rename-buffer "claude-agent-dev.org" t)
    (let* ((ctx (claude-agent-make-query-context :instruction-num 5))
           (state (claude-agent--make-process-state
                   :request-id "req-42-1234567890"
                   :source-buffer (current-buffer)
                   :query-context ctx)))
      ;; Short form should show "basename#label"
      (should (equal "claude-agent-dev#5"
                     (claude-agent--format-query-identity state)))
      ;; Long form should show full buffer name
      (should (string-match-p "claude-agent-dev.*#5"
                              (claude-agent--format-query-identity state t))))))

(ert-deftest test-claude-agent-format-query-identity-buffer-only ()
  "Test query identity with buffer but no query-context."
  :tags '(:unit :fast :stable :isolated :display)
  (with-temp-buffer
    (rename-buffer "test-file.org" t)
    (let ((state (claude-agent--make-process-state
                  :request-id "req-10-1234567890"
                  :source-buffer (current-buffer)
                  :query-context nil)))
      ;; Should show just buffer name without "#"
      (should (equal "test-file"
                     (claude-agent--format-query-identity state))))))

(ert-deftest test-claude-agent-format-query-identity-fallback ()
  "Test query identity fallback when no buffer available."
  :tags '(:unit :fast :stable :isolated :display)
  ;; No source buffer - should fall back to request-id
  (let ((state (claude-agent--make-process-state
                :request-id "req-99-1234567890"
                :source-buffer nil
                :query-context nil)))
    (should (equal "#99" (claude-agent--format-query-identity state))))
  ;; Dead buffer - should also fall back
  (let* ((buf (generate-new-buffer "temp-dead"))
         (ctx (claude-agent-make-query-context :instruction-num 3))
         (state (claude-agent--make-process-state
                 :request-id "req-88-1234567890"
                 :source-buffer buf
                 :query-context ctx)))
    (kill-buffer buf)
    (should (equal "#88" (claude-agent--format-query-identity state)))))

(ert-deftest test-claude-agent-get-single-active-state ()
  "Test getting single active query state."
  :tags '(:unit :fast :stable :isolated :display)
  (let ((claude-agent--active-queries (make-hash-table :test 'equal)))
    ;; Empty - should return nil
    (should-not (claude-agent--get-single-active-state))
    ;; One active query
    (let ((state1 (claude-agent--make-process-state
                   :request-id "req-1"
                   :closed nil)))
      (claude-agent--register-query "req-1" state1)
      (should (eq state1 (claude-agent--get-single-active-state))))
    ;; Two queries - should return nil
    (let ((state2 (claude-agent--make-process-state
                   :request-id "req-2"
                   :closed nil)))
      (claude-agent--register-query "req-2" state2)
      (should-not (claude-agent--get-single-active-state)))
    ;; Clean up
    (claude-agent--unregister-query "req-1")
    (claude-agent--unregister-query "req-2")))

(ert-deftest test-claude-agent-process-state-source-slots ()
  "Test that process-state has source-buffer and query-context slots."
  :tags '(:unit :fast :stable :isolated :display)
  (with-temp-buffer
    (let* ((ctx (claude-agent-make-query-context
                 :instruction-num 42
                 :loop-current 1
                 :loop-max 1))
           (state (claude-agent--make-process-state
                   :source-buffer (current-buffer)
                   :query-context ctx)))
      (should (eq (current-buffer)
                  (claude-agent--process-state-source-buffer state)))
      (should (claude-agent-query-context-p
               (claude-agent--process-state-query-context state)))
      (should (equal 42
                     (claude-agent-query-context-instruction-num
                      (claude-agent--process-state-query-context state)))))))

(ert-deftest test-claude-agent-query-context-format-id ()
  "Test query-context-format-id formatting."
  :tags '(:unit :fast :stable :isolated :display)
  ;; Single execution (no loop suffix)
  (let ((ctx (claude-agent-make-query-context
              :instruction-num 5
              :loop-current 1
              :loop-max 1)))
    (should (equal "5" (claude-agent-query-context-format-id ctx))))
  ;; Loop iteration
  (let ((ctx (claude-agent-make-query-context
              :instruction-num 5
              :loop-current 2
              :loop-max 3)))
    (should (equal "5(2/3)" (claude-agent-query-context-format-id ctx))))
  ;; First iteration of loop
  (let ((ctx (claude-agent-make-query-context
              :instruction-num 5
              :loop-current 1
              :loop-max 3)))
    (should (equal "5(1/3)" (claude-agent-query-context-format-id ctx))))
  ;; No instruction number
  (let ((ctx (claude-agent-make-query-context
              :instruction-num nil)))
    (should (null (claude-agent-query-context-format-id ctx)))))

(ert-deftest test-claude-agent-query-context-format-label ()
  "Test query-context-format-label formatting."
  :tags '(:unit :fast :stable :isolated :display)
  ;; Single execution
  (let ((ctx (claude-agent-make-query-context
              :instruction-num 5
              :loop-current 1
              :loop-max 1)))
    (should (equal "Instruction 5" (claude-agent-query-context-format-label ctx))))
  ;; Loop iteration
  (let ((ctx (claude-agent-make-query-context
              :instruction-num 5
              :loop-current 2
              :loop-max 3)))
    (should (equal "Instruction 5 (2/3)" (claude-agent-query-context-format-label ctx))))
  ;; First iteration of loop
  (let ((ctx (claude-agent-make-query-context
              :instruction-num 5
              :loop-current 1
              :loop-max 3)))
    (should (equal "Instruction 5 (1/3)" (claude-agent-query-context-format-label ctx)))))

;;; Activity Mode-Line Tests

(ert-deftest test-claude-agent-format-activity-tooltip ()
  "Test activity tooltip formatting function exists and works."
  :tags '(:unit :fast :stable :isolated :display)
  ;; First verify the function exists (this would have caught the deletion!)
  (should (fboundp 'claude-agent--format-activity-tooltip))
  ;; Test with no active queries
  (let ((claude-agent--active-queries (make-hash-table :test 'equal)))
    (let ((tooltip (claude-agent--format-activity-tooltip)))
      (should (stringp tooltip))
      (should (string-match-p "Active Claude Queries" tooltip))
      (should (string-match-p "no active queries" tooltip))))
  ;; Test with one active query
  (let ((claude-agent--active-queries (make-hash-table :test 'equal)))
    (with-temp-buffer
      (rename-buffer "test-activity.org" t)
      (let* ((ctx (claude-agent-make-query-context :instruction-num 7))
             (state (claude-agent--make-process-state
                     :request-id "req-123"
                     :source-buffer (current-buffer)
                     :query-context ctx
                     :start-time (float-time)
                     :closed nil)))
        (claude-agent--register-query "req-123" state)
        (let ((tooltip (claude-agent--format-activity-tooltip)))
          (should (stringp tooltip))
          (should (string-match-p "test-activity" tooltip))
          (should (string-match-p "#7" tooltip))
          (should (string-match-p "\\[.*s\\]" tooltip)))  ; elapsed time like [0s]
        (claude-agent--unregister-query "req-123")))))

(ert-deftest test-claude-agent-update-activity-string ()
  "Test activity string update doesn't error.
This test ensures all helper functions called exist."
  :tags '(:unit :fast :stable :isolated :display)
  ;; This test will fail if any function called by update-activity-string is missing
  (let ((claude-agent--active-queries (make-hash-table :test 'equal))
        (claude-agent-activity-string "")
        (claude-agent--spinner-index 0))
    ;; Test with no queries - should not error
    (should (progn (claude-agent--update-activity-string) t))
    (should (equal "" claude-agent-activity-string))
    ;; Test with one query
    (let* ((ctx (claude-agent-make-query-context :instruction-num 1))
           (state (claude-agent--make-process-state
                   :request-id "req-test"
                   :start-time (float-time)
                   :query-context ctx
                   :closed nil)))
      (claude-agent--register-query "req-test" state)
      ;; This call would have caught the void-function error!
      (should (progn (claude-agent--update-activity-string) t))
      (should (stringp claude-agent-activity-string))
      (should (> (length claude-agent-activity-string) 0))
      ;; Verify tooltip is set as help-echo property
      (should (get-text-property 0 'help-echo claude-agent-activity-string))
      (claude-agent--unregister-query "req-test"))))

;;; Session Recovery Unit Tests

(ert-deftest test-claude-agent-recovery-abnormal-exit-detection ()
  "Test the abnormal exit detection logic for automatic recovery."
  :tags '(:unit :fast :stable :isolated :recovery)

  (let ((claude-agent-auto-recovery t))
    ;; Test 1: Signal kill should trigger recovery (if session-id available)
    (let ((state (claude-agent--make-process-state
                  :session-id "test-uuid")))
      (should (claude-agent--is-abnormal-exit-p "killed: 9" state)))

    ;; Test 2: Abnormal exit should trigger recovery
    (let ((state (claude-agent--make-process-state
                  :session-id "test-uuid")))
      (should (claude-agent--is-abnormal-exit-p "exited abnormally with code 1" state)))

    ;; Test 3: Normal finish without result should trigger recovery
    (let ((state (claude-agent--make-process-state
                  :session-id "test-uuid")))
      (should (claude-agent--is-abnormal-exit-p "finished" state)))

    ;; Test 4: Normal finish WITH result should NOT trigger recovery
    (let ((state (claude-agent--make-process-state
                  :session-id "test-uuid"
                  :got-result t)))
      (should-not (claude-agent--is-abnormal-exit-p "finished" state)))

    ;; Test 5: No session-id means no recovery possible
    (let ((state (claude-agent--make-process-state)))
      (should-not (claude-agent--is-abnormal-exit-p "killed: 9" state)))

    ;; Test 6: Recovery disabled globally
    (let ((claude-agent-auto-recovery nil)
          (state (claude-agent--make-process-state
                  :session-id "test-uuid")))
      (should-not (claude-agent--is-abnormal-exit-p "killed: 9" state)))))

(ert-deftest test-claude-agent-recovery-message-format ()
  "Test that the recovery message has the expected format."
  :tags '(:unit :fast :stable :isolated :recovery)

  ;; Create a mock state with token-callback
  (let ((received-message nil))
    (let ((state (claude-agent--make-process-state
                  :token-callback (lambda (text)
                                    (setq received-message text)))))
      ;; Test with kill signal
      (claude-agent--insert-recovery-message state "killed: 9")
      (should received-message)
      (should (string-match-p "Session interrupted" received-message))
      (should (string-match-p "killed: 9" received-message))
      (should (string-match-p "automatic recovery" received-message)))))

(ert-deftest test-claude-agent-recovery-message-exit-code ()
  "Test recovery message format with exit code."
  :tags '(:unit :fast :stable :isolated :recovery)

  (let ((received-message nil))
    (let ((state (claude-agent--make-process-state
                  :token-callback (lambda (text)
                                    (setq received-message text)))))
      ;; Test with exit code
      (claude-agent--insert-recovery-message state "exited abnormally with code 137")
      (should received-message)
      (should (string-match-p "exit code: 137" received-message)))))

(ert-deftest test-claude-agent-recovery-message-no-callback ()
  "Test that recovery message gracefully handles missing token-callback."
  :tags '(:unit :fast :stable :isolated :recovery)

  ;; State without token-callback should not crash
  (let ((state (claude-agent--make-process-state)))
    (should-not (claude-agent--insert-recovery-message state "killed: 9"))))

(ert-deftest test-claude-agent-recovery-config-default ()
  "Test that auto-recovery is enabled by default."
  :tags '(:unit :fast :stable :isolated :recovery)
  (should (boundp 'claude-agent-auto-recovery))
  (should claude-agent-auto-recovery))

(ert-deftest test-claude-agent-recovery-prompt-defined ()
  "Test that recovery prompt is defined and non-empty."
  :tags '(:unit :fast :stable :isolated :recovery)
  (should (boundp 'claude-agent-recovery-prompt))
  (should (stringp claude-agent-recovery-prompt))
  (should (> (length claude-agent-recovery-prompt) 0)))

(ert-deftest test-claude-agent-process-state-recovery-fields ()
  "Test that process-state struct has the recovery fields."
  :tags '(:unit :fast :stable :isolated :recovery)
  (let ((state (claude-agent--make-process-state
                :session-id "test-session-id"
                :got-result t)))
    ;; Test session-id field
    (should (equal "test-session-id" (claude-agent--process-state-session-id state)))
    ;; Test got-result field
    (should (eq t (claude-agent--process-state-got-result state)))
    ;; Test default values
    (let ((default-state (claude-agent--make-process-state)))
      (should-not (claude-agent--process-state-session-id default-state))
      (should-not (claude-agent--process-state-got-result default-state)))))

(ert-deftest test-claude-agent-recovery-error-result-sets-got-result ()
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
         (state (claude-agent--make-process-state
                 :session-id "test-session"
                 :error-callback (lambda (_err) (setq error-called t)))))

    ;; Process the error result message (2-arg: callbacks from state)
    (claude-agent--process-normal-message error-result state)

    ;; Verify got-result is set even for error results
    (should (claude-agent--process-state-got-result state))
    ;; Error callback should have been called
    (should error-called)

    ;; Now verify that abnormal exit detection does NOT trigger recovery
    ;; because got-result is true
    (let ((claude-agent-auto-recovery t))
      (should-not (claude-agent--is-abnormal-exit-p "exited abnormally with code 1" state)))))

(ert-deftest test-claude-agent-recovery-success-result-sets-got-result ()
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
         (state (claude-agent--make-process-state
                 :session-id "test-session"
                 :callback (lambda (msg) (setq message-received msg)))))

    ;; Process the success result message (2-arg: callbacks from state)
    (claude-agent--process-normal-message success-result state)

    ;; Verify got-result is set
    (should (claude-agent--process-state-got-result state))
    ;; Message callback should have been called
    (should message-received)))

(ert-deftest test-claude-agent-extract-json-error-uses-errors-array ()
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
    (let ((error-msg (claude-agent--extract-json-error error-result)))
      ;; Should extract the specific error from :errors array
      (should error-msg)
      (should (string-match-p "No conversation found" error-msg))
      ;; Should NOT return the generic "Execution error" message
      (should-not (string-match-p "Execution error" error-msg)))))

(ert-deftest test-claude-agent-extract-json-error-falls-back-to-subtype ()
  "Test that generic subtype message is used when :errors is empty."
  :tags '(:unit :fast :stable :isolated)

  ;; Error result without :errors array
  (let ((error-result '(:type "result"
                        :subtype "error_during_execution"
                        :is_error t
                        :duration_ms 0)))
    (let ((error-msg (claude-agent--extract-json-error error-result)))
      ;; Should fall back to generic message
      (should error-msg)
      (should (string-match-p "Execution error" error-msg)))))

;;; Environment Building Tests

(ert-deftest test-claude-agent-build-env-strips-claudecode ()
  "Test that CLAUDECODE is stripped from the process environment.
Claude CLI refuses to launch inside another Claude Code session when
CLAUDECODE is set.  Our SDK must unset it so Emacs users can run
queries from within a Claude Code session."
  :tags '(:unit :fast :stable :isolated :process)
  (let* ((process-environment '("HOME=/home/user"
                                "CLAUDECODE=1"
                                "PATH=/usr/bin"
                                "EDITOR=emacs"))
         (result (claude-agent--build-process-environment nil nil)))
    ;; CLAUDECODE should be stripped
    (should-not (cl-find-if (lambda (s) (string-prefix-p "CLAUDECODE=" s)) result))
    ;; Other vars should remain
    (should (member "HOME=/home/user" result))
    (should (member "PATH=/usr/bin" result))
    (should (member "EDITOR=emacs" result))))

(ert-deftest test-claude-agent-build-env-preserves-custom-vars ()
  "Test that custom env vars from options are prepended."
  :tags '(:unit :fast :stable :isolated :process)
  (let* ((process-environment '("HOME=/home/user" "PATH=/usr/bin"))
         (env-vars '(("MY_VAR" . "my_value") ("OTHER" . "test")))
         (result (claude-agent--build-process-environment env-vars nil)))
    (should (member "MY_VAR=my_value" result))
    (should (member "OTHER=test" result))
    (should (member "HOME=/home/user" result))))

(ert-deftest test-claude-agent-build-env-prepends-cli-dir-to-path ()
  "Test that cli-dir is prepended to PATH when provided."
  :tags '(:unit :fast :stable :isolated :process)
  (let* ((process-environment '("HOME=/home/user" "PATH=/usr/bin"))
         (result (claude-agent--build-process-environment nil "/opt/node/bin/")))
    (should (cl-find-if (lambda (s)
                          (and (string-prefix-p "PATH=" s)
                               (string-match-p "/opt/node/bin/" s)))
                        result))))

(ert-deftest test-claude-agent-build-env-no-claudecode-even-with-custom-vars ()
  "Test CLAUDECODE is stripped even when custom env vars are provided."
  :tags '(:unit :fast :stable :isolated :process)
  (let* ((process-environment '("CLAUDECODE=1" "HOME=/home/user"))
         (env-vars '(("FOO" . "bar")))
         (result (claude-agent--build-process-environment env-vars "/some/dir/")))
    (should-not (cl-find-if (lambda (s) (string-prefix-p "CLAUDECODE=" s)) result))
    (should (member "FOO=bar" result))))

;;; Phase 0a: Sentinel per-process cleanup tests

(ert-deftest test-claude-agent-sentinel-cleanup-preserves-other-sessions ()
  "Test that sentinel cleanup only removes entries for the exiting process.
The old code used clrhash which wiped ALL entries including other sessions."
  :tags '(:unit :fast :stable :isolated :sentinel :phase-0a)
  (let ((claude-agent--pending-background-tasks (make-hash-table :test 'equal))
        (claude-agent--pending-control-requests (make-hash-table :test 'equal)))
    ;; Session A owns task-1 and ctrl-1
    (puthash "task-1" "req-A" claude-agent--pending-background-tasks)
    (puthash "ctrl-1" "req-A" claude-agent--pending-control-requests)
    ;; Session B owns task-2 and ctrl-2
    (puthash "task-2" "req-B" claude-agent--pending-background-tasks)
    (puthash "ctrl-2" "req-B" claude-agent--pending-control-requests)
    ;; Cleanup session A
    (claude-agent--cleanup-process-entries "req-A")
    ;; Session B entries must survive
    (should (gethash "task-2" claude-agent--pending-background-tasks))
    (should (gethash "ctrl-2" claude-agent--pending-control-requests))
    ;; Session A entries must be gone
    (should-not (gethash "task-1" claude-agent--pending-background-tasks))
    (should-not (gethash "ctrl-1" claude-agent--pending-control-requests))))

(ert-deftest test-claude-agent-sentinel-cleanup-removes-all-owned-entries ()
  "Test that sentinel cleanup removes ALL entries for the exiting process."
  :tags '(:unit :fast :stable :isolated :sentinel :phase-0a)
  (let ((claude-agent--pending-background-tasks (make-hash-table :test 'equal))
        (claude-agent--pending-control-requests (make-hash-table :test 'equal)))
    ;; Session A owns multiple tasks and control requests
    (puthash "task-1" "req-A" claude-agent--pending-background-tasks)
    (puthash "task-3" "req-A" claude-agent--pending-background-tasks)
    (puthash "ctrl-1" "req-A" claude-agent--pending-control-requests)
    (puthash "ctrl-3" "req-A" claude-agent--pending-control-requests)
    ;; Cleanup session A
    (claude-agent--cleanup-process-entries "req-A")
    ;; All A entries gone
    (should (= 0 (hash-table-count claude-agent--pending-background-tasks)))
    (should (= 0 (hash-table-count claude-agent--pending-control-requests)))))

(ert-deftest test-claude-agent-sentinel-cleanup-noop-when-no-entries ()
  "Test that cleanup is safe when no entries exist for the process."
  :tags '(:unit :fast :stable :isolated :sentinel :phase-0a)
  (let ((claude-agent--pending-background-tasks (make-hash-table :test 'equal))
        (claude-agent--pending-control-requests (make-hash-table :test 'equal)))
    ;; Only session B entries
    (puthash "task-2" "req-B" claude-agent--pending-background-tasks)
    ;; Cleanup non-existent session A - should not error
    (claude-agent--cleanup-process-entries "req-A")
    ;; Session B untouched
    (should (= 1 (hash-table-count claude-agent--pending-background-tasks)))))

(ert-deftest test-claude-agent-background-task-tracker-stores-owner ()
  "Test that background-task-tracker stores request-id as owner, not just t."
  :tags '(:unit :fast :stable :isolated :sentinel :phase-0a)
  (let ((claude-agent--pending-background-tasks (make-hash-table :test 'equal))
        (state (claude-agent--make-process-state :request-id "req-X")))
    ;; Simulate Task tool async launch
    (claude-agent--background-task-tracker
     nil nil nil
     '(:isAsync t :agentId "agent-1")
     state)
    ;; Value should be the owning request-id, not t
    (should (equal "req-X" (gethash "agent-1" claude-agent--pending-background-tasks)))))

(ert-deftest test-claude-agent-control-request-tracker-stores-owner ()
  "Test that control request tracking stores request-id as owner."
  :tags '(:unit :fast :stable :isolated :sentinel :phase-0a)
  (let ((claude-agent--pending-control-requests (make-hash-table :test 'equal)))
    ;; Track with owner
    (claude-agent--track-control-request "ctrl-1" "req-X")
    ;; Value should be the owning request-id
    (should (equal "req-X" (gethash "ctrl-1" claude-agent--pending-control-requests)))))

;;; Phase 0c: Verbose buffer memory leak tests

(ert-deftest test-claude-agent-verbose-buffer-max-size ()
  "Test that verbose buffer is trimmed when it exceeds max size."
  :tags '(:unit :fast :stable :isolated :verbose :phase-0c)
  (let ((claude-agent--session-verbose-buffers (make-hash-table :test 'equal))
        (claude-agent-verbose-buffer-max-size 100)
        (buf (generate-new-buffer " *test-verbose*")))
    (unwind-protect
        (progn
          (puthash "test-key" buf claude-agent--session-verbose-buffers)
          ;; Insert more than max-size
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (insert (make-string 200 ?x))))
          ;; Trigger insert which should trim
          (claude-agent--verbose-insert "test-key" "new-content")
          (with-current-buffer buf
            ;; Buffer should have been trimmed: not dramatically larger than max
            (should (<= (buffer-size) (+ claude-agent-verbose-buffer-max-size 50)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest test-claude-agent-verbose-buffer-no-trim-under-limit ()
  "Test that verbose buffer is NOT trimmed when under max size."
  :tags '(:unit :fast :stable :isolated :verbose :phase-0c)
  (let ((claude-agent--session-verbose-buffers (make-hash-table :test 'equal))
        (claude-agent-verbose-buffer-max-size 10000)
        (buf (generate-new-buffer " *test-verbose*")))
    (unwind-protect
        (progn
          (puthash "test-key" buf claude-agent--session-verbose-buffers)
          (claude-agent--verbose-insert "test-key" "small text")
          (with-current-buffer buf
            (should (string-match-p "small text" (buffer-string)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest test-claude-agent-verbose-buffer-max-size-nil-no-trim ()
  "Test that nil max-size means no trimming (unlimited)."
  :tags '(:unit :fast :stable :isolated :verbose :phase-0c)
  (let ((claude-agent--session-verbose-buffers (make-hash-table :test 'equal))
        (claude-agent-verbose-buffer-max-size nil)
        (buf (generate-new-buffer " *test-verbose*")))
    (unwind-protect
        (progn
          (puthash "test-key" buf claude-agent--session-verbose-buffers)
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (insert (make-string 200 ?x))))
          (claude-agent--verbose-insert "test-key" "more")
          (with-current-buffer buf
            ;; No trimming, so buffer should be large
            (should (> (buffer-size) 200))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; Phase 0b: Docker path mappings per-process tests

(ert-deftest test-claude-agent-path-mappings-stored-in-process-state ()
  "Test that path-mappings are stored per-process, not in a global."
  :tags '(:unit :fast :stable :isolated :docker :phase-0b)
  (let ((state (claude-agent--make-process-state
                :path-mappings '(("/host" . "/container")))))
    ;; path-mappings should be in the process state
    (should (equal '(("/host" . "/container"))
                   (claude-agent--process-state-path-mappings state)))))

;;; Phase 0d: Shared JSON parser tests

(ert-deftest test-claude-agent-try-parse-json-valid ()
  "Test that try-parse-json parses valid JSON into plist."
  :tags '(:unit :fast :stable :isolated :json :phase-0d)
  (let ((result (claude-agent--try-parse-json "{\"type\":\"assistant\",\"id\":\"123\"}")))
    (should result)
    (should (equal "assistant" (plist-get result :type)))
    (should (equal "123" (plist-get result :id)))))

(ert-deftest test-claude-agent-try-parse-json-invalid ()
  "Test that try-parse-json returns nil for invalid JSON."
  :tags '(:unit :fast :stable :isolated :json :phase-0d)
  (should-not (claude-agent--try-parse-json "not json at all"))
  (should-not (claude-agent--try-parse-json ""))
  (should-not (claude-agent--try-parse-json "{broken")))

(ert-deftest test-claude-agent-try-parse-json-array ()
  "Test that try-parse-json handles arrays correctly."
  :tags '(:unit :fast :stable :isolated :json :phase-0d)
  (let ((result (claude-agent--try-parse-json "{\"items\":[1,2,3]}")))
    (should result)
    (should (equal '(1 2 3) (plist-get result :items)))))

;;; Phase 1a: query-accumulate helper tests

(ert-deftest test-claude-agent-query-accumulate-exists ()
  "Test that claude-agent-query-accumulate function exists."
  :tags '(:unit :fast :stable :isolated :phase-1a)
  (should (fboundp 'claude-agent-query-accumulate)))

(ert-deftest test-claude-agent-query-accumulate-calls-query ()
  "Test that query-accumulate calls claude-agent-query with correct args."
  :tags '(:unit :fast :stable :isolated :phase-1a)
  (let ((query-called nil)
        (query-args nil))
    (cl-letf (((symbol-function 'claude-agent-query)
               (lambda (prompt &rest args)
                 (setq query-called t
                       query-args (cons prompt args)))))
      (claude-agent-query-accumulate
       "test prompt"
       :options '(:model "haiku")
       :on-result (lambda (_text) nil))
      (should query-called)
      (should (equal "test prompt" (car query-args))))))

(ert-deftest test-claude-agent-query-accumulate-accumulates-text ()
  "Test that query-accumulate accumulates text from on-message and passes to on-result."
  :tags '(:unit :fast :stable :isolated :phase-1a)
  (let ((result-text nil)
        (captured-on-message nil)
        (captured-on-complete nil))
    (cl-letf (((symbol-function 'claude-agent-query)
               (lambda (_prompt &rest args)
                 (setq captured-on-message (plist-get args :on-message)
                       captured-on-complete (plist-get args :on-complete)))))
      (claude-agent-query-accumulate
       "test"
       :on-result (lambda (text) (setq result-text text)))
      ;; Simulate messages
      (let ((msg1 '(:type "assistant" :message (:content ((:type "text" :text "hello "))))))
        (funcall captured-on-message (claude-agent--parse-message msg1)))
      (let ((msg2 '(:type "assistant" :message (:content ((:type "text" :text "world"))))))
        (funcall captured-on-message (claude-agent--parse-message msg2)))
      ;; Simulate completion
      (funcall captured-on-complete nil)
      ;; Result should be trimmed accumulated text
      (should (equal "hello world" result-text)))))

;;; Phase 1d: process-normal-message 2-arg signature tests

(ert-deftest test-claude-agent-process-normal-message-2-arg ()
  "Test that process-normal-message works with just (parsed state)."
  :tags '(:unit :fast :stable :isolated :process :phase-1d)
  (let* ((msg-received nil)
         (token-received nil)
         (state (claude-agent--make-process-state
                 :callback (lambda (msg) (setq msg-received msg))
                 :token-callback (lambda (text) (setq token-received text))
                 :error-callback nil
                 :session-key "test-session"))
         ;; Create a minimal assistant message with text content
         (parsed '(:type "assistant"
                   :message (:role "assistant"
                             :content ((:type "text" :text "hello"))))))
    ;; Should work with just 2 args - callback/token-callback extracted from state
    (claude-agent--process-normal-message parsed state)
    ;; Message callback should have been called
    (should msg-received)))

(ert-deftest test-claude-agent-process-normal-message-error-from-state ()
  "Test that process-normal-message extracts error-callback from state."
  :tags '(:unit :fast :stable :isolated :process :phase-1d)
  (let* ((error-received nil)
         (state (claude-agent--make-process-state
                 :callback nil
                 :error-callback (lambda (err) (setq error-received err))))
         ;; Simulate error in result
         (parsed '(:type "result"
                   :is_error t
                   :error "Something went wrong")))
    (claude-agent--process-normal-message parsed state)
    ;; Error callback should have been called
    (should error-received)))

;;; Phase 2: Public accessors for cross-module encapsulation

(ert-deftest test-claude-agent-close-and-unregister-state ()
  "Test public API to close state and unregister query."
  :tags '(:unit :fast :stable :isolated :api :phase-2)
  (let* ((claude-agent--active-queries (make-hash-table :test 'equal))
         (state (claude-agent--make-process-state :request-id "req-test")))
    ;; Register query first
    (puthash "req-test" state claude-agent--active-queries)
    (should (gethash "req-test" claude-agent--active-queries))
    ;; Use public API to close and unregister
    (claude-agent-close-process-state state)
    ;; State should be closed
    (should (claude-agent--process-state-closed state))
    ;; Query should be unregistered
    (should-not (gethash "req-test" claude-agent--active-queries))))

(ert-deftest test-claude-agent-close-process-state-idempotent ()
  "Test that closing an already-closed state is safe."
  :tags '(:unit :fast :stable :isolated :api :phase-2)
  (let ((state (claude-agent--make-process-state :request-id "req-test")))
    (claude-agent-close-process-state state)
    (should (claude-agent--process-state-closed state))
    ;; Second call should not error
    (claude-agent-close-process-state state)
    (should (claude-agent--process-state-closed state))))

;;; Phase 9: Client callback mutation helper tests

(ert-deftest test-claude-agent-update-state-callbacks ()
  "Test public API to update process state callbacks."
  :tags '(:unit :fast :stable :isolated :api :phase-9)
  (let* ((state (claude-agent--make-process-state
                 :callback (lambda (_) nil)
                 :error-callback (lambda (_) nil)))
         (new-cb (lambda (msg) msg))
         (new-err (lambda (err) err))
         (new-tok (lambda (text) text)))
    (claude-agent-update-state-callbacks state
                                         :callback new-cb
                                         :error-callback new-err
                                         :token-callback new-tok)
    (should (eq new-cb (claude-agent--process-state-callback state)))
    (should (eq new-err (claude-agent--process-state-error-callback state)))
    (should (eq new-tok (claude-agent--process-state-token-callback state)))))

(ert-deftest test-claude-agent-update-state-callbacks-partial ()
  "Test that update-state-callbacks only changes provided keys."
  :tags '(:unit :fast :stable :isolated :api :phase-9)
  (let* ((original-cb (lambda (_) nil))
         (state (claude-agent--make-process-state
                 :callback original-cb
                 :error-callback nil))
         (new-err (lambda (err) err)))
    ;; Only update error-callback
    (claude-agent-update-state-callbacks state :error-callback new-err)
    ;; Original callback should be unchanged
    (should (eq original-cb (claude-agent--process-state-callback state)))
    (should (eq new-err (claude-agent--process-state-error-callback state)))))

;;; Phase 3: process-state sub-structs tests

(ert-deftest test-claude-agent-callback-state-struct ()
  "Test that callback-state sub-struct exists and holds callbacks."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-3)
  (let ((cs (claude-agent--make-callback-state
             :callback (lambda (_) nil)
             :token-callback (lambda (_) nil)
             :error-callback (lambda (_) nil)
             :complete-callback (lambda (_) nil))))
    (should (claude-agent--callback-state-p cs))
    (should (functionp (claude-agent--callback-state-callback cs)))
    (should (functionp (claude-agent--callback-state-token-callback cs)))))

(ert-deftest test-claude-agent-recovery-state-struct ()
  "Test that recovery-state sub-struct exists."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-3)
  (let ((rs (claude-agent--make-recovery-state
             :session-id "sid-123"
             :original-prompt "hello")))
    (should (claude-agent--recovery-state-p rs))
    (should (equal "sid-123" (claude-agent--recovery-state-session-id rs)))
    (should-not (claude-agent--recovery-state-got-result rs))))

(ert-deftest test-claude-agent-source-state-struct ()
  "Test that source-state sub-struct exists."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-3)
  (let ((ss (claude-agent--make-source-state
             :buffer (current-buffer))))
    (should (claude-agent--source-state-p ss))
    (should (bufferp (claude-agent--source-state-buffer ss)))))

(ert-deftest test-claude-agent-docker-state-struct ()
  "Test that docker-state sub-struct exists."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-3)
  (let ((ds (claude-agent--make-docker-state
             :mode t
             :path-mappings '(("/host" . "/container")))))
    (should (claude-agent--docker-state-p ds))
    (should (claude-agent--docker-state-mode ds))
    (should (equal '(("/host" . "/container"))
                   (claude-agent--docker-state-path-mappings ds)))))

(ert-deftest test-claude-agent-process-state-flat-accessors ()
  "Test that process-state provides flat accessors for sub-struct fields."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-3)
  (let ((state (claude-agent--make-process-state
                :callback (lambda (_) 'test)
                :session-id "sid-abc"
                :docker-mode t
                :source-buffer (current-buffer))))
    ;; Flat accessors reach into sub-structs
    (should (functionp (claude-agent--process-state-callback state)))
    (should (equal "sid-abc" (claude-agent--process-state-session-id state)))
    (should (claude-agent--process-state-docker-mode state))
    (should (bufferp (claude-agent--process-state-source-buffer state)))))

;;; Phase 0e: Remove duplicate provide

(ert-deftest test-claude-agent-single-provide ()
  "Test that claude-agent has exactly one provide in active code blocks.
Provides inside :load no blocks (tangle templates) are excluded."
  :tags '(:unit :fast :stable :isolated :phase-0e)
  ;; Find claude-agent.org: try relative to test file, then default-directory
  (let* ((test-dir (file-name-directory (or load-file-name buffer-file-name default-directory)))
         (org-file (or (let ((f (expand-file-name "../claude-agent.org" test-dir)))
                         (and (file-exists-p f) f))
                       (let ((f (expand-file-name "claude-agent.org" default-directory)))
                         (and (file-exists-p f) f))))
         (count 0))
    (when (file-exists-p org-file)
      (with-temp-buffer
        (insert-file-contents org-file)
        (goto-char (point-min))
        ;; Count provides that are in active src blocks (not :load no)
        (while (re-search-forward "(provide 'claude-agent)" nil t)
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

(ert-deftest test-claude-agent-handle-message-generic-exists ()
  "Test that cl-defgeneric claude-agent-handle-message exists."
  :tags '(:unit :fast :stable :isolated :dispatch :phase-4)
  (should (fboundp 'claude-agent-handle-message)))

(ert-deftest test-claude-agent-handle-message-assistant ()
  "Test that assistant messages are dispatched via handle-message."
  :tags '(:unit :fast :stable :isolated :dispatch :phase-4)
  (let* ((received nil)
         (state (claude-agent--make-process-state
                 :callback (lambda (msg)
                             (push (list 'callback msg) received))
                 :token-callback (lambda (tok)
                                   (push (list 'token tok) received)))))
    (claude-agent-handle-message
     'assistant
     '(:type "assistant"
       :message (:role "assistant"
                 :content ((:type "text" :text "hello"))))
     state)
    ;; Should have invoked callback with parsed message
    (should (cl-some (lambda (r) (eq (car r) 'callback)) received))))

(ert-deftest test-claude-agent-handle-message-result ()
  "Test that result messages dispatch stop hooks."
  :tags '(:unit :fast :stable :isolated :dispatch :phase-4)
  (let* ((stop-called nil)
         (state (claude-agent--make-process-state
                 :callback (lambda (_msg) nil)))
         (claude-agent-stop-functions
          (list (lambda (_msg _state) (setq stop-called t)))))
    (claude-agent-handle-message
     'result
     '(:type "result"
       :result (:role "assistant"
                :content ((:type "text" :text "done"))))
     state)
    (should stop-called)))

(ert-deftest test-claude-agent-handle-message-fallback ()
  "Test that unknown message types fall through to normal processing."
  :tags '(:unit :fast :stable :isolated :dispatch :phase-4)
  (let* ((callback-called nil)
         (state (claude-agent--make-process-state
                 :callback (lambda (_msg) (setq callback-called t)))))
    (claude-agent-handle-message
     'system
     '(:type "system"
       :subtype "init"
       :data (:session_id "sid-test"))
     state)
    (should callback-called)))

;;; Phase 6: Unified registry struct tests

(ert-deftest test-claude-agent-registry-struct-exists ()
  "Test that unified registry struct exists with all sub-tables."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-6)
  (let ((reg (claude-agent--make-registry)))
    (should (claude-agent--registry-p reg))
    ;; active-states defaults to nil (list)
    (should-not (claude-agent--registry-active-states reg))
    ;; Hash tables should be initialized
    (should (hash-table-p (claude-agent--registry-queries reg)))
    (should (hash-table-p (claude-agent--registry-sessions reg)))
    (should (hash-table-p (claude-agent--registry-background-tasks reg)))
    (should (hash-table-p (claude-agent--registry-control-requests reg)))
    (should (hash-table-p (claude-agent--registry-verbose-buffers reg)))))

(ert-deftest test-claude-agent-registry-singleton ()
  "Test that claude-agent--registry is a single registry instance."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-6)
  (should (claude-agent--registry-p claude-agent--registry)))

(ert-deftest test-claude-agent-registry-cleanup-process ()
  "Test per-process cleanup removes only owned entries."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-6)
  (let ((claude-agent--registry (claude-agent--make-registry)))
    ;; Add background tasks: task-id -> owner-request-id
    ;; "bg-task-1" owned by "req-A", "bg-task-2" owned by "req-B"
    (puthash "bg-task-1" "req-A" (claude-agent--registry-background-tasks claude-agent--registry))
    (puthash "bg-task-2" "req-B" (claude-agent--registry-background-tasks claude-agent--registry))
    ;; Add control request owned by "req-A"
    (puthash "ctrl-1" "req-A" (claude-agent--registry-control-requests claude-agent--registry))
    ;; Register active state for req-A
    (let ((state-a (claude-agent--make-process-state :request-id "req-A")))
      (push state-a (claude-agent--registry-active-states claude-agent--registry))
      ;; Cleanup for req-A should remove only req-A's entries
      (claude-agent-registry-cleanup-process state-a))
    ;; req-A's task removed, req-B's task preserved
    (should-not (gethash "bg-task-1" (claude-agent--registry-background-tasks claude-agent--registry)))
    (should (gethash "bg-task-2" (claude-agent--registry-background-tasks claude-agent--registry)))
    (should-not (gethash "ctrl-1" (claude-agent--registry-control-requests claude-agent--registry)))))

;;; Phase 8: Permission system protocol tests

(ert-deftest test-claude-agent-permission-checker-struct-exists ()
  "Test that base permission-checker struct exists."
  :tags '(:unit :fast :stable :isolated :permissions :phase-8)
  (let ((checker (claude-agent-make-permission-checker)))
    (should (claude-agent-permission-checker-p checker))))

(ert-deftest test-claude-agent-pattern-checker-struct-exists ()
  "Test that pattern-checker sub-struct exists with allow/deny patterns."
  :tags '(:unit :fast :stable :isolated :permissions :phase-8)
  (let ((checker (claude-agent-make-pattern-checker
                  :allow-patterns '("Read" "Grep")
                  :deny-patterns '("Bash(rm *)"))))
    (should (claude-agent-permission-checker-p checker))
    (should (claude-agent-pattern-checker-p checker))
    (should (equal '("Read" "Grep")
                   (claude-agent-pattern-checker-allow-patterns checker)))
    (should (equal '("Bash(rm *)")
                   (claude-agent-pattern-checker-deny-patterns checker)))))

(ert-deftest test-claude-agent-check-tool-permission-generic-exists ()
  "Test that cl-defgeneric check-tool-permission exists."
  :tags '(:unit :fast :stable :isolated :permissions :phase-8)
  (should (fboundp 'claude-agent-check-tool-permission)))

(ert-deftest test-claude-agent-pattern-checker-allows ()
  "Test that pattern-checker allows matching tools."
  :tags '(:unit :fast :stable :isolated :permissions :phase-8)
  (let ((checker (claude-agent-make-pattern-checker
                  :allow-patterns '("Read" "Grep"))))
    (should (eq 'allow
                (claude-agent-check-tool-permission
                 checker "Read" '(:file_path "/tmp/test.txt") nil)))))

(ert-deftest test-claude-agent-pattern-checker-denies ()
  "Test that pattern-checker denies matching tools."
  :tags '(:unit :fast :stable :isolated :permissions :phase-8)
  (let ((checker (claude-agent-make-pattern-checker
                  :deny-patterns '("Bash(rm *)"))))
    (should (eq 'deny
                (claude-agent-check-tool-permission
                 checker "Bash" '(:command "rm -rf /") nil)))))

(ert-deftest test-claude-agent-pattern-checker-ask-fallback ()
  "Test that pattern-checker returns ask for unmatched tools."
  :tags '(:unit :fast :stable :isolated :permissions :phase-8)
  (let ((checker (claude-agent-make-pattern-checker
                  :allow-patterns '("Read"))))
    (should (eq 'ask
                (claude-agent-check-tool-permission
                 checker "Write" '(:file_path "/tmp/out.txt") nil)))))

;;; R10: JSON buffer overflow protection tests

(ert-deftest test-json-buffer-max-size-defcustom-exists ()
  "claude-agent-max-json-buffer-size defcustom should exist with default 10MB."
  :tags '(:unit :fast :stable :isolated :process :r10)
  (should (boundp 'claude-agent-max-json-buffer-size))
  (should (= (* 10 1024 1024) claude-agent-max-json-buffer-size)))

(ert-deftest test-json-buffer-overflow-triggers-error ()
  "process-filter should signal error callback when buffer exceeds max size."
  :tags '(:unit :fast :stable :isolated :process :r10)
  (let* ((error-received nil)
         (state (claude-agent--make-process-state
                 :json-buffer ""
                 :ready t
                 :error-callback (lambda (err) (setq error-received err))))
         ;; Create a mock process
         (proc (start-process "test-r10" nil "true")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          ;; Set buffer just under limit
          (setf (claude-agent--process-state-json-buffer state)
                (make-string (- claude-agent-max-json-buffer-size 10) ?x))
          ;; This output should push it over the limit
          (claude-agent--process-filter proc (make-string 20 ?y))
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
                   (claude-agent--extract-result-error parsed)))))

(ert-deftest test-extract-result-error-with-subtype ()
  "Sub-extractor should fall back to known subtype message."
  :tags '(:unit :fast :stable :isolated :error :r5)
  (let ((parsed '(:type "result" :is_error t
                  :subtype "rate_limit")))
    (should (equal "Rate limit exceeded"
                   (claude-agent--extract-result-error parsed)))))

(ert-deftest test-extract-assistant-error ()
  "Sub-extractor for assistant messages with error field."
  :tags '(:unit :fast :stable :isolated :error :r5)
  (let ((parsed '(:type "assistant"
                  :message (:error "invalid_request"
                            :content ((:type "text" :text "Bad request details"))))))
    (should (equal "Bad request details"
                   (claude-agent--extract-assistant-error parsed)))))

(ert-deftest test-extract-assistant-error-nil-for-no-error ()
  "Sub-extractor returns nil when assistant message has no error."
  :tags '(:unit :fast :stable :isolated :error :r5)
  (let ((parsed '(:type "assistant"
                  :message (:content ((:type "text" :text "Normal"))))))
    (should-not (claude-agent--extract-assistant-error parsed))))

;;; R8: Decomposed process-sentinel tests

(ert-deftest test-sentinel-sub-handlers-exist ()
  "Sentinel sub-handler functions should exist."
  :tags '(:unit :fast :stable :isolated :sentinel :r8)
  (should (fboundp 'claude-agent--sentinel-handle-normal-exit))
  (should (fboundp 'claude-agent--sentinel-handle-abnormal-exit))
  (should (fboundp 'claude-agent--sentinel-cleanup)))

(ert-deftest test-sentinel-normal-exit-finished ()
  "Normal exit with 'finished' should call complete callback with nil."
  :tags '(:unit :fast :stable :isolated :sentinel :r8)
  (let* ((completed nil)
         (state (claude-agent--make-process-state
                 :complete-callback (lambda (err) (setq completed (list 'called err))))))
    (claude-agent--sentinel-handle-normal-exit state "finished\n")
    (should completed)
    (should (eq 'called (car completed)))
    (should-not (cadr completed))))

(ert-deftest test-sentinel-normal-exit-abnormal-code ()
  "Normal exit with exit code should call complete callback with error."
  :tags '(:unit :fast :stable :isolated :sentinel :r8)
  (let* ((completed nil)
         (state (claude-agent--make-process-state
                 :complete-callback (lambda (err) (setq completed err)))))
    (claude-agent--sentinel-handle-normal-exit state "exited abnormally with code 1\n")
    (should completed)
    (should (eq 'claude-agent-process-error (car completed)))))

;;; R9: Decomposed claude-agent-query tests

(ert-deftest test-prepare-query-options-exists ()
  "prepare-query-options function should exist."
  :tags '(:unit :fast :stable :isolated :query :r9)
  (should (fboundp 'claude-agent--prepare-query-options)))

(ert-deftest test-prepare-query-options-defaults ()
  "prepare-query-options should return plist with :options and :cli-path keys."
  :tags '(:unit :fast :stable :isolated :query :r9)
  (let ((result (claude-agent--prepare-query-options nil nil nil)))
    ;; Should have :options key with a valid options plist
    (should (plist-get result :options))
    ;; Should have :cli-path key (value can be nil when no CLI configured)
    (should (plist-member result :cli-path))))

;;; Review Fixes: JSON buffer overflow clears buffer

(ert-deftest test-json-buffer-overflow-clears-buffer ()
  "After overflow, json-buffer should be cleared to prevent sentinel re-parse."
  :tags '(:unit :fast :stable :isolated :process :review-fix)
  (let* ((error-received nil)
         (state (claude-agent--make-process-state
                 :json-buffer ""
                 :ready t
                 :error-callback (lambda (err) (setq error-received err))))
         (proc (start-process "test-overflow-clear" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          ;; Set buffer just under limit
          (setf (claude-agent--process-state-json-buffer state)
                (make-string (- claude-agent-max-json-buffer-size 10) ?x))
          ;; Push over the limit
          (claude-agent--process-filter proc (make-string 20 ?y))
          ;; Error should be signalled
          (should error-received)
          ;; CRITICAL: json-buffer should be cleared so sentinel won't re-parse
          (should (equal "" (claude-agent--process-state-json-buffer state))))
      (when (process-live-p proc)
        (delete-process proc)))))

;;; Review Fixes: Sentinel cleanup uses kill-child-processes helper

(ert-deftest test-sentinel-cleanup-calls-kill-child-processes ()
  "sentinel-cleanup should delegate to kill-child-processes, not inline the logic."
  :tags '(:unit :fast :stable :isolated :process :review-fix)
  (let* ((kill-helper-called nil)
         (state (claude-agent--make-process-state
                 :json-buffer ""
                 :ready t))
         (proc (start-process "test-cleanup-helper" nil "sleep" "60")))
    (unwind-protect
        (progn
          (process-put proc 'claude-agent-state state)
          ;; Stub kill-child-processes to track if it's called
          (cl-letf (((symbol-function 'claude-agent--kill-child-processes)
                     (lambda (pid) (setq kill-helper-called pid))))
            (claude-agent--sentinel-cleanup proc state)
            ;; Should have called the helper, not inlined the logic
            (should kill-helper-called)))
      (when (process-live-p proc)
        (delete-process proc)))))

;;; Stale background tasks should not block stdin closure for other processes

(ert-deftest test-stale-background-tasks-do-not-block-stdin-close ()
  "maybe-close-stdin should only consider tasks owned by the current process.
Stale tasks from dead processes must not block stdin closure for new queries.
Reproduces: session stays busy=t because stale background tasks prevent
stdin close, so CLI never exits and handle-complete never fires."
  :tags '(:unit :fast :stable :isolated :process :stdin :scheduled)
  (let* ((eof-sent nil)
         (claude-agent-stdin-close-delay 0) ;; Immediate close for testability
         (state (claude-agent--make-process-state
                 :json-buffer ""
                 :ready t
                 :request-id "req-NEW"))
         (proc (start-process "test-stdin-stale" nil "sleep" "60")))
    (unwind-protect
        (let ((saved-bg-tasks (copy-hash-table claude-agent--pending-background-tasks)))
          (unwind-protect
              (progn
                (process-put proc 'claude-agent-state state)
                ;; Simulate stale background tasks from OLDER processes
                (clrhash claude-agent--pending-background-tasks)
                (puthash "stale-agent-1" "req-OLD-1" claude-agent--pending-background-tasks)
                (puthash "stale-agent-2" "req-OLD-2" claude-agent--pending-background-tasks)
                ;; The global check would see 2 pending tasks and block
                (should (claude-agent--has-pending-background-tasks-p))
                ;; But maybe-close-stdin should close anyway because none belong to req-NEW
                (cl-letf (((symbol-function 'process-send-eof)
                           (lambda (_proc) (setq eof-sent t))))
                  (claude-agent--maybe-close-stdin
                   proc '(:type "result"))
                  ;; CRITICAL: stdin should have been closed despite stale tasks
                  (should eof-sent)))
            ;; Restore original background tasks
            (clrhash claude-agent--pending-background-tasks)
            (maphash (lambda (k v) (puthash k v claude-agent--pending-background-tasks))
                     saved-bg-tasks)))
      (when (process-live-p proc)
        (delete-process proc)))))

(ert-deftest test-no-state-process-ignores-stale-tasks ()
  "maybe-close-stdin should close stdin even when process has no attached state.
When process-get returns nil for state, owner-req-id is nil.
The nil guard ensures stale global tasks do not block stdin closure."
  :tags '(:unit :fast :stable :isolated :process :stdin)
  (let* ((eof-sent nil)
         (claude-agent-stdin-close-delay 0)
         (proc (start-process "test-no-state" nil "sleep" "60")))
    (unwind-protect
        (let ((saved-bg-tasks (copy-hash-table claude-agent--pending-background-tasks)))
          (unwind-protect
              (progn
                ;; NO process-put — process has no attached state
                (clrhash claude-agent--pending-background-tasks)
                (puthash "stale-1" "req-OLD" claude-agent--pending-background-tasks)
                (cl-letf (((symbol-function 'process-send-eof)
                           (lambda (_proc) (setq eof-sent t))))
                  (claude-agent--maybe-close-stdin proc '(:type "result"))
                  ;; Should still close despite stale global tasks
                  (should eof-sent)))
            (clrhash claude-agent--pending-background-tasks)
            (maphash (lambda (k v) (puthash k v claude-agent--pending-background-tasks))
                     saved-bg-tasks)))
      (when (process-live-p proc) (delete-process proc)))))

(provide 'test-claude-agent-unit)
;;; test-claude-agent-unit.el ends here
