;;; test-otel-trace.el --- Tests for OTel tracing module -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2025 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for code-agent-trace.org
;; These tests mock HTTP requests so no real calls are made.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'code-agent-trace)

;;; Test 1: trace-id generation

(ert-deftest test-otel-generate-trace-id ()
  "Generate-trace-id returns a 32-char hex string."
  :tags '(:unit :otel)
  (let ((id (code-agent-trace--generate-trace-id)))
    (should (stringp id))
    (should (= 32 (length id)))
    (should (string-match-p "\\`[0-9a-f]\\{32\\}\\'" id))))

;;; Test 2: span-id generation

(ert-deftest test-otel-generate-span-id ()
  "Generate-span-id returns a 16-char hex string."
  :tags '(:unit :otel)
  (let ((id (code-agent-trace--generate-span-id)))
    (should (stringp id))
    (should (= 16 (length id)))
    (should (string-match-p "\\`[0-9a-f]\\{16\\}\\'" id))))

;;; Test 3: trace-context captures cons cell

(ert-deftest test-otel-trace-context ()
  "code-agent-trace-context captures and returns (trace-id . span-id)."
  :tags '(:unit :otel)
  (let ((requests '()))
    (cl-letf (((symbol-function 'code-agent-trace--request)
               (lambda (_path _data) nil))
              ((symbol-function 'code-agent-trace--write-context)
               (lambda (&rest _args) nil)))
      (let ((ctx nil))
        (code-agent-with-trace "test-op" nil
          (setq ctx (code-agent-trace-context)))
        (should (consp ctx))
        (should (= 32 (length (car ctx))))
        (should (= 16 (length (cdr ctx))))))))

;;; Test 4: with-trace sends start/end span requests

(ert-deftest test-otel-with-trace-sends-requests ()
  "code-agent-with-trace sends span/start and span/end requests."
  :tags '(:unit :otel)
  (let ((requests '()))
    (cl-letf (((symbol-function 'code-agent-trace--request)
               (lambda (path data)
                 (push (cons path data) requests)))
              ((symbol-function 'code-agent-trace--write-context)
               (lambda (&rest _args) nil)))
      (code-agent-with-trace "test-op" nil
        (+ 1 2)))
    ;; Should have start and end
    (should (= 2 (length requests)))
    ;; requests are pushed, so last pushed is first: end is first, start is second
    (let ((end-req (nth 0 requests))
          (start-req (nth 1 requests)))
      (should (equal "span/start" (car start-req)))
      (should (equal "test-op" (alist-get 'name (cdr start-req))))
      (should (equal "span/end" (car end-req)))
      (should (equal "ok" (alist-get 'status (cdr end-req)))))))

;;; Test 5: with-trace on error sends error status and re-signals

(ert-deftest test-otel-with-trace-error-status ()
  "code-agent-with-trace sends error status on exception and re-signals."
  :tags '(:unit :otel)
  (let ((requests '()))
    (cl-letf (((symbol-function 'code-agent-trace--request)
               (lambda (path data)
                 (push (cons path data) requests)))
              ((symbol-function 'code-agent-trace--write-context)
               (lambda (&rest _args) nil)))
      (should-error
       (code-agent-with-trace "test-op" nil
         (error "test error"))
       :type 'error))
    ;; end request should have error status (it's the last pushed, so first in list)
    (let ((end-req (nth 0 requests)))
      (should (equal "span/end" (car end-req)))
      (should (equal "error" (alist-get 'status (cdr end-req))))
      (should (equal "test error" (alist-get 'error_message (cdr end-req)))))))

;;; Test 6: with-span links to parent via dynamic binding

(ert-deftest test-otel-with-span-links-parent ()
  "code-agent-with-span links to parent span via dynamic binding."
  :tags '(:unit :otel)
  (let ((requests '()))
    (cl-letf (((symbol-function 'code-agent-trace--request)
               (lambda (path data)
                 (push (cons path data) requests)))
              ((symbol-function 'code-agent-trace--write-context)
               (lambda (&rest _args) nil)))
      (code-agent-with-trace "parent-op" nil
        (code-agent-with-span "child-op" nil nil
          (+ 1 2))))
    ;; 4 requests: parent-start, child-start, child-end, parent-end
    (should (= 4 (length requests)))
    ;; child start is the 3rd pushed (index 2 when reversed... let's just find it)
    (let* ((child-start (cl-find-if
                         (lambda (r)
                           (and (equal "span/start" (car r))
                                (equal "child-op" (alist-get 'name (cdr r)))))
                         requests)))
      (should child-start)
      ;; child should have parent_span_id set
      (should (alist-get 'parent_span_id (cdr child-start))))))

;;; Test 7: with-span with explicit trace-ctx (async pattern)

(ert-deftest test-otel-with-span-explicit-ctx ()
  "code-agent-with-span accepts explicit trace-ctx for async use."
  :tags '(:unit :otel)
  (let ((requests '())
        (saved-ctx nil))
    (cl-letf (((symbol-function 'code-agent-trace--request)
               (lambda (path data)
                 (push (cons path data) requests)))
              ((symbol-function 'code-agent-trace--write-context)
               (lambda (&rest _args) nil)))
      ;; Create a root trace and save context
      (code-agent-with-trace "root" nil
        (setq saved-ctx (code-agent-trace-context)))
      ;; Now use saved context outside the dynamic scope
      (setq requests '())
      (code-agent-with-span "async-child" nil saved-ctx
        (+ 1 2)))
    ;; Should have start and end for the child span
    (should (= 2 (length requests)))
    (let ((child-start (cl-find-if
                        (lambda (r) (equal "span/start" (car r)))
                        requests)))
      (should child-start)
      ;; trace-id should match the saved context
      (should (equal (car saved-ctx) (alist-get 'trace_id (cdr child-start))))
      ;; parent_span_id should match the saved context's span-id
      (should (equal (cdr saved-ctx) (alist-get 'parent_span_id (cdr child-start)))))))

;;; Test 8: write-context writes W3C traceparent file

(ert-deftest test-otel-write-context-file ()
  "code-agent-trace--write-context writes W3C traceparent to file."
  :tags '(:unit :otel)
  (let* ((tmp-dir (make-temp-file "otel-test" t))
         (code-agent-trace-context-dir tmp-dir)
         (trace-id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
         (span-id "bbbbbbbbbbbbbbbb")
         (session-id "test-session")
         (expected "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01"))
    (unwind-protect
        (progn
          (code-agent-trace--write-context trace-id span-id session-id "my-block-id")
          ;; Check generic traceparent file
          (let ((content (with-temp-buffer
                           (insert-file-contents (expand-file-name "traceparent" tmp-dir))
                           (buffer-string))))
            (should (string-match-p expected content)))
          ;; Check per-session file
          (let ((content (with-temp-buffer
                           (insert-file-contents (expand-file-name "test-session.trace-context" tmp-dir))
                           (buffer-string))))
            (should (string-match-p expected content)))
          ;; Check per-custom-id file
          (let ((content (with-temp-buffer
                           (insert-file-contents (expand-file-name "my-block-id.trace-context" tmp-dir))
                           (buffer-string))))
            (should (string-match-p expected content))))
      (delete-directory tmp-dir t))))

;;; Test 9: disabled tracing skips HTTP calls

(ert-deftest test-otel-disabled-tracing-skips-requests ()
  "When code-agent-trace-enabled is nil, no HTTP calls are made."
  :tags '(:unit :otel)
  (let ((requests '())
        (code-agent-trace-enabled nil))
    (cl-letf (((symbol-function 'code-agent-trace--request)
               (lambda (path data)
                 (push (cons path data) requests))))
      (code-agent-with-trace "test-op" nil
        (+ 1 2)))
    (should (= 0 (length requests)))))

;;; Test 10: start-bridge launches process

(ert-deftest test-otel-ensure-bridge ()
  "code-agent-trace--ensure-bridge auto-starts the bridge process."
  :tags '(:unit :otel)
  (let ((started nil)
        (code-agent-trace-enabled t)
        (mock-buf (generate-new-buffer " *mock-bridge*")))
    ;; Reset the singleton slot so the ensure-call spawns a fresh process.
    (setf (code-agent-trace-service-process
           code-agent-trace--bridge-service) nil)
    (unwind-protect
        (cl-letf (((symbol-function 'start-process)
                   (lambda (&rest args)
                     (setq started args)
                     mock-buf)))
          (should (code-agent-trace--ensure-bridge))
          (should started)
          (should (member "otel-bridge" started)))
      (setf (code-agent-trace-service-process
             code-agent-trace--bridge-service) nil)
      (kill-buffer mock-buf))))

;;; Test 11: stop-bridge kills process

(ert-deftest test-otel-stop-bridge ()
  "code-agent-trace-stop-bridge kills the bridge process."
  :tags '(:unit :otel)
  (let ((killed nil)
        (mock-buf (generate-new-buffer " *mock-bridge*")))
    (unwind-protect
        (progn
          (setf (code-agent-trace-service-process
                 code-agent-trace--bridge-service) mock-buf)
          (cl-letf (((symbol-function 'process-live-p)
                     (lambda (_p) t))
                    ((symbol-function 'kill-process)
                     (lambda (p) (setq killed p))))
            (code-agent-trace-stop-bridge)
            (should killed)
            (should (null (code-agent-trace-service-process
                           code-agent-trace--bridge-service)))))
      (when (buffer-live-p mock-buf)
        (kill-buffer mock-buf)))))

;;; Test 12: ensure-phoenix auto-starts

(ert-deftest test-otel-ensure-phoenix ()
  "code-agent-trace--ensure-phoenix auto-starts Phoenix."
  :tags '(:unit :otel)
  (let ((started nil)
        (mock-buf (generate-new-buffer " *mock-phoenix*")))
    (setf (code-agent-trace-service-process
           code-agent-trace--phoenix-service) nil)
    (unwind-protect
        (cl-letf (((symbol-function 'start-process)
                   (lambda (&rest args)
                     (setq started args)
                     mock-buf)))
          (should (code-agent-trace--ensure-phoenix))
          (should started)
          (should (member "phoenix" started)))
      (setf (code-agent-trace-service-process
             code-agent-trace--phoenix-service) nil)
      (kill-buffer mock-buf))))

;;; Test 13: stop-phoenix kills process

(ert-deftest test-otel-stop-phoenix ()
  "code-agent-trace-stop-phoenix kills the phoenix process."
  :tags '(:unit :otel)
  (let ((killed nil)
        (mock-buf (generate-new-buffer " *mock-phoenix*")))
    (unwind-protect
        (progn
          (setf (code-agent-trace-service-process
                 code-agent-trace--phoenix-service) mock-buf)
          (cl-letf (((symbol-function 'process-live-p)
                     (lambda (_p) t))
                    ((symbol-function 'kill-process)
                     (lambda (p) (setq killed p))))
            (code-agent-trace-stop-phoenix)
            (should killed)
            (should (null (code-agent-trace-service-process
                           code-agent-trace--phoenix-service)))))
      (when (buffer-live-p mock-buf)
        (kill-buffer mock-buf)))))

;;; Test 14: with-trace sends SERVER kind by default

(ert-deftest test-otel-with-trace-sends-server-kind ()
  "code-agent-with-trace sends SERVER as default span kind."
  :tags '(:unit :otel)
  (let ((requests '()))
    (cl-letf (((symbol-function 'code-agent-trace--request)
               (lambda (path data)
                 (push (cons path data) requests)))
              ((symbol-function 'code-agent-trace--write-context)
               (lambda (&rest _args) nil)))
      (code-agent-with-trace "test-op" nil
        (+ 1 2)))
    (let ((start-req (cl-find-if
                      (lambda (r) (equal "span/start" (car r)))
                      requests)))
      (should (equal "SERVER" (alist-get 'kind (cdr start-req)))))))

;;; Test 15: with-span sends INTERNAL kind by default

(ert-deftest test-otel-with-span-sends-internal-kind ()
  "code-agent-with-span sends INTERNAL as default span kind."
  :tags '(:unit :otel)
  (let ((requests '()))
    (cl-letf (((symbol-function 'code-agent-trace--request)
               (lambda (path data)
                 (push (cons path data) requests)))
              ((symbol-function 'code-agent-trace--write-context)
               (lambda (&rest _args) nil)))
      (code-agent-with-trace "root" nil
        (code-agent-with-span "child" nil nil
          (+ 1 2))))
    (let ((child-start (cl-find-if
                        (lambda (r)
                          (and (equal "span/start" (car r))
                               (equal "child" (alist-get 'name (cdr r)))))
                        requests)))
      (should (equal "INTERNAL" (alist-get 'kind (cdr child-start)))))))

;;; Test 16: with-span respects :span-kind override

(ert-deftest test-otel-with-span-custom-kind ()
  "code-agent-with-span sends custom span kind from attrs."
  :tags '(:unit :otel)
  (let ((requests '()))
    (cl-letf (((symbol-function 'code-agent-trace--request)
               (lambda (path data)
                 (push (cons path data) requests)))
              ((symbol-function 'code-agent-trace--write-context)
               (lambda (&rest _args) nil)))
      (code-agent-with-trace "root" nil
        (code-agent-with-span "client-call"
            (list :span-kind "CLIENT") nil
          (+ 1 2))))
    (let ((client-start (cl-find-if
                         (lambda (r)
                           (and (equal "span/start" (car r))
                                (equal "client-call" (alist-get 'name (cdr r)))))
                         requests)))
      (should (equal "CLIENT" (alist-get 'kind (cdr client-start)))))))

;;; Test 17: wait-for-url calls callback on success

(ert-deftest test-otel-wait-for-url-success ()
  "code-agent-trace--wait-for-url calls callback when URL responds."
  :tags '(:unit :otel)
  (let ((callback-called nil)
        (retrieve-calls 0))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _args)
                 (cl-incf retrieve-calls)
                 ;; Simulate successful response on first try
                 (funcall callback nil))))
      (code-agent-trace--wait-for-url
       "http://localhost:9999/"
       (lambda () (setq callback-called t))
       5)
      ;; Timer fires at 0s delay, so process pending timers
      ;; In batch mode, we need to let the timer fire
      (sleep-for 0.1)
      (should (>= retrieve-calls 1))
      (should callback-called))))

;;; Test 15: wait-for-url times out

(ert-deftest test-otel-wait-for-url-timeout ()
  "code-agent-trace--wait-for-url reports timeout after max retries."
  :tags '(:unit :otel)
  (let ((callback-called nil)
        (messages '()))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _args)
                 ;; Simulate connection error
                 (funcall callback '(:error (error "Connection refused")))))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (code-agent-trace--wait-for-url
       "http://localhost:9999/"
       (lambda () (setq callback-called t))
       1)  ;; Only 1 retry
      (sleep-for 2.5)  ;; Wait for retries to exhaust
      (should-not callback-called)
      (should (cl-some (lambda (m) (string-match-p "Timed out" m)) messages)))))

(provide 'test-otel-trace)
;;; test-otel-trace.el ends here
