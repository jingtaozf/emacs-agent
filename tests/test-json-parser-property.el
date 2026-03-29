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

;;; Test: Interleaved message ordering

(ert-deftest test-json-interleaved-message-ordering ()
  "Messages arrive in non-standard order (result before assistant, etc.).
The parser should dispatch all messages regardless of ordering.
Real-world protocols may send messages in unexpected sequences."
  :tags '(:unit :fuzzer)
  (let ((orderings
         ;; Various non-standard orderings
         '(;; result before assistant
           ((:type "result" :result "early-done")
            (:type "assistant" :message (:content "late")))
           ;; multiple system messages interspersed
           ((:type "system" :subtype "init" :session_id "s1")
            (:type "assistant" :message (:content "hi"))
            (:type "system" :subtype "config" :data "stuff")
            (:type "assistant" :message (:content "there"))
            (:type "result" :result "fin"))
           ;; assistant after result
           ((:type "assistant" :message (:content "a1"))
            (:type "result" :result "done")
            (:type "assistant" :message (:content "a2-post-result")))
           ;; back-to-back system messages
           ((:type "system" :subtype "a")
            (:type "system" :subtype "b")
            (:type "system" :subtype "c")))))
    (dolist (msgs orderings)
      (let ((received-types '())
            (errors '()))
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
                (let ((stream (mapconcat #'json-encode msgs "\n")))
                  (setf (claude-agent--process-state-json-buffer state)
                        (concat stream "\n"))
                  (claude-agent--process-json-buffer process)
                  ;; All messages should arrive, regardless of order
                  (should (= (length msgs) (length received-types)))
                  ;; No errors from unexpected ordering
                  (should (null errors)))
              (test-json-fuzzer--cleanup process))))))))

;;; Test: Malformed JSON recovery — bad lines don't kill subsequent parsing

(ert-deftest test-json-malformed-recovery ()
  "A malformed JSON line should not prevent subsequent valid lines from parsing.
The parser should skip bad lines and continue processing."
  :tags '(:unit :fuzzer)
  (let ((received-types '())
        (error-lines '()))
    (let* ((pair (test-json-fuzzer--make-process-with-state
                  (list :error-callback
                        (lambda (err) (push (plist-get (cdr err) :message)
                                            error-lines)))))
           (process (car pair))
           (state (cdr pair)))
      (cl-letf (((symbol-function 'claude-agent-handle-message)
                 (lambda (_type parsed _state)
                   (push (plist-get parsed :type) received-types)))
                ((symbol-function 'claude-agent--handle-control-request)
                 #'ignore))
        (unwind-protect
            (let ((stream (concat
                           (json-encode '(:type "assistant" :message (:content "before"))) "\n"
                           "{this is not valid json}\n"
                           "totally not json at all\n"
                           "{\"truncated\n"
                           (json-encode '(:type "result" :result "after")) "\n")))
              (setf (claude-agent--process-state-json-buffer state) stream)
              (claude-agent--process-json-buffer process)
              ;; Both valid messages should arrive
              (should (= 2 (length received-types)))
              (should (member "assistant" received-types))
              (should (member "result" received-types))
              ;; Error callback should have fired for each bad line
              (should (>= (length error-lines) 2)))
          (test-json-fuzzer--cleanup process))))))

;;; Test: Truncated JSON completed in subsequent chunks

(ert-deftest test-json-truncated-then-completed ()
  "Partial JSON without trailing newline is preserved in the buffer.
When the rest arrives in the next chunk, the complete message parses."
  :tags '(:unit :fuzzer)
  (let ((received-types '()))
    (let* ((pair (test-json-fuzzer--make-process-with-state nil))
           (process (car pair))
           (state (cdr pair)))
      (cl-letf (((symbol-function 'claude-agent-handle-message)
                 (lambda (_type parsed _state)
                   (push (plist-get parsed :type) received-types)))
                ((symbol-function 'claude-agent--handle-control-request)
                 #'ignore))
        (unwind-protect
            (let* ((full-json (json-encode '(:type "assistant"
                                             :message (:content "hello world"))))
                   ;; Split at an arbitrary point (middle of the JSON)
                   (split-pos (/ (length full-json) 2))
                   (chunk1 (substring full-json 0 split-pos))
                   (chunk2 (concat (substring full-json split-pos) "\n")))
              ;; Feed first chunk — no trailing newline, should not parse yet
              (test-json-fuzzer--feed-chunks process state (list chunk1))
              (should (= 0 (length received-types)))
              ;; Buffer should still hold the incomplete JSON
              (should (string= (claude-agent--process-state-json-buffer state) chunk1))
              ;; Feed second chunk — completes the line
              (test-json-fuzzer--feed-chunks process state (list chunk2))
              ;; Now the message should have arrived
              (should (= 1 (length received-types)))
              (should (equal "assistant" (car received-types))))
          (test-json-fuzzer--cleanup process))))))

;;; Test: Large messages parse correctly

(ert-deftest test-json-large-message ()
  "Messages with large payloads (tool output, long responses) parse correctly."
  :tags '(:unit :fuzzer)
  (let ((received-contents '()))
    (let* ((pair (test-json-fuzzer--make-process-with-state nil))
           (process (car pair))
           (state (cdr pair)))
      (cl-letf (((symbol-function 'claude-agent-handle-message)
                 (lambda (_type parsed _state)
                   (push (plist-get (plist-get parsed :message) :content)
                         received-contents)))
                ((symbol-function 'claude-agent--handle-control-request)
                 #'ignore))
        (unwind-protect
            (let* (;; 100KB payload — typical large tool output
                   (large-content (make-string (* 100 1024) ?A))
                   (json-str (concat
                              (json-encode `(:type "assistant"
                                            :message (:content ,large-content)))
                              "\n")))
              (setf (claude-agent--process-state-json-buffer state) json-str)
              (claude-agent--process-json-buffer process)
              ;; Message should arrive with full content
              (should (= 1 (length received-contents)))
              (should (= (* 100 1024) (length (car received-contents)))))
          (test-json-fuzzer--cleanup process))))))

;;; Test: Large message split across many small chunks

(ert-deftest test-json-large-message-many-chunks ()
  "A large message split into many small chunks (simulating slow network)
reassembles correctly."
  :tags '(:unit :fuzzer)
  (let ((received-types '()))
    (let* ((pair (test-json-fuzzer--make-process-with-state nil))
           (process (car pair))
           (state (cdr pair)))
      (cl-letf (((symbol-function 'claude-agent-handle-message)
                 (lambda (_type parsed _state)
                   (push (plist-get parsed :type) received-types)))
                ((symbol-function 'claude-agent--handle-control-request)
                 #'ignore))
        (unwind-protect
            (let* ((json-str (concat
                              (json-encode '(:type "assistant"
                                            :message (:content "data")))
                              "\n"))
                   ;; Split into chunks of 5 bytes each
                   (chunks '())
                   (pos 0))
              (while (< pos (length json-str))
                (push (substring json-str pos (min (+ pos 5) (length json-str)))
                      chunks)
                (setq pos (+ pos 5)))
              (setq chunks (nreverse chunks))
              ;; Feed all tiny chunks
              (test-json-fuzzer--feed-chunks process state chunks)
              ;; Message should eventually arrive
              (should (= 1 (length received-types))))
          (test-json-fuzzer--cleanup process))))))

;;; Test: Rapid empty buffer processing is harmless

(ert-deftest test-json-empty-buffer-repeated-calls ()
  "Calling process-json-buffer on an empty buffer repeatedly is safe.
No errors, no state corruption."
  :tags '(:unit :fuzzer)
  (let ((errors '()))
    (let* ((pair (test-json-fuzzer--make-process-with-state
                  (list :error-callback (lambda (err) (push err errors)))))
           (process (car pair))
           (state (cdr pair)))
      (unwind-protect
          (progn
            ;; Call 50 times with empty buffer
            (dotimes (_ 50)
              (setf (claude-agent--process-state-json-buffer state) "")
              (claude-agent--process-json-buffer process))
            ;; No errors should have occurred
            (should (null errors))
            ;; Buffer should still be empty
            (should (string= "" (claude-agent--process-state-json-buffer state))))
        (test-json-fuzzer--cleanup process)))))

;;; Test: Deeply nested JSON structures

(ert-deftest test-json-deeply-nested ()
  "JSON with deep nesting (tool results with nested objects) parses correctly."
  :tags '(:unit :fuzzer)
  (let ((received '()))
    (let* ((pair (test-json-fuzzer--make-process-with-state nil))
           (process (car pair))
           (state (cdr pair)))
      (cl-letf (((symbol-function 'claude-agent-handle-message)
                 (lambda (_type parsed _state)
                   (push parsed received)))
                ((symbol-function 'claude-agent--handle-control-request)
                 #'ignore))
        (unwind-protect
            (let* (;; Build a 10-level deep structure
                   (nested '(:leaf "value"))
                   (_ (dotimes (_ 10)
                        (setq nested `(:level ,nested))))
                   (msg `(:type "assistant" :message (:content "ok")
                          :tool_result ,nested))
                   (json-str (concat (json-encode msg) "\n")))
              (setf (claude-agent--process-state-json-buffer state) json-str)
              (claude-agent--process-json-buffer process)
              ;; Message should arrive intact
              (should (= 1 (length received)))
              ;; Verify the deep nesting survived
              (let ((result (plist-get (car received) :tool_result)))
                (should result)
                ;; Walk 10 levels deep
                (dotimes (_ 10)
                  (setq result (plist-get result :level)))
                (should (equal "value" (plist-get result :leaf)))))
          (test-json-fuzzer--cleanup process))))))

;;; Test: Buffer overflow protection via process filter

(ert-deftest test-json-buffer-overflow-kills-process ()
  "When accumulated data exceeds max-json-buffer-size, process is killed
and error callback fires."
  :tags '(:unit :fuzzer)
  (let ((error-received nil))
    (let* ((state (claude-agent--make-process-state
                   :json-buffer ""
                   :ready t
                   :error-callback (lambda (err) (setq error-received err))))
           (process (start-process "test-overflow" nil "sleep" "10")))
      (unwind-protect
          (progn
            (process-put process 'claude-agent-state state)
            ;; Use a tiny limit for testing
            (let ((claude-agent-max-json-buffer-size 100))
              ;; Feed data that exceeds the limit (no newlines = no parsing)
              (claude-agent--process-filter process (make-string 200 ?x))
              ;; Error callback should have fired
              (should error-received)
              ;; Buffer should have been cleared
              (should (string= "" (claude-agent--process-state-json-buffer state)))
              ;; Process should be dead
              (should-not (process-live-p process))))
        (when (process-live-p process)
          (delete-process process))))))

;;; Test: control_request messages dispatch correctly

(ert-deftest test-json-control-request-dispatch ()
  "control_request messages bypass claude-agent-handle-message and go to
claude-agent--handle-control-request directly."
  :tags '(:unit :fuzzer)
  (let ((control-requests '())
        (normal-messages '()))
    (let* ((pair (test-json-fuzzer--make-process-with-state nil))
           (process (car pair))
           (state (cdr pair)))
      (cl-letf (((symbol-function 'claude-agent-handle-message)
                 (lambda (_type parsed _state)
                   (push (plist-get parsed :type) normal-messages)))
                ((symbol-function 'claude-agent--handle-control-request)
                 (lambda (_proc parsed)
                   (push parsed control-requests))))
        (unwind-protect
            (let ((stream (concat
                           (json-encode '(:type "system" :subtype "init")) "\n"
                           (json-encode '(:type "control_request"
                                          :request_id "req-1"
                                          :tool (:name "Bash"))) "\n"
                           (json-encode '(:type "assistant"
                                          :message (:content "hi"))) "\n"
                           (json-encode '(:type "control_request"
                                          :request_id "req-2"
                                          :tool (:name "Read"))) "\n"
                           (json-encode '(:type "result" :result "done")) "\n")))
              (setf (claude-agent--process-state-json-buffer state) stream)
              (claude-agent--process-json-buffer process)
              ;; Normal messages: system, assistant, result = 3
              (should (= 3 (length normal-messages)))
              ;; Control requests dispatched separately: 2
              (should (= 2 (length control-requests)))
              ;; Verify control request content
              (should (equal "req-2"
                             (plist-get (nth 0 control-requests) :request_id)))
              (should (equal "req-1"
                             (plist-get (nth 1 control-requests) :request_id))))
          (test-json-fuzzer--cleanup process))))))

;;; Test: Mixed valid/invalid across random split points

(ert-deftest test-json-mixed-valid-invalid-random-splits ()
  "Stream containing both valid JSON and malformed lines, split at random
positions. Valid messages should all arrive despite the bad lines."
  :tags '(:unit :fuzzer)
  (dotimes (_iteration 15)
    (let ((received-types '())
          (errors '()))
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
              (let* ((stream (concat
                              (json-encode '(:type "system" :subtype "init")) "\n"
                              "GARBAGE LINE 1\n"
                              (json-encode '(:type "assistant"
                                            :message (:content "msg1"))) "\n"
                              "NOT JSON {{{broken\n"
                              (json-encode '(:type "assistant"
                                            :message (:content "msg2"))) "\n"
                              "plain text error message\n"
                              (json-encode '(:type "result" :result "end")) "\n"))
                     (n-splits (+ 3 (random 10)))
                     (chunks (test-json-fuzzer--split-string-randomly
                              stream n-splits)))
                (test-json-fuzzer--feed-chunks process state chunks)
                ;; All 4 valid messages should arrive
                (should (= 4 (length received-types)))
                (should (member "system" received-types))
                (should (member "result" received-types))
                ;; Error callback should have fired for bad lines
                (should (>= (length errors) 1)))
            (test-json-fuzzer--cleanup process)))))))

(provide 'test-json-parser-property)
;;; test-json-parser-property.el ends here
