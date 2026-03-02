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

(provide 'test-structural)
;;; test-structural.el ends here
