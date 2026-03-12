;;; test-json-parser-property.el --- Property-based tests for JSON stream parser -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Property-based (fuzzer) tests for `claude-agent--process-json-buffer'.
;; These tests verify that the JSON streaming parser handles arbitrary
;; split positions, whitespace noise, unicode content, and unknown message
;; types without data loss or errors.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; Test Helpers

(defun test-json-fuzzer--make-process-with-state (&optional callbacks)
  "Create a dummy process with an attached process-state.
CALLBACKS is a plist of :callback :token-callback :error-callback :complete-callback.
Returns (process . state)."
  (let* ((error-cb (plist-get callbacks :error-callback))
         (msg-cb (plist-get callbacks :callback))
         (token-cb (plist-get callbacks :token-callback))
         (complete-cb (plist-get callbacks :complete-callback))
         (state (claude-agent--make-process-state
                 :json-buffer ""
                 :ready t
                 :callback msg-cb
                 :token-callback token-cb
                 :error-callback error-cb
                 :complete-callback complete-cb))
         (process (start-process "test-fuzzer" nil "true")))
    (process-put process 'claude-agent-state state)
    (cons process state)))

(defun test-json-fuzzer--cleanup (process)
  "Delete PROCESS if still live."
  (when (process-live-p process)
    (delete-process process)))

(defun test-json-fuzzer--feed-chunks (process state chunks)
  "Feed CHUNKS (list of strings) into PROCESS/STATE one at a time.
Simulates incremental data arrival by appending to the json-buffer
and calling `claude-agent--process-json-buffer' after each chunk."
  (dolist (chunk chunks)
    (let ((buf (or (claude-agent--process-state-json-buffer state) "")))
      (setf (claude-agent--process-state-json-buffer state)
            (concat buf chunk))
      (claude-agent--process-json-buffer process))))

(defun test-json-fuzzer--split-string-randomly (str n-splits)
  "Split STR at N-SPLITS random positions into a list of substrings.
Positions are sorted and deduplicated."
  (let* ((len (length str))
         (positions (sort (cl-remove-duplicates
                           (cl-loop repeat n-splits
                                    collect (random len)))
                          #'<))
         (result '())
         (prev 0))
    (dolist (pos positions)
      (push (substring str prev pos) result)
      (setq prev pos))
    (push (substring str prev) result)
    (nreverse result)))

(defun test-json-fuzzer--make-jsonl (&rest json-objects)
  "Build a JSONL string from JSON-OBJECTS (plists).
Each object is encoded and terminated with a newline."
  (mapconcat (lambda (obj) (json-encode obj)) json-objects "\n"))

;;; Test: Random splits preserve messages

(ert-deftest test-json-random-splits-preserve-messages ()
  "Take a valid JSONL stream, split at random positions, feed chunks to the parser.
Verify all messages arrive exactly once regardless of split positions."
  :tags '(:unit :fuzzer)
  (let* ((messages-json
          (concat
           (json-encode '(:type "system" :subtype "init" :session_id "s1")) "\n"
           (json-encode '(:type "assistant" :message (:content "hello"))) "\n"
           (json-encode '(:type "assistant" :message (:content "world"))) "\n"
           (json-encode '(:type "result" :result "done" :session_id "s2")) "\n"))
         (received-types '())
         (errors '()))
    ;; Run 20 iterations with different random splits
    (dotimes (iteration 20)
      (setq received-types nil errors nil)
      (let* ((pair (test-json-fuzzer--make-process-with-state
                    (list :error-callback (lambda (err) (push err errors)))))
             (process (car pair))
             (state (cdr pair)))
        ;; Intercept message dispatch
        (cl-letf (((symbol-function 'claude-agent-handle-message)
                   (lambda (_type parsed _state)
                     (push (plist-get parsed :type) received-types)))
                  ((symbol-function 'claude-agent--handle-control-request)
                   #'ignore))
          (unwind-protect
              (let* ((n-splits (+ 2 (random 8)))
                     (chunks (test-json-fuzzer--split-string-randomly
                              messages-json n-splits)))
                (test-json-fuzzer--feed-chunks process state chunks)
                ;; All 4 messages should arrive
                (should (= 4 (length received-types)))
                (should (member "system" received-types))
                (should (member "result" received-types))
                ;; No errors
                (should (null errors)))
            (test-json-fuzzer--cleanup process)))))))

;;; Test: Empty/whitespace lines ignored

(ert-deftest test-json-empty-lines-ignored ()
  "Insert random empty/whitespace lines between valid JSON.
Verify no errors and all messages still arrive."
  :tags '(:unit :fuzzer)
  (let ((received-types '())
        (errors '()))
    (dotimes (_iteration 10)
      (setq received-types nil errors nil)
      (let* ((pair (test-json-fuzzer--make-process-with-state
                    (list :error-callback (lambda (err) (push err errors)))))
             (process (car pair))
             (state (cdr pair)))
        (cl-letf (((symbol-function 'claude-agent-handle-message)
                   (lambda (_type parsed _state)
                     (push (plist-get parsed :type) received-types)))
                  ((symbol-function 'claude-agent--handle-control-request)
                   #'ignore))
          (unwind-protect
              (let* (;; Build JSONL with random whitespace lines injected
                     (json1 (json-encode '(:type "assistant" :message (:content "one"))))
                     (json2 (json-encode '(:type "result" :result "ok")))
                     ;; Generate random whitespace lines
                     (ws-lines (cl-loop repeat (+ 1 (random 5))
                                        collect (make-string (random 10) ?\s)))
                     (stream (concat
                              (nth 0 ws-lines) "\n"
                              json1 "\n"
                              (mapconcat #'identity (cdr ws-lines) "\n") "\n"
                              json2 "\n"
                              "   \n\n  \t  \n")))
                (setf (claude-agent--process-state-json-buffer state) stream)
                (claude-agent--process-json-buffer process)
                ;; Both messages should arrive
                (should (= 2 (length received-types)))
                ;; No errors from whitespace lines
                (should (null errors)))
            (test-json-fuzzer--cleanup process)))))))

;;; Test: Unicode survives parsing

(ert-deftest test-json-unicode-survives ()
  "JSON with unicode chars (emoji, CJK, combining marks) parses correctly."
  :tags '(:unit :fuzzer)
  (let ((received-texts '())
        (test-strings '("Hello \u4e16\u754c"         ; CJK: Hello 世界
                        "Caf\u00e9 \u2615"            ; Café ☕
                        "\ud83d\ude80 rocket"          ; 🚀 rocket
                        "a\u0301 combining"            ; á combining mark
                        "\u00fc\u00f6\u00e4")))        ; üöä
    (dolist (text test-strings)
      (setq received-texts nil)
      (let* ((pair (test-json-fuzzer--make-process-with-state nil))
             (process (car pair))
             (state (cdr pair)))
        (cl-letf (((symbol-function 'claude-agent-handle-message)
                   (lambda (_type parsed _state)
                     (push (plist-get (plist-get parsed :message) :content)
                           received-texts)))
                  ((symbol-function 'claude-agent--handle-control-request)
                   #'ignore))
          (unwind-protect
              (let ((stream (concat
                             (json-encode `(:type "assistant"
                                           :message (:content ,text)))
                             "\n")))
                (setf (claude-agent--process-state-json-buffer state) stream)
                (claude-agent--process-json-buffer process)
                (should (= 1 (length received-texts)))
                (should (equal text (car received-texts))))
            (test-json-fuzzer--cleanup process)))))))

;;; Test: Unknown message types pass through without error

(ert-deftest test-json-unknown-types-pass-through ()
  "Unknown message types don't cause errors.
The parser dispatches them via `claude-agent-handle-message' with
the unknown type symbol — the caller decides what to do."
  :tags '(:unit :fuzzer)
  (let ((dispatched-types '())
        (errors '())
        (unknown-types '("future_type" "experimental_v2" "debug_trace"
                         "metric" "heartbeat")))
    (dolist (utype unknown-types)
      (setq dispatched-types nil errors nil)
      (let* ((pair (test-json-fuzzer--make-process-with-state
                    (list :error-callback (lambda (err) (push err errors)))))
             (process (car pair))
             (state (cdr pair)))
        (cl-letf (((symbol-function 'claude-agent-handle-message)
                   (lambda (type _parsed _state)
                     (push type dispatched-types)))
                  ((symbol-function 'claude-agent--handle-control-request)
                   #'ignore))
          (unwind-protect
              (let ((stream (concat
                             (json-encode `(:type ,utype :data "payload"))
                             "\n")))
                (setf (claude-agent--process-state-json-buffer state) stream)
                (claude-agent--process-json-buffer process)
                ;; Should have been dispatched (interned as symbol)
                (should (= 1 (length dispatched-types)))
                (should (eq (intern utype) (car dispatched-types)))
                ;; No errors
                (should (null errors)))
            (test-json-fuzzer--cleanup process)))))))

(provide 'test-json-parser-property)
;;; test-json-parser-property.el ends here
