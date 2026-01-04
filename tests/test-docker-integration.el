;;; test-docker-integration.el --- Tests for Docker integration -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for Docker container integration in claude-agent.
;; Tests path translation functions in emacs-mcp-server.org.
;;
;; Run these tests with:
;;   make test-docker

;;; Code:

(require 'ert)

;; The MCP server module is expected to be loaded before this test file
;; via the Makefile: literate-elisp-load "emacs-mcp-server.org"

;;; Project Directory Setup

(defvar test-docker-project-dir
  (file-name-directory
   (directory-file-name
    (file-name-directory
     (or load-file-name buffer-file-name default-directory))))
  "Path to project root directory (parent of tests/).")

;;; Path Translation Tests

(ert-deftest test-mcp-path-translation-to-host ()
  "Test container path to host path translation."
  :tags '(:unit :fast :stable :isolated :docker)
  (let ((emacs-mcp-server-path-mappings
         '(("/home/user/project" . "/workspace"))))
    ;; Container path should translate to host path
    (should (equal "/home/user/project/src/main.py"
                   (emacs-mcp-server--to-host-path "/workspace/src/main.py")))
    ;; Root container path
    (should (equal "/home/user/project"
                   (emacs-mcp-server--to-host-path "/workspace")))
    ;; Path not matching mapping should pass through unchanged
    (should (equal "/tmp/other"
                   (emacs-mcp-server--to-host-path "/tmp/other")))))

(ert-deftest test-mcp-path-translation-to-container ()
  "Test host path to container path translation."
  :tags '(:unit :fast :stable :isolated :docker)
  (let ((emacs-mcp-server-path-mappings
         '(("/home/user/project" . "/workspace"))))
    ;; Host path should translate to container path
    (should (equal "/workspace/src/main.py"
                   (emacs-mcp-server--to-container-path "/home/user/project/src/main.py")))
    ;; Root host path
    (should (equal "/workspace"
                   (emacs-mcp-server--to-container-path "/home/user/project")))
    ;; Path not matching mapping should pass through unchanged
    (should (equal "/tmp/other"
                   (emacs-mcp-server--to-container-path "/tmp/other")))))

(ert-deftest test-mcp-path-translation-nil-mappings ()
  "Test path translation with nil mappings passes through unchanged."
  :tags '(:unit :fast :stable :isolated :docker)
  (let ((emacs-mcp-server-path-mappings nil))
    (should (equal "/workspace/file.txt"
                   (emacs-mcp-server--to-host-path "/workspace/file.txt")))
    (should (equal "/home/user/file.txt"
                   (emacs-mcp-server--to-container-path "/home/user/file.txt")))))

(ert-deftest test-mcp-translate-paths-in-code-to-host ()
  "Test translation of paths in elisp code strings."
  :tags '(:unit :fast :stable :isolated :docker)
  (let ((emacs-mcp-server-path-mappings
         '(("/home/user/project" . "/workspace"))))
    ;; Simple path in code
    (should (equal "(find-file \"/home/user/project/test.el\")"
                   (emacs-mcp-server--translate-paths-in-code
                    "(find-file \"/workspace/test.el\")" :to-host)))
    ;; Multiple paths in code
    (should (equal "(progn (find-file \"/home/user/project/a.el\") (find-file \"/home/user/project/b.el\"))"
                   (emacs-mcp-server--translate-paths-in-code
                    "(progn (find-file \"/workspace/a.el\") (find-file \"/workspace/b.el\"))" :to-host)))))

(ert-deftest test-mcp-translate-paths-in-code-to-container ()
  "Test translation of paths in result strings back to container paths."
  :tags '(:unit :fast :stable :isolated :docker)
  (let ((emacs-mcp-server-path-mappings
         '(("/home/user/project" . "/workspace"))))
    ;; Result containing host path should translate back
    (should (equal "\"/workspace/test.el\""
                   (emacs-mcp-server--translate-paths-in-code
                    "\"/home/user/project/test.el\"" :to-container)))))

(ert-deftest test-mcp-translate-paths-in-result ()
  "Test translate-paths-in-result helper function."
  :tags '(:unit :fast :stable :isolated :docker)
  (let ((emacs-mcp-server-path-mappings
         '(("/home/user/project" . "/workspace"))))
    (should (equal "\"/workspace/test.el\""
                   (emacs-mcp-server--translate-paths-in-result
                    "\"/home/user/project/test.el\"")))))

(ert-deftest test-mcp-path-mapping-multiple-entries ()
  "Test path translation with multiple mapping entries."
  :tags '(:unit :fast :stable :isolated :docker)
  (let ((emacs-mcp-server-path-mappings
         '(("/home/user/project1" . "/workspace1")
           ("/home/user/project2" . "/workspace2"))))
    ;; First mapping
    (should (equal "/home/user/project1/file.txt"
                   (emacs-mcp-server--to-host-path "/workspace1/file.txt")))
    ;; Second mapping
    (should (equal "/home/user/project2/file.txt"
                   (emacs-mcp-server--to-host-path "/workspace2/file.txt")))
    ;; Reverse: first mapping
    (should (equal "/workspace1/file.txt"
                   (emacs-mcp-server--to-container-path "/home/user/project1/file.txt")))
    ;; Reverse: second mapping
    (should (equal "/workspace2/file.txt"
                   (emacs-mcp-server--to-container-path "/home/user/project2/file.txt")))))

(ert-deftest test-mcp-path-translation-no-false-positives ()
  "Test that path translation doesn't match partial directory names.
E.g., /workspacefoo should NOT match /workspace prefix."
  :tags '(:unit :fast :stable :isolated :docker)
  (let ((emacs-mcp-server-path-mappings
         '(("/home/user/project" . "/workspace"))))
    ;; Similar prefix but NOT a subdirectory - should pass through unchanged
    (should (equal "/workspacefoo/file.txt"
                   (emacs-mcp-server--to-host-path "/workspacefoo/file.txt")))
    (should (equal "/workspace2/file.txt"
                   (emacs-mcp-server--to-host-path "/workspace2/file.txt")))
    ;; Same for host paths
    (should (equal "/home/user/projectfoo/file.txt"
                   (emacs-mcp-server--to-container-path "/home/user/projectfoo/file.txt")))
    (should (equal "/home/user/project2/file.txt"
                   (emacs-mcp-server--to-container-path "/home/user/project2/file.txt")))
    ;; But actual subdirectories SHOULD match
    (should (equal "/home/user/project/subdir/file.txt"
                   (emacs-mcp-server--to-host-path "/workspace/subdir/file.txt")))
    (should (equal "/workspace/subdir/file.txt"
                   (emacs-mcp-server--to-container-path "/home/user/project/subdir/file.txt")))))

(ert-deftest test-mcp-path-translation-trailing-slash ()
  "Test path translation handles trailing slashes correctly."
  :tags '(:unit :fast :stable :isolated :docker)
  (let ((emacs-mcp-server-path-mappings
         '(("/home/user/project" . "/workspace"))))
    ;; Paths with trailing slashes in subpaths should work
    (should (equal "/home/user/project/dir/"
                   (emacs-mcp-server--to-host-path "/workspace/dir/")))
    (should (equal "/workspace/dir/"
                   (emacs-mcp-server--to-container-path "/home/user/project/dir/"))))
  ;; Also test with trailing slash IN the mapping (shouldn't break)
  (let ((emacs-mcp-server-path-mappings
         '(("/home/user/project/" . "/workspace/"))))
    (should (equal "/home/user/project/file.txt"
                   (emacs-mcp-server--to-host-path "/workspace/file.txt")))
    (should (equal "/workspace/file.txt"
                   (emacs-mcp-server--to-container-path "/home/user/project/file.txt")))))

(ert-deftest test-mcp-path-matches-p ()
  "Test the path matching helper function directly."
  :tags '(:unit :fast :stable :isolated :docker)
  (skip-unless (fboundp 'emacs-mcp-server--path-matches-p))
  ;; Exact match
  (should (emacs-mcp-server--path-matches-p "/workspace" "/workspace"))
  ;; Proper subdirectory
  (should (emacs-mcp-server--path-matches-p "/workspace" "/workspace/foo"))
  (should (emacs-mcp-server--path-matches-p "/workspace" "/workspace/foo/bar"))
  ;; NOT a match - similar prefix but not subdirectory
  (should-not (emacs-mcp-server--path-matches-p "/workspace" "/workspacefoo"))
  (should-not (emacs-mcp-server--path-matches-p "/workspace" "/workspace2"))
  ;; Also works with trailing slash in prefix
  (should (emacs-mcp-server--path-matches-p "/workspace/" "/workspace/foo")))

;;; Claude-org Docker Property Tests

(ert-deftest test-claude-org-docker-properties ()
  "Test that Docker property constants are defined."
  :tags '(:unit :fast :stable :isolated :docker)
  (skip-unless (featurep 'claude-org))
  (should (boundp 'claude-org-code-path-property))
  (should (boundp 'claude-org-container-path-property))
  (should (equal "CLAUDE_CODE_PATH" claude-org-code-path-property))
  (should (equal "CLAUDE_CONTAINER_PATH" claude-org-container-path-property))
  ;; CLAUDE_HOST_PATH was removed - now uses PROJECT_ROOT instead
  (should-not (boundp 'claude-org-host-path-property)))

(ert-deftest test-claude-org-elisp-reload-hint ()
  "Test elisp reload hint function."
  :tags '(:unit :fast :stable :isolated :docker)
  (skip-unless (fboundp 'claude-org--build-elisp-reload-hint))
  ;; Test that hint is always generated (not mode-dependent)
  (let ((hint (claude-org--build-elisp-reload-hint)))
    (should hint)
    (should (stringp hint))
    (should (string-match-p "load-file" hint))
    (should (string-match-p "literate-elisp-load" hint))
    (should (string-match-p "evalElisp" hint))))

;;; Claude-agent Docker Support Tests

(ert-deftest test-claude-agent-docker-command-detection ()
  "Test Docker command detection function."
  :tags '(:unit :fast :stable :isolated :docker)
  (skip-unless (fboundp 'claude-agent--docker-command-p))
  ;; Docker compose command
  (should (claude-agent--docker-command-p "docker compose exec claude claude"))
  ;; Docker run command
  (should (claude-agent--docker-command-p "docker run -it claude"))
  ;; Regular claude command
  (should-not (claude-agent--docker-command-p "claude"))
  (should-not (claude-agent--docker-command-p "/usr/local/bin/claude")))

(ert-deftest test-claude-agent-extract-compose-file ()
  "Test extraction of compose file from Docker command."
  :tags '(:unit :fast :stable :isolated :docker)
  (skip-unless (fboundp 'claude-agent--extract-compose-file-from-command))
  ;; With -f flag
  (should (equal "/path/to/docker-compose.yml"
                 (claude-agent--extract-compose-file-from-command
                  "docker compose -f /path/to/docker-compose.yml exec claude claude")))
  ;; With --file flag
  (should (equal "/other/path/compose.yml"
                 (claude-agent--extract-compose-file-from-command
                  "docker compose --file /other/path/compose.yml exec claude claude")))
  ;; Relative path
  (should (equal ".devcontainer/docker-compose.yml"
                 (claude-agent--extract-compose-file-from-command
                  "docker compose -f .devcontainer/docker-compose.yml exec claude claude")))
  ;; No -f flag
  (should-not (claude-agent--extract-compose-file-from-command
               "docker compose exec claude claude"))
  ;; nil input
  (should-not (claude-agent--extract-compose-file-from-command nil)))

(ert-deftest test-claude-agent-find-compose-dir ()
  "Test finding compose directory from CLI path and project root."
  :tags '(:unit :fast :stable :isolated :docker)
  (skip-unless (fboundp 'claude-agent--find-compose-dir))
  ;; Use test-docker-project-dir which is defined earlier in the file
  (let* ((project-dir test-docker-project-dir)
         (devcontainer-dir (expand-file-name ".devcontainer" project-dir))
         (compose-file (expand-file-name "docker-compose.yml" devcontainer-dir)))
    ;; Skip if compose file doesn't exist (this test requires the project setup)
    (skip-unless (file-exists-p compose-file))
    ;; With absolute path in -f flag
    (let* ((cli-path (format "docker compose -f %s exec claude claude" compose-file))
           (result (claude-agent--find-compose-dir cli-path nil)))
      ;; Compare without trailing slash differences
      (should (equal (directory-file-name devcontainer-dir)
                     (directory-file-name result))))
    ;; With relative path in -f flag + project-root
    (let* ((cli-path "docker compose -f .devcontainer/docker-compose.yml exec claude claude")
           (result (claude-agent--find-compose-dir cli-path project-dir)))
      (should (equal (directory-file-name devcontainer-dir)
                     (directory-file-name result))))
    ;; With project-root only (no -f flag), should find .devcontainer
    (let ((result (claude-agent--find-compose-dir nil project-dir)))
      (should (equal (directory-file-name devcontainer-dir)
                     (directory-file-name result))))
    ;; With neither - should return nil for non-existent path
    (should-not (claude-agent--find-compose-dir nil "/nonexistent/path"))))

;;; Docker Sandbox Integration Tests
;;
;; These tests require:
;; 1. Docker container running: docker compose -f .devcontainer/docker-compose.yml up -d
;; 2. Claude authenticated: make docker-auth
;;
;; Run with: make test-docker-sandbox

(defvar test-docker-compose-file
  (expand-file-name ".devcontainer/docker-compose.yml" test-docker-project-dir)
  "Absolute path to docker-compose.yml file.")

(defvar test-docker-cli-command
  (format "docker compose -f %s exec claude claude" test-docker-compose-file)
  "CLI command for Docker sandbox environment.")

(defun test-docker-container-ready-p ()
  "Check if Docker container is running and Claude is installed."
  (zerop (call-process "docker" nil nil nil
                       "compose" "-f" test-docker-compose-file
                       "ps" "--status" "running" "-q" "claude")))

(defun test-docker-skip-unless-container-ready ()
  "Skip test if Docker container is not ready."
  (unless (test-docker-container-ready-p)
    (ert-skip "Docker container not running - run 'make docker-up' first")))

(ert-deftest test-docker-sandbox-container-status ()
  "Test Docker container status check function."
  :tags '(:integration :docker :sandbox)
  (test-docker-skip-unless-container-ready)
  ;; Container should be detected as running
  (should (claude-agent--docker-container-running-p)))

(ert-deftest test-docker-sandbox-simple-query ()
  "Test simple query via Docker sandbox."
  :tags '(:integration :slow :docker :sandbox)
  (test-docker-skip-unless-container-ready)

  (let ((response nil)
        (completed nil)
        (error-msg nil))
    (claude-agent-query
     "What is 2+2? Answer with just the number."
     :cli-path test-docker-cli-command
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     (setq response (claude-agent-extract-text msg))))
     :on-error (lambda (err)
                 (setq error-msg (format "%S" err)))
     :on-complete (lambda (_result)
                    (setq completed t)))

    ;; Wait for completion (Docker may be slower)
    (let ((timeout 60)
          (start (float-time)))
      (while (and (not completed)
                  (not error-msg)
                  (< (- (float-time) start) timeout))
        (sleep-for 0.2)
        (accept-process-output nil 0.2)))

    (when error-msg
      (ert-fail (format "Query error: %s" error-msg)))
    (should completed)
    (should response)
    (should (string-match-p "4" response))))

(ert-deftest test-docker-sandbox-session-continuity ()
  "Test session continuity in Docker sandbox."
  :tags '(:integration :slow :docker :sandbox :session)
  (test-docker-skip-unless-container-ready)

  (let ((first-response nil)
        (second-response nil)
        (sdk-uuid nil)
        (completed1 nil)
        (completed2 nil)
        (error-msg nil))

    ;; First query - establish session
    (claude-agent-query
     "Remember this: the secret word is ELEPHANT. Just confirm."
     :cli-path test-docker-cli-command
     :on-message (lambda (msg)
                   (when (claude-agent-result-message-p msg)
                     (setq sdk-uuid (claude-agent-result-message-session-id msg)))
                   (when (claude-agent-assistant-message-p msg)
                     (setq first-response (claude-agent-extract-text msg))))
     :on-error (lambda (err) (setq error-msg (format "%S" err)))
     :on-complete (lambda (_result) (setq completed1 t)))

    ;; Wait for first query
    (let ((timeout 60) (start (float-time)))
      (while (and (not completed1) (not error-msg)
                  (< (- (float-time) start) timeout))
        (sleep-for 0.2)
        (accept-process-output nil 0.2)))

    (when error-msg
      (ert-fail (format "First query error: %s" error-msg)))
    (should completed1)
    (should sdk-uuid)
    (should first-response)

    ;; Second query - continue session
    (setq error-msg nil)
    (claude-agent-query
     "What was the secret word I told you to remember?"
     :cli-path test-docker-cli-command
     :options (claude-agent-options :resume sdk-uuid)
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     (setq second-response (claude-agent-extract-text msg))))
     :on-error (lambda (err) (setq error-msg (format "%S" err)))
     :on-complete (lambda (_result) (setq completed2 t)))

    ;; Wait for second query
    (let ((timeout 60) (start (float-time)))
      (while (and (not completed2) (not error-msg)
                  (< (- (float-time) start) timeout))
        (sleep-for 0.2)
        (accept-process-output nil 0.2)))

    (when error-msg
      (ert-fail (format "Second query error: %s" error-msg)))
    (should completed2)
    (should second-response)
    ;; Session should remember the secret word
    (should (string-match-p "ELEPHANT" (upcase second-response)))))

(ert-deftest test-docker-sandbox-path-mappings ()
  "Test that path mappings are correctly passed to Docker queries."
  :tags '(:integration :slow :docker :sandbox :path)
  (test-docker-skip-unless-container-ready)

  (let ((response nil)
        (completed nil)
        (error-msg nil)
        ;; Map host project dir to container /workspace
        (host-path test-docker-project-dir)
        (container-path "/workspace"))

    ;; Query asking about a file that exists in both locations
    (claude-agent-query
     "List the files in /workspace using ls. Just show the output."
     :cli-path test-docker-cli-command
     :path-mappings `((,host-path . ,container-path))
     :options (claude-agent-options :permission-mode "acceptEdits")
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     (setq response (claude-agent-extract-text msg))))
     :on-error (lambda (err) (setq error-msg (format "%S" err)))
     :on-complete (lambda (_result) (setq completed t)))

    ;; Wait for completion
    (let ((timeout 90) (start (float-time)))
      (while (and (not completed) (not error-msg)
                  (< (- (float-time) start) timeout))
        (sleep-for 0.2)
        (accept-process-output nil 0.2)))

    (when error-msg
      (ert-fail (format "Query error: %s" error-msg)))
    (should completed)
    (should response)
    ;; Should see project files (README.md should exist)
    (should (or (string-match-p "README" response)
                (string-match-p "claude-agent" response)
                (string-match-p "Makefile" response)))))

(ert-deftest test-docker-sandbox-elisp-reload ()
  "Test that Claude reloads elisp after editing in Docker mode.
This tests the system prompt rule that Claude must reload code after editing."
  :tags '(:integration :slow :docker :sandbox :reload)
  (test-docker-skip-unless-container-ready)

  (let ((response nil)
        (completed nil)
        (error-msg nil)
        (host-path test-docker-project-dir)
        (container-path "/workspace")
        (test-file (expand-file-name "tests/fixtures/test-reload.el" test-docker-project-dir)))

    ;; Create a simple test file
    (with-temp-file test-file
      (insert ";; Test file for reload\n")
      (insert "(defvar test-docker-reload-value 1 \"Initial value.\")\n")
      (insert "(provide 'test-reload)\n"))

    ;; Load initial value
    (load-file test-file)
    (should (= test-docker-reload-value 1))

    ;; Ask Claude to edit the file AND reload it
    ;; The system prompt instructs Claude to reload after editing
    (claude-agent-query
     (format "Please edit the file /workspace/tests/fixtures/test-reload.el to change the value from 1 to 42.
After editing, reload the file in Emacs using evalElisp with (load-file \"%s\").
Confirm the value was changed by evaluating test-docker-reload-value."
             test-file)
     :cli-path test-docker-cli-command
     :path-mappings `((,host-path . ,container-path))
     :options (claude-agent-options :permission-mode "acceptEdits")
     :on-message (lambda (msg)
                   (when (claude-agent-assistant-message-p msg)
                     (setq response (claude-agent-extract-text msg))))
     :on-error (lambda (err) (setq error-msg (format "%S" err)))
     :on-complete (lambda (_result) (setq completed t)))

    ;; Wait for completion (Docker + file edit + reload may be slow)
    (let ((timeout 120) (start (float-time)))
      (while (and (not completed) (not error-msg)
                  (< (- (float-time) start) timeout))
        (sleep-for 0.2)
        (accept-process-output nil 0.2)))

    ;; Cleanup
    (when (file-exists-p test-file)
      (delete-file test-file))

    (when error-msg
      (ert-fail (format "Query error: %s" error-msg)))
    (should completed)
    (should response)
    ;; The variable should have been updated to 42 by Claude's reload
    (should (= test-docker-reload-value 42))
    ;; Response should mention 42 or confirm the change
    (should (string-match-p "42" response))))

(provide 'test-docker-integration)
;;; test-docker-integration.el ends here
