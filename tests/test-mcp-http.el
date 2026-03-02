;;; test-mcp-http.el --- Tests for MCP HTTP response layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; TDD tests for MCP HTTP response construction and request handling.
;; Uses mock process objects — no real HTTP server needed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacs-mcp-server)

;;; Test Helpers

(defun test-mcp-http--make-mock-process ()
  "Create a mock process that captures sent strings.
Returns (process . captured-output-list)."
  (let* ((output-list (list nil))  ;; mutable cell
         (buf (generate-new-buffer " *test-mcp-http-mock*"))
         (proc (start-process "test-mcp-mock" buf "cat")))
    ;; Override process-send-string to capture output
    (cons proc output-list)))

(defmacro test-mcp-http--with-mock-process (&rest body)
  "Run BODY with a mock process, capturing all sent data.
Binds `mock-process' and `mock-sent' (a list accumulator).
Use (test-mcp-http--get-sent) to get concatenated output."
  (declare (indent 0) (debug t))
  `(let ((mock-sent '())
         (mock-process (make-symbol "mock-proc")))
     ;; Make it look like a live process
     (cl-letf (((symbol-function 'process-live-p)
                (lambda (p) (eq p mock-process)))
               ((symbol-function 'process-send-string)
                (lambda (_p str) (push str mock-sent))))
       ,@body)))

(defun test-mcp-http--get-sent (mock-sent)
  "Concatenate MOCK-SENT list into a single string (in send order)."
  (apply #'concat (nreverse mock-sent)))

;;; Tests: Raw HTTP Response

(ert-deftest test-mcp-http-raw-response-format ()
  "send-raw-response builds correct HTTP response with CRLF headers."
  :tags '(:unit :fast :stable :mcp-http)
  (test-mcp-http--with-mock-process
    (emacs-mcp-server--send-raw-response
     mock-process 200
     '(("Content-Type" . "application/json")
       ("Content-Length" . "13"))
     "{\"result\":42}")
    (let ((output (test-mcp-http--get-sent mock-sent)))
      ;; Status line
      (should (string-match-p "^HTTP/1\\.1 200 OK\r\n" output))
      ;; Headers with CRLF
      (should (string-match-p "Content-Type: application/json\r\n" output))
      (should (string-match-p "Content-Length: 13\r\n" output))
      ;; Blank line separator
      (should (string-match-p "\r\n\r\n" output))
      ;; Body
      (should (string-match-p "{\"result\":42}" output)))))

(ert-deftest test-mcp-http-raw-response-dead-process ()
  "send-raw-response silently handles nil/dead process.
FIX: Check that the MCP server process is still alive."
  :tags '(:unit :fast :stable :mcp-http)
  ;; nil process — should not error
  (should-not
   (condition-case err
       (progn
         (emacs-mcp-server--send-raw-response nil 200 nil "body")
         nil)
     (error err)))
  ;; Dead process — should not error
  (cl-letf (((symbol-function 'process-live-p) (lambda (_) nil)))
    (should-not
     (condition-case err
         (progn
           (emacs-mcp-server--send-raw-response 'fake 200 nil "body")
           nil)
       (error err)))))

(ert-deftest test-mcp-http-raw-response-status-codes ()
  "send-raw-response maps status codes to text correctly."
  :tags '(:unit :fast :stable :mcp-http)
  (dolist (pair '((200 . "OK") (202 . "Accepted")
                  (400 . "Bad Request") (404 . "Not Found")
                  (500 . "Internal Server Error")))
    (test-mcp-http--with-mock-process
      (emacs-mcp-server--send-raw-response
       mock-process (car pair) nil nil)
      (let ((output (test-mcp-http--get-sent mock-sent)))
        (should (string-match-p
                 (format "HTTP/1\\.1 %d %s" (car pair) (cdr pair))
                 output))))))

;;; Tests: JSON-RPC Response

(ert-deftest test-mcp-http-send-response-jsonrpc ()
  "send-response builds valid JSON-RPC 2.0 response body."
  :tags '(:unit :fast :stable :mcp-http)
  (test-mcp-http--with-mock-process
    ;; Create a minimal mock request with `process' slot
    (let ((request (make-instance 'ws-request)))
      (setf (slot-value request 'process) mock-process)
      (emacs-mcp-server--send-response
       request 1 '((tools . [])))
      (let* ((output (test-mcp-http--get-sent mock-sent))
             ;; Extract JSON body after blank line
             (body-start (+ 4 (string-match "\r\n\r\n" output)))
             (body (substring output body-start))
             (json (json-parse-string body :object-type 'alist)))
        (should (equal "2.0" (alist-get 'jsonrpc json)))
        (should (= 1 (alist-get 'id json)))
        (should (assq 'result json))))))

(ert-deftest test-mcp-http-send-response-session-header ()
  "send-response includes Mcp-Session-Id header when provided."
  :tags '(:unit :fast :stable :mcp-http)
  (test-mcp-http--with-mock-process
    (let ((request (make-instance 'ws-request)))
      (setf (slot-value request 'process) mock-process)
      (emacs-mcp-server--send-response
       request 1 '((ok . t)) "sess-abc-123")
      (let ((output (test-mcp-http--get-sent mock-sent)))
        (should (string-match-p "Mcp-Session-Id: sess-abc-123\r\n" output))))))

;;; Tests: Error Response

(ert-deftest test-mcp-http-send-error-format ()
  "send-error builds JSON-RPC error response with code and message."
  :tags '(:unit :fast :stable :mcp-http)
  (test-mcp-http--with-mock-process
    (let ((request (make-instance 'ws-request)))
      (setf (slot-value request 'process) mock-process)
      (emacs-mcp-server--send-error request 1 -32601 "Method not found")
      (let* ((output (test-mcp-http--get-sent mock-sent))
             (body-start (+ 4 (string-match "\r\n\r\n" output)))
             (body (substring output body-start))
             (json (json-parse-string body :object-type 'alist)))
        (should (equal "2.0" (alist-get 'jsonrpc json)))
        (should (= 1 (alist-get 'id json)))
        (let ((err (alist-get 'error json)))
          (should (= -32601 (alist-get 'code err)))
          (should (equal "Method not found" (alist-get 'message err))))))))

;;; Tests: Accepted Response

(ert-deftest test-mcp-http-send-accepted ()
  "send-accepted returns HTTP 202 with empty body."
  :tags '(:unit :fast :stable :mcp-http)
  (test-mcp-http--with-mock-process
    (let ((request (make-instance 'ws-request)))
      (setf (slot-value request 'process) mock-process)
      (emacs-mcp-server--send-accepted request)
      (let ((output (test-mcp-http--get-sent mock-sent)))
        (should (string-match-p "^HTTP/1\\.1 202 Accepted\r\n" output))
        (should (string-match-p "Content-Length: 0\r\n" output))))))

;;; Tests: Request Handler (handle-post)

(ert-deftest test-mcp-http-handle-post-malformed-json ()
  "handle-post returns -32700 parse error for malformed JSON.
FIX: Ensure request body is valid JSON before sending to MCP server."
  :tags '(:unit :fast :stable :mcp-http)
  (test-mcp-http--with-mock-process
    (let ((request (make-instance 'ws-request)))
      (setf (slot-value request 'process) mock-process)
      (cl-letf (((symbol-function 'ws-body)
                 (lambda (_req) "not valid json{{")))
        (emacs-mcp-server--handle-post request)
        (let* ((output (test-mcp-http--get-sent mock-sent))
               (body-start (+ 4 (string-match "\r\n\r\n" output)))
               (body (substring output body-start))
               (json (json-parse-string body :object-type 'alist))
               (err (alist-get 'error json)))
          (should (= -32700 (alist-get 'code err))))))))

(ert-deftest test-mcp-http-handle-post-empty-body ()
  "handle-post returns parse error for empty body."
  :tags '(:unit :fast :stable :mcp-http)
  (test-mcp-http--with-mock-process
    (let ((request (make-instance 'ws-request)))
      (setf (slot-value request 'process) mock-process)
      (cl-letf (((symbol-function 'ws-body)
                 (lambda (_req) "")))
        (emacs-mcp-server--handle-post request)
        (let* ((output (test-mcp-http--get-sent mock-sent))
               (body-start (+ 4 (string-match "\r\n\r\n" output)))
               (body (substring output body-start))
               (json (json-parse-string body :object-type 'alist))
               (err (alist-get 'error json)))
          (should (= -32700 (alist-get 'code err))))))))

(provide 'test-mcp-http)
;;; test-mcp-http.el ends here
