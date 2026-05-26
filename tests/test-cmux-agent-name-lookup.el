;;; test-cmux-agent-name-lookup.el --- Cross-cmux-restart routing recovery  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Tests for `code-agent-org-cmux--lookup-session-by-agent-name', the Elisp
;; entry point the workspace bridge calls after cmux app restart to recover
;; (org-file, session-id, custom-id) when the WORKSPACE_* env vars are stale.
;;
;; The recovery contract is:
;;
;; 1. Heading title → slug conversion mirrors
;;    `claude_workspace._normalize_story_slug' EXACTLY (lowercase,
;;    [^a-z0-9]+ → -, strip edge dashes).  Any divergence breaks the
;;    cross-side handshake silently.
;; 2. Walks open org buffers, regex-scans for :CLAUDE_SESSION_ID: lines
;;    (much cheaper than org-map-entries — must stay <100ms even on a
;;    200kB notebook with 100+ headings).
;; 3. Returns `nil' when no slug matches; the bridge then falls back to
;;    env routing (legacy path).
;; 4. CWD tiebreaker only fires on duplicate-slug collisions across
;;    open buffers — rare in practice but possible when the user has
;;    two workspaces with same-named headings.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)

(unless (fboundp 'code-agent-org-cmux--lookup-session-by-agent-name)
  (let* ((tests-dir (file-name-directory (or load-file-name buffer-file-name)))
         (repo (file-name-directory (directory-file-name tests-dir))))
    (add-to-list 'load-path (expand-file-name "../literate-elisp" repo))
    (require 'literate-elisp)
    (dolist (mod '("claude-agent-trace.org"
                   "claude-agent.org"
                   "code-agent-org.org"
                   "code-agent-org-terminal-base.org"
                   "code-agent-org-cmux.org"))
      (literate-elisp-load (expand-file-name mod repo)))))

(defmacro test-cmux-name--with-buffers (specs &rest body)
  "Open temp org files for SPECS, run BODY, clean up.
SPECS is a list of (VAR CONTENT) bindings — for each, write CONTENT to a
fresh temp .org file and bind VAR to the file-backed buffer."
  (declare (indent 1) (debug t))
  (let ((paths (gensym "paths-"))
        (bufs (gensym "bufs-")))
    `(let* ((,paths nil)
            (,bufs nil)
            ,@(mapcar (lambda (spec) (list (car spec) nil)) specs))
       (unwind-protect
           (progn
             ,@(mapcar
                (lambda (spec)
                  (let ((var (car spec))
                        (content (cadr spec)))
                    `(let ((p (make-temp-file "test-cmux-name-" nil ".org")))
                       (push p ,paths)
                       (with-temp-file p (insert ,content))
                       (setq ,var (find-file-noselect p))
                       (push ,var ,bufs))))
                specs)
             ,@body)
         (dolist (b ,bufs)
           (when (and b (buffer-live-p b)) (kill-buffer b)))
         (dolist (p ,paths)
           (when (file-exists-p p) (delete-file p)))))))

;; --- normalize-name-slug --------------------------------------------------

(ert-deftest test-cmux-agent-name/normalize-space-to-dash ()
  "Heading with a space slugifies to dash, matching cmux's --name format."
  :tags '(:cmux-name :fast)
  (should (equal "edo-dev1" (code-agent-org-cmux--normalize-name-slug "edo dev1"))))

(ert-deftest test-cmux-agent-name/normalize-uppercase-to-lowercase ()
  "Heading with uppercase letters gets lowercased."
  :tags '(:cmux-name :fast)
  (should (equal "emacs-claude-dev1"
                 (code-agent-org-cmux--normalize-name-slug "Emacs-claude dev1"))))

(ert-deftest test-cmux-agent-name/normalize-punctuation-collapses-to-dash ()
  "Runs of non-alphanumeric collapse to a single dash."
  :tags '(:cmux-name :fast)
  (should (equal "pi-dev-1"
                 (code-agent-org-cmux--normalize-name-slug "Pi DEV (1)"))))

(ert-deftest test-cmux-agent-name/normalize-strips-edge-dashes ()
  "Leading/trailing whitespace + punctuation gone after strip."
  :tags '(:cmux-name :fast)
  (should (equal "edo" (code-agent-org-cmux--normalize-name-slug "  edo  "))))

(ert-deftest test-cmux-agent-name/normalize-nil-returns-empty ()
  "nil input is safe (bridge passes the slug as-is from PPID argv parse)."
  :tags '(:cmux-name :fast)
  (should (equal "" (code-agent-org-cmux--normalize-name-slug nil))))

;; --- lookup-session-by-agent-name -----------------------------------------

(defconst test-cmux-name--edo-org
  "#+TITLE: edo
* edo dev1
:PROPERTIES:
:CUSTOM_ID: mega-edo-dev1
:CLAUDE_SESSION_ID: sdd-edo-dev1
:PROJECT_ROOT: /edo
:END:

* edo dev2
:PROPERTIES:
:CUSTOM_ID: mega-edo-dev2
:CLAUDE_SESSION_ID: sdd-edo-dev2
:PROJECT_ROOT: /edo
:END:
")

(defconst test-cmux-name--other-org
  "#+TITLE: other
* claude-agent dev1
:PROPERTIES:
:CUSTOM_ID: claude-agent-dev1
:CLAUDE_SESSION_ID: sdd-claude-dev1
:PROJECT_ROOT: /claude-agent
:END:
")

(ert-deftest test-cmux-agent-name/lookup-hits-correct-buffer ()
  "Slug \"edo-dev1\" matches \"edo dev1\" heading in edo buffer."
  :tags '(:cmux-name :fast)
  (test-cmux-name--with-buffers ((b1 test-cmux-name--edo-org)
                                  (b2 test-cmux-name--other-org))
    (let ((r (code-agent-org-cmux--lookup-session-by-agent-name "edo-dev1" nil)))
      (should r)
      (should (equal (plist-get r :session-id) "sdd-edo-dev1"))
      (should (equal (plist-get r :custom-id) "mega-edo-dev1"))
      (should (equal (plist-get r :heading) "edo dev1"))
      (should (string-suffix-p ".org" (plist-get r :org-file))))))

(ert-deftest test-cmux-agent-name/lookup-finds-cross-file ()
  "Slug \"claude-agent-dev1\" routes to the OTHER buffer, not the edo one."
  :tags '(:cmux-name :fast)
  (test-cmux-name--with-buffers ((b1 test-cmux-name--edo-org)
                                  (b2 test-cmux-name--other-org))
    (let ((r (code-agent-org-cmux--lookup-session-by-agent-name
              "claude-agent-dev1" nil)))
      (should r)
      (should (equal (plist-get r :session-id) "sdd-claude-dev1")))))

(ert-deftest test-cmux-agent-name/lookup-returns-nil-when-no-match ()
  "Bridge keys off the empty/nil result to fall back to env routing."
  :tags '(:cmux-name :fast)
  (test-cmux-name--with-buffers ((b1 test-cmux-name--edo-org))
    (should (null (code-agent-org-cmux--lookup-session-by-agent-name
                   "no-such-session" nil)))))

(ert-deftest test-cmux-agent-name/lookup-empty-slug-returns-nil ()
  "Empty input cannot match anything (avoids `null slug == empty heading')."
  :tags '(:cmux-name :fast)
  (test-cmux-name--with-buffers ((b1 test-cmux-name--edo-org))
    (should (null (code-agent-org-cmux--lookup-session-by-agent-name "" nil)))))

(ert-deftest test-cmux-agent-name/lookup-cwd-tiebreaker-prefers-exact ()
  "Duplicate slugs across two buffers → exact :PROJECT_ROOT match wins."
  :tags '(:cmux-name :fast)
  (test-cmux-name--with-buffers
      ((b1 "#+TITLE: edo
* dup name
:PROPERTIES:
:CLAUDE_SESSION_ID: sdd-from-edo
:PROJECT_ROOT: /edo
:END:
")
       (b2 "#+TITLE: other
* dup name
:PROPERTIES:
:CLAUDE_SESSION_ID: sdd-from-other
:PROJECT_ROOT: /other
:END:
"))
    (let ((r (code-agent-org-cmux--lookup-session-by-agent-name
              "dup-name" "/other")))
      (should r)
      (should (equal (plist-get r :session-id) "sdd-from-other")))))

(ert-deftest test-cmux-agent-name/as-string-formats-with-nul-separators ()
  "Bridge entry point returns file\\0sid\\0cid; empty string on no match."
  :tags '(:cmux-name :fast)
  (test-cmux-name--with-buffers ((b1 test-cmux-name--edo-org))
    (let ((r (code-agent-org-cmux--lookup-session-by-agent-name-as-string
              "edo-dev1" "")))
      (should (string-match-p "\0sdd-edo-dev1\0mega-edo-dev1" r))
      (should (string-suffix-p "mega-edo-dev1" r)))
    (should (equal ""
                   (code-agent-org-cmux--lookup-session-by-agent-name-as-string
                    "nonexistent" "")))))

(provide 'test-cmux-agent-name-lookup)
;;; test-cmux-agent-name-lookup.el ends here
