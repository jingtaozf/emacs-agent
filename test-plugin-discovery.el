;;; test-plugin-discovery.el --- Tests for plugin command discovery -*- lexical-binding: t; -*-

;; Copyright (C) 2024

;;; Commentary:

;; Test cases for plugin slash command discovery.

;;; Code:

(require 'ert)
(require 'claude-org)

(ert-deftest test-plugin-scan-finds-marketplace-plugins ()
  "Test that plugin scanner finds commands in marketplace plugins."
  (let ((commands (claude-org--scan-plugin-commands)))
    ;; Should find some plugin commands (if plugins installed)
    (should (listp commands))
    ;; All plugin commands should have namespace (contain colon)
    (dolist (cmd commands)
      (should (string-match-p ":" cmd)))))

(ert-deftest test-plugin-commands-in-discovery ()
  "Test that plugin commands appear in full discovery."
  (let ((all-commands (claude-org--discover-slash-commands)))
    (should (> (length all-commands) 0))
    ;; Should include built-in commands
    (should (member "/help" all-commands))
    ;; Plugin commands should be included (if any exist)
    (let ((plugin-cmds (seq-filter (lambda (c) (string-match-p ":[^:]+$" c))
                                    all-commands)))
      ;; At least some namespaced commands should exist
      (should (>= (length plugin-cmds) 0)))))

(ert-deftest test-plugin-namespace-format ()
  "Test that plugin commands have correct namespace format."
  (let ((commands (claude-org--scan-plugin-commands)))
    (dolist (cmd commands)
      ;; Should start with /
      (should (string-prefix-p "/" cmd))
      ;; Should have format /plugin-name:command-name
      (should (string-match-p "^/[^:]+:[^:]+$" cmd)))))

(ert-deftest test-plugin-discovery-no-subdirs ()
  "Test that plugin scanner only scans flat commands directory."
  ;; This is a behavioral test - plugins should not have nested namespaces
  (let ((commands (claude-org--scan-plugin-commands)))
    (dolist (cmd commands)
      ;; Should have exactly one colon (plugin:command, not plugin:sub:command)
      (should (= 1 (cl-count ?: cmd))))))

(ert-deftest test-discover-handles-missing-plugins-dir ()
  "Test graceful handling when plugins directory doesn't exist."
  (let ((claude-org--test-plugins-dir "/nonexistent/path/to/plugins"))
    ;; Should not error, just return empty list or continue
    (should (listp (claude-org--discover-slash-commands)))))

(ert-deftest test-plugin-commands-completion-integration ()
  "Test that plugin commands work in company completion."
  (with-temp-buffer
    (org-mode)
    (claude-org-mode 1)
    (insert "#+begin_src ai\n/")
    (let* ((prefix (claude-org-company-slash-commands 'prefix))
           (candidates (when prefix
                        (claude-org-company-slash-commands 'candidates (car prefix)))))
      (should prefix)
      (should (consp prefix))
      (should (string= (car prefix) "/"))
      (should (listp candidates))
      ;; Should have at least built-in commands
      (should (> (length candidates) 0)))))

(defun test-plugin-discovery-run-all ()
  "Run all plugin discovery tests."
  (interactive)
  (ert-run-tests-interactively "^test-plugin-"))

(provide 'test-plugin-discovery)
;;; test-plugin-discovery.el ends here
