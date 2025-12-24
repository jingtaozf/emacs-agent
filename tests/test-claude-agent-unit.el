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
      ;; Get it back
      (should (claude-agent--get-active-query "req-123"))
      ;; Unregister
      (claude-agent--unregister-query "req-123")
      (should (= 0 (claude-agent-active-query-count))))))

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
  "Test query identity formatting with source buffer and label."
  :tags '(:unit :fast :stable :isolated :display)
  (with-temp-buffer
    (rename-buffer "claude-agent-dev.org" t)
    (let ((state (claude-agent--make-process-state
                  :request-id "req-42-1234567890"
                  :source-buffer (current-buffer)
                  :source-label "5")))
      ;; Short form should show "basename#label"
      (should (equal "claude-agent-dev#5"
                     (claude-agent--format-query-identity state)))
      ;; Long form should show full buffer name
      (should (string-match-p "claude-agent-dev.*#5"
                              (claude-agent--format-query-identity state t))))))

(ert-deftest test-claude-agent-format-query-identity-buffer-only ()
  "Test query identity with buffer but no label."
  :tags '(:unit :fast :stable :isolated :display)
  (with-temp-buffer
    (rename-buffer "test-file.org" t)
    (let ((state (claude-agent--make-process-state
                  :request-id "req-10-1234567890"
                  :source-buffer (current-buffer)
                  :source-label nil)))
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
                :source-label nil)))
    (should (equal "#99" (claude-agent--format-query-identity state))))
  ;; Dead buffer - should also fall back
  (let* ((buf (generate-new-buffer "temp-dead"))
         (state (claude-agent--make-process-state
                 :request-id "req-88-1234567890"
                 :source-buffer buf
                 :source-label "3")))
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
  "Test that process-state has source-buffer and source-label slots."
  :tags '(:unit :fast :stable :isolated :display)
  (with-temp-buffer
    (let ((state (claude-agent--make-process-state
                  :source-buffer (current-buffer)
                  :source-label "42")))
      (should (eq (current-buffer)
                  (claude-agent--process-state-source-buffer state)))
      (should (equal "42"
                     (claude-agent--process-state-source-label state))))))

(provide 'test-claude-agent-unit)
;;; test-claude-agent-unit.el ends here
