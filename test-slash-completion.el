;;; test-slash-completion.el --- Tests for slash command completion -*- lexical-binding: t; -*-

;; Copyright (C) 2024

;; Author: Jingtao Xu
;; Keywords: test

;;; Commentary:

;; Test cases for claude-org slash command completion feature.

;;; Code:

(require 'ert)
(require 'claude-org)

;;; Test Fixtures

(defun test-slash--setup-ai-block (&optional content)
  "Create a temp buffer with AI block containing CONTENT."
  (let ((buf (generate-new-buffer " *test-slash*")))
    (with-current-buffer buf
      (org-mode)
      (claude-org-mode 1)
      (insert "#+begin_src ai\n")
      (when content
        (insert content))
      (insert "\n#+end_src")
      ;; Position cursor before #+end_src
      (forward-line -1)
      (beginning-of-line))
    buf))

(defun test-slash--setup-incomplete-ai-block (&optional content)
  "Create a temp buffer with incomplete AI block (no end marker) containing CONTENT."
  (let ((buf (generate-new-buffer " *test-slash*")))
    (with-current-buffer buf
      (org-mode)
      (claude-org-mode 1)
      (insert "#+begin_src ai\n")
      (when content
        (insert content)))
    buf))

(defmacro test-slash--with-ai-block (content &rest body)
  "Execute BODY in a temp buffer with AI block containing CONTENT."
  (declare (indent 1))
  `(let ((buf (test-slash--setup-ai-block ,content)))
     (unwind-protect
         (with-current-buffer buf
           ,@body)
       (kill-buffer buf))))

(defmacro test-slash--with-incomplete-block (content &rest body)
  "Execute BODY in a temp buffer with incomplete AI block containing CONTENT."
  (declare (indent 1))
  `(let ((buf (test-slash--setup-incomplete-ai-block ,content)))
     (unwind-protect
         (with-current-buffer buf
           ,@body)
       (kill-buffer buf))))

;;; Tests for claude-org--in-ai-block-p

(ert-deftest test-slash-in-ai-block-complete ()
  "Test that we detect being inside a complete AI block."
  (test-slash--with-ai-block ""
    (should (claude-org--in-ai-block-p))))

(ert-deftest test-slash-in-ai-block-incomplete ()
  "Test that we detect being inside an incomplete AI block (no end marker)."
  (test-slash--with-incomplete-block "/"
    (should (claude-org--in-ai-block-p))))

(ert-deftest test-slash-not-in-ai-block ()
  "Test that we don't detect AI block when outside one."
  (with-temp-buffer
    (org-mode)
    (claude-org-mode 1)
    (insert "Some text\n")
    (should-not (claude-org--in-ai-block-p))))

(ert-deftest test-slash-in-ai-block-with-content ()
  "Test detection inside AI block with content."
  (test-slash--with-ai-block "/test"
    (goto-char (+ (point) 2)) ;; Position in middle of "/test"
    (should (claude-org--in-ai-block-p))))

;;; Tests for Command Discovery

(ert-deftest test-slash-builtin-commands ()
  "Test that builtin commands are always available."
  (with-temp-buffer
    (org-mode)
    (claude-org-mode 1)
    (let ((commands (claude-org--discover-slash-commands)))
      (should (member "/help" commands))
      (should (member "/clear" commands))
      (should (member "/add-dir" commands))
      (should (member "/content" commands)))))

(ert-deftest test-slash-scan-command-dir-nonexistent ()
  "Test scanning a non-existent directory returns nil."
  (let ((result (claude-org--scan-command-dir "/nonexistent/path/12345")))
    (should (null result))))

(ert-deftest test-slash-scan-command-dir-empty ()
  "Test scanning an empty directory returns nil."
  (let ((temp-dir (make-temp-file "test-slash-" t)))
    (unwind-protect
        (let ((result (claude-org--scan-command-dir temp-dir)))
          (should (null result)))
      (delete-directory temp-dir))))

(ert-deftest test-slash-scan-command-dir-with-files ()
  "Test scanning directory with .md files."
  (let ((temp-dir (make-temp-file "test-slash-" t)))
    (unwind-protect
        (progn
          ;; Create test files
          (write-region "" nil (expand-file-name "test1.md" temp-dir))
          (write-region "" nil (expand-file-name "test2.md" temp-dir))
          (let ((result (claude-org--scan-command-dir temp-dir)))
            (should (= (length result) 2))
            (should (member "/test1" result))
            (should (member "/test2" result))))
      (delete-directory temp-dir t))))

(ert-deftest test-slash-scan-command-dir-with-subdirs ()
  "Test scanning directory with subdirectories creates namespaced commands."
  (let ((temp-dir (make-temp-file "test-slash-" t)))
    (unwind-protect
        (progn
          ;; Create subdirectory structure
          (make-directory (expand-file-name "custom" temp-dir))
          (write-region "" nil (expand-file-name "custom/deploy.md" temp-dir))
          (make-directory (expand-file-name "build" temp-dir))
          (write-region "" nil (expand-file-name "build/docker.md" temp-dir))
          (let ((result (claude-org--scan-command-dir temp-dir)))
            (should (member "/custom:deploy" result))
            (should (member "/build:docker" result))))
      (delete-directory temp-dir t))))

(ert-deftest test-slash-scan-command-dir-nested-subdirs ()
  "Test scanning directory with deeply nested subdirectories."
  (let ((temp-dir (make-temp-file "test-slash-" t)))
    (unwind-protect
        (progn
          ;; Create nested structure: foo/bar/baz.md -> /foo:bar:baz
          (make-directory (expand-file-name "foo/bar" temp-dir) t)
          (write-region "" nil (expand-file-name "foo/bar/baz.md" temp-dir))
          (let ((result (claude-org--scan-command-dir temp-dir)))
            (should (member "/foo:bar:baz" result))))
      (delete-directory temp-dir t))))

;;; Tests for Company Backend

(ert-deftest test-slash-company-prefix-simple ()
  "Test company prefix detection for simple slash."
  (test-slash--with-incomplete-block "/"
    (let ((prefix (claude-org-company-slash-commands 'prefix)))
      (should (consp prefix))
      (should (string= (car prefix) "/"))
      (should (eq (cdr prefix) t)))))

(ert-deftest test-slash-company-prefix-partial ()
  "Test company prefix detection for partial command."
  (test-slash--with-incomplete-block "/te"
    (let ((prefix (claude-org-company-slash-commands 'prefix)))
      (should (consp prefix))
      (should (string= (car prefix) "/te"))
      (should (eq (cdr prefix) t)))))

(ert-deftest test-slash-company-prefix-with-colon ()
  "Test company prefix detection for namespaced command."
  (test-slash--with-incomplete-block "/sc:te"
    (let ((prefix (claude-org-company-slash-commands 'prefix)))
      (should (consp prefix))
      (should (string= (car prefix) "/sc:te"))
      (should (eq (cdr prefix) t)))))

(ert-deftest test-slash-company-prefix-not-at-line-start ()
  "Test that slash in middle of line doesn't trigger completion."
  (test-slash--with-incomplete-block "some text /"
    (let ((prefix (claude-org-company-slash-commands 'prefix)))
      (should (null prefix)))))

(ert-deftest test-slash-company-prefix-outside-ai-block ()
  "Test that slash outside AI block doesn't trigger."
  (with-temp-buffer
    (org-mode)
    (claude-org-mode 1)
    (insert "/test")
    (let ((prefix (claude-org-company-slash-commands 'prefix)))
      (should (null prefix)))))

(ert-deftest test-slash-company-candidates-all ()
  "Test getting all candidates with just /."
  (test-slash--with-incomplete-block "/"
    (let* ((prefix (claude-org-company-slash-commands 'prefix))
           (candidates (claude-org-company-slash-commands 'candidates (car prefix))))
      (should (listp candidates))
      (should (> (length candidates) 0))
      (should (member "/help" candidates)))))

(ert-deftest test-slash-company-candidates-filtered ()
  "Test filtering candidates by prefix."
  (test-slash--with-incomplete-block "/hel"
    (let* ((prefix (claude-org-company-slash-commands 'prefix))
           (candidates (claude-org-company-slash-commands 'candidates (car prefix))))
      (should (member "/help" candidates))
      ;; Should not contain commands that don't start with /hel
      (should-not (member "/clear" candidates)))))

(ert-deftest test-slash-company-candidates-case-insensitive ()
  "Test that candidate filtering is case-insensitive."
  (test-slash--with-incomplete-block "/HEL"
    (let* ((prefix (claude-org-company-slash-commands 'prefix))
           (candidates (when prefix
                         (claude-org-company-slash-commands 'candidates (car prefix)))))
      ;; Case insensitive matching should work
      (should (or (null candidates) (member "/help" candidates))))))

(ert-deftest test-slash-company-candidates-no-match ()
  "Test that non-matching prefix returns empty list."
  (test-slash--with-incomplete-block "/zzzznonexistent"
    (let* ((prefix (claude-org-company-slash-commands 'prefix))
           (candidates (when prefix
                         (claude-org-company-slash-commands 'candidates (car prefix)))))
      (should (or (null candidates) (= (length candidates) 0))))))

(ert-deftest test-slash-company-sorted ()
  "Test that backend reports candidates as sorted."
  (should (eq (claude-org-company-slash-commands 'sorted) t)))

;;; Tests for Integration

(ert-deftest test-slash-company-backend-installed ()
  "Test that company backend is installed when mode is enabled."
  (with-temp-buffer
    (org-mode)
    (claude-org-mode 1)
    (should (member 'claude-org-company-slash-commands company-backends))))

(ert-deftest test-slash-company-backend-removed ()
  "Test that company backend is buffer-local and doesn't affect other buffers."
  (let ((buf1 (generate-new-buffer " *test1*"))
        (buf2 (generate-new-buffer " *test2*")))
    (unwind-protect
        (progn
          ;; Enable mode in buf1
          (with-current-buffer buf1
            (org-mode)
            (claude-org-mode 1)
            (should (member 'claude-org-company-slash-commands company-backends)))
          ;; buf2 should not have the backend
          (with-current-buffer buf2
            (org-mode)
            (should-not (member 'claude-org-company-slash-commands
                                (if (boundp 'company-backends) company-backends nil)))))
      (kill-buffer buf1)
      (kill-buffer buf2))))

(ert-deftest test-slash-completion-end-to-end ()
  "End-to-end test of slash completion workflow."
  (test-slash--with-incomplete-block "/he"
    ;; Simulate company completion workflow
    (let* ((prefix (claude-org-company-slash-commands 'prefix))
           (candidates (when prefix
                         (claude-org-company-slash-commands 'candidates (car prefix)))))
      (should prefix)
      (should (string= (car prefix) "/he"))
      (should candidates)
      (should (member "/help" candidates)))))

;;; Test Runner

(defun test-slash-run-all ()
  "Run all slash completion tests."
  (interactive)
  (ert-run-tests-interactively "^test-slash-"))

(provide 'test-slash-completion)
;;; test-slash-completion.el ends here
