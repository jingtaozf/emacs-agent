;;; test-mcp-protocol.el --- Tests for MCP protocol dispatch layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; TDD tests for emacs-mcp-server MCP protocol handling.
;; Tests dispatch routing, initialize handshake, tools/list,
;; tools/call, and schema conversion — all without HTTP.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-mcp-server)

;;; Test Helpers

(defmacro test-mcp-proto--with-clean-state (&rest body)
  "Run BODY with a clean MCP server state (no registered tools, empty sessions)."
  (declare (indent 0) (debug t))
  `(let ((emacs-mcp-server--tools '())
         (emacs-mcp-server--sessions (make-hash-table :test 'equal))
         (emacs-mcp-server--port 9999))
     ,@body))

;;; Tests: Dispatch Routing

(ert-deftest test-mcp-proto-dispatch-initialize ()
  "Dispatch routes 'initialize' and returns protocol version + capabilities."
  :tags '(:unit :fast :stable :mcp-protocol)
  (test-mcp-proto--with-clean-state
    (let ((result (emacs-mcp-server--dispatch "initialize" nil)))
      ;; initialize returns (session-id . response-alist)
      (should (consp result))
      (should (stringp (car result)))  ;; session ID
      (let ((response (cdr result)))
        (should (equal (alist-get 'protocolVersion response)
                       emacs-mcp-server-protocol-version))
        (should (assq 'capabilities response))
        (should (assq 'serverInfo response))))))

(ert-deftest test-mcp-proto-dispatch-tools-list ()
  "Dispatch routes 'tools/list' and returns builtin tools."
  :tags '(:unit :fast :stable :mcp-protocol)
  (test-mcp-proto--with-clean-state
    (let* ((result (emacs-mcp-server--dispatch "tools/list" nil))
           (tools (alist-get 'tools result)))
      ;; Should return a vector of tools
      (should (vectorp tools))
      ;; Should contain at least evalElisp and report_invocation
      (let ((names (mapcar (lambda (t) (alist-get 'name t))
                           (append tools nil))))
        (should (member "evalElisp" names))
        (should (member "report_invocation" names))))))

(ert-deftest test-mcp-proto-dispatch-tools-call ()
  "Dispatch routes 'tools/call' and invokes the named tool handler."
  :tags '(:unit :fast :stable :mcp-protocol)
  (test-mcp-proto--with-clean-state
    (let ((handler-called nil)
          (handler-args nil))
      ;; Register a mock tool
      (push `((name . "test-tool")
              (description . "A test tool")
              (handler . ,(lambda (params _session)
                            (setq handler-called t
                                  handler-args params)
                            (list `((type . "text") (text . "ok"))))))
            emacs-mcp-server--tools)
      ;; Call it via dispatch
      (let ((result (emacs-mcp-server--dispatch
                     "tools/call"
                     `((name . "test-tool")
                       (arguments . ((foo . "bar")))))))
        (should handler-called)
        (should (equal (alist-get 'foo handler-args) "bar"))
        (should (assq 'content result))))))

(ert-deftest test-mcp-proto-dispatch-unknown-method ()
  "Dispatch signals error for unknown methods.
FIX: Add the method to --dispatch pcase or check for typos."
  :tags '(:unit :fast :stable :mcp-protocol)
  (test-mcp-proto--with-clean-state
    (should-error
     (emacs-mcp-server--dispatch "nonexistent/method" nil)
     :type 'error)))

(ert-deftest test-mcp-proto-dispatch-prompts-list ()
  "Dispatch returns empty prompts array for MCP compliance."
  :tags '(:unit :fast :stable :mcp-protocol)
  (test-mcp-proto--with-clean-state
    (let ((result (emacs-mcp-server--dispatch "prompts/list" nil)))
      (should (equal (alist-get 'prompts result) [])))))

(ert-deftest test-mcp-proto-dispatch-resources-list ()
  "Dispatch returns empty resources array for MCP compliance."
  :tags '(:unit :fast :stable :mcp-protocol)
  (test-mcp-proto--with-clean-state
    (let ((result (emacs-mcp-server--dispatch "resources/list" nil)))
      (should (equal (alist-get 'resources result) [])))))

;;; Tests: Initialize Handler

(ert-deftest test-mcp-proto-initialize-creates-session ()
  "Initialize stores session in hash table.
FIX: Check that --handle-initialize calls puthash on --sessions."
  :tags '(:unit :fast :stable :mcp-protocol)
  (test-mcp-proto--with-clean-state
    (let ((result (emacs-mcp-server--handle-initialize nil)))
      (should (consp result))
      (let ((session-id (car result)))
        (should (stringp session-id))
        (should (> (length session-id) 0))
        ;; Session should be in the hash table
        (should (gethash session-id emacs-mcp-server--sessions))))))

;;; Tests: Tools/Call Errors

(ert-deftest test-mcp-proto-tools-call-unknown-tool ()
  "tools/call signals error for unknown tool name.
FIX: Register the tool with emacs-mcp-server-register-tool before calling."
  :tags '(:unit :fast :stable :mcp-protocol)
  (test-mcp-proto--with-clean-state
    (should-error
     (emacs-mcp-server--handle-tools-call
      `((name . "nonexistent-tool") (arguments . nil))
      nil)
     :type 'error)))

;;; Tests: Schema Conversion

(ert-deftest test-mcp-proto-fix-empty-alists ()
  "fix-empty-alists converts nil to empty hash table for JSON encoding.
FIX: Ensure alist values use empty hash tables, not nil, for MCP compliance."
  :tags '(:unit :fast :stable :mcp-protocol)
  ;; nil → empty hash table
  (let ((result (emacs-mcp-server--fix-empty-alists nil)))
    (should (hash-table-p result))
    (should (= 0 (hash-table-count result))))
  ;; Nested nil in alist
  (let ((result (emacs-mcp-server--fix-empty-alists
                 '((properties . nil)))))
    (should (consp result))
    (should (hash-table-p (cdr (car result)))))
  ;; Non-nil passes through
  (should (equal (emacs-mcp-server--fix-empty-alists "hello") "hello"))
  (should (equal (emacs-mcp-server--fix-empty-alists 42) 42)))

(ert-deftest test-mcp-proto-tool-to-mcp-format ()
  "tool-to-mcp-format strips handler and fixes schema.
FIX: Ensure tool specs include name, description, and inputSchema keys."
  :tags '(:unit :fast :stable :mcp-protocol)
  (let* ((tool `((name . "my-tool")
                 (description . "Does stuff")
                 (handler . ,(lambda (&rest _) nil))
                 (inputSchema . ((type . "object")
                                 (properties . nil)))))
         (result (emacs-mcp-server--tool-to-mcp-format tool)))
    ;; Should have name and description
    (should (equal (alist-get 'name result) "my-tool"))
    (should (equal (alist-get 'description result) "Does stuff"))
    ;; Should NOT have handler
    (should-not (assq 'handler result))
    ;; inputSchema properties should be hash table (not nil)
    (let* ((schema (alist-get 'inputSchema result))
           (props (alist-get 'properties schema)))
      (should (hash-table-p props)))))

(provide 'test-mcp-protocol)
;;; test-mcp-protocol.el ends here
