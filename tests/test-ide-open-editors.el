;;; test-ide-open-editors.el --- Tests for getOpenEditors filtering -*- lexical-binding: t -*-

;;; Commentary:

;; Tests that claude-ide-default-get-open-editors-tool correctly excludes
;; claude-org-mode buffers and applies buffer exclusion filters.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)

;; Load project source
(let ((project-root (file-name-directory
                     (directory-file-name
                      (file-name-directory
                       (or load-file-name buffer-file-name))))))
  (require 'literate-elisp)
  (literate-elisp-load (expand-file-name "claude-agent-trace.org" project-root))
  (literate-elisp-load (expand-file-name "claude-agent.org" project-root))
  (literate-elisp-load (expand-file-name "claude-agent-backend.org" project-root))
  (literate-elisp-load (expand-file-name "claude-org.org" project-root))
  (literate-elisp-load (expand-file-name "claude-ide.org" project-root)))

;;; ============================================================================
;;; Helpers
;;; ============================================================================

(defun test-ide--parse-editors (result)
  "Parse the editors list from a getOpenEditors MCP result."
  (let* ((text (cdr (assq 'text (car result))))
         (json-obj (json-read-from-string text)))
    (cdr (assq 'editors json-obj))))

(defun test-ide--editor-paths (result)
  "Extract file paths from a getOpenEditors result."
  (mapcar (lambda (e) (cdr (assq 'path e)))
          (test-ide--parse-editors result)))

;;; ============================================================================
;;; Tests
;;; ============================================================================

(ert-deftest test-ide-open-editors-excludes-claude-org-mode ()
  "Buffers with claude-org-mode should be excluded from getOpenEditors.
Regression: notebook files appeared in the IDE editors list, polluting
Claude Code's file context."
  :tags '(:unit :stable)
  (let ((org-file (make-temp-file "test-notebook-" nil ".org"))
        (py-file (make-temp-file "test-source-" nil ".py")))
    (unwind-protect
        (let ((org-buf (find-file-noselect org-file))
              (py-buf (find-file-noselect py-file)))
          ;; Enable claude-org-mode on the org buffer (suppress MCP auto-start)
          (with-current-buffer org-buf
            (org-mode)
            (let ((claude-org-auto-start-mcp-server nil))
              (claude-org-mode 1)))
          ;; Get open editors
          (let ((paths (test-ide--editor-paths
                        (claude-ide-default-get-open-editors-tool))))
            ;; Python file should be included
            (should (member py-file paths))
            ;; Org notebook should be excluded
            (should-not (member org-file paths)))
          ;; Clean up buffers
          (kill-buffer org-buf)
          (kill-buffer py-buf))
      (delete-file org-file)
      (delete-file py-file))))

(ert-deftest test-ide-open-editors-includes-normal-org ()
  "Org buffers WITHOUT claude-org-mode should still be included."
  :tags '(:unit :stable)
  (let ((org-file (make-temp-file "test-normal-" nil ".org")))
    (unwind-protect
        (let ((buf (find-file-noselect org-file)))
          (with-current-buffer buf (org-mode))
          (let ((paths (test-ide--editor-paths
                        (claude-ide-default-get-open-editors-tool))))
            (should (member org-file paths)))
          (kill-buffer buf))
      (delete-file org-file))))

(ert-deftest test-ide-open-editors-respects-count-limit ()
  "getOpenEditors should cap results at 20 buffers."
  :tags '(:unit :stable)
  (let ((files (cl-loop for i below 25
                        collect (make-temp-file (format "test-limit-%d-" i) nil ".txt"))))
    (unwind-protect
        (let ((bufs (mapcar #'find-file-noselect files)))
          (let ((editors (test-ide--parse-editors
                          (claude-ide-default-get-open-editors-tool))))
            ;; Should be capped (may be less if other excluded buffers exist)
            (should (<= (length editors) 20)))
          (mapc #'kill-buffer bufs))
      (mapc #'delete-file files))))

(provide 'test-ide-open-editors)

;;; test-ide-open-editors.el ends here
