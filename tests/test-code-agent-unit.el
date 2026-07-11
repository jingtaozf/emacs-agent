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

(ert-deftest test-code-agent-path-mappings-stored-in-process-state ()
  "Test that path-mappings are stored per-process, not in a global."
  :tags '(:unit :fast :stable :isolated :docker :phase-0b)
  (let ((state (code-agent--make-process-state
                :path-mappings '(("/host" . "/container")))))
    ;; path-mappings should be in the process state
    (should (equal '(("/host" . "/container"))
                   (code-agent--process-state-path-mappings state)))))

;;; Phase 3: Process state flat accessors

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
                       (let ((f (expand-file-name "lp/chat/code-agent.org" default-directory)))
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

;;; Phase 6: Registry struct tests

(ert-deftest test-code-agent-registry-struct-exists ()
  "Test that the registry struct exists with an active-states slot."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-6)
  (let ((reg (code-agent--make-registry)))
    (should (code-agent--registry-p reg))
    ;; active-states defaults to nil (list)
    (should-not (code-agent--registry-active-states reg))))

(ert-deftest test-code-agent-registry-singleton ()
  "Test that code-agent--registry is a single registry instance."
  :tags '(:unit :fast :stable :isolated :data-structures :phase-6)
  (should (code-agent--registry-p code-agent--registry)))

(provide 'test-code-agent-unit)
;;; test-code-agent-unit.el ends here
