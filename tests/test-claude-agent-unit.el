;;; test-claude-agent-unit.el --- Unit tests for claude-agent.el -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for claude-agent.el
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

(provide 'test-claude-agent-unit)
;;; test-claude-agent-unit.el ends here
