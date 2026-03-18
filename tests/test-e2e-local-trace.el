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
  (let* ((trace-id (claude-agent-trace--generate-trace-id))
         (span-id (claude-agent-trace--generate-span-id))
         (start-ns (truncate (* (float-time) 1e9))))
    (claude-agent-trace--request
     "span/start"
     (list (cons 'trace_id trace-id)
           (cons 'span_id span-id)
           (cons 'name "e2e-root-span-test")
           (cons 'start_time_ns start-ns)))
    (claude-agent-trace--request
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

(ert-deftest test-e2e-local-with-span-auto-promote ()
  "claude-agent-with-span auto-promotes to root when no context exists."
  :tags '(:local-e2e)
  (skip-unless (test-e2e-local--service-alive-p test-e2e-local--bridge-url))
  (skip-unless (test-e2e-local--service-alive-p test-e2e-local--phoenix-url))
  (let ((claude-agent-trace-enabled t)
        (claude-agent-trace--current-context nil))
    ;; with-span with no context should auto-promote to root
    (claude-agent-with-span "e2e-auto-promote-test"
        (list :input "auto-promote verification") nil
      "done")
    (sleep-for 3)
    (let* ((spans (test-e2e-local--recent-spans 20))
           (test-span (seq-find (lambda (s)
                                  (equal (alist-get 'name s) "e2e-auto-promote-test"))
                                spans)))
      (should (not (null test-span)))
      (should (eq (alist-get 'parentId test-span) :null)))))

(ert-deftest test-e2e-local-child-span-has-parent ()
  "Child spans created within a trace have correct parentId."
  :tags '(:local-e2e)
  (skip-unless (test-e2e-local--service-alive-p test-e2e-local--bridge-url))
  (skip-unless (test-e2e-local--service-alive-p test-e2e-local--phoenix-url))
  (let ((claude-agent-trace-enabled t))
    (claude-agent-with-trace "e2e-parent-test" nil
      (claude-agent-with-span "e2e-child-test" nil nil
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
