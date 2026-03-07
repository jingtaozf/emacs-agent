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
  "All public API functions (claude-agent-* and claude-org-*) have docstrings.
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
                        (string-prefix-p "claude-org-" name)))
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
  "ARCHITECTURE.org is under 150 lines (meta-map must stay small).
FIX: Move detailed content to docs/ files. ARCHITECTURE.org is a navigational aid."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((arch-file (expand-file-name "ARCHITECTURE.org" test-structural--project-root)))
      (when (file-exists-p arch-file)
        (let ((line-count (with-temp-buffer
                            (insert-file-contents arch-file)
                            (count-lines (point-min) (point-max)))))
          (should (or (<= line-count 150)
                      (error "ARCHITECTURE.org has %d lines (max 150).\nFIX: Move details to docs/."
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
  "claude-agent.org must not require claude-org (lower layer cannot depend on upper).
FIX: Remove (require 'claude-org...) from claude-agent.org.
See ARCHITECTURE.org Module Boundary Diagram for allowed dependency directions."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((agent-file (expand-file-name "claude-agent.org" test-structural--project-root)))
      (when (file-exists-p agent-file)
        (let ((content (with-temp-buffer
                         (insert-file-contents agent-file)
                         (buffer-string))))
          (should (or (not (string-match-p "(require 'claude-org" content))
                      (error "claude-agent.org requires claude-org!\nFIX: Remove (require 'claude-org...) — lower layer cannot depend on upper.\nSee ARCHITECTURE.org."))))))))

(ert-deftest test-structural-mcp-server-independent ()
  "emacs-mcp-server.org must not depend on claude-agent or claude-org.
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
  "All defcustom variables in claude-agent/claude-org have :type keyword.
FIX: Add :type to the defcustom form. Example: :type 'boolean or :type 'string"
  :tags '(:unit :fast :stable :structural)
  (let ((missing-type '()))
    (mapatoms
     (lambda (sym)
       (when (and (boundp sym)
                  (custom-variable-p sym)
                  (let ((name (symbol-name sym)))
                    (or (string-prefix-p "claude-agent-" name)
                        (string-prefix-p "claude-org-" name)
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

;;; F9: ELISP_IDIOMS.org and CLAUDE.md Verification section checks

(ert-deftest test-structural-elisp-idioms-exists ()
  "docs/ELISP_IDIOMS.org exists and is referenced from CLAUDE.md.
FIX: Create docs/ELISP_IDIOMS.org with Emacs Lisp idiom reference.
Then add it to CLAUDE.md Further Reading section."
  :tags '(:unit :fast :stable :structural)
  (when test-structural--project-root
    (let ((idioms-file (expand-file-name "docs/ELISP_IDIOMS.org" test-structural--project-root))
          (claude-md (expand-file-name "CLAUDE.md" test-structural--project-root)))
      (should (or (file-exists-p idioms-file)
                  (error "docs/ELISP_IDIOMS.org not found.\nFIX: Create it with Emacs Lisp idiom reference.")))
      (when (and (file-exists-p idioms-file) (file-exists-p claude-md))
        (let ((content (with-temp-buffer
                         (insert-file-contents claude-md)
                         (buffer-string))))
          (should (or (string-match-p "ELISP_IDIOMS" content)
                      (error "CLAUDE.md doesn't reference ELISP_IDIOMS.org.\nFIX: Add to Further Reading section."))))))))

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
FIX: Rename the function to use -- prefix (e.g., claude-org--my-func),
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
    "claude-agent-continue-session"
    "claude-agent-resume-session"
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
    "claude-agent-permission-check"
    "claude-agent-permission-handler"
    "claude-agent-permission-check-patterns"
    "claude-agent-permission-prompt"
    "claude-agent-permission-auto-allow"
    "claude-agent-permission-ask-user-question"
    ;; claude-agent: IDE context
    "claude-agent-collect-ide-context"
    "claude-agent-get-system-reminder"
    "claude-agent-ide-context"
    "claude-agent-build-system-reminder"
    ;; claude-agent: verbose/debug
    "claude-agent-get-verbose-buffer"
    "claude-agent-show-session-verbose"
    "claude-agent-list-session-verbose-buffers"
    ;; claude-agent: usage & mode-line
    "claude-agent-usage-callback"
    "claude-agent-usage-fetch"
    "claude-agent-usage-fetch-if-working-hours"
    "claude-agent-usage-format-reset-time"
    "claude-agent-usage-mode-line-start"
    "claude-agent-usage-mode-line-stop"
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
    ;; claude-agent-backend public API
    "claude-agent-backend-register"
    "claude-agent-backend-get"
    "claude-agent-backend-list"
    "claude-agent-backend-start"
    "claude-agent-backend-stop"
    "claude-agent-backend-send"
    "claude-agent-backend-cancel"
    "claude-agent-backend-filter-callbacks"
    ;; claude-org: core execution
    "claude-org-execute"
    "claude-org-cancel"
    "claude-org-cancel-all"
    "claude-org-cancel-queue"
    "claude-org-mode"
    "claude-org-setup"
    "claude-org-cleanup"
    ;; claude-org: navigation & insertion
    "claude-org-insert-ai-block"
    "claude-org-insert-block"
    "claude-org-insert-block-menu"
    "claude-org-insert-session-block"
    "claude-org-insert-template"
    "claude-org-insert-story"
    "claude-org-next-ai-block"
    "claude-org-prev-ai-block"
    "claude-org-jump-to-ai-block"
    "claude-org-goto-source"
    "claude-org-goto-custom-id"
    ;; claude-org: SDD workflow
    "claude-org-insert-sdd"
    "claude-org-tag-prompt"
    ;; claude-org: refine
    "claude-org-refine"
    "claude-org-refine-block"
    "claude-org-refine-prompt"
    ;; claude-org: session & connection management
    "claude-org-session-status"
    "claude-org-set-model"
    "claude-org-disconnect-all-clients"
    "claude-org-disconnect-all-sessions"
    "claude-org-disconnect-session"
    "claude-org-list-persistent-clients"
    "claude-org-list-sessions"
    "claude-org-show-session-info"
    "claude-org-show-verbose"
    ;; claude-org: response
    "claude-org-append-to-response"
    ;; claude-org: loop
    "claude-org-loop"
    "claude-org-loop-abort"
    "claude-org-loop-inject-warning"
    ;; claude-org: scheduling
    "claude-org-schedule-at"
    "claude-org-schedule-at-transient"
    "claude-org-schedule-cancel"
    "claude-org-schedule-list"
    "claude-org-schedule-clear-all"
    "claude-org-scheduled-list"
    "claude-org-scheduled-list-goto"
    "claude-org-scheduled-list-refresh"
    "claude-org-scheduled-scan-all"
    "claude-org-scheduled-start"
    "claude-org-scheduled-stop"
    "claude-org-scheduled-run"
    "claude-org-scheduled-cancel"
    ;; claude-org: header line & mode
    "claude-org-header-line"
    "claude-org-header-line-mode"
    ;; claude-org: permissions
    "claude-org-permission-protect-org"
    "claude-org-switch-permission-mode"
    ;; claude-org: native terminal
    "claude-org-open-native-terminal"
    "claude-org-native-mode"
    "claude-org-native-kill"
    "claude-org-native-refresh"
    "claude-org-native-menu"
    "claude-org-native-send-command"
    "claude-org-native-send-escape"
    "claude-org-native-send-interrupt"
    "claude-org-native-send-option"
    "claude-org-native-send-return"
    "claude-org-native-send-shift-tab"
    "claude-org-native-send-slash"
    "claude-org-native-toggle-copy-mode"
    ;; claude-org: iTerm2 backend
    "claude-org-iterm2-open-tab"
    "claude-org-iterm2-cancel"
    ;; claude-org: SDD bridge (terminal workflow)
    "claude-org-sdd-archive-workflow"
    "claude-org-sdd-bridge-get-cli-session"
    "claude-org-sdd-bridge-insert-prompt"
    "claude-org-sdd-bridge-insert-response"
    "claude-org-sdd-bridge-list-sessions"
    "claude-org-sdd-bridge-save-cli-session"
    "claude-org-sdd-bridge-send-prompt"
    "claude-org-sdd-bridge-system-prompt"
    "claude-org-sdd-bridge-update-todos"
    ;; claude-org: company completion
    "claude-org-company-slash-commands"
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
            ;; Normalize: claude-org-session maps to claude-org-session
            ;; We need module basenames (matching .org filenames without extension)
            (push req requires)))))
    (delete-dups requires)))

(defvar test-structural--module-layers
  '(("emacs-mcp-server"       . 0)   ; independent
    ("claude-agent-backend"    . 1)   ; bottom layer
    ("claude-agent-permission" . 1)
    ("claude-agent-ide"        . 1)
    ("claude-agent"            . 2)   ; core
    ("claude-org-session"      . 3)   ; org sub-modules
    ("claude-org-queue"        . 3)
    ("claude-org-response"     . 3)
    ("claude-org"              . 4)   ; top-level org
    ("claude-org-history"      . 5)   ; top extensions
    ("claude-org-scheduled"    . 5))
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

(provide 'test-structural)
;;; test-structural.el ends here
