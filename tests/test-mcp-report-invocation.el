;;; test-mcp-report-invocation.el --- Tests for report_invocation MCP tool -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for the report_invocation MCP tool which enables monitoring
;; of skill and rule invocations by the Claude agent.
;;
;; Tests verify:
;; - Handler function is defined
;; - Parameter validation (required type and name)
;; - Type validation (must be "skill" or "rule")
;; - Hook is called with correct arguments
;; - Return value format

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; Unit Tests - Function Definition

(ert-deftest test-mcp-report-invocation-handler-defined ()
  "Test that report_invocation handler function is defined."
  :tags '(:unit :fast :stable :mcp-invocation)
  (should (fboundp 'emacs-mcp-server--handler-report-invocation)))

(ert-deftest test-mcp-report-invocation-hook-defined ()
  "Test that code-agent-invocation-hook is defined."
  :tags '(:unit :fast :stable :mcp-invocation)
  (should (boundp 'code-agent-invocation-hook)))

(ert-deftest test-mcp-report-invocation-in-builtin-tools ()
  "Test that report_invocation is in the builtin tools list."
  :tags '(:unit :fast :stable :mcp-invocation)
  (should (boundp 'emacs-mcp-server--builtin-tools))
  (let ((tool (cl-find-if (lambda (t) (equal (alist-get 'name t) "report_invocation"))
                          emacs-mcp-server--builtin-tools)))
    (should tool)
    (should (alist-get 'handler tool))
    (should (alist-get 'inputSchema tool))
    (should (alist-get 'description tool))))

;;; Unit Tests - Parameter Validation

(ert-deftest test-mcp-report-invocation-missing-type-error ()
  "Test that missing type parameter causes an error."
  :tags '(:unit :fast :stable :mcp-invocation)
  (should-error
   (emacs-mcp-server--handler-report-invocation
    '((name . "test-skill"))
    nil)
   :type 'error))

(ert-deftest test-mcp-report-invocation-missing-name-error ()
  "Test that missing name parameter causes an error."
  :tags '(:unit :fast :stable :mcp-invocation)
  (should-error
   (emacs-mcp-server--handler-report-invocation
    '((type . "skill"))
    nil)
   :type 'error))

(ert-deftest test-mcp-report-invocation-invalid-type-error ()
  "Test that invalid type value causes an error."
  :tags '(:unit :fast :stable :mcp-invocation)
  (should-error
   (emacs-mcp-server--handler-report-invocation
    '((type . "invalid") (name . "test"))
    nil)
   :type 'error))

;;; Unit Tests - Hook Invocation

(ert-deftest test-mcp-report-invocation-calls-hook-for-skill ()
  "Test that hook is called with correct args for skill invocation."
  :tags '(:unit :fast :stable :mcp-invocation)
  (let ((hook-called nil)
        (captured-args nil))
    (cl-letf (((symbol-value 'code-agent-invocation-hook)
               (list (lambda (type name reason)
                       (setq hook-called t
                             captured-args (list type name reason))))))
      (emacs-mcp-server--handler-report-invocation
       '((type . "skill") (name . "commit") (reason . "user requested"))
       nil)
      (should hook-called)
      (should (equal (nth 0 captured-args) "skill"))
      (should (equal (nth 1 captured-args) "commit"))
      (should (equal (nth 2 captured-args) "user requested")))))

(ert-deftest test-mcp-report-invocation-calls-hook-for-rule ()
  "Test that hook is called with correct args for rule invocation."
  :tags '(:unit :fast :stable :mcp-invocation)
  (let ((hook-called nil)
        (captured-args nil))
    (cl-letf (((symbol-value 'code-agent-invocation-hook)
               (list (lambda (type name reason)
                       (setq hook-called t
                             captured-args (list type name reason))))))
      (emacs-mcp-server--handler-report-invocation
       '((type . "rule") (name . "no-emojis"))
       nil)
      (should hook-called)
      (should (equal (nth 0 captured-args) "rule"))
      (should (equal (nth 1 captured-args) "no-emojis"))
      (should (null (nth 2 captured-args))))))

;;; Unit Tests - Return Value

(ert-deftest test-mcp-report-invocation-returns-correct-format ()
  "Test that handler returns MCP-compatible response format."
  :tags '(:unit :fast :stable :mcp-invocation)
  (let ((code-agent-invocation-hook nil))  ; Disable hook
    (let ((result (emacs-mcp-server--handler-report-invocation
                   '((type . "skill") (name . "commit"))
                   nil)))
      ;; Should return list of content blocks
      (should (listp result))
      (should (= (length result) 1))
      ;; First block should have type and text
      (let ((block (car result)))
        (should (equal (alist-get 'type block) "text"))
        (should (stringp (alist-get 'text block)))
        (should (string-match-p "skill" (alist-get 'text block)))
        (should (string-match-p "commit" (alist-get 'text block)))))))

(provide 'test-mcp-report-invocation)
;;; test-mcp-report-invocation.el ends here
