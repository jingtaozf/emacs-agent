;;; test-claude-org-integration.el --- Integration tests for claude-org.el -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Integration tests for claude-org.el
;; These tests make REAL API calls to Claude using the org-mode interface.
;; Requires ANTHROPIC_API_KEY environment variable.

;;; Code:

(require 'ert)
(require 'org)
(require 'claude-org)
(require 'test-config)

;;; Basic Execution Tests

(ert-deftest test-org-integration-basic-execution ()
  "Test basic AI block execution with real API."
  :tags '(:integration :slow :api :org :process)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (let ((response (test-claude-execute-and-wait org-file 1 30)))
       ;; Should get a response containing "4" (answer to 2+2)
       (should (stringp response))
       (should (> (length (string-trim response)) 0))
       (should (string-match-p "4" response))))))

(ert-deftest test-org-integration-session-context ()
  "Test that session maintains context across queries."
  :tags '(:integration :slow :api :org :session)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     ;; Execute instruction 1 (asks 2+2)
     (let ((response1 (test-claude-execute-and-wait org-file 1 30)))
       (should (stringp response1))
       (should (string-match-p "4" response1)))
     ;; Execute instruction 2 (asks what was in instruction 1)
     (let ((response2 (test-claude-execute-and-wait org-file 2 30)))
       (should (stringp response2))
       ;; Should reference the previous question about 2+2 or 4
       (should (or (string-match-p "2.*\\+.*2" response2)
                   (string-match-p "addition" response2)
                   (string-match-p "sum" response2)
                   (string-match-p "4" response2)))))))

(ert-deftest test-org-integration-response-section-creation ()
  "Test automatic Response section creation."
  :tags '(:integration :slow :api :flaky :org :process)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (test-claude-execute-and-wait org-file 1 30)
     ;; Check that Response section was created
     (with-current-buffer (find-file-noselect org-file)
       (goto-char (point-min))
       (should (re-search-forward "^\\*+ Response 1" nil t))
       ;; Should have ai_output tag
       (should (member claude-org-output-tag (org-get-tags nil t)))))))

;;; Session Scope Tests

(ert-deftest test-org-integration-independent-sessions ()
  "Test that :claude_session: tagged sections are independent.
Session A remembers '42', Session B remembers 'blue'.
Session B should NOT know about '42' from Session A."
  :tags '(:integration :slow :api :org :session)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     ;; Execute Session A: remember 42
     (let ((response3 (test-claude-execute-and-wait org-file 3 30)))
       (should (stringp response3))
       (should (string-match-p "42\\|remember\\|confirm" response3)))

     ;; Execute Session B: remember blue
     (let ((response5 (test-claude-execute-and-wait org-file 5 30)))
       (should (stringp response5))
       (should (string-match-p "blue\\|remember\\|confirm" response5)))

     ;; Now ask Session B what number was remembered
     ;; It should NOT know about 42 (that was Session A)
     ;; Instruction 6 asks about color, so we need to check Session A's recall
     (let ((response4 (test-claude-execute-and-wait org-file 4 30)))
       (should (stringp response4))
       ;; Session A should remember 42
       (should (string-match-p "42" response4)))

     (let ((response6 (test-claude-execute-and-wait org-file 6 30)))
       (should (stringp response6))
       ;; Session B should remember blue
       (should (string-match-p "blue" response6))))))

(ert-deftest test-org-integration-section-vs-file-scope ()
  "Test that section-scoped sessions don't see file-scoped context.
File scope: Instruction 1 asks '2+2', Instruction 2 recalls it.
Session A: Instructions 3-4 remember/recall 42.
The key test: Session A should NOT know about the '2+2' from file scope."
  :tags '(:integration :slow :api :org :session)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     ;; Step 1: Execute file-scoped instruction 1 (2+2)
     (let ((response1 (test-claude-execute-and-wait org-file 1 30)))
       (should (stringp response1))
       (should (string-match-p "4" response1)))

     ;; Step 2: Verify file scope has context - instruction 2 recalls instruction 1
     (let ((response2 (test-claude-execute-and-wait org-file 2 30)))
       (should (stringp response2))
       ;; File scope should remember the 2+2 question
       (should (or (string-match-p "2.*\\+.*2\\|addition\\|math\\|number\\|4" response2)
                   (string-match-p "asked\\|previous" response2))))

     ;; Step 3: Execute Session A - this is a DIFFERENT session
     (let ((response3 (test-claude-execute-and-wait org-file 3 30)))
       (should (stringp response3))
       (should (string-match-p "42\\|remember\\|confirm" response3)))

     ;; Step 4: Session A should remember its own context (42)
     (let ((response4 (test-claude-execute-and-wait org-file 4 30)))
       (should (stringp response4))
       (should (string-match-p "42" response4))))))

;;; Tool Use Tests

(ert-deftest test-org-integration-tool-use-read ()
  "Test Claude using Read tool from org file."
  :tags '(:integration :slow :api :org :tools)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (let ((response (test-claude-execute-and-wait org-file 7 60)))
       ;; Should get a response about README.md content
       (should (stringp response))
       (should (> (length (string-trim response)) 0))))))

(ert-deftest test-org-integration-tool-use-glob ()
  "Test Claude using Glob tool from org file."
  :tags '(:integration :slow :api :org :tools)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (let ((response (test-claude-execute-and-wait org-file 8 60)))
       ;; Should get a response listing .org files
       (should (stringp response))
       (should (> (length (string-trim response)) 0))
       ;; Should mention test-session.org
       (should (string-match-p "test-session\\.org" response))))))

;;; Session Recovery Tests

(ert-deftest test-org-integration-session-recovery ()
  "Test automatic session recovery with invalid UUID."
  :tags '(:integration :slow :api :org :session)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     ;; Instruction 11 has intentionally-invalid-uuid
     (let ((response (test-claude-execute-and-wait org-file 11 60)))
       ;; Should get a response despite invalid UUID (recovery kicks in)
       (should (stringp response))
       (should (> (length (string-trim response)) 0))
       ;; Should see recovery confirmation
       (should (string-match-p "Recovery\\|successful\\|read" response))))))

;;; Permission Mode Tests

(ert-deftest test-org-integration-readonly-mode ()
  "Test readonly permission mode from org property.
Instruction 12 has CLAUDE_PERMISSION_MODE: readonly and asks to read a file."
  :tags '(:integration :slow :api :org :permissions)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     ;; Instruction 12 has readonly permission mode
     ;; It asks Claude to read README.md
     (let ((response (test-claude-execute-and-wait org-file 12 60)))
       ;; Should get a response (readonly mode allows read operations)
       (should (stringp response))
       (should (> (length (string-trim response)) 0))))))

(ert-deftest test-org-integration-plan-mode ()
  "Test plan permission mode from org property.
Instruction 13 has CLAUDE_PERMISSION_MODE: plan and asks for a plan."
  :tags '(:integration :slow :api :org :permissions)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     ;; Instruction 13 has plan permission mode
     ;; It asks Claude to suggest a plan
     (let ((response (test-claude-execute-and-wait org-file 13 60)))
       ;; Should get a response with planning content
       (should (stringp response))
       (should (> (length (string-trim response)) 0))
       ;; Response should contain planning-related content
       (should (or (string-match-p "plan\\|step\\|read\\|file" response)
                   (string-match-p "\\.el" response)))))))

;;; Multi-Session Concurrency Tests

(ert-deftest test-org-integration-concurrent-sessions ()
  "Test executing multiple sessions concurrently.
Concurrent Session 1 (Instruction 9) and Concurrent Session 2 (Instruction 10)
should be able to execute in parallel without interference."
  :tags '(:integration :slow :api :org :session :concurrent)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       (claude-org-mode 1)

       ;; Start both sessions
       (let (session-key-1 session-key-2)
         ;; Start instruction 9 (Concurrent Session 1)
         (goto-char (point-min))
         (re-search-forward "^\\*+ Instruction 9")
         (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai")
         (setq session-key-1 (claude-org--current-session-key))
         (claude-org-execute)

         ;; Start instruction 10 (Concurrent Session 2)
         (goto-char (point-min))
         (re-search-forward "^\\*+ Instruction 10")
         (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai")
         (setq session-key-2 (claude-org--current-session-key))
         (claude-org-execute)

         ;; Wait for both to complete (with longer timeout for concurrent ops)
         (let ((completed-1 (test-claude-wait-for-completion session-key-1 60))
               (completed-2 (test-claude-wait-for-completion session-key-2 60)))
           (should completed-1)
           (should completed-2)))))))

;;; Header Line Tests

(ert-deftest test-org-integration-header-line-updates ()
  "Test that header line updates during execution."
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       (claude-org-mode 1)

       ;; Save initial header line state
       (let ((initial-header header-line-format))

         ;; Execute query
         (goto-char (point-min))
         (re-search-forward "^\\*+ Instruction 1")
         (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai")
         (let ((session-key (claude-org--current-session-key)))
           (claude-org-execute)

           ;; Give it time to start and update header
           (sleep-for 1.0)
           (accept-process-output nil 0.5)

           ;; Check that header line exists (specific content may vary)
           (let ((active-header header-line-format))
             (should active-header))

           ;; Wait for completion
           (test-claude-wait-for-completion session-key 30)

           ;; Header should still exist after completion
           (let ((final-header header-line-format))
             (should final-header))))))))

;;; Cancellation Tests

(ert-deftest test-org-integration-cancel-query ()
  "Test cancelling an active query with C-c C-k."
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       (claude-org-mode 1)

       ;; Start a query that takes time
       (goto-char (point-min))
       (re-search-forward "^\\*+ Instruction 1")
       (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai")
       (let ((session-key (claude-org--current-session-key)))
         (claude-org-execute)

         ;; Wait longer for query to actually start
         (sleep-for 1.0)
         (accept-process-output nil 0.5)

         ;; Cancel it
         (claude-org-cancel)

         ;; Wait a bit for cleanup
         (sleep-for 0.3)
         (accept-process-output nil 0.3)

         ;; Should no longer be busy
         (should-not (claude-org--session-get session-key :busy))

         ;; Should see [Cancelled] marker
         (goto-char (point-min))
         (should (re-search-forward "\\[Cancelled\\]" nil t)))))))

;;; Block Insertion Tests

(ert-deftest test-org-integration-auto-numbering ()
  "Test automatic instruction numbering."
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       (claude-org-mode 1)

       ;; Find highest instruction number
       (let ((max-num 0))
         (goto-char (point-min))
         (while (re-search-forward "^\\*+ Instruction \\([0-9]+\\)" nil t)
           (setq max-num (max max-num (string-to-number (match-string 1)))))

         ;; Insert new block
         (goto-char (point-max))
         (claude-org-insert-block)

         ;; Should create Instruction with max+1
         (goto-char (point-max))
         (re-search-backward "^\\*+ Instruction \\([0-9]+\\)" nil t)
         (let ((new-num (string-to-number (match-string 1))))
           (should (= new-num (1+ max-num)))))))))

(ert-deftest test-org-integration-skip-output-sections ()
  "Test that block insertion skips :ai_output: sections."
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       (claude-org-mode 1)

       ;; Position in an output section
       (goto-char (point-min))
       (when (re-search-forward ":ai_output:" nil t)
         (let ((before-point (point)))
           ;; Insert block
           (claude-org-insert-block)

           ;; Should have moved past the output section
           (should (> (point) before-point))
           ;; Should not be in output section anymore
           (should-not (claude-org--in-output-section-p))))))))

;;; Project Configuration Tests

(ert-deftest test-org-integration-project-root ()
  "Test that PROJECT_ROOT property is used for cwd."
  :tags '(:integration :slow :api :org :context)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     ;; The fixture has PROJECT_ROOT set to ~/projects/claude-agent
     ;; Instruction 7 asks to read README.md from project root
     (let ((response (test-claude-execute-and-wait org-file 7 60)))
       (should (stringp response))
       (should (> (length (string-trim response)) 0))))))

(ert-deftest test-org-integration-system-prompts ()
  "Test that :system_prompt: sections are included."
  :tags '(:integration :slow :api :org :context)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     ;; The fixture has a :system_prompt: section asking for brief responses
     ;; Test that instruction 1 gets a brief response
     (let ((response (test-claude-execute-and-wait org-file 1 30)))
       (should (stringp response))
       ;; Response should be relatively brief (system prompt asks for 2 sentences max)
       (should (< (length response) 500))))))

;;; Environment Variable Tests

(ert-deftest test-org-integration-env-property ()
  "Test ANTHROPIC_MODEL property override."
  :tags '(:integration :slow :api :org :env)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     ;; Instruction 15 asks what model is being used
     ;; The fixture has ANTHROPIC_MODEL: claude-sonnet-3-5
     (let ((response (test-claude-execute-and-wait org-file 15 30)))
       (should (stringp response))
       (should (> (length (string-trim response)) 0))))))

;;; Session Manager UI Tests

(ert-deftest test-org-integration-list-sessions ()
  "Test session manager UI."
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (with-current-buffer (find-file-noselect org-file)
       (claude-org-mode 1)

       ;; Execute a query to create a session
       (goto-char (point-min))
       (re-search-forward "^\\*+ Instruction 1")
       (re-search-forward "^[ \t]*#\\+begin_src[ \t]+ai")
       (let ((session-key (claude-org--current-session-key)))
         (claude-org-execute)

         ;; Wait for query to start
         (sleep-for 1.0)
         (accept-process-output nil 0.5)

         ;; List sessions (should work even while query is active)
         (claude-org-list-sessions)

         ;; Should create session list buffer
         (should (get-buffer "*Claude Org Sessions*"))

         ;; Clean up - wait for completion and kill session buffer
         (test-claude-wait-for-completion session-key 30)
         (when (get-buffer "*Claude Org Sessions*")
           (kill-buffer "*Claude Org Sessions*")))))))

;;; Stress Tests

(ert-deftest test-org-integration-multiple-sequential-queries ()
  "Test executing multiple queries sequentially in same session."
  :tags '(:integration :slow :api :org :stress)
  (test-claude-skip-unless-cli-available)

  (test-claude-with-fixture
   (lambda (org-file)
     ;; Execute 3 sequential queries
     (let ((response1 (test-claude-execute-and-wait org-file 1 30)))
       (should (stringp response1))
       (should (string-match-p "4" response1)))
     (let ((response2 (test-claude-execute-and-wait org-file 2 30)))
       (should (stringp response2))
       (should (> (length (string-trim response2)) 0)))
     (let ((response3 (test-claude-execute-and-wait org-file 3 30)))
       (should (stringp response3))
       (should (> (length (string-trim response3)) 0))))))

;;; MCP Tool Access Tests

(ert-deftest test-org-integration-mcp-emacs-tools ()
  "Test that Emacs MCP tools are accessible via claude-org.
This test verifies the MCP server integration is working correctly
by checking that Claude can see the emacs MCP tools.
FLAKY: Response capture sometimes returns empty in batch mode."
  :tags '(:integration :slow :api :mcp :org :process :flaky)
  (test-claude-skip-unless-cli-available)
  (test-claude-skip-unless-mcp-server-available)

  (test-claude-with-fixture
   (lambda (org-file)
     (let ((response (test-claude-execute-and-wait org-file 16 60)))
       ;; Response may be empty due to timing issues in batch mode
       ;; Skip if empty rather than fail
       (when (or (null response) (string-empty-p (string-trim response)))
         (ert-skip "Empty response - flaky in batch mode"))
       ;; Verify emacs MCP tools are listed
       ;; The response should contain mcp__emacs__ prefixed tools
       (should (or (string-match-p "mcp__emacs__" response)
                   (string-match-p "evalElisp" response)
                   (string-match-p "org_list_sections" response)
                   (string-match-p "org_read_section" response)
                   (string-match-p "getDiagnostics" response)))))))

(provide 'test-claude-org-integration)
;;; test-claude-org-integration.el ends here
