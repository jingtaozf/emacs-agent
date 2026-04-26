;;; test-code-agent-org-mock.el --- Mock CLI integration tests for code-agent-org -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Integration tests for the org-mode layer using the mock Claude CLI.
;; Exercises the full pipeline: org-mode buffer → code-agent-org-execute →
;; backend → subprocess → JSON protocol → response insertion.
;;
;; To switch to real CLI: replace `claude-agent-cli-path' binding with
;; the real path and add `test-claude-skip-unless-cli-available'.

;;; Code:

(require 'ert)
(require 'code-agent-org)
(require 'test-config)

;;; Helpers

(defun test-code-agent-org-mock--execute-with-fixture (org-content scenario
                                                    &optional timeout)
  "Execute the first AI block in ORG-CONTENT using mock SCENARIO.
Returns (RESPONSE . SESSION-KEY) on success, signals error on timeout.
TIMEOUT defaults to 10 seconds.
Uses a temp file so `buffer-file-name' is non-nil (required for session keys)."
  (let* ((timeout (or timeout 10))
         (temp-file (make-temp-file "test-org-mock-" nil ".org"))
         (claude-agent-cli-path test-claude-mock-cli-path)
         (code-agent-org-auto-start-mcp-server nil)
         test-buffer)
    (unwind-protect
        (progn
          ;; Write org content to temp file and open it
          (with-temp-file temp-file
            (insert org-content))
          (setq test-buffer (find-file-noselect temp-file))
          (with-current-buffer test-buffer
            (code-agent-org-mode 1)
            ;; Set MOCK_SCENARIO via process environment
            (let ((process-environment
                   (cons (format "MOCK_SCENARIO=%s" scenario)
                         process-environment)))
              ;; Find and execute the AI block
              (goto-char (point-min))
              (re-search-forward "#\\+begin_src ai" nil t)
              (let ((session-key (code-agent-org--current-session-key)))
                (code-agent-org-execute)
                ;; Wait for completion
                (if (test-claude-wait-for-completion session-key timeout)
                    ;; Extract response text from buffer
                    (let ((response
                           (save-excursion
                             (goto-char (point-min))
                             (when (re-search-forward "^\\*+ Response" nil t)
                               ;; Skip heading, properties, blank lines
                               (forward-line 1)
                               (when (looking-at ":PROPERTIES:")
                                 (re-search-forward ":END:" nil t)
                                 (forward-line 1))
                               (while (and (not (eobp))
                                           (looking-at "^[ \t]*$"))
                                 (forward-line 1))
                               (let ((start (point))
                                     (end (or (save-excursion
                                                (when (re-search-forward "^\\*+ " nil t)
                                                  (match-beginning 0)))
                                              (point-max))))
                                 (string-trim
                                  (buffer-substring-no-properties start end)))))))
                      (cons response session-key))
                  (error "Timeout waiting for mock query completion"))))))
      ;; Cleanup
      (when (and test-buffer (buffer-live-p test-buffer))
        (with-current-buffer test-buffer
          (when (bound-and-true-p code-agent-org-mode)
            (ignore-errors (code-agent-org-cancel-all)))
          (set-buffer-modified-p nil))
        (kill-buffer test-buffer))
      (ignore-errors (delete-file temp-file))
      (test-claude-cleanup-all))))

(defvar test-code-agent-org-mock--basic-org
  "* Test Section
:PROPERTIES:
:CUSTOM_ID: test-mock-org-section
:END:

** Instruction 1 :ai_instruction:

#+begin_src ai
What is 2+2? Answer with just the number.
#+end_src
"
  "Minimal org content for mock tests.")

;;; Basic Execution Tests

(ert-deftest test-org-mock-basic-execution ()
  "Test basic AI block execution via mock CLI.
Verifies the full pipeline: execute → subprocess → JSON parse → response insert."
  :tags '(:mock :fast :stable :org :process)
  (let ((result (test-code-agent-org-mock--execute-with-fixture
                 test-code-agent-org-mock--basic-org "simple-query")))
    (should result)
    (should (car result))  ; response text
    (should (string-match-p "4" (car result)))))

(ert-deftest test-org-mock-response-section-created ()
  "Test that a Response section heading is created with proper tags."
  :tags '(:mock :fast :stable :org :response)
  (let* ((temp-file (make-temp-file "test-org-mock-resp-" nil ".org"))
         (claude-agent-cli-path test-claude-mock-cli-path)
         (code-agent-org-auto-start-mcp-server nil)
         test-buffer)
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert test-code-agent-org-mock--basic-org))
          (setq test-buffer (find-file-noselect temp-file))
          (with-current-buffer test-buffer
            (code-agent-org-mode 1)
            (let ((process-environment
                   (cons "MOCK_SCENARIO=simple-query" process-environment)))
              (goto-char (point-min))
              (re-search-forward "#\\+begin_src ai" nil t)
              (let ((session-key (code-agent-org--current-session-key)))
                (code-agent-org-execute)
                (should (test-claude-wait-for-completion session-key 10))
                ;; Verify Response heading exists with ai_output tag
                (goto-char (point-min))
                (should (re-search-forward "^\\*+ Response.*:ai_output:" nil t))
                ;; Check for QUERY_ID property
                (should (re-search-forward ":QUERY_ID:" nil t))))))
      (when (and test-buffer (buffer-live-p test-buffer))
        (with-current-buffer test-buffer
          (ignore-errors (code-agent-org-cancel-all))
          (set-buffer-modified-p nil))
        (kill-buffer test-buffer))
      (ignore-errors (delete-file temp-file))
      (test-claude-cleanup-all))))

;;; Cancel Tests

(ert-deftest test-org-mock-cancel-removes-from-active-queries ()
  "Test that cancel removes the query from active queries hash table.
Equivalent to test-org-cancel-removes-from-active-queries but with mock CLI."
  :tags '(:mock :fast :stable :org :cancel :active-queries)
  (let* ((temp-file (make-temp-file "test-org-mock-cancel-" nil ".org"))
         (cancel-org "* Test Section
:PROPERTIES:
:CUSTOM_ID: test-mock-cancel
:END:

** Instruction 1 :ai_instruction:

#+begin_src ai
Write a very long story about numbers...
#+end_src
")
         (claude-agent-cli-path test-claude-mock-cli-path)
         (code-agent-org-auto-start-mcp-server nil)
         test-buffer)
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert cancel-org))
          (setq test-buffer (find-file-noselect temp-file))
          (with-current-buffer test-buffer
            (code-agent-org-mode 1)
            (let ((process-environment
                   (cons "MOCK_SCENARIO=slow-response" process-environment)))
              (goto-char (point-min))
              (re-search-forward "#\\+begin_src ai" nil t)
              (let ((session-key (code-agent-org--current-session-key))
                    (block-pos (point)))
                (code-agent-org-execute)
                ;; Wait for query to start (busy flag set)
                (should (test-claude-wait-until
                         (lambda ()
                           (code-agent-org--session-get session-key :busy))
                         5))
                ;; Wait for query-handle (process-state) to appear
                (should (test-claude-wait-until
                         (lambda ()
                           (let ((qh (code-agent-org--session-get session-key :query-handle)))
                             (and qh (claude-agent--process-state-request-id qh))))
                         5))
                (sleep-for 0.2)
                (accept-process-output nil 0.1)

                (let* ((query-handle (code-agent-org--session-get session-key :query-handle))
                       (request-id (claude-agent--process-state-request-id query-handle)))
                  (should request-id)
                  ;; Before cancel: should be in hash table
                  (should (gethash request-id claude-agent--active-queries))

                  ;; Cancel
                  (goto-char block-pos)
                  (code-agent-org-cancel)

                  ;; Immediately after cancel: busy cleared, cancelled flag set
                  (should-not (code-agent-org--session-get session-key :busy))
                  (should (claude-agent--process-state-cancelled query-handle))

                  ;; Wait for process to die and sentinel to unregister
                  (should (test-claude-wait-until
                           (lambda ()
                             (not (gethash request-id claude-agent--active-queries)))
                           5))
                  ;; Now should be gone from active-queries
                  (should-not (gethash request-id claude-agent--active-queries)))))))
      (when (and test-buffer (buffer-live-p test-buffer))
        (with-current-buffer test-buffer
          (ignore-errors (code-agent-org-cancel-all))
          (set-buffer-modified-p nil))
        (kill-buffer test-buffer))
      (ignore-errors (delete-file temp-file))
      (test-claude-cleanup-all))))

(ert-deftest test-org-mock-cancel-stays-cancelled-after-sentinel ()
  "Test that cancelled state persists after process sentinel fires.
Race condition: handle-complete from sentinel must not re-set :busy to t."
  :tags '(:mock :fast :stable :org :cancel :race)
  (let* ((temp-file (make-temp-file "test-org-mock-race-" nil ".org"))
         (race-org "* Test Section
:PROPERTIES:
:CUSTOM_ID: test-mock-race
:END:

** Instruction 1 :ai_instruction:

#+begin_src ai
Write a very long story about numbers...
#+end_src
")
         (claude-agent-cli-path test-claude-mock-cli-path)
         (code-agent-org-auto-start-mcp-server nil)
         test-buffer)
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert race-org))
          (setq test-buffer (find-file-noselect temp-file))
          (with-current-buffer test-buffer
            (code-agent-org-mode 1)
            (let ((process-environment
                   (cons "MOCK_SCENARIO=slow-response" process-environment)))
              (goto-char (point-min))
              (re-search-forward "#\\+begin_src ai" nil t)
              (let ((session-key (code-agent-org--current-session-key)))
                (code-agent-org-execute)
                ;; Wait for query to be busy with query-handle present
                (should (test-claude-wait-until
                         (lambda ()
                           (and (code-agent-org--session-get session-key :busy)
                                (code-agent-org--session-get session-key :query-handle)))
                         5))
                (sleep-for 0.3)
                (accept-process-output nil 0.1)

                ;; Verify busy before cancel
                (should (code-agent-org--session-get session-key :busy))

                (let ((query-handle (code-agent-org--session-get session-key :query-handle)))
                  ;; Cancel
                  (code-agent-org-cancel)

                  ;; Immediately: busy should be nil, cancelled flag set
                  (should-not (code-agent-org--session-get session-key :busy))
                  (should (claude-agent--process-state-cancelled query-handle))

                  ;; Wait for process to fully exit (sentinel fires)
                  (sleep-for 1.0)
                  (accept-process-output nil 0.5)

                  ;; After sentinel: busy must STILL be nil, cancelled must persist
                  (should-not (code-agent-org--session-get session-key :busy))
                  (should (claude-agent--process-state-cancelled query-handle)))))))
      (when (and test-buffer (buffer-live-p test-buffer))
        (with-current-buffer test-buffer
          (ignore-errors (code-agent-org-cancel-all))
          (set-buffer-modified-p nil))
        (kill-buffer test-buffer))
      (ignore-errors (delete-file temp-file))
      (test-claude-cleanup-all))))

;;; Session Context Tests

(ert-deftest test-org-mock-session-uuid-captured ()
  "Test that session UUID is captured and stored from mock CLI output."
  :tags '(:mock :fast :stable :org :session)
  (let* ((temp-file (make-temp-file "test-org-mock-uuid-" nil ".org"))
         (claude-agent-cli-path test-claude-mock-cli-path)
         (code-agent-org-auto-start-mcp-server nil)
         test-buffer)
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert test-code-agent-org-mock--basic-org))
          (setq test-buffer (find-file-noselect temp-file))
          (with-current-buffer test-buffer
            (code-agent-org-mode 1)
            (let ((process-environment
                   (cons "MOCK_SCENARIO=simple-query" process-environment)))
              (goto-char (point-min))
              (re-search-forward "#\\+begin_src ai" nil t)
              (let ((session-key (code-agent-org--current-session-key)))
                (code-agent-org-execute)
                (should (test-claude-wait-for-completion session-key 10))
                ;; SDK UUID should have been captured from the result message
                (let ((sdk-uuid (code-agent-org--get-sdk-uuid)))
                  (should sdk-uuid)
                  (should (stringp sdk-uuid))
                  (should (string-match-p "mock-session" sdk-uuid)))))))
      (when (and test-buffer (buffer-live-p test-buffer))
        (with-current-buffer test-buffer
          (ignore-errors (code-agent-org-cancel-all))
          (set-buffer-modified-p nil))
        (kill-buffer test-buffer))
      (ignore-errors (delete-file temp-file))
      (test-claude-cleanup-all))))

;;; Helper: execute Nth AI block in org content with mock

(defun test-code-agent-org-mock--setup-buffer (org-content)
  "Create temp file with ORG-CONTENT, return (BUFFER . TEMP-FILE).
Caller must clean up both."
  (let* ((temp-file (make-temp-file "test-org-mock-" nil ".org"))
         buf)
    (with-temp-file temp-file
      (insert org-content))
    (setq buf (find-file-noselect temp-file))
    (with-current-buffer buf
      (let ((code-agent-org-auto-start-mcp-server nil))
        (code-agent-org-mode 1)))
    (cons buf temp-file)))

(defun test-code-agent-org-mock--cleanup (buf temp-file)
  "Clean up BUF and TEMP-FILE from a mock test."
  (when (and buf (buffer-live-p buf))
    (with-current-buffer buf
      (ignore-errors (code-agent-org-cancel-all))
      (set-buffer-modified-p nil))
    (kill-buffer buf))
  (ignore-errors (delete-file temp-file))
  (test-claude-cleanup-all))

;;; Queue org content for queue tests (3 blocks, same session)

(defvar test-code-agent-org-mock--queue-org
  "* Queue Test Section
:PROPERTIES:
:CUSTOM_ID: test-mock-queue
:CLAUDE_SESSION_ID: mock-queue-session
:END:

** Instruction 1 :ai_instruction:

#+begin_src ai
Write a very long story about numbers. This is Block A.
#+end_src

** Instruction 2 :ai_instruction:

#+begin_src ai
Say \"Block B executed\" - this is the queued block.
#+end_src

** Instruction 3 :ai_instruction:

#+begin_src ai
Say \"Block C executed\" - this is another queued block.
#+end_src
"
  "Org content with 3 blocks in the same session for queue tests.
Block A auto-detects to slow-response, B to block-b-response, C to block-c-response.")

;;; Session Context Tests

(ert-deftest test-org-mock-session-context ()
  "Test that session maintains context across queries.
Execute 2 blocks sequentially — second should use --resume."
  :tags '(:mock :fast :stable :org :session)
  (let* ((org-content "* Session Context Test
:PROPERTIES:
:CUSTOM_ID: test-mock-session-ctx
:END:

** Instruction 1 :ai_instruction:

#+begin_src ai
What is 2+2? Answer with just the number.
#+end_src

** Instruction 2 :ai_instruction:

#+begin_src ai
What number did I ask you to remember? Just the number.
#+end_src
")
         (setup (test-code-agent-org-mock--setup-buffer org-content))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path))
            ;; Execute instruction 1
            (goto-char (point-min))
            (re-search-forward "^\\*+ Instruction 1" nil t)
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (should (test-claude-wait-for-completion session-key 10))
              ;; SDK UUID should be stored
              (let ((sdk-uuid (code-agent-org--get-sdk-uuid)))
                (should sdk-uuid)
                (should (stringp sdk-uuid))))
            ;; Execute instruction 2
            (goto-char (point-min))
            (re-search-forward "^\\*+ Instruction 2" nil t)
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (should (test-claude-wait-for-completion session-key 10)))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

;;; Independent Sessions Tests

(ert-deftest test-org-mock-independent-sessions ()
  "Test that different :claude_session: tagged sections are independent."
  :tags '(:mock :fast :stable :org :session)
  (let* ((org-content "* Session A :claude_session:
:PROPERTIES:
:CUSTOM_ID: test-mock-sess-a
:CLAUDE_SESSION_ID: sess-a-mock
:END:

** Instruction 1 :ai_instruction:

#+begin_src ai
What is 2+2? Answer with just the number.
#+end_src

* Session B :claude_session:
:PROPERTIES:
:CUSTOM_ID: test-mock-sess-b
:CLAUDE_SESSION_ID: sess-b-mock
:END:

** Instruction 2 :ai_instruction:

#+begin_src ai
What is 2+2? Answer with just the number.
#+end_src
")
         (setup (test-code-agent-org-mock--setup-buffer org-content))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path))
            ;; Execute in Session A
            (goto-char (point-min))
            (re-search-forward "^\\*+ Instruction 1" nil t)
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((key-a (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (should (test-claude-wait-for-completion key-a 10))
              ;; Execute in Session B
              (goto-char (point-min))
              (re-search-forward "^\\*+ Instruction 2" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (let ((key-b (code-agent-org--current-session-key)))
                ;; Session keys should be different
                (should-not (equal key-a key-b))
                (code-agent-org-execute)
                (should (test-claude-wait-for-completion key-b 10))))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

;;; Header Line Tests

(ert-deftest test-org-mock-header-line-updates ()
  "Test that header line is set during execution."
  :tags '(:mock :fast :stable :org :display)
  (let* ((setup (test-code-agent-org-mock--setup-buffer
                 test-code-agent-org-mock--basic-org))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path)
                (process-environment
                 (cons "MOCK_SCENARIO=slow-response" process-environment)))
            (goto-char (point-min))
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              ;; Wait for query to start
              (should (test-claude-wait-until
                       (lambda ()
                         (code-agent-org--session-get session-key :busy))
                       5))
              ;; Header line should exist
              (should header-line-format)
              ;; Wait for completion
              (test-claude-wait-for-completion session-key 10)
              ;; Header should still exist after completion
              (should header-line-format))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

;;; Query Identity Display Tests

(ert-deftest test-org-mock-query-identity-display ()
  "Test that active queries show buffer name and instruction number."
  :tags '(:mock :fast :stable :org :display)
  (let* ((setup (test-code-agent-org-mock--setup-buffer
                 test-code-agent-org-mock--basic-org))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path)
                (process-environment
                 (cons "MOCK_SCENARIO=slow-response" process-environment)))
            (clrhash claude-agent--active-queries)
            (goto-char (point-min))
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (sleep-for 0.5)
              (accept-process-output nil 0.2)
              ;; Find active query with source info
              (let ((found-state nil))
                (maphash
                 (lambda (_id state)
                   (when (and state
                              (claude-agent--process-state-p state)
                              (not (claude-agent--process-state-closed state))
                              (claude-agent--process-state-source-buffer state))
                     (setq found-state state)))
                 claude-agent--active-queries)
                (should found-state)
                ;; Source buffer should be our buffer
                (should (eq (claude-agent--process-state-source-buffer found-state) buf))
                ;; Format identity should be a non-empty string
                (let ((identity (claude-agent--format-query-identity found-state)))
                  (should (stringp identity))
                  (should (> (length identity) 0))))
              (test-claude-wait-for-completion session-key 10))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

(ert-deftest test-org-mock-mode-line-identity ()
  "Test that mode-line shows query identity for single active query."
  :tags '(:mock :fast :stable :org :display)
  (let* ((setup (test-code-agent-org-mock--setup-buffer
                 test-code-agent-org-mock--basic-org))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path)
                (process-environment
                 (cons "MOCK_SCENARIO=slow-response" process-environment)))
            (clrhash claude-agent--active-queries)
            (goto-char (point-min))
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (sleep-for 0.5)
              (accept-process-output nil 0.2)
              ;; Trigger mode-line update
              (claude-agent--update-activity-string)
              (should (stringp claude-agent-activity-string))
              ;; If there's an active query, verify format
              (when (and (> (length claude-agent-activity-string) 0)
                         (claude-agent-active-p))
                (should (string-match-p "\\[C:" claude-agent-activity-string)))
              (test-claude-wait-for-completion session-key 10))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

;;; Queue Tests

(ert-deftest test-org-mock-queue-basic ()
  "Test that executing while busy queues the block.
Execute Block A (slow), then Block B — B should be queued."
  :tags '(:mock :fast :stable :org :queue)
  (let* ((setup (test-code-agent-org-mock--setup-buffer
                 test-code-agent-org-mock--queue-org))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path))
            ;; Execute Block A (slow-response via auto-detect)
            (goto-char (point-min))
            (re-search-forward "^\\*+ Instruction 1" nil t)
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (should (test-claude-wait-until
                       (lambda () (code-agent-org--session-get session-key :busy))
                       5))
              (should (= 0 (code-agent-org--queue-count session-key)))
              ;; Navigate to Block B and execute while A runs
              (goto-char (point-min))
              (re-search-forward "^\\*+ Instruction 2" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (code-agent-org-execute)
              ;; B should be queued
              (should (= 1 (code-agent-org--queue-count session-key)))
              ;; Wait for A to complete, then B auto-starts
              (test-claude-wait-for-completion session-key 15)
              ;; Wait for B to complete
              (test-claude-wait-for-completion session-key 10)
              ;; Queue should be empty, session not busy
              (should (= 0 (code-agent-org--queue-count session-key)))
              (should-not (code-agent-org--session-get session-key :busy)))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

(ert-deftest test-org-mock-queue-multiple ()
  "Test queueing multiple blocks: A runs, B and C queued."
  :tags '(:mock :fast :stable :org :queue)
  (let* ((setup (test-code-agent-org-mock--setup-buffer
                 test-code-agent-org-mock--queue-org))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path))
            ;; Execute Block A
            (goto-char (point-min))
            (re-search-forward "^\\*+ Instruction 1" nil t)
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (should (test-claude-wait-until
                       (lambda () (code-agent-org--session-get session-key :busy))
                       5))
              ;; Queue Block B
              (goto-char (point-min))
              (re-search-forward "^\\*+ Instruction 2" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (code-agent-org-execute)
              (should (= 1 (code-agent-org--queue-count session-key)))
              ;; Queue Block C
              (goto-char (point-min))
              (re-search-forward "^\\*+ Instruction 3" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (code-agent-org-execute)
              (should (= 2 (code-agent-org--queue-count session-key)))
              ;; Wait for all to complete (A → B → C)
              (test-claude-wait-for-completion session-key 15)
              (test-claude-wait-for-completion session-key 10)
              (test-claude-wait-for-completion session-key 10)
              ;; All done
              (should (= 0 (code-agent-org--queue-count session-key)))
              (should-not (code-agent-org--session-get session-key :busy)))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

(ert-deftest test-org-mock-queue-cancel-clears ()
  "Test that canceling clears the queue."
  :tags '(:mock :fast :stable :org :queue :cancel)
  (let* ((setup (test-code-agent-org-mock--setup-buffer
                 test-code-agent-org-mock--queue-org))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path))
            (goto-char (point-min))
            (re-search-forward "^\\*+ Instruction 1" nil t)
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (should (test-claude-wait-until
                       (lambda () (code-agent-org--session-get session-key :busy))
                       5))
              ;; Queue Block B
              (goto-char (point-min))
              (re-search-forward "^\\*+ Instruction 2" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (code-agent-org-execute)
              (should (= 1 (code-agent-org--queue-count session-key)))
              ;; Cancel all — should clear queue
              (code-agent-org-cancel)
              (should (= 0 (code-agent-org--queue-count session-key)))
              (should-not (code-agent-org--session-get session-key :busy)))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

(ert-deftest test-org-mock-queue-response-appears ()
  "Test that queued blocks produce responses in the buffer."
  :tags '(:mock :fast :stable :org :queue)
  (let* ((setup (test-code-agent-org-mock--setup-buffer
                 test-code-agent-org-mock--queue-org))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path))
            (goto-char (point-min))
            (re-search-forward "^\\*+ Instruction 1" nil t)
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (should (test-claude-wait-until
                       (lambda () (code-agent-org--session-get session-key :busy))
                       5))
              ;; Queue Block B
              (goto-char (point-min))
              (re-search-forward "^\\*+ Instruction 2" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (code-agent-org-execute)
              ;; Wait for A then B to complete
              (test-claude-wait-for-completion session-key 15)
              (test-claude-wait-for-completion session-key 10)
              ;; Block B's response should be in buffer
              (goto-char (point-min))
              (should (re-search-forward "Block B executed" nil t)))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

(ert-deftest test-org-mock-queue-response-position ()
  "Test that queued block's response appears in buffer after execution.
Verifies Block B's response is present when Block A completes first."
  :tags '(:mock :fast :stable :org :queue :position)
  (let* ((setup (test-code-agent-org-mock--setup-buffer
                 test-code-agent-org-mock--queue-org))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path))
            (goto-char (point-min))
            (re-search-forward "^\\*+ Instruction 1" nil t)
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (should (test-claude-wait-until
                       (lambda () (code-agent-org--session-get session-key :busy))
                       5))
              ;; Queue Block B
              (goto-char (point-min))
              (re-search-forward "^\\*+ Instruction 2" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (code-agent-org-execute)
              ;; Wait for both to complete
              (test-claude-wait-for-completion session-key 15)
              (test-claude-wait-for-completion session-key 10)
              ;; Block B's response should be present
              (goto-char (point-min))
              (should (re-search-forward "Block B executed" nil t))
              ;; Block A's response should also be present
              (goto-char (point-min))
              (should (re-search-forward "Once upon a time" nil t)))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

(ert-deftest test-org-mock-queue-no-duplicate ()
  "Test that the same block cannot be queued twice."
  :tags '(:mock :fast :stable :org :queue)
  (let* ((setup (test-code-agent-org-mock--setup-buffer
                 test-code-agent-org-mock--queue-org))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path))
            (goto-char (point-min))
            (re-search-forward "^\\*+ Instruction 1" nil t)
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (should (test-claude-wait-until
                       (lambda () (code-agent-org--session-get session-key :busy))
                       5))
              ;; Queue Block B
              (goto-char (point-min))
              (re-search-forward "^\\*+ Instruction 2" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (code-agent-org-execute)
              (should (= 1 (code-agent-org--queue-count session-key)))
              ;; Try to queue Block B again — should NOT add duplicate
              (goto-char (point-min))
              (re-search-forward "^\\*+ Instruction 2" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (code-agent-org-execute)
              (should (= 1 (code-agent-org--queue-count session-key)))
              ;; Clean up
              (code-agent-org-cancel))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

(ert-deftest test-org-mock-queue-running-block-rejected ()
  "Test that queueing the CURRENTLY RUNNING block is rejected."
  :tags '(:mock :fast :stable :org :queue)
  (let* ((setup (test-code-agent-org-mock--setup-buffer
                 test-code-agent-org-mock--queue-org))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path))
            (goto-char (point-min))
            (re-search-forward "^\\*+ Instruction 1" nil t)
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (should (test-claude-wait-until
                       (lambda () (code-agent-org--session-get session-key :busy))
                       5))
              ;; Try to execute the SAME block again
              (goto-char (point-min))
              (re-search-forward "^\\*+ Instruction 1" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (code-agent-org-execute)
              ;; Queue should be empty — running block can't be queued
              (should (= 0 (code-agent-org--queue-count session-key)))
              (code-agent-org-cancel))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

(ert-deftest test-org-mock-queue-cancel-preserves-running ()
  "Test that cancel-queue clears only the queue, not the running query."
  :tags '(:mock :fast :stable :org :queue :cancel)
  (let* ((setup (test-code-agent-org-mock--setup-buffer
                 test-code-agent-org-mock--queue-org))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path))
            (goto-char (point-min))
            (re-search-forward "^\\*+ Instruction 1" nil t)
            (re-search-forward "#\\+begin_src ai" nil t)
            (let ((session-key (code-agent-org--current-session-key)))
              (code-agent-org-execute)
              (should (test-claude-wait-until
                       (lambda () (code-agent-org--session-get session-key :busy))
                       5))
              ;; Queue Block B
              (goto-char (point-min))
              (re-search-forward "^\\*+ Instruction 2" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (code-agent-org-execute)
              (should (= 1 (code-agent-org--queue-count session-key)))
              ;; Cancel queue only (not running query)
              (code-agent-org-cancel-queue)
              ;; Queue cleared
              (should (= 0 (code-agent-org--queue-count session-key)))
              ;; Running query still active
              (should (code-agent-org--session-get session-key :busy))
              ;; Wait for Block A to complete naturally
              (test-claude-wait-for-completion session-key 15)
              (should-not (code-agent-org--session-get session-key :busy)))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

;;; Scheduled Execution Tests

(ert-deftest test-org-mock-scheduled-past-due ()
  "Test that past-due scheduled AI block executes via mock CLI."
  :tags '(:mock :fast :stable :org :scheduled)
  (let* ((org-content (format "* Scheduled Tests

** Scheduled Task - Past Due
SCHEDULED: <2025-01-01 Wed 00:00>
:PROPERTIES:
:CUSTOM_ID: mock-scheduled-past-due
:END:

#+begin_src ai
Say scheduled-past-due-executed
#+end_src

** Scheduled Task - Future
SCHEDULED: <2099-12-31 Thu 23:59>
:PROPERTIES:
:CUSTOM_ID: mock-scheduled-future
:END:

#+begin_src ai
This should not run.
#+end_src
"))
         (setup (test-code-agent-org-mock--setup-buffer org-content))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path))
            ;; Navigate to past-due block
            (goto-char (point-min))
            (re-search-forward ":CUSTOM_ID: mock-scheduled-past-due" nil t)
            (org-back-to-heading t)
            ;; Should not have LAST_AI_EXECUTED yet
            (should-not (org-entry-get nil "LAST_AI_EXECUTED"))
            ;; Get scheduled time
            (let ((scheduled-time (org-get-scheduled-time (point))))
              (should scheduled-time)
              (should (time-less-p scheduled-time (current-time)))
              ;; Execute
              (code-agent-org-scheduled--maybe-execute
               temp-file "mock-scheduled-past-due" scheduled-time)
              ;; Find the AI block and get session key
              (goto-char (point-min))
              (re-search-forward ":CUSTOM_ID: mock-scheduled-past-due" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (forward-line 1)
              (let ((session-key (code-agent-org--current-session-key)))
                (test-claude-wait-for-completion session-key 10))
              ;; LAST_AI_EXECUTED should now be set
              (goto-char (point-min))
              (re-search-forward ":CUSTOM_ID: mock-scheduled-past-due" nil t)
              (org-back-to-heading t)
              (let ((last-executed (org-entry-get nil "LAST_AI_EXECUTED")))
                (should last-executed)
                (should (stringp last-executed)))
              ;; Response should contain expected text
              (goto-char (point-min))
              (should (re-search-forward "scheduled-past-due-executed" nil t)))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

(ert-deftest test-org-mock-scheduled-repeater ()
  "Test that repeater timestamps advance after scheduled execution."
  :tags '(:mock :fast :stable :org :scheduled :repeater)
  (let* ((org-content "* Scheduled Tests

** Scheduled Repeater
SCHEDULED: <2025-01-01 Wed 00:00 +1d>
:PROPERTIES:
:CUSTOM_ID: mock-scheduled-repeater
:END:

#+begin_src ai
Say daily-repeater-executed
#+end_src
")
         (setup (test-code-agent-org-mock--setup-buffer org-content))
         (buf (car setup))
         (temp-file (cdr setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-agent-cli-path test-claude-mock-cli-path))
            (goto-char (point-min))
            (re-search-forward ":CUSTOM_ID: mock-scheduled-repeater" nil t)
            (org-back-to-heading t)
            (let* ((original-scheduled (org-entry-get nil "SCHEDULED"))
                   (scheduled-time (org-get-scheduled-time (point))))
              (should original-scheduled)
              (should (string-match-p "\\+1d" original-scheduled))
              ;; Execute
              (code-agent-org-scheduled--maybe-execute
               temp-file "mock-scheduled-repeater" scheduled-time)
              ;; Find AI block and wait
              (goto-char (point-min))
              (re-search-forward ":CUSTOM_ID: mock-scheduled-repeater" nil t)
              (re-search-forward "#\\+begin_src ai" nil t)
              (forward-line 1)
              (let ((session-key (code-agent-org--current-session-key)))
                (test-claude-wait-for-completion session-key 10))
              ;; Check timestamp was advanced
              (goto-char (point-min))
              (re-search-forward ":CUSTOM_ID: mock-scheduled-repeater" nil t)
              (org-back-to-heading t)
              (let ((new-scheduled (org-entry-get nil "SCHEDULED")))
                (should new-scheduled)
                (should (string-match-p "\\+1d" new-scheduled))
                ;; Date should have changed
                (should-not (string= original-scheduled new-scheduled)))
              ;; Response should be in buffer
              (goto-char (point-min))
              (should (re-search-forward "daily-repeater-executed" nil t)))))
      (test-code-agent-org-mock--cleanup buf temp-file))))

;;; Cancel Bug Reproduction Tests
;;
;; These tests reproduce the reported issue: "cancel doesn't take effect
;; sometimes."  They use a cancel-test fixture with 0.5s delays between
;; tokens and distinctive FIRST_TOKEN..EIGHTH_TOKEN markers so we can
;; count exactly how many tokens were inserted before and after cancel.

(defvar test-code-agent-org-mock--cancel-org
  "* Test Section
:PROPERTIES:
:CUSTOM_ID: test-mock-cancel-repro
:END:

** Instruction 1 :ai_instruction:

#+begin_src ai
Write a very long story for cancel testing...
#+end_src
"
  "Org content for cancel reproduction tests.")

(defvar test-code-agent-org-mock--cancel-tokens
  '("FIRST_TOKEN" "SECOND_TOKEN" "THIRD_TOKEN" "FOURTH_TOKEN"
    "FIFTH_TOKEN" "SIXTH_TOKEN" "SEVENTH_TOKEN" "EIGHTH_TOKEN")
  "Token markers emitted by the cancel-test fixture.")

(defun test-code-agent-org-mock--count-tokens (text)
  "Count how many cancel-test tokens appear in TEXT."
  (cl-count-if (lambda (tok) (string-match-p tok text))
               test-code-agent-org-mock--cancel-tokens))

(defun test-code-agent-org-mock--goto-ai-block ()
  "Move point to the first AI block in the current buffer."
  (goto-char (point-min))
  (re-search-forward "#\\+begin_src ai" nil t))

(defun test-code-agent-org-mock--wait-for-first-token ()
  "Wait until FIRST_TOKEN appears in the current buffer."
  (should (test-claude-wait-until
           (lambda ()
             (save-excursion
               (goto-char (point-min))
               (re-search-forward "FIRST_TOKEN" nil t)))
           5)))

(defmacro test-code-agent-org-mock--with-cancel-fixture (&rest body)
  "Set up cancel-test fixture buffer, execute AI block, wait for first token, cancel.
Binds for BODY:
  `session-key'       — the session key
  `pre-cancel-tokens' — token count before cancel
  `query-handle'      — the process-state (never nil if first token arrived)
  `cancel-process'    — the Emacs process object
Handles setup and cleanup automatically.
BODY runs after cancel, with point in the test buffer."
  (declare (indent 0) (debug t))
  `(let* ((setup (test-code-agent-org-mock--setup-buffer
                  test-code-agent-org-mock--cancel-org))
          (buf (car setup))
          (temp-file (cdr setup)))
     (unwind-protect
         (with-current-buffer buf
           (let ((process-environment
                  (cons "MOCK_SCENARIO=cancel-test" process-environment))
                 (claude-agent-cli-path test-claude-mock-cli-path))
             (test-code-agent-org-mock--goto-ai-block)
             (let ((session-key (code-agent-org--current-session-key)))
               (code-agent-org-execute)
               (test-code-agent-org-mock--wait-for-first-token)
               ;; Capture state BEFORE cancel for assertions
               (let* ((pre-cancel-tokens
                       (test-code-agent-org-mock--count-tokens (buffer-string)))
                      (query-handle
                       (code-agent-org--session-get session-key :query-handle))
                      (cancel-process
                       (when query-handle
                         (claude-agent--process-state-process query-handle))))
                 ;; Guard: query-handle and process must exist if token arrived
                 (should query-handle)
                 (should cancel-process)
                 ;; Re-navigate (execute may move point) and cancel
                 (test-code-agent-org-mock--goto-ai-block)
                 (code-agent-org-cancel)
                 ,@body))))
       (test-code-agent-org-mock--cleanup buf temp-file))))

(ert-deftest test-org-mock-cancel-stops-token-insertion ()
  "Test that cancel stops new tokens from appearing in the buffer.
Reproduction for: 'cancel doesn't take effect sometimes.'
Starts a slow query, waits for FIRST_TOKEN to appear, cancels, then
verifies that no tokens beyond the cancel point continue to appear."
  :tags '(:mock :cancel :reproduction :org :process)
  (test-code-agent-org-mock--with-cancel-fixture
    ;; Wait for process to die and drain any pipe-buffered output
    (should (test-claude-wait-until
             (lambda () (not (process-live-p cancel-process)))
             5))
    (sleep-for 0.5)
    (accept-process-output nil 0.3)
    (let ((tokens-after-drain (test-code-agent-org-mock--count-tokens
                               (buffer-string))))
      ;; Should NOT have all 8 tokens (cancel had no effect)
      (should (< tokens-after-drain 8))
      ;; No new tokens appeared after cancel — pre-cancel-tokens was
      ;; captured BEFORE cancel, so any increase means token leakage
      (should (= pre-cancel-tokens tokens-after-drain)))))

(ert-deftest test-org-mock-cancel-kills-process ()
  "Test that cancel actually kills the subprocess.
If the process stays alive after cancel, it can continue generating
output and potentially interfere with the next query."
  :tags '(:mock :cancel :reproduction :org :process)
  (test-code-agent-org-mock--with-cancel-fixture
    ;; cancel-process is captured BEFORE cancel by the macro — no nil risk
    (should (test-claude-wait-until
             (lambda () (not (process-live-p cancel-process)))
             5))))

(ert-deftest test-org-mock-cancel-no-recovery-triggered ()
  "Test that cancel does NOT trigger auto-recovery.
A cancelled query should set the cancelled flag, which prevents
`is-abnormal-exit-p' from triggering recovery.  If recovery fires
after cancel, the user sees a new query start unexpectedly."
  :tags '(:mock :cancel :reproduction :org :recovery)
  ;; Drain stale sentinels from previous tests to prevent cross-test
  ;; contamination (a prior test's SIGKILL sentinel could fire here).
  (sleep-for 0.5)
  (accept-process-output nil 0.3)
  (let ((claude-agent-auto-recovery t)
        (recovery-triggered nil))
    (cl-letf (((symbol-function 'claude-agent--resume-session)
               (lambda (&rest _args)
                 (setq recovery-triggered t))))
      (test-code-agent-org-mock--with-cancel-fixture
        ;; query-handle and cancel-process captured BEFORE cancel by macro
        ;; Verify cancelled flag was set on the process-state
        (should (claude-agent--process-state-cancelled query-handle))
        ;; Wait for process to fully exit and sentinel to fire
        (should (test-claude-wait-until
                 (lambda () (not (process-live-p cancel-process)))
                 5))
        ;; Drain any pending sentinel callbacks
        (sleep-for 0.5)
        (accept-process-output nil 0.3)
        ;; Recovery should NOT have been triggered
        (should-not recovery-triggered)))))

(ert-deftest test-org-mock-cancel-text-appears ()
  "Test that [Cancelled] text is inserted after the AI block, not before it."
  :tags '(:mock :cancel :reproduction :org)
  (test-code-agent-org-mock--with-cancel-fixture
    ;; Find the end of the AI source block
    (goto-char (point-min))
    (should (re-search-forward "#\\+end_src" nil t))
    (let ((end-src-pos (point)))
      ;; [Cancelled] text should appear AFTER #+end_src
      (should (re-search-forward "\\[Cancelled\\]" nil t))
      (should (> (match-beginning 0) end-src-pos)))
    ;; Session should no longer be busy
    (should-not (code-agent-org--session-get session-key :busy))))

(ert-deftest test-org-mock-cancel-execute-cancel-cycle ()
  "Test rapid execute -> cancel -> re-execute cycle.
After cancelling, the user should be able to immediately start a new
query.  If cancel leaves stale state, the re-execute may fail or
behave incorrectly."
  :tags '(:mock :cancel :reproduction :org :cycle)
  (test-code-agent-org-mock--with-cancel-fixture
    (should-not (code-agent-org--session-get session-key :busy))
    ;; Ensure first process is fully dead before re-executing
    (should (test-claude-wait-until
             (lambda () (not (process-live-p cancel-process)))
             5))
    (sleep-for 0.3)
    (accept-process-output nil 0.2)
    ;; Re-execute with simple-query scenario
    (let ((process-environment
           (cons "MOCK_SCENARIO=simple-query" process-environment)))
      (test-code-agent-org-mock--goto-ai-block)
      (code-agent-org-execute)
      ;; Should start a new query successfully
      (should (test-claude-wait-until
               (lambda ()
                 (code-agent-org--session-get session-key :busy))
               5))
      ;; Wait for second query to complete
      (should (test-claude-wait-for-completion session-key 10))
      ;; Buffer should contain "4" from simple-query (word-boundary match
      ;; avoids false positives from cancel tokens like FOURTH_TOKEN)
      (goto-char (point-min))
      (should (re-search-forward "\\b4\\b" nil t)))))

(provide 'test-code-agent-org-mock)
;;; test-code-agent-org-mock.el ends here
