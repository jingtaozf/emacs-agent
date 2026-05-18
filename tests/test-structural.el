;;; test-structural.el --- Structural/architectural tests -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;;; Commentary:

;; F1: Structural tests that enforce architectural invariants mechanically.
;; F2: Each failure includes remediation guidance (FIX: message).
;; F6: CLAUDE.md existence and structure checks.

;;; Code:

(require 'ert)
(require 'test-helpers)

(defvar test-structural--project-root
  (or (and load-file-name
           (locate-dominating-file (file-name-directory load-file-name) "Makefile"))
      (locate-dominating-file default-directory "Makefile"))
  "Project root directory.")

;;; F1 Test 1: Public API functions have docstrings

(ert-deftest test-structural-public-api-documented ()
  "All public API functions (claude-agent-* and code-agent-org-*) have docstrings.
FIX: Add a docstring as the first form after the argument list."
  :tags '(:unit :fast :stable :structural)
  ;; Only check interactively-defined functions, skip autoloads and internal
  (let ((undocumented '()))
    (mapatoms
     (lambda (sym)
       (when (and (fboundp sym)
                  (not (subrp (symbol-function sym)))
                  (let ((name (symbol-name sym)))
                    (or (string-prefix-p "claude-agent-" name)
                        (string-prefix-p "code-agent-org-" name)))
                  ;; Skip internal functions (double-dash)
                  (not (string-match-p "--" (symbol-name sym)))
                  ;; Skip struct accessors/constructors
                  (not (string-match-p "-\\(make\\|p\\)$" (symbol-name sym)))
                  (not (string-match-p "-\\(name\\|input\\|content\\|type\\|subtype\\)$"
                                       (symbol-name sym)))
                  ;; Must be a function (not macro/alias)
                  (functionp (symbol-function sym))
                  ;; No documentation
                  (not (documentation sym)))
         (push sym undocumented))))
    (should (or (null undocumented)
                (error "Undocumented public functions: %s\nFIX: Add docstring to each:\n%s"
                       (length undocumented)
                       (mapconcat
                        (lambda (s)
                          (format "  (defun %s (...)\n    \"Description.\")" s))
                        (sort undocumented #'string<)
                        "\n"))))))

;;; F1 Test 2: No orphaned test files

(ert-deftest test-structural-no-orphaned-test-files ()
  "Every test file in tests/ appears in at least one Makefile target.
FIX: Add the missing file to the appropriate Makefile target
(test-agent-unit, test-org-unit, or test-backend-unit)."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let* ((tests-dir (expand-file-name "tests" test-structural--project-root))
           (makefile (expand-file-name "Makefile" test-structural--project-root))
           (makefile-content (when (file-exists-p makefile)
                               (with-temp-buffer
                                 (insert-file-contents makefile)
                                 (buffer-string))))
           (orphaned '()))
      (when (and makefile-content (file-directory-p tests-dir))
        (dolist (file (directory-files tests-dir nil "^test-.*\\.el$"))
          (unless (or (string-match-p (regexp-quote (format "-l tests/%s" file))
                                      makefile-content)
                      ;; Also check without -l prefix (some targets use different syntax)
                      (string-match-p (regexp-quote file) makefile-content))
            (push file orphaned)))
        (should (or (null orphaned)
                    (error "Orphaned test files not in Makefile: %s\nFIX: Add to Makefile target:\n%s"
                           (length orphaned)
                           (mapconcat
                            (lambda (f)
                              (format "  -l tests/%s \\" f))
                            (sort orphaned #'string<)
                            "\n"))))))))

;;; F1 Test 3: Provide matches filename

(ert-deftest test-structural-provide-matches-filename ()
  "Each test file's (provide 'X) matches its filename.
FIX: Change the provide form to match: (provide 'FILENAME-WITHOUT-EL)"
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let* ((tests-dir (expand-file-name "tests" test-structural--project-root))
           (mismatches '()))
      (when (file-directory-p tests-dir)
        (dolist (file (directory-files tests-dir nil "^test-.*\\.el$"))
          (let* ((expected-symbol (file-name-sans-extension file))
                 (filepath (expand-file-name file tests-dir))
                 (content (with-temp-buffer
                            (insert-file-contents filepath)
                            (buffer-string))))
            ;; Find (provide 'something) at start of line (not inside strings)
            (when (string-match "^(provide '\\([^)]+\\))" content)
              (let ((provided (match-string 1 content)))
                (unless (string= provided expected-symbol)
                  (push (list file provided expected-symbol) mismatches))))))
        (should (or (null mismatches)
                    (error "Provide/filename mismatches: %d\nFIX:\n%s"
                           (length mismatches)
                           (mapconcat
                            (lambda (m)
                              (format "  %s: has (provide '%s), should be (provide '%s)"
                                      (nth 0 m) (nth 1 m) (nth 2 m)))
                            mismatches
                            "\n"))))))))

;;; F1 Test 4: No hardcoded absolute paths in tests

(ert-deftest test-structural-no-hardcoded-paths ()
  "Test files don't contain hardcoded developer-specific absolute paths.
Catches /Users/<name>/ or /home/<name>/ but allows generic test fixtures
like /home/user/ which are placeholder paths in test data.
FIX: Use (make-temp-file ...) or relative paths instead."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let* ((tests-dir (expand-file-name "tests" test-structural--project-root))
           (violations '())
           ;; Generic placeholder usernames allowed in test data
           (generic-users '("user" "test" "example" "nobody" "root")))
      (when (file-directory-p tests-dir)
        (dolist (file (directory-files tests-dir nil "^test-.*\\.el$"))
          ;; Skip this test file itself (contains detection patterns)
          (unless (string= file "test-structural.el")
          (let* ((filepath (expand-file-name file tests-dir))
                 (content (with-temp-buffer
                            (insert-file-contents filepath)
                            (buffer-string)))
                 (lines (split-string content "\n"))
                 (line-num 0))
            (dolist (line lines)
              (cl-incf line-num)
              ;; Match /Users/<name>/ or /home/<name>/ with a real username
              (when (and (string-match "\\(/Users/\\|/home/\\)\\([^/\"]+\\)" line)
                         (let ((username (match-string 2 line)))
                           ;; Only flag non-generic usernames
                           (not (member username generic-users)))
                         ;; Skip comment-only lines
                         (not (string-match-p "^\\s-*;" line))
                         ;; Skip docstring description lines
                         (not (string-match-p "^\\s-*\"" line)))
                (push (format "%s:%d: %s" file line-num (string-trim line))
                      violations))))))
        (should (or (null violations)
                    (error "Hardcoded paths found: %d\nFIX: Use (make-temp-file) or relative paths:\n%s"
                           (length violations)
                           (mapconcat #'identity (nreverse violations) "\n"))))))))

;;; F2: Meta-test for remediation messages

(ert-deftest test-structural-remediation-messages ()
  "Verify should-with-fix produces FIX: guidance on failure."
  :tags '(:unit :fast :stable :structural)
  ;; Test that should-with-fix signals error with fix message
  (let ((err (should-error
              (should-with-fix nil "FIX: Do something specific"))))
    (should (string-match-p "FIX:" (error-message-string err)))))

;;; F6: CLAUDE.md checks

(ert-deftest test-structural-claude-md-exists ()
  "CLAUDE.md exists at project root and is under 300 lines.
FIX: Create CLAUDE.md at project root with essential commands,
architecture overview, key rules, and further reading pointers."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((claude-md (expand-file-name "CLAUDE.md" test-structural--project-root)))
      (should (or (file-exists-p claude-md)
                  (error "CLAUDE.md not found at project root.\nFIX: Create %s with project conventions."
                         claude-md)))
      (when (file-exists-p claude-md)
        (let ((line-count (with-temp-buffer
                            (insert-file-contents claude-md)
                            (count-lines (point-min) (point-max)))))
          (should (or (<= line-count 300)
                      (error "CLAUDE.md has %d lines (max 300).\nFIX: Move detailed rules to docs/ files."
                             line-count))))))))

(ert-deftest test-structural-claude-md-sections ()
  "CLAUDE.md contains essential progressive disclosure sections.
FIX: Add missing sections to CLAUDE.md."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((claude-md (expand-file-name "CLAUDE.md" test-structural--project-root)))
      (when (file-exists-p claude-md)
        (let ((content (with-temp-buffer
                         (insert-file-contents claude-md)
                         (buffer-string)))
              (missing '()))
          (dolist (section '("Commands" "Architecture" "Rules" "Further Reading"))
            (unless (string-match-p section content)
              (push section missing)))
          (should (or (null missing)
                      (error "CLAUDE.md missing sections: %s\nFIX: Add ## %s section(s)."
                             (mapconcat #'identity missing ", ")
                             (car missing)))))))))

;;; F7: ARCHITECTURE.org checks

(ert-deftest test-structural-architecture-org-exists ()
  "ARCHITECTURE.org exists at project root with required sections.
FIX: Create ARCHITECTURE.org with: Invariants, Absence Constraints, Extension Points.
See docs/ for templates."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((arch-file (expand-file-name "ARCHITECTURE.org" test-structural--project-root)))
      (should (or (file-exists-p arch-file)
                  (error "ARCHITECTURE.org not found at project root.\nFIX: Create %s as a meta-map."
                         arch-file)))
      (when (file-exists-p arch-file)
        (let ((content (with-temp-buffer
                         (insert-file-contents arch-file)
                         (buffer-string)))
              (missing '()))
          ;; Check required sections
          (dolist (section '("Invariants" "Absence Constraints" "Extension Points"))
            (unless (string-match-p (regexp-quote section) content)
              (push section missing)))
          (should (or (null missing)
                      (error "ARCHITECTURE.org missing sections: %s\nFIX: Add * %s section(s)."
                             (mapconcat #'identity missing ", ")
                             (car missing)))))))))

(ert-deftest test-structural-architecture-org-size ()
  "ARCHITECTURE.org is under 200 lines (meta-map must stay small).
FIX: Move detailed content into the most relevant code .org. ARCHITECTURE.org
is a navigational aid, not a place for per-feature design narrative."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((arch-file (expand-file-name "ARCHITECTURE.org" test-structural--project-root)))
      (when (file-exists-p arch-file)
        (let ((line-count (with-temp-buffer
                            (insert-file-contents arch-file)
                            (count-lines (point-min) (point-max)))))
          (should (or (<= line-count 200)
                      (error "ARCHITECTURE.org has %d lines (max 200).\nFIX: Move details into the most relevant code .org."
                             line-count))))))))

(ert-deftest test-structural-architecture-org-currency ()
  "ARCHITECTURE.org mentions all .org module files in the project root.
FIX: Add the missing module to ARCHITECTURE.org Module Boundary Diagram.
See the Extension Points section for where new modules belong."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((arch-file (expand-file-name "ARCHITECTURE.org" test-structural--project-root)))
      (when (file-exists-p arch-file)
        (let ((arch-content (with-temp-buffer
                              (insert-file-contents arch-file)
                              (buffer-string)))
              (missing '()))
          ;; Find all module .org files (claude-* and emacs-mcp-server*)
          (dolist (file (directory-files test-structural--project-root nil
                                        "^\\(claude-\\|emacs-mcp-server\\).*\\.org$"))
            ;; README.org is not a code module, skip it
            (unless (string= file "README.org")
              (let ((base (file-name-sans-extension file)))
                (unless (string-match-p (regexp-quote base) arch-content)
                  (push file missing)))))
          (should (or (null missing)
                      (error "ARCHITECTURE.org doesn't mention: %s\nFIX: Add to Module Boundary Diagram.\n%s"
                             (mapconcat #'identity missing ", ")
                             "See Extension Points section for where new modules belong."))))))))

;;; F8: Dependency direction enforcement

(ert-deftest test-structural-no-reverse-dependency ()
  "claude-agent.org must not require code-agent-org (lower layer cannot depend on upper).
FIX: Remove (require 'code-agent-org...) from claude-agent.org.
See ARCHITECTURE.org Module Boundary Diagram for allowed dependency directions."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((agent-file (expand-file-name "claude-agent.org" test-structural--project-root)))
      (when (file-exists-p agent-file)
        (let ((content (with-temp-buffer
                         (insert-file-contents agent-file)
                         (buffer-string))))
          (should (or (not (string-match-p "(require 'code-agent-org" content))
                      (error "claude-agent.org requires code-agent-org!\nFIX: Remove (require 'code-agent-org...) — lower layer cannot depend on upper.\nSee ARCHITECTURE.org."))))))))

(ert-deftest test-structural-mcp-server-independent ()
  "emacs-mcp-server.org must not depend on claude-agent or code-agent-org.
FIX: Remove the (require 'claude-...) from emacs-mcp-server.org.
The MCP server is an independent module. See ARCHITECTURE.org."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((mcp-file (expand-file-name "emacs-mcp-server.org" test-structural--project-root)))
      (when (file-exists-p mcp-file)
        (let ((content (with-temp-buffer
                         (insert-file-contents mcp-file)
                         (buffer-string))))
          (should (or (not (string-match-p "(require 'claude-" content))
                      (error "emacs-mcp-server.org depends on claude-*!\nFIX: Remove (require 'claude-...) — MCP server must be independent.\nSee ARCHITECTURE.org."))))))))

;;; F8: Agent-mistake structural tests

(ert-deftest test-structural-defcustom-has-type ()
  "All defcustom variables in claude-agent/code-agent-org have :type keyword.
FIX: Add :type to the defcustom form. Example: :type 'boolean or :type 'string"
  :tags '(:unit :fast :stable :structural)
  (let ((missing-type '()))
    (mapatoms
     (lambda (sym)
       (when (and (boundp sym)
                  (custom-variable-p sym)
                  (let ((name (symbol-name sym)))
                    (or (string-prefix-p "claude-agent-" name)
                        (string-prefix-p "code-agent-org-" name)
                        (string-prefix-p "emacs-mcp-server-" name)))
                  ;; Check if :type is specified
                  (not (get sym 'custom-type)))
         (push sym missing-type))))
    (should (or (null missing-type)
                (error "defcustom without :type: %s\nFIX: Add :type keyword to each:\n%s"
                       (length missing-type)
                       (mapconcat
                        (lambda (s)
                          (format "  (defcustom %s ... :type 'TYPE)" s))
                        (sort missing-type
                              (lambda (a b) (string< (symbol-name a) (symbol-name b))))
                        "\n"))))))

;;; F9: ELISP-IDIOMS.org and CLAUDE.md Verification section checks

(ert-deftest test-structural-elisp-idioms-exists ()
  "ELISP-IDIOMS.org exists at root and is referenced from CLAUDE.md.
FIX: Create ELISP-IDIOMS.org with Emacs Lisp idiom reference.
Then add it to CLAUDE.md Further Reading section."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((idioms-file (expand-file-name "ELISP-IDIOMS.org" test-structural--project-root))
          (claude-md (expand-file-name "CLAUDE.md" test-structural--project-root)))
      (should (or (file-exists-p idioms-file)
                  (error "ELISP-IDIOMS.org not found at project root.\nFIX: Create it with Emacs Lisp idiom reference.")))
      (when (and (file-exists-p idioms-file) (file-exists-p claude-md))
        (let ((content (with-temp-buffer
                         (insert-file-contents claude-md)
                         (buffer-string))))
          (should (or (string-match-p "ELISP-IDIOMS" content)
                      (error "CLAUDE.md doesn't reference ELISP-IDIOMS.org.\nFIX: Add to Further Reading section."))))))))

(ert-deftest test-structural-claude-md-verification-section ()
  "CLAUDE.md contains a Verification section with make commands.
FIX: Add ## Verification section to CLAUDE.md with make test-smoke, make check."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((claude-md (expand-file-name "CLAUDE.md" test-structural--project-root)))
      (when (file-exists-p claude-md)
        (let ((content (with-temp-buffer
                         (insert-file-contents claude-md)
                         (buffer-string))))
          (should (or (string-match-p "Verification" content)
                      (error "CLAUDE.md missing Verification section.\nFIX: Add ## Verification with make test-smoke, make check."))))))))

;;; F30: Naming Convention Linter

(ert-deftest test-structural-internal-functions-use-double-dash ()
  "All non-public functions in claude-*/emacs-mcp-server-* use -- prefix.
Functions defined in source .org files without -- must be in the known
public API list. This catches functions that should be internal but forgot
the -- naming convention.
FIX: Rename the function to use -- prefix (e.g., code-agent-org--my-func),
or add it to test-structural--known-public-api if it's intentionally public."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((violations nil)
          (all-defuns (test-structural--extract-defuns-from-sources)))
      (dolist (name all-defuns)
        (when (and (or (string-prefix-p "claude-" name)
                       (string-prefix-p "emacs-mcp-server-" name))
                   ;; Skip internal functions (already have --)
                   (not (string-match-p "--" name))
                   ;; Skip struct accessors/constructors/predicates
                   (not (string-match-p "-\\(make\\|p\\)$" name))
                   ;; Skip known public API
                   (not (member name test-structural--known-public-api)))
          (push name violations)))
      (should-with-fix (null violations)
        (format "Functions without -- prefix (should be internal or added to public API list):\n%s\nFIX: Rename with -- prefix or add to test-structural--known-public-api."
                (mapconcat #'identity (sort violations #'string<) "\n"))))))

(defvar test-structural--known-public-api
  '(;; claude-agent: core query API
    "claude-agent-query"
    "claude-agent-query-async"
    "claude-agent-query-accumulate"
    "claude-agent-query-interrupt"
    "claude-agent-query-kill"
    "claude-agent-query-request-id"
    "claude-agent-query-context-format-id"
    "claude-agent-query-context-format-label"
    "claude-agent-cancel"
    "claude-agent-cancel-all"
    "claude-agent-cancel-all-queries"
    "claude-agent-cancel-query"
    "claude-agent-version"
    "claude-agent-active-query-count"
    "claude-agent-list-queries"
    "claude-agent-options"
    ;; claude-agent: message extraction
    "claude-agent-extract-text"
    "claude-agent-extract-thinking"
    "claude-agent-extract-tool-uses"
    "claude-agent-message-type"
    ;; claude-agent: client API (bidirectional chat)
    "claude-agent-client-create"
    "claude-agent-client-connect"
    "claude-agent-client-disconnect"
    "claude-agent-client-send"
    "claude-agent-client-send-message"
    "claude-agent-client-interrupt"
    "claude-agent-get-session-id"
    ;; claude-agent: chat mode (comint-based)
    "claude-agent-chat"
    "claude-agent-chat-mode"
    "claude-agent-chat-send"
    "claude-agent-chat-interrupt"
    "claude-agent-chat-quit"
    "claude-agent-chat-clear"
    "claude-agent-chat-new-session"
    "claude-agent-chat-font-lock-keywords"
    ;; claude-agent: session & state management
    "claude-agent-make-session-key"
    "claude-agent-get-effective-permissions"
    "claude-agent-close-process-state"
    "claude-agent-cleanup"
    "claude-agent-kill-all-processes"
    "claude-agent-registry-cleanup-process"
    "claude-agent-update-state-callbacks"
    ;; claude-agent: permission system
    "claude-agent-check-permission"
    "claude-agent-permission-check-patterns"
    "claude-agent-permission-prompt"
    "claude-agent-permission-auto-allow"
    "claude-agent-permission-ask-user-question"
    ;; claude-agent: IDE context
    "claude-agent-collect-ide-context"
    "claude-agent-get-system-reminder"
    "claude-agent-build-system-reminder"
    ;; claude-agent: alerts (mode-line)
    "claude-agent-add-alert"
    "claude-agent-remove-alert"
    ;; claude-agent: rate-limit mode-line ([C:5h|7d|sonnet]) public commands
    "claude-agent-rate-limit-mode-line-start"
    "claude-agent-rate-limit-mode-line-stop"
    "claude-agent-rate-limit-refresh"
    ;; claude-agent: verbose/debug
    "claude-agent-get-verbose-buffer"
    "claude-agent-show-session-verbose"
    "claude-agent-list-session-verbose-buffers"
    ;; claude-agent: elapsed time helper
    "claude-agent-format-elapsed-time"
    ;; claude-agent: title generation
    "claude-agent-generate-title"
    "claude-agent-generate-title-from-text"
    ;; claude-agent: refine & translate
    "claude-agent-refine-prompt"
    "claude-agent-translate"
    "claude-agent-translate-buffer"
    "claude-agent-translate-cancel"
    "claude-agent-translate-dwim"
    "claude-agent-translate-region"
    "claude-agent-translate-to-chinese"
    "claude-agent-translate-to-english"
    ;; claude-agent: query management buffer
    "claude-agent-queries-cancel-at-point"
    "claude-agent-queries-goto-source"
    "claude-agent-queries-show-verbose"
    ;; claude-agent-jsonrpc (transport public API)
    "claude-agent-jsonrpc-make-client"
    "claude-agent-jsonrpc-send-request"
    "claude-agent-jsonrpc-send-response"
    "claude-agent-jsonrpc-send-notification"
    "claude-agent-jsonrpc-add-notification-handler"
    "claude-agent-jsonrpc-add-request-handler"
    "claude-agent-jsonrpc-shutdown"
    ;; claude-agent-acp (per-agent constructors)
    "claude-agent-acp-opencode-create"
    "claude-agent-acp-gemini-create"
    "claude-agent-acp-codex-create"
    ;; claude-agent-cmux-backend (Phase 3 multiplexer factory)
    "claude-agent-cmux-backend-create"
    ;; claude-agent-tmux-backend (Phase 4 multiplexer factory)
    "claude-agent-tmux-backend-create"
    ;; claude-agent-backend public API
    "claude-agent-backend-register"
    "claude-agent-backend-get"
    "claude-agent-backend-list"
    "claude-agent-backend-start"
    "claude-agent-backend-stop"
    "claude-agent-backend-send"
    "claude-agent-backend-cancel"
    "claude-agent-backend-filter-callbacks"
    ;; code-agent-org: core execution
    "code-agent-org-execute"
    "code-agent-org-cancel"
    "code-agent-org-cancel-all"
    "code-agent-org-cancel-queue"
    "code-agent-org-mode"
    "code-agent-org-setup"
    "code-agent-org-cleanup"
    ;; code-agent-org: navigation & insertion
    "code-agent-org-insert-ai-block"
    "code-agent-org-insert-block"
    "code-agent-org-insert-session-block"
    "code-agent-org-insert-template"
    "code-agent-org-insert-story"
    "code-agent-org-next-ai-block"
    "code-agent-org-prev-ai-block"
    "code-agent-org-goto-story"
    "code-agent-org-goto-custom-id"
    ;; code-agent-org: workspace workflow
    "code-agent-org-insert-workspace"
    ;; code-agent-org: refine
    "code-agent-org-refine"
    "code-agent-org-refine-block"
    "code-agent-org-refine-prompt"
    ;; code-agent-org: session & connection management
    "code-agent-org-session-status"
    "code-agent-org-set-model"
    "code-agent-org-disconnect-all-clients"
    "code-agent-org-disconnect-all-sessions"
    "code-agent-org-disconnect-session"
    "code-agent-org-list-persistent-clients"
    "code-agent-org-list-sessions"
    "code-agent-org-show-session-info"
    "code-agent-org-show-verbose"
    ;; code-agent-org: persistent-client registry (class-based singleton)
    "code-agent-org-persistent-registry-get-entry"
    "code-agent-org-persistent-registry-get"
    "code-agent-org-persistent-registry-alive-p"
    "code-agent-org-persistent-registry-register"
    "code-agent-org-persistent-registry-update-activity"
    "code-agent-org-persistent-registry-disconnect"
    "code-agent-org-persistent-registry-disconnect-buffer"
    "code-agent-org-persistent-registry-list"
    "code-agent-org-persistent-registry-count"
    ;; code-agent-org: copilot title generator (class-based singleton)
    "code-agent-org-copilot-title-generator-ensure-instance"
    "code-agent-org-copilot-title-generator-generate"
    ;; code-agent-org: response streaming (per-query state carrier)
    "code-agent-org-response-stream-handle-token"
    "code-agent-org-response-stream-handle-message"
    "code-agent-org-response-stream-handle-error"
    "code-agent-org-response-stream-handle-complete"
    "code-agent-org-response-stream-callbacks"
    ;; code-agent-org: execute command (input bundle for one run)
    "code-agent-org-execute-command-run"
    "code-agent-org-execute-command-from-block-info"
    ;; code-agent-org: response
    "code-agent-org-append-to-response"
    ;; code-agent-org: loop
    "code-agent-org-loop"
    "code-agent-org-loop-abort"
    "code-agent-org-loop-inject-warning"
    ;; code-agent-org: scheduling
    "code-agent-org-schedule-at"
    "code-agent-org-schedule-at-transient"
    "code-agent-org-schedule-cancel"
    "code-agent-org-schedule-list"
    "code-agent-org-schedule-clear-all"
    "code-agent-org-scheduled-list"
    "code-agent-org-scheduled-list-goto"
    "code-agent-org-scheduled-list-refresh"
    "code-agent-org-scheduled-scan-all"
    "code-agent-org-scheduled-start"
    "code-agent-org-scheduled-stop"
    "code-agent-org-scheduled-run"
    "code-agent-org-scheduled-cancel"
    ;; code-agent-org: header line & mode
    "code-agent-org-header-line"
    "code-agent-org-header-line-mode"
    ;; code-agent-org: permissions
    "code-agent-org-switch-permission-mode"
    ;; code-agent-org: unified terminal tab
    "code-agent-org-open-terminal-tab"
    ;; code-agent-org: cmux backend
    "code-agent-org-cmux-cancel"
    "code-agent-org-cmux-restart"
    "code-agent-org-cmux-clear-status"
    "code-agent-org-cmux-notify"
    "code-agent-org-cmux-verbose-mode"
    "code-agent-org-cmux-verbose-menu"
    "code-agent-org-cmux-verbose-follow"
    "code-agent-org-cmux-open-tab"
    "code-agent-org-cmux-set-progress"
    "code-agent-org-cmux-set-status"
    ;; code-agent-org: workspace bridge (terminal workflow)
    "code-agent-org-get-active-story"
    "code-agent-org-workspace-archive-workflow"
    "code-agent-org-workspace-bridge-get-cli-session"
    "code-agent-org-workspace-bridge-insert-prompt"
    "code-agent-org-workspace-bridge-insert-response"
    "code-agent-org-workspace-bridge-latest-instruction-custom-id"
    "code-agent-org-workspace-bridge-list-sessions"
    "code-agent-org-workspace-bridge-mark-cancelled"
    "code-agent-org-workspace-bridge-save-cli-session"
    "code-agent-org-workspace-bridge-send-prompt"
    "code-agent-org-workspace-bridge-system-prompt"
    "code-agent-org-workspace-bridge-update-todos"
    ;; code-agent-org: company completion
    "code-agent-org-company-slash-commands"
    ;; claude-ide: WebSocket IDE server (migrated from monet)
    "claude-ide-default-check-document-dirty-tool"
    "claude-ide-default-get-current-selection-tool"
    "claude-ide-default-get-latest-selection-tool"
    "claude-ide-default-get-open-editors-tool"
    "claude-ide-default-get-workspace-folders-tool"
    "claude-ide-default-open-file-tool"
    "claude-ide-default-save-document-tool"
    "claude-ide-disable-logging"
    "claude-ide-ediff-cleanup-tool"
    "claude-ide-ediff-tool"
    "claude-ide-enable-logging"
    "claude-ide-flymake-flycheck-diagnostics-tool"
    "claude-ide-list-sessions"
    "claude-ide-register-hooks"
    "claude-ide-simple-diff-cleanup-tool"
    "claude-ide-simple-diff-tool"
    "claude-ide-start-server"
    "claude-ide-start-server-in-directory"
    "claude-ide-stop-all-servers"
    "claude-ide-stop-server"
    ;; claude-agent-trace: OTel tracing
    "claude-agent-trace-context"
    "claude-agent-trace-connect"
    "claude-agent-trace-stop-bridge"
    "claude-agent-trace-stop-phoenix"
    "claude-agent-trace-open-phoenix"
    "claude-agent-trace-service-ensure"
    "claude-agent-trace-service-stop"
    "claude-agent-with-trace"
    "claude-agent-with-span"
    ;; emacs-mcp-server public API
    "emacs-mcp-server-start"
    "emacs-mcp-server-stop"
    "emacs-mcp-server-register-tool"
    "emacs-mcp-server-unregister-tool"
    "emacs-mcp-server-clear-tools"
    "emacs-mcp-server-running-p"
    "emacs-mcp-server-port"
    "emacs-mcp-server-show-log"
    "emacs-mcp-server-toggle-verbose")
  "Functions that are intentionally public (no -- prefix needed).
Only add functions here that are genuinely part of the public API.
When F30 test fails, either rename the function with -- prefix
or add it here if it's truly public.")

(defun test-structural--extract-defuns-from-sources ()
  "Extract all defun names from source .org files.
Returns a list of function name strings."
  (let ((names nil)
        (source-files
         (directory-files test-structural--project-root t
                          "^\\(claude-\\|emacs-mcp-server\\).*\\.org$")))
    (dolist (file source-files)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward
                "^(\\(?:defun\\|cl-defun\\)\\s-+\\(\\S-+\\)" nil t)
          (push (match-string-no-properties 1) names))))
    (delete-dups names)))

;;; F31: Full Dependency Graph Validation

(defun test-structural--extract-internal-requires (module-basename)
  "Extract internal requires from MODULE-BASENAME.org file.
Returns a list of module basenames that MODULE-BASENAME depends on.
Only returns claude-* and emacs-mcp-server-* requires, not standard libs."
  (let ((file (expand-file-name (concat module-basename ".org")
                                test-structural--project-root))
        (requires nil))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward
                "^(require '\\(\\(?:claude-\\|emacs-mcp-server\\)[^)]*\\))" nil t)
          (let ((req (match-string-no-properties 1)))
            ;; Normalize: code-agent-org-session maps to code-agent-org-session
            ;; We need module basenames (matching .org filenames without extension)
            (push req requires)))))
    (delete-dups requires)))

(defvar test-structural--module-layers
  '(("emacs-mcp-server"       . 0)   ; independent
    ("claude-agent-backend"    . 1)   ; bottom layer
    ("claude-agent-permission" . 1)
    ("claude-agent-ide"        . 1)
    ("claude-agent"            . 2)   ; core
    ("code-agent-org-session"      . 3)   ; org sub-modules
    ("code-agent-org-queue"        . 3)
    ("code-agent-org-response"     . 3)
    ("code-agent-org"              . 4)   ; top-level org
    ("code-agent-org-scheduled"    . 5)
    ("code-agent-org-workspace-bridge" . 5) ; workspace bridge, needs org
    ("code-agent-org-terminal-base" . 2)) ; shared terminal, needs agent
  "Module layer assignments from ARCHITECTURE.org.
Higher layers may depend on same or lower layers, but not upward.")

(ert-deftest test-structural-no-circular-dependencies ()
  "Module dependency graph must be acyclic (no circular requires).
FIX: Remove the circular (require ...) that creates the cycle.
See ARCHITECTURE.org Module Boundary Diagram for allowed directions."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let* ((modules (mapcar #'car test-structural--module-layers))
           (graph (mapcar (lambda (m)
                            (cons m (test-structural--extract-internal-requires m)))
                          modules))
           ;; Kahn's algorithm for topological sort
           ;; If we can't sort all nodes, there's a cycle
           (in-degree (make-hash-table :test 'equal))
           (adjacency (make-hash-table :test 'equal)))
      ;; Initialize
      (dolist (m modules)
        (puthash m 0 in-degree)
        (puthash m nil adjacency))
      ;; Build graph
      (dolist (entry graph)
        (let ((from (car entry))
              (deps (cdr entry)))
          (dolist (to deps)
            (when (gethash to in-degree)  ; only track known modules
              (puthash to (1+ (gethash to in-degree 0)) in-degree)
              (puthash from (cons to (gethash from adjacency)) adjacency)))))
      ;; Kahn's: start with zero in-degree nodes
      (let ((queue nil)
            (sorted nil))
        (maphash (lambda (k v)
                   (when (= v 0) (push k queue)))
                 in-degree)
        (while queue
          (let ((node (pop queue)))
            (push node sorted)
            (dolist (neighbor (gethash node adjacency))
              (puthash neighbor (1- (gethash neighbor in-degree)) in-degree)
              (when (= (gethash neighbor in-degree) 0)
                (push neighbor queue)))))
        ;; If sorted count != module count, there's a cycle
        (let ((unsorted (cl-remove-if (lambda (m) (member m sorted)) modules)))
          (should-with-fix (null unsorted)
            (format "Circular dependency detected among: %s\nFIX: Remove circular (require ...) statements. See ARCHITECTURE.org."
                    (mapconcat #'identity unsorted ", "))))))))

(ert-deftest test-structural-dependency-direction ()
  "Dependencies only flow downward: higher layers may require same or lower layers.
FIX: Remove the upward dependency. See ARCHITECTURE.org Module Boundary Diagram."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((violations nil))
      (dolist (entry test-structural--module-layers)
        (let* ((module (car entry))
               (layer (cdr entry))
               (deps (test-structural--extract-internal-requires module)))
          (dolist (dep deps)
            (let ((dep-layer (cdr (assoc dep test-structural--module-layers))))
              (when (and dep-layer (> dep-layer layer))
                (push (format "%s (L%d) requires %s (L%d) — upward dependency!"
                              module layer dep dep-layer)
                      violations))))))
      (should-with-fix (null violations)
        (format "Upward dependencies found:\n%s\nFIX: Remove upward requires. See ARCHITECTURE.org."
                (mapconcat #'identity violations "\n"))))))

;;; F34: Dead Code Detection

(defun test-structural--concat-all-sources ()
  "Concatenate all source .org files and test .el files into one string."
  (let ((content ""))
    ;; Source .org files
    (dolist (file (directory-files test-structural--project-root t "\\.org$"))
      (unless (string-match-p "/docs/" file)
        (setq content (concat content
                              (with-temp-buffer
                                (insert-file-contents file)
                                (buffer-string))
                              "\n"))))
    ;; Test .el files
    (let ((tests-dir (expand-file-name "tests" test-structural--project-root)))
      (when (file-directory-p tests-dir)
        (dolist (file (directory-files tests-dir t "\\.el$"))
          (setq content (concat content
                                (with-temp-buffer
                                  (insert-file-contents file)
                                  (buffer-string))
                                "\n")))))
    ;; Also check claude-code.el entry point
    (let ((entry (expand-file-name "claude-code.el" test-structural--project-root)))
      (when (file-exists-p entry)
        (setq content (concat content
                              (with-temp-buffer
                                (insert-file-contents entry)
                                (buffer-string))
                              "\n"))))
    ;; Prompts directory
    (let ((prompts-dir (expand-file-name "prompts" test-structural--project-root)))
      (when (file-directory-p prompts-dir)
        (dolist (file (directory-files-recursively prompts-dir "\\.org$"))
          (setq content (concat content
                                (with-temp-buffer
                                  (insert-file-contents file)
                                  (buffer-string))
                                "\n")))))
    content))

(ert-deftest test-structural-no-dead-public-functions ()
  "Public functions should be referenced somewhere (code, tests, or docs).
A function that only appears once across all sources is likely dead code.
FIX: Remove the unused function, or add a test/usage for it."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let* ((all-content (test-structural--concat-all-sources))
           (public-defuns (test-structural--extract-defuns-from-sources))
           (dead nil))
      (dolist (name public-defuns)
        (when (and (or (string-prefix-p "claude-" name)
                       (string-prefix-p "emacs-mcp-server-" name))
                   ;; Only check public functions (no --)
                   (not (string-match-p "--" name))
                   ;; Skip struct accessors/constructors/predicates
                   (not (string-match-p "-\\(make\\|p\\)$" name))
                   ;; Skip interactive commands (called by users, not code)
                   (not (and (fboundp (intern name))
                             (commandp (intern name))))
                   ;; Skip known public API (entry points are legit single-use)
                   (not (member name test-structural--known-public-api)))
          ;; Count occurrences — must appear at least twice (definition + usage)
          (let ((count 0)
                (start 0)
                (search-name (regexp-quote name)))
            (while (and (< count 2)
                        (string-match search-name all-content start))
              (setq count (1+ count)
                    start (1+ (match-beginning 0))))
            (when (< count 2)
              (push name dead)))))
      (should-with-fix (null dead)
        (format "Dead public functions (defined but never referenced elsewhere):\n%s\nFIX: Remove unused functions or add usage/tests."
                (mapconcat #'identity (sort dead #'string<) "\n"))))))

;;; F36: Process filters and sentinels must have condition-case

(ert-deftest test-structural-process-filters-guarded ()
  "All process filter and sentinel functions wrap their body in condition-case.
An unguarded error in a process filter kills the process silently.
An unguarded error in a sentinel leaks state permanently.
FIX: Wrap the function body in (condition-case err ... (error (message ...)))."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((violations nil)
          (source-files
           (directory-files test-structural--project-root t
                            "^\\(claude-\\|emacs-mcp-server\\).*\\.org$")))
      (dolist (file source-files)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          ;; Find defuns whose name contains "process-filter" or "process-sentinel"
          (while (re-search-forward
                  "^(defun\\s-+\\(\\S-*\\(?:process-filter\\|process-sentinel\\)\\S-*\\)" nil t)
            (let ((fn-name (match-string-no-properties 1))
                  (fn-start (match-beginning 0)))
              ;; Check if condition-case appears before the next top-level defun
              (let ((next-defun (save-excursion
                                  (if (re-search-forward "^(defun\\s-" nil t)
                                      (match-beginning 0)
                                    (point-max)))))
                (unless (save-excursion
                          (goto-char fn-start)
                          (re-search-forward "condition-case" next-defun t))
                  (push (format "%s: %s lacks condition-case guard"
                                (file-name-nondirectory file) fn-name)
                        violations)))))))
      (should-with-fix (null violations)
        (format "Unguarded process filters/sentinels:\n%s\nFIX: Wrap body in (condition-case err ... (error (message \"...: %%S\" err)))."
                (mapconcat #'identity (nreverse violations) "\n"))))))

;;; F35: No hardcoded status paths in backends

(ert-deftest test-structural-no-hardcoded-status-dir ()
  "Backend .org files must not hardcode /tmp/claude-agent-status.
Use `code-agent-org-terminal-status-dir' from code-agent-org-terminal-base instead.
FIX: Replace hardcoded \"/tmp/claude-agent-status\" with `code-agent-org-terminal-status-dir'."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((violations nil))
      (dolist (file '("code-agent-org-cmux.org"))
        (let ((filepath (expand-file-name file test-structural--project-root)))
          (when (file-exists-p filepath)
            (let ((content (with-temp-buffer
                             (insert-file-contents filepath)
                             (buffer-string)))
                  (line-num 0))
              (dolist (line (split-string content "\n"))
                (cl-incf line-num)
                (when (string-match-p "/tmp/claude-agent-status" line)
                  (push (format "%s:%d: %s" file line-num (string-trim line))
                        violations)))))))
      (should-with-fix (null violations)
        (format "Hardcoded /tmp/claude-agent-status found in backend files:\n%s\nFIX: Use `code-agent-org-terminal-status-dir' constant from code-agent-org-terminal-base.org."
                (mapconcat #'identity (nreverse violations) "\n"))))))

;;; F37: No stale iTerm2 references in source .org files

(ert-deftest test-structural-no-iterm2-references ()
  "Source .org files must not reference iTerm2 (backend was removed in 1038144).
Historical design docs under docs/ are exempt.
FIX: Replace the iTerm2 reference with a generic term (e.g., 'terminal backend')."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((violations nil)
          (source-files
           (directory-files test-structural--project-root t
                            "^\\(claude-\\|emacs-mcp-server\\).*\\.org$")))
      (dolist (file source-files)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (let ((line-num 0))
            (while (not (eobp))
              (cl-incf line-num)
              (let ((line (buffer-substring-no-properties
                           (line-beginning-position) (line-end-position))))
                (when (string-match-p "iTerm2" line)
                  (push (format "%s:%d: %s"
                                (file-name-nondirectory file) line-num
                                (string-trim line))
                        violations)))
              (forward-line 1)))))
      (should-with-fix (null violations)
        (format "Stale iTerm2 references in source files (backend removed in 1038144):\n%s\nFIX: Replace with generic term (e.g., 'terminal backend')."
                (mapconcat #'identity (nreverse violations) "\n"))))))

;;; F38: No standalone active-states alias variable

(ert-deftest test-structural-no-active-states-alias ()
  "Source .org files must not define or setq `claude-agent--active-states'.
Active states are owned exclusively by the unified `claude-agent--registry'
struct. The standalone defvar alias was removed in the A1 consolidation.
Any read must go through `claude-agent-registry-active-states' accessor or
the struct accessor `claude-agent--registry-active-states'.
FIX: Use (claude-agent-registry-active-states) for reads and
     (setf (claude-agent--registry-active-states claude-agent--registry) ...)
     for writes."
  :tags '(:unit :fast :stable :structural)
  (let ((violations '())
        (source-files
         (directory-files test-structural--project-root t
                          "^\\(claude-\\|emacs-mcp-server\\).*\\.org$")))
    (dolist (file source-files)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((line-num 0))
          (while (not (eobp))
            (cl-incf line-num)
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              ;; Match defvar or setq of the standalone alias in elisp code
              (when (and (string-match-p "claude-agent--active-states\\b" line)
                         ;; Only flag lines inside code blocks, not prose
                         (not (string-match-p "^[ \t]*[#*|]" line))
                         ;; Allow references in comments/docstrings that explain the removal
                         (not (string-match-p "^[ \t]*;" line)))
                (push (format "%s:%d: %s"
                              (file-name-nondirectory file) line-num
                              (string-trim line))
                      violations)))
            (forward-line 1)))))
    (should-with-fix (null violations)
      (format "Standalone `claude-agent--active-states' alias found in source files.\n%s\nFIX: Use (claude-agent-registry-active-states) accessor instead. Active states live exclusively in claude-agent--registry."
              (mapconcat #'identity (nreverse violations) "\n")))))

;;; F39: JSON parser guards against non-plist parsed values

(ert-deftest test-structural-json-parser-guards-non-plist ()
  "process-json-buffer and sentinel must guard against non-plist parsed JSON.
A bare JSON value (42, \"hello\", true) parses successfully but is not a plist.
Calling (plist-get 42 :type) returns nil, then (intern nil) crashes.
Both the filter path and the sentinel remaining-JSON handler must check
(listp parsed) before calling plist-get.
FIX: Add (and parsed (listp parsed)) guard in process-json-buffer and
     the sentinel remaining-JSON handler."
  :tags '(:unit :fast :stable :structural)
  (let ((violations '())
        (backend-file (expand-file-name "claude-agent-backend.org"
                                        test-structural--project-root)))
    (with-temp-buffer
      (insert-file-contents backend-file)
      (goto-char (point-min))
      ;; Find all (if parsed (let ((msg-type (plist-get parsed :type)))
      ;; patterns that are NOT guarded by (listp parsed)
      (while (re-search-forward "(if parsed" nil t)
        (let* ((line-num (line-number-at-pos))
               (line (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position))))
          ;; This pattern is unsafe — it should be (if (and parsed (listp parsed))
          (when (and (not (string-match-p "listp" line))
                     ;; Only flag lines inside code blocks
                     (not (string-match-p "^[ \t]*[#*|;]" line)))
            (push (format "claude-agent-backend.org:%d: %s"
                          line-num (string-trim line))
                  violations)))))
    (should-with-fix (null violations)
      (format "Unguarded `(if parsed ...)' without `(listp parsed)' check:\n%s\nFIX: Change to `(if (and parsed (listp parsed)) ...)' to prevent crash on bare JSON values."
              (mapconcat #'identity (nreverse violations) "\n")))))

;;; F40: No hardcoded /tmp paths in test files

(ert-deftest test-structural-no-hardcoded-tmp-in-tests ()
  "Test files must not hardcode /tmp/claude-agent-status paths.
Use `code-agent-org-terminal-status-dir' constant instead.
FIX: Replace \"/tmp/claude-agent-status\" with `code-agent-org-terminal-status-dir'."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((violations nil)
          (test-dir (expand-file-name "tests" test-structural--project-root)))
      (dolist (file (directory-files test-dir t "\\.el$"))
        (let ((filename (file-name-nondirectory file)))
          ;; Skip this structural test file itself (it mentions the pattern in assertions)
          (unless (equal filename "test-structural.el")
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (let ((line-num 0))
                (while (not (eobp))
                  (cl-incf line-num)
                  (let ((line (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position))))
                    (when (string-match-p "\"/tmp/claude-agent-status\"" line)
                      (push (format "%s:%d: %s" filename line-num (string-trim line))
                            violations)))
                  (forward-line 1)))))))
      (should-with-fix (null violations)
        (format "Hardcoded /tmp/claude-agent-status in test files:\n%s\nFIX: Use `code-agent-org-terminal-status-dir' constant."
                (mapconcat #'identity (nreverse violations) "\n"))))))

;;; F41: No commented-out test files in Makefile

(ert-deftest test-structural-no-commented-out-test-files ()
  "Makefile should not have commented-out test file loads.
FIX: Either enable the test (uncomment and add to correct target) or delete the dead test file."
  :tags '(:unit :fast :stable :structural)
  (let ((makefile (expand-file-name "Makefile" test-structural--project-root))
        (violations '()))
    (with-temp-buffer
      (insert-file-contents makefile)
      (goto-char (point-min))
      (let ((line-num 0))
        (while (not (eobp))
          (cl-incf line-num)
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (when (string-match-p "^#.*-l tests/test-.*\\.el" line)
              (push (format "Makefile:%d: %s" line-num (string-trim line))
                    violations)))
          (forward-line 1))))
    (should-with-fix (null violations)
      (format "Commented-out test files in Makefile:\n%s\nFIX: Uncomment and add to correct target, or delete the dead test file."
              (mapconcat #'identity (nreverse violations) "\n")))))

;;; Dead backend guard: claude-cli / eat backend must not be reintroduced

(ert-deftest test-structural-no-claude-cli-backend ()
  "Source .org files must not reference the dead claude-cli/eat backend.
The claude-cli backend (CLAUDE_BACKEND=claude-cli, eat terminal) was
removed.  Only claude-code and cmux backends are supported.
FIX: Remove any claude-cli or eat-backend references from the flagged file."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((violations '())
          (org-files (directory-files test-structural--project-root
                                     t "\\.org$")))
      (dolist (file org-files)
        ;; Skip docs/, tests/, and root-level review/backlog files that
        ;; may legitimately reference removed code in their historical
        ;; prose (CODEBASE-REVIEW.org carries pre-removal review items).
        (unless (or (string-match-p "/docs/" file)
                    (string-match-p "/tests/" file)
                    (string-match-p "/reference/" file)
                    (member (file-name-nondirectory file)
                            '("CODEBASE-REVIEW.org" "ELISP-IDIOMS.org"
                              "RATIONALE.md")))
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (let ((line-num 0))
              (while (not (eobp))
                (cl-incf line-num)
                (let ((line (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position))))
                  ;; Match claude-cli backend references in elisp code
                  ;; (not in comments/docs about the removal itself)
                  (when (and (or (string-match-p "claude-agent-claude-backend" line)
                                 (string-match-p ":claude-cli" line)
                                 (string-match-p "'claude-cli" line))
                             ;; Allow in comments explaining the removal
                             (not (string-match-p "^\\s-*#\\+" line))
                             (not (string-match-p "^\\s-*;" line)))
                    (push (format "%s:%d: %s"
                                  (file-name-nondirectory file) line-num
                                  (string-trim line))
                          violations)))
                (forward-line 1))))))
      (should-with-fix (null violations)
        (format "Dead claude-cli backend references found in source files:\n%s\nFIX: Remove these references. The claude-cli/eat backend is not supported."
                (mapconcat #'identity (nreverse violations) "\n"))))))

;;; F43: Verbose format dispatcher stays thin

(ert-deftest test-structural-verbose-format-dispatcher-thin ()
  "claude-agent--verbose-format-message should be a thin dispatcher (<15 lines).
The type-specific formatting logic belongs in dedicated helpers
\(--verbose-format-assistant-msg, --verbose-format-user-msg, etc.).
FIX: Extract formatting logic into type-specific helpers."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let* ((file (expand-file-name "claude-agent-backend.org"
                                    test-structural--project-root))
           (line-count 0)
           (found nil))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (when (search-forward "(defun claude-agent--verbose-format-message " nil t)
          (setq found t)
          (let ((start (line-number-at-pos)))
            ;; Find matching closing paren
            (goto-char (match-beginning 0))
            (forward-sexp 1)
            (setq line-count (1+ (- (line-number-at-pos) start))))))
      (when found
        (should-with-fix (<= line-count 15)
          (format "claude-agent--verbose-format-message is %d lines (max 15).\nFIX: Extract type-specific logic into --verbose-format-*-msg helpers."
                  line-count))))))

;;; F44: Activity string dispatcher must stay thin

(ert-deftest test-structural-activity-string-dispatcher-thin ()
  "claude-agent--update-activity-string should be a thin dispatcher (<20 lines).
The alert and query-spinner rendering logic belongs in dedicated helpers
\(--activity-alert-string, --activity-queries-string).
FIX: Extract rendering logic into helper functions."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let* ((file (expand-file-name "claude-agent.org"
                                    test-structural--project-root))
           (line-count 0)
           (found nil))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (when (search-forward "(defun claude-agent--update-activity-string " nil t)
          (setq found t)
          (let ((start (line-number-at-pos)))
            (goto-char (match-beginning 0))
            (forward-sexp 1)
            (setq line-count (1+ (- (line-number-at-pos) start))))))
      (when found
        (should-with-fix (<= line-count 20)
          (format "claude-agent--update-activity-string is %d lines (max 20).\nFIX: Extract rendering logic into --activity-alert-string and --activity-queries-string helpers."
                  line-count))))))

;;; F45: launch-workspace orchestrator must stay thin

(ert-deftest test-structural-launch-workspace-thin ()
  "code-agent-org-cmux--launch-workspace should stay under 65 lines.
State persistence belongs in --persist-workspace-state, IDE setup
in --setup-ide-after-ready.
FIX: Extract phase-specific logic into helper functions."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let* ((file (expand-file-name "code-agent-org-cmux.org"
                                    test-structural--project-root))
           (line-count 0)
           (found nil))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (when (search-forward "(defun code-agent-org-cmux--launch-workspace " nil t)
          (setq found t)
          (let ((start (line-number-at-pos)))
            (goto-char (match-beginning 0))
            (forward-sexp 1)
            (setq line-count (1+ (- (line-number-at-pos) start))))))
      (when found
        (should-with-fix (<= line-count 65)
          (format "code-agent-org-cmux--launch-workspace is %d lines (max 65).\nFIX: Extract state persistence into --persist-workspace-state and IDE setup into --setup-ide-after-ready."
                  line-count))))))

;;; Regression: no synchronous cmux CLI calls in periodic timers
;;
;; History: `code-agent-org-cmux--stream-tick' ran every 2 seconds via
;; `run-at-time' and called `cmux pipe-pane' synchronously via `call-process'.
;; Each tick blocked Emacs 200–1500 ms for the entire duration of every Claude
;; query.  Worse, its insertion marker was never initialised, so every tick
;; silently discarded the captured output — pure waste.
;;
;; Rule: any new periodic timer that talks to `cmux' MUST use `start-process'
;; + sentinel (async), not `code-agent-org-cmux--call' (which is sync).
;; See `.claude/rules/minimize-emacs-mcp-calls.md'.
(ert-deftest test-structural-no-dead-cmux-streaming-timer ()
  "Ensure the dead pipe-pane streaming subsystem stays removed.
The stream-tick timer was synchronous, hung Emacs every 2 s, and its
insertion marker was never wired up.  Response text arrives via the
Stop hook (handle_response → insert-response), not polling.
FIX: Do not reintroduce `code-agent-org-cmux--start-streaming',
`code-agent-org-cmux--stop-streaming', or `code-agent-org-cmux--stream-tick'.
If you need live terminal echo, use the async verbose mirror."
  :tags '(:unit :fast :stable :structural)
  (let ((cmux-org (expand-file-name "code-agent-org-cmux.org"
                                    test-structural--project-root)))
    (with-temp-buffer
      (insert-file-contents cmux-org)
      (dolist (sym '("code-agent-org-cmux--start-streaming"
                     "code-agent-org-cmux--stop-streaming"
                     "code-agent-org-cmux--stream-tick"
                     "code-agent-org-cmux--stream-timer"
                     "code-agent-org-cmux--stream-marker"
                     "code-agent-org-cmux--stream-last-len"))
        (goto-char (point-min))
        (should-with-fix
         (not (re-search-forward (format "^(def\\(?:un\\|var-local\\|var\\) %s"
                                         (regexp-quote sym))
                                 nil t))
         (format "Dead streaming symbol reintroduced: %s\nFIX: Remove the defun/defvar.  See rule minimize-emacs-mcp-calls.md." sym))))))

;;; F44: Semantic-duplicate defun detection (lens #17 architectural drift)
;;
;; AI agents often emit "the same function in 4 different files" because
;; each session re-derives an answer to the same problem from scratch.
;; Lens #17 of the AI codebase mastery research calls these *mutant
;; duplicates* — `grep` doesn't catch them because variable names differ;
;; SAST doesn't catch them because individual files look fine.
;;
;; This test fingerprints every `defun` body across all source .org files
;; (literate-elisp blocks) and flags any fingerprint that appears more
;; than once. Fingerprint = the body sexp printed with whitespace
;; collapsed, docstring stripped, but symbols + structure preserved.
;; Bodies shorter than a token threshold are ignored — they're too small
;; to count as meaningful duplication (`(error "not implemented")` stubs
;; would otherwise dominate the report).
;;
;; cl-defmethod intentional dispatch is filtered: same protocol method
;; implemented on different receivers will share a fingerprint by design.

(defun test-structural--defun-body-fingerprint (sexp &optional min-tokens)
  "Return a fingerprint string for SEXP if it is a defun-shaped form
with a body of at least MIN-TOKENS (default 12) whitespace-separated
tokens. Strips docstring; preserves all other structure.

Returns nil for non-defun forms, cl-defmethod (intentional dispatch),
and bodies smaller than the threshold."
  (let ((min-tokens (or min-tokens 12)))
    (when (and (consp sexp)
               (memq (car-safe sexp) '(defun cl-defun defmacro)))
      (let* ((body (nthcdr 3 sexp))
             ;; Strip leading docstring (a string literal as the first body form)
             (body (if (and body (stringp (car body))) (cdr body) body))
             ;; Skip declare / interactive forms — they're metadata, not behaviour
             (body (cl-remove-if
                    (lambda (form)
                      (and (consp form)
                           (memq (car-safe form) '(declare interactive))))
                    body))
             (printed (prin1-to-string body))
             (printed (replace-regexp-in-string "[ \t\n]+" " " printed))
             (printed (string-trim printed)))
        (when (>= (length (split-string printed)) min-tokens)
          printed)))))

(defun test-structural--read-sexps-from-org-elisp-blocks (file)
  "Read top-level sexps from #+begin_src elisp blocks in FILE.
Returns the list in reading order. Tolerates parse errors per block."
  (let ((sexps nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward
              "^#\\+\\(?:begin_src\\|BEGIN_SRC\\)[ \t]+\\(?:elisp\\|emacs-lisp\\)"
              nil t)
        (forward-line 1)
        (let* ((block-start (point))
               (block-end (save-excursion
                            (when (re-search-forward
                                   "^#\\+\\(?:end_src\\|END_SRC\\)" nil t)
                              (match-beginning 0)))))
          (when block-end
            (save-restriction
              (narrow-to-region block-start block-end)
              (goto-char (point-min))
              (let (continue)
                (setq continue t)
                (while continue
                  (let ((sexp (condition-case _err
                                  (read (current-buffer))
                                ((end-of-file invalid-read-syntax) 'eof))))
                    (cond
                     ((eq sexp 'eof) (setq continue nil))
                     ((consp sexp) (push sexp sexps)))))))
            (goto-char block-end)))))
    (nreverse sexps)))

(defun test-structural--scan-semantic-duplicates ()
  "Walk all source .org files, fingerprint every defun body, return a
list of (FINGERPRINT . LIST-OF (NAME . FILE)) for fingerprints that
appear more than once. Skips reference/, docs/, tests/, tasks/."
  (let ((by-fp (make-hash-table :test 'equal))
        (source-files
         (cl-remove-if
          (lambda (f)
            (or (string-match-p "/reference/" f)
                (string-match-p "/docs/" f)
                (string-match-p "/tests/" f)
                (string-match-p "/tasks/" f)
                (string-match-p "/.cache/" f)))
          (directory-files-recursively
           test-structural--project-root "\\.org$"))))
    (dolist (file source-files)
      (dolist (sexp (test-structural--read-sexps-from-org-elisp-blocks file))
        (let ((fp (test-structural--defun-body-fingerprint sexp))
              (name (when (and (consp sexp)
                               (memq (car-safe sexp) '(defun cl-defun defmacro))
                               (symbolp (cadr sexp)))
                      (symbol-name (cadr sexp)))))
          (when (and fp name)
            (push (cons name file) (gethash fp by-fp))))))
    (let ((dupes nil))
      (maphash (lambda (fp entries)
                 (when (> (length entries) 1)
                   (push (cons fp entries) dupes)))
               by-fp)
      dupes)))

(ert-deftest test-structural-fingerprint-self-test ()
  "Self-test for the fingerprint helper used by F44.
Confirms that:
- docstring is stripped (two functions with same body, one with docstring,
  produce identical fingerprints)
- different bodies produce different fingerprints
- different argnames are NOT normalised away — fingerprint preserves
  symbol identity (so `(+ a b)` and `(+ x y)` differ; this is a
  conservative stance that yields false negatives, not false positives)"
  :tags '(:unit :fast :stable :structural)
  (let* ((sexp1 '(defun foo (x)
                   (let ((y (+ x 1))) (when (> y 10) (* y 2 3 4 5 6)))))
         (sexp2 '(defun bar (x)
                   "this is a docstring"
                   (let ((y (+ x 1))) (when (> y 10) (* y 2 3 4 5 6)))))
         (sexp3 '(defun baz (x)
                   (let ((y (- x 1))) (when (> y 10) (* y 2 3 4 5 6)))))
         (fp1 (test-structural--defun-body-fingerprint sexp1 0))
         (fp2 (test-structural--defun-body-fingerprint sexp2 0))
         (fp3 (test-structural--defun-body-fingerprint sexp3 0)))
    (should fp1)
    (should fp2)
    (should fp3)
    (should-with-fix (equal fp1 fp2)
      "Fingerprint helper failed to strip docstring.\nFIX: ensure the (stringp (car body)) branch fires in test-structural--defun-body-fingerprint.")
    (should-with-fix (not (equal fp1 fp3))
      "Fingerprint helper collapsed semantically distinct bodies.\nFIX: do not normalise symbol identity (`+` vs `-` must be preserved).")))

(ert-deftest test-structural-no-semantic-duplicate-defuns ()
  "Two or more defuns with identical normalised body fingerprints suggest
copy-paste / AI mutant duplication. Lens #17 (architectural drift).

Allowlist:
- bodies < 12 whitespace-separated tokens (filtered by fingerprinter)
- cl-defmethod (intentional dispatch — same body across receivers)
- declare / interactive forms (metadata, not behaviour)

FIX: If the finding is real duplication, extract a shared helper. If
it's intentional (e.g. backend-specific stubs that legitimately do the
same thing), add an explicit `;; intentional duplicate of <other>` comment
just above one of them and wrap a no-op variation around the body."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((dupes (test-structural--scan-semantic-duplicates)))
      (should-with-fix (null dupes)
        (format
         "Semantic-duplicate defuns found (identical normalised bodies):\n\n%s\n\nFIX: Extract a shared helper, or annotate intentional duplication."
         (mapconcat
          (lambda (entry)
            (let ((fp (car entry))
                  (occurrences (cdr entry)))
              (format
               "Fingerprint (truncated):\n  %s\n  duplicates:\n%s"
               (if (> (length fp) 200) (concat (substring fp 0 200) " …") fp)
               (mapconcat
                (lambda (occ)
                  (format "    - %s   in %s"
                          (car occ)
                          (file-name-nondirectory (cdr occ))))
                occurrences "\n"))))
          dupes "\n\n"))))))

;;; F45: Module Overview must have substantive prose

(ert-deftest test-structural-module-overview-exists ()
  "Source .org files must have a * Overview section with substantive prose.
An empty Overview means the next reader recovers intent from code alone,
which defeats the purpose of literate programming.
FIX: Add a * Overview with motivation, invariant, and design principles."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((violations nil)
          (org-files (directory-files test-structural--project-root t "\\.org$")))
      (dolist (file org-files)
        (when (test-structural--source-org-file-p file)
          (with-temp-buffer
            (insert-file-contents file)
            (let ((content (buffer-string)))
              (when (string-match "^\\*\\s-+Overview" content)
                (let* ((ov-start (match-end 0))
                       (ov-end (or (and (string-match
                                         "^\\*\\s-\\|\\#\\+begin_src"
                                         content ov-start)
                                        (match-beginning 0))
                                   (length content)))
                       (ov-text (substring content ov-start ov-end))
                       (prose-count 0))
                  (dolist (ln (split-string ov-text "\n"))
                    (when (and (> (length (string-trim ln)) 10)
                               (not (string-match-p "^\\*+" ln))
                               (not (string-match-p "^\\s-*#" ln)))
                      (cl-incf prose-count)))
                  (when (< prose-count 3)
                    (push (format "%s: Overview has %d prose lines, need 3+"
                                  (file-name-nondirectory file) prose-count)
                          violations))))))))
      (should-with-fix (null violations)
        (format "Thin Overviews:\n%s\nFIX: Add motivation + invariant + design principles."
                (mapconcat #'identity (nreverse violations) "\n"))))))

;;; F46: No generic section headings in source .org files

(ert-deftest test-structural-no-generic-headings ()
  "Source .org files must not use generic headings like Functions or Helpers.
These are phase names, not concepts. Headings should name a concept.
FIX: Rename to describe the concept (e.g. Permission Handler, not Functions)."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((violations nil)
          (org-files (directory-files test-structural--project-root t "\\.org$"))
          (bad-re (concat "^\\*\\*\\s-+\\(Functions\\|Helpers\\|Utilities"
                          "\\|Implementation\\|Misc\\|Other\\|Code\\|Stuff\\)\\b")))
      (dolist (file org-files)
        (when (test-structural--source-org-file-p file)
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (let ((lnum 0))
              (while (not (eobp))
                (cl-incf lnum)
                (let ((line (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position))))
                  (when (string-match-p bad-re line)
                    (push (format "%s:%d: %s"
                                  (file-name-nondirectory file) lnum
                                  (string-trim line))
                          violations)))
                (forward-line 1))))))
      (should-with-fix (null violations)
        (format "Generic headings:\n%s\nFIX: Rename to a concept, not a phase."
                (mapconcat #'identity (nreverse violations) "\n"))))))

;;; F47: No pcase with string literal patterns (dynamic-binding trap)

(ert-deftest test-structural-pcase-string-detect ()
  "Source .org files must not use pcase with string literal patterns.
Under dynamic binding pcase string patterns compile differently.
FIX: Use (cond ((equal X \"str\") body)) instead."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((violations nil)
          (org-files (directory-files test-structural--project-root t "\\.org$")))
      (dolist (file org-files)
        (when (test-structural--source-org-file-p file)
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (let ((in-src nil)
                  (lnum 0))
              (while (not (eobp))
                (cl-incf lnum)
                (let ((line (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position))))
                  (cond
                   ((string-match-p "^#\\+begin_src\\s-+elisp" line)
                    (setq in-src t))
                   ((string-match-p "^#\\+end_src" line)
                    (setq in-src nil))
                   ((and in-src
                         (string-match-p "(pcase\\b" line)
                         (not (string-match-p "^\\s-*;" line)))
                    (when (and (test-structural--pcase-has-string-arm-p)
                               (not (test-structural--pcase-allowlisted-p file lnum)))
                      (push (format "%s:%d: pcase with string pattern"
                                    (file-name-nondirectory file) lnum)
                            violations)))))
                (forward-line 1))))))
      (should-with-fix (null violations)
        (format "pcase with string patterns:\n%s\nFIX: Use cond + equal for string dispatch."
                (mapconcat #'identity (nreverse violations) "\n"))))))

(defun test-structural--pcase-allowlisted-p (file lnum)
  "Return non-nil if FILE:LNUM is in the pcase string-pattern allowlist."
  (let ((entry (assoc (file-name-nondirectory file)
                      test-structural--pcase-string-allowlist)))
    (and entry (memq lnum (cdr entry)))))

(defvar test-structural--pcase-string-allowlist
  '(("claude-agent-backend.org" . (2279 2311))
    ("claude-ide.org" . (415 641 888))
    ("code-agent-org-scheduled.org" . (214))
    ("emacs-mcp-server.org" . (703)))
  "Known pcase string-pattern violations in existing code.
Entries are (FILENAME . (LINE-NUM ...)). These are pre-existing and need
a separate migration effort to convert to cond + equal.")

(defvar test-structural--source-org-excluded-dirs-re
  "\\(/docs/\\|/tests/\\|/reference/\\|/prompts/\\|/scripts/\\|/tasks/\\|/\\.claude/\\)"
  "Regex matching directory prefixes that are not source .org files.")

(defvar test-structural--source-org-excluded-names
  '("README.org" "CLAUDE.md" "ARCHITECTURE.org" "CONTRIBUTING.org" "CHANGELOG.org")
  "Filenames at project root that are not source .org files.")

(defun test-structural--source-org-file-p (file)
  "Return non-nil if FILE is a source .org file (not docs/tests/reference)."
  (and (not (string-match-p test-structural--source-org-excluded-dirs-re file))
       (not (member (file-name-nondirectory file)
                    test-structural--source-org-excluded-names))))

(defun test-structural--pcase-has-string-arm-p ()
  "Check if a pcase form at current line has a string literal arm nearby.
Searches forward up to 10 lines for a non-comment line starting with (\"."
  (save-excursion
    (save-match-data
      (let ((limit (save-excursion (forward-line 10) (point)))
            (found nil))
        (while (and (not found) (< (point) limit))
          (forward-line 1)
          (let ((ln (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
            (when (and (string-match "(\"" ln)
                       (not (string-match-p "^\\s-*;" ln)))
              (setq found t))))
        found))))

(provide 'test-structural)
;;; test-structural.el ends here
