;;; test-mcp-lifecycle.el --- Tests for MCP server lifecycle -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; TDD tests for MCP server lifecycle: tool registration,
;; start/stop state, and helper functions.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-mcp-server)

;;; Test Helpers

(defmacro test-mcp-life--with-clean-state (&rest body)
  "Run BODY with clean MCP server state."
  (declare (indent 0) (debug t))
  `(let ((emacs-mcp-server--tools '())
         (emacs-mcp-server--server nil)
         (emacs-mcp-server--port nil)
         (emacs-mcp-server--sessions (make-hash-table :test 'equal))
         (emacs-mcp-server--spinner-timer nil)
         (emacs-mcp-server--eval-active nil)
         (emacs-mcp-server--eval-count 0))
     ,@body))

;;; Tests: Tool Registration

(ert-deftest test-mcp-life-register-tool-adds ()
  "register-tool adds tool to the tools list."
  :tags '(:unit :fast :stable :mcp-lifecycle)
  (test-mcp-life--with-clean-state
    (emacs-mcp-server-register-tool
     `((name . "foo") (handler . ,(lambda (&rest _) nil))))
    (should (= 1 (length emacs-mcp-server--tools)))
    (should (equal "foo" (alist-get 'name (car emacs-mcp-server--tools))))))

(ert-deftest test-mcp-life-register-tool-requires-name ()
  "register-tool errors without name.
FIX: Add (name . \"tool-name\") to your tool-spec alist."
  :tags '(:unit :fast :stable :mcp-lifecycle)
  (test-mcp-life--with-clean-state
    (should-error
     (emacs-mcp-server-register-tool
      `((handler . ,(lambda (&rest _) nil))))
     :type 'error)))

(ert-deftest test-mcp-life-register-tool-requires-handler ()
  "register-tool errors without handler.
FIX: Add (handler . #'my-handler-fn) to your tool-spec alist."
  :tags '(:unit :fast :stable :mcp-lifecycle)
  (test-mcp-life--with-clean-state
    (should-error
     (emacs-mcp-server-register-tool
      `((name . "no-handler")))
     :type 'error)))

(ert-deftest test-mcp-life-register-replaces-same-name ()
  "register-tool replaces existing tool with same name."
  :tags '(:unit :fast :stable :mcp-lifecycle)
  (test-mcp-life--with-clean-state
    (emacs-mcp-server-register-tool
     `((name . "foo") (description . "v1")
       (handler . ,(lambda (&rest _) nil))))
    (emacs-mcp-server-register-tool
     `((name . "foo") (description . "v2")
       (handler . ,(lambda (&rest _) nil))))
    ;; Should be exactly 1 tool, not 2
    (should (= 1 (length emacs-mcp-server--tools)))
    (should (equal "v2" (alist-get 'description (car emacs-mcp-server--tools))))))

(ert-deftest test-mcp-life-unregister-removes ()
  "unregister-tool removes tool by name."
  :tags '(:unit :fast :stable :mcp-lifecycle)
  (test-mcp-life--with-clean-state
    (emacs-mcp-server-register-tool
     `((name . "foo") (handler . ,(lambda (&rest _) nil))))
    (emacs-mcp-server-unregister-tool "foo")
    (should (= 0 (length emacs-mcp-server--tools)))))

(ert-deftest test-mcp-life-clear-tools ()
  "clear-tools empties the tools list."
  :tags '(:unit :fast :stable :mcp-lifecycle)
  (test-mcp-life--with-clean-state
    (emacs-mcp-server-register-tool
     `((name . "a") (handler . ,(lambda (&rest _) nil))))
    (emacs-mcp-server-register-tool
     `((name . "b") (handler . ,(lambda (&rest _) nil))))
    (emacs-mcp-server-register-tool
     `((name . "c") (handler . ,(lambda (&rest _) nil))))
    (emacs-mcp-server-clear-tools)
    (should (= 0 (length emacs-mcp-server--tools)))))

;;; Tests: Server State

(ert-deftest test-mcp-life-running-p-reflects-state ()
  "running-p returns nil when stopped, non-nil when running."
  :tags '(:unit :fast :stable :mcp-lifecycle)
  (test-mcp-life--with-clean-state
    ;; Initially stopped
    (should-not (emacs-mcp-server-running-p))
    ;; Simulate running
    (setq emacs-mcp-server--server t
          emacs-mcp-server--port 9999)
    (should (emacs-mcp-server-running-p))))

(ert-deftest test-mcp-life-port-returns-current ()
  "port returns current port or nil."
  :tags '(:unit :fast :stable :mcp-lifecycle)
  (test-mcp-life--with-clean-state
    (should-not (emacs-mcp-server-port))
    (setq emacs-mcp-server--port 8080)
    (should (= 8080 (emacs-mcp-server-port)))))

;;; Tests: Helper Functions

(ert-deftest test-mcp-life-truncate-edge-cases ()
  "truncate handles edge cases correctly.
FIX: Check emacs-mcp-server-max-output-length setting."
  :tags '(:unit :fast :stable :mcp-lifecycle)
  ;; Short string — no truncation
  (should (equal "hi" (emacs-mcp-server--truncate "hi" 100)))
  ;; Exact length — no truncation
  (should (equal "abc" (emacs-mcp-server--truncate "abc" 3)))
  ;; Over limit — truncated with ... (total length = max-len)
  (let ((result (emacs-mcp-server--truncate "abcdefgh" 5)))
    (should (= 5 (length result)))  ;; "ab..."
    (should (equal "ab..." result))
    (should (string-suffix-p "..." result)))
  ;; Empty string
  (should (equal "" (emacs-mcp-server--truncate "" 10))))

(ert-deftest test-mcp-life-pp-to-string-edge-values ()
  "pp-to-string handles various value types without error.
FIX: Check that eval result is serializable."
  :tags '(:unit :fast :stable :mcp-lifecycle)
  ;; nil
  (should (stringp (emacs-mcp-server--pp-to-string nil)))
  ;; Number
  (should (stringp (emacs-mcp-server--pp-to-string 42)))
  ;; String
  (should (stringp (emacs-mcp-server--pp-to-string "hello")))
  ;; List
  (should (stringp (emacs-mcp-server--pp-to-string '(1 2 3))))
  ;; Hash table (not directly printable in some contexts)
  (should (stringp (emacs-mcp-server--pp-to-string
                    (make-hash-table)))))

(provide 'test-mcp-lifecycle)
;;; test-mcp-lifecycle.el ends here
