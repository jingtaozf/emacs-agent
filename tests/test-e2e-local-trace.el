;;; test-e2e-local-trace.el --- Local-only E2E trace verification -*- lexical-binding: t; -*-

;;; Commentary:

;; E2E tests that verify Phoenix tracing works with real cmux + Claude Code.
;; These tests require a running local environment:
;;   - Phoenix at http://localhost:6006
;;   - OTel bridge at http://localhost:7331
;;   - cmux CLI available
;;
;; Tagged :local-e2e — excluded from CI (GitHub Actions), run only on dev machines.
;;
;; Run manually:
;;   make test-e2e-local

;;; Code:

(require 'ert)

(defvar test-e2e-local--phoenix-url "http://localhost:6006"
  "Phoenix GraphQL endpoint.")

(defvar test-e2e-local--bridge-url "http://localhost:7331"
  "OTel bridge endpoint.")

(defun test-e2e-local--service-alive-p (url)
  "Check if HTTP service at URL is reachable."
  (condition-case nil
      (let ((buf (url-retrieve-synchronously (concat url "/health") t nil 3)))
        (when buf
          (prog1 t (kill-buffer buf))))
    (error nil)))

(defun test-e2e-local--query-phoenix (query)
  "Send GraphQL QUERY to Phoenix, return parsed JSON."
  (let ((url-request-method "POST")
        (url-request-extra-headers '(("Content-Type" . "application/json")))
        (url-request-data (json-serialize `((query . ,query)))))
    (with-current-buffer
        (url-retrieve-synchronously
         (concat test-e2e-local--phoenix-url "/graphql") t nil 5)
      (goto-char (point-min))
      (re-search-forward "\n\n" nil t)
      (prog1 (json-parse-buffer :object-type 'alist)
        (kill-buffer (current-buffer))))))

(defun test-e2e-local--recent-spans (n)
  "Get N most recent spans from Phoenix emacs-agent project."
  (let* ((query (format "query { node(id: \"UHJvamVjdDoy\") { ... on Project { spans(first: %d, sort: {col: startTime, dir: desc}) { edges { node { name parentId spanId startTime } } } } } }" n))
         (result (test-e2e-local--query-phoenix query))
         (edges (alist-get 'edges
                  (alist-get 'spans
                    (alist-get 'node
                      (alist-get 'data result))))))
    (mapcar (lambda (e) (alist-get 'node e)) edges)))

(defun test-e2e-local--root-spans (spans)
  "Filter SPANS to only root spans (parentId is null)."
  (seq-filter (lambda (s) (eq (alist-get 'parentId s) :null)) spans))

(defun test-e2e-local--recent-spans-full (n)
  "Get N most recent spans with statusCode and latencyMs."
  (let* ((query (format "query { node(id: \"UHJvamVjdDoy\") { ... on Project { spans(first: %d, sort: {col: startTime, dir: desc}) { edges { node { name parentId spanId spanKind statusCode startTime latencyMs } } } } } }" n))
         (result (test-e2e-local--query-phoenix query))
         (edges (alist-get 'edges
                  (alist-get 'spans
                    (alist-get 'node
                      (alist-get 'data result))))))
    (mapcar (lambda (e) (alist-get 'node e)) edges)))

(defun test-e2e-local--find-span (spans name)
  "Find first span in SPANS with given NAME."
  (seq-find (lambda (s) (equal (alist-get 'name s) name)) spans))

(defun test-e2e-local--find-spans (spans name)
  "Find all spans in SPANS with given NAME."
  (seq-filter (lambda (s) (equal (alist-get 'name s) name)) spans))

(defun test-e2e-local--assert-span-exists (spans name)
  "Assert that a span named NAME exists in SPANS. Returns the span."
  (let ((span (test-e2e-local--find-span spans name)))
    (should-not (null span))
    span))

(defun test-e2e-local--assert-parent-child (spans parent-name child-name)
  "Assert that CHILD-NAME span has PARENT-NAME span as its parent."
  (let ((parent (test-e2e-local--find-span spans parent-name))
        (child (test-e2e-local--find-span spans child-name)))
    (should-not (null parent))
    (should-not (null child))
    (should (equal (alist-get 'parentId child)
                   (alist-get 'spanId parent)))))

(defun test-e2e-local--assert-no-errors (spans)
  "Assert no span in SPANS has ERROR statusCode."
  (let ((errors (seq-filter
                 (lambda (s) (equal (alist-get 'statusCode s) "ERROR"))
                 spans)))
    (when errors
      (ert-fail (format "Found %d ERROR spans: %s"
                        (length errors)
                        (mapconcat (lambda (s) (alist-get 'name s)) errors ", "))))))

(defun test-e2e-local--spans-by-name-prefix (spans prefix)
  "Filter SPANS to those whose name starts with PREFIX."
  (seq-filter (lambda (s) (string-prefix-p prefix (or (alist-get 'name s) ""))) spans))

;;; Tests

(ert-deftest test-e2e-local-phoenix-reachable ()
  "Phoenix UI is running at localhost:6006."
  :tags '(:local-e2e)
  (skip-unless (test-e2e-local--service-alive-p test-e2e-local--phoenix-url))
  (should (test-e2e-local--service-alive-p test-e2e-local--phoenix-url)))

(ert-deftest test-e2e-local-bridge-reachable ()
  "OTel bridge is running at localhost:7331."
  :tags '(:local-e2e)
  (skip-unless (test-e2e-local--service-alive-p test-e2e-local--bridge-url))
  (should (test-e2e-local--service-alive-p test-e2e-local--bridge-url)))

(ert-deftest test-e2e-local-bridge-root-span-export ()
  "Root spans sent to the bridge appear in Phoenix with parentId=null."
  :tags '(:local-e2e)
  (skip-unless (test-e2e-local--service-alive-p test-e2e-local--bridge-url))
  (skip-unless (test-e2e-local--service-alive-p test-e2e-local--phoenix-url))
  ;; Send a test root span
  (let* ((trace-id (code-agent-trace--generate-trace-id))
         (span-id (code-agent-trace--generate-span-id))
         (start-ns (truncate (* (float-time) 1e9))))
    (code-agent-trace--request
     "span/start"
     (list (cons 'trace_id trace-id)
           (cons 'span_id span-id)
           (cons 'name "e2e-root-span-test")
           (cons 'start_time_ns start-ns)))
    (code-agent-trace--request
     "span/end"
     (list (cons 'span_id span-id)
           (cons 'end_time_ns (truncate (* (float-time) 1e9)))
           (cons 'status "ok")))
    ;; Wait for Phoenix to ingest
    (sleep-for 3)
    ;; Check Phoenix
    (let* ((spans (test-e2e-local--recent-spans 20))
           (test-span (seq-find (lambda (s)
                                  (equal (alist-get 'name s) "e2e-root-span-test"))
                                spans)))
      (should (not (null test-span)))
      (should (eq (alist-get 'parentId test-span) :null)))))

(ert-deftest test-e2e-local-with-span-no-context-untraced ()
  "`code-agent-with-span' returns its body value but exports no span
when no trace context is active.

This locks in the current design (commit 775cecd, 2026-03-20): without
an explicit TRACE-CTX or a dynamically bound
`code-agent-trace--current-context', the macro skips span export.
Auto-promoting to root in that case produced noisy stray roots from
timers and MCP callbacks (cmux-call, cmux-permission-resolved,
auto-title-complete)."
  :tags '(:local-e2e)
  (skip-unless (test-e2e-local--service-alive-p test-e2e-local--bridge-url))
  (skip-unless (test-e2e-local--service-alive-p test-e2e-local--phoenix-url))
  (let* ((code-agent-trace-enabled t)
         (code-agent-trace--current-context nil)
         ;; Unique name so stale spans from earlier runs can't satisfy the assertion.
         (probe-name (make-temp-name "e2e-no-context-probe-"))
         (result (code-agent-with-span probe-name
                     (list :input "no-context verification") nil
                   "done")))
    (should (equal result "done"))
    (sleep-for 3)
    (should (null (seq-find (lambda (s) (equal (alist-get 'name s) probe-name))
                            (test-e2e-local--recent-spans 20))))))

(ert-deftest test-e2e-local-child-span-has-parent ()
  "Child spans created within a trace have correct parentId."
  :tags '(:local-e2e)
  (skip-unless (test-e2e-local--service-alive-p test-e2e-local--bridge-url))
  (skip-unless (test-e2e-local--service-alive-p test-e2e-local--phoenix-url))
  (let ((code-agent-trace-enabled t))
    (code-agent-with-trace "e2e-parent-test" nil
      (code-agent-with-span "e2e-child-test" nil nil
        "child-result"))
    (sleep-for 3)
    (let* ((spans (test-e2e-local--recent-spans 30))
           (parent (seq-find (lambda (s) (equal (alist-get 'name s) "e2e-parent-test")) spans))
           (child (seq-find (lambda (s) (equal (alist-get 'name s) "e2e-child-test")) spans)))
      ;; Parent should be root
      (should (not (null parent)))
      (should (eq (alist-get 'parentId parent) :null))
      ;; Child should reference parent's spanId
      (should (not (null child)))
      (should (equal (alist-get 'parentId child)
                     (alist-get 'spanId parent))))))

(provide 'test-e2e-local-trace)
;;; test-e2e-local-trace.el ends here
