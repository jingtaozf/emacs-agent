;;; test-e2e-pi-backend.el --- Fixture-driven E2E tests for Pi backend -*- lexical-binding: t; -*-

;;; Commentary:

;; Runs each =:pi-e2e:= tagged heading in
;; tests/e2e/org/pi-backend-test.org as a parameterized story:
;;
;;   - parse properties (EXPECTED / TIMEOUT / NEEDS / CANCEL_AFTER ...)
;;   - extract the first =#+begin_src ai= block body as the prompt
;;   - spawn a fresh Pi backend, drive the prompt, collect tokens
;;   - assert: ON-COMPLETE fires AND EXPECTED substring appears
;;
;; The runner does NOT invoke `code-agent-org-execute' (that path is
;; A3 — frontend dispatch wiring).  Instead it calls
;; `claude-agent-backend-query' directly on a backend struct, so the
;; fixture exercises the *transport* layer end-to-end without needing
;; the org-mode dispatch infrastructure.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-element)

;; --- Load dependencies in batch ---
(let* ((this-file (or load-file-name buffer-file-name))
       (here (file-name-directory this-file))
       (root (expand-file-name ".." here)))
  (add-to-list 'load-path root)
  (add-to-list 'load-path (expand-file-name "tests/support" root))
  (require 'literate-elisp)
  (unless (featurep 'claude-agent-backend)
    (literate-elisp-load (expand-file-name "claude-agent-backend.org" root)))
  (unless (featurep 'claude-agent-pi-backend)
    (literate-elisp-load
     (expand-file-name "claude-agent-pi-backend.org" root))))

(require 'claude-agent-backend)
(require 'claude-agent-pi-backend)
(require 'pi-test-helpers)


(defconst test-e2e-pi--fixture
  (expand-file-name "tests/e2e/org/pi-backend-test.org"
                    (file-name-directory
                     (directory-file-name
                      (file-name-directory
                       (or load-file-name buffer-file-name)))))
  "Absolute path to the Pi E2E fixture .org file.")


;; --- Fixture parsing ---

(defun test-e2e-pi--with-fixture-buffer (fn)
  "Open the fixture .org in a fresh buffer, call FN with that buffer current.
Always kills the buffer afterwards.  Suppresses local-eval prompts."
  (let ((enable-local-eval nil)
        (enable-local-variables :safe))
    (with-current-buffer (find-file-noselect test-e2e-pi--fixture)
      (unwind-protect
          (progn
            (org-mode)
            (funcall fn (current-buffer)))
        (kill-buffer (current-buffer))))))

(defun test-e2e-pi--story (custom-id)
  "Return a plist describing the story headed by CUSTOM-ID, or signal.
Plist keys: :heading, :properties (alist), :prompt (string)."
  (test-e2e-pi--with-fixture-buffer
   (lambda (_buf)
     (let* ((tree (org-element-parse-buffer))
            (heading
             (cl-loop for h in (org-element-map tree 'headline #'identity)
                      when (equal custom-id
                                  (org-element-property :CUSTOM_ID h))
                      return h)))
       (unless heading
         (error "No heading with :CUSTOM_ID: %s in %s"
                custom-id test-e2e-pi--fixture))
       ;; Collect all property-drawer values as a flat alist.
       (let ((props
              (mapcar (lambda (k)
                        (cons k (org-element-property
                                 (intern (concat ":" k)) heading)))
                      '("EXPECTED" "TIMEOUT" "NEEDS"
                        "CANCEL_AFTER" "SHOW_THINKING")))
             ;; First ai src block under the heading is the prompt.
             (prompt
              (cl-loop for blk in (org-element-map heading 'src-block #'identity)
                       when (equal "ai" (org-element-property :language blk))
                       return (string-trim
                               (org-element-property :value blk)))))
         (list :heading (org-element-property :raw-value heading)
               :properties props
               :prompt prompt))))))

(defun test-e2e-pi--needs (story keyword)
  "Return non-nil if STORY's NEEDS property mentions KEYWORD (a string)."
  (let ((needs (cdr (assoc "NEEDS" (plist-get story :properties)))))
    (and needs (string-match-p (regexp-quote keyword) needs))))

(defun test-e2e-pi--prerequisites-met (story)
  "Return non-nil if STORY's NEEDS list is fully satisfied by the host."
  (and (or (not (test-e2e-pi--needs story "mcp"))
           (test-pi--mcp-available-p))
       (or (not (test-e2e-pi--needs story "extension"))
           (test-pi--extension-installed-p))))


;; --- Story runner ---

(cl-defun test-e2e-pi--run-story (custom-id)
  "Drive the story headed by CUSTOM-ID through the Pi backend.
Returns a plist with :collected (string), :complete (bool),
:errored (string-or-nil), :duration (float seconds), :prompt (string)."
  (let* ((story (test-e2e-pi--story custom-id))
         (props (plist-get story :properties))
         (timeout (string-to-number
                   (or (cdr (assoc "TIMEOUT" props)) "30")))
         (cancel-after (cdr (assoc "CANCEL_AFTER" props)))
         (show-thinking (equal "yes"
                               (downcase
                                (or (cdr (assoc "SHOW_THINKING" props)) "no"))))
         (prompt (plist-get story :prompt))
         (collected "")
         (complete nil)
         (errored nil)
         (t0 (float-time)))
    (unless prompt
      (error "Story %s has no `ai' src block" custom-id))
    (test-pi--with-backend b
      ;; Allow emacs_eval for stories that may need it.
      (setf (claude-agent-pi-backend-environment b)
            '("EMACS_MCP_ALLOW_EVAL=1"))
      (setf (claude-agent-pi-backend-show-thinking b) show-thinking)
      (let ((handle
             (claude-agent-backend-query
              b prompt
              (list
               :on-token (lambda (delta)
                           (setq collected (concat collected delta)))
               :on-complete (lambda (_msgs) (setq complete t))
               :on-error (lambda (msg) (setq errored msg))))))
        ;; Mid-stream cancel if requested.
        (when cancel-after
          (let ((delay (string-to-number cancel-after)))
            (run-at-time delay nil
                         (lambda ()
                           (ignore-errors
                             (claude-agent-backend-cancel b handle))))))
        (test-pi--wait-until
         (lambda () (or complete errored))
         timeout)))
    (list :collected collected
          :complete complete
          :errored errored
          :duration (- (float-time) t0)
          :prompt prompt)))


;; --- Helper: assert the standard "expected substring" contract ---

(defun test-e2e-pi--assert (custom-id)
  "Run CUSTOM-ID and assert ON-COMPLETE fired and EXPECTED appeared."
  (let* ((story (test-e2e-pi--story custom-id))
         (props (plist-get story :properties))
         (expected (cdr (assoc "EXPECTED" props)))
         (result (test-e2e-pi--run-story custom-id)))
    (should (null (plist-get result :errored)))
    (should (plist-get result :complete))
    (when (and expected (> (length expected) 0))
      (should (string-match-p (regexp-quote expected)
                              (plist-get result :collected))))
    result))


;; --- One ERT test per automated story ---
;;
;; Each test goes through the same shape: prerequisites → assert.
;; Hand-written (vs auto-generated) so ERT reports per-story timing
;; and per-story failure cleanly.

(ert-deftest e2e-pi--simple-query ()
  "Story 1: simplest text round-trip."
  :tags '(:e2e-pi)
  (skip-unless (test-pi--available-p))
  (let ((story (test-e2e-pi--story "pi-e2e-simple-query")))
    (skip-unless (test-e2e-pi--prerequisites-met story))
    (test-e2e-pi--assert "pi-e2e-simple-query")))


(ert-deftest e2e-pi--multiline-streaming ()
  "Story 2: multi-line response exercises text_delta concatenation."
  :tags '(:e2e-pi)
  (skip-unless (test-pi--available-p))
  (let ((story (test-e2e-pi--story "pi-e2e-multiline")))
    (skip-unless (test-e2e-pi--prerequisites-met story))
    (let ((result (test-e2e-pi--assert "pi-e2e-multiline")))
      ;; Also assert the earlier markers landed (full chunk preservation).
      (let ((collected (plist-get result :collected)))
        (should (string-match-p "BETA_ONE" collected))
        (should (string-match-p "BETA_TWO" collected))))))


(ert-deftest e2e-pi--cancel-mid-stream ()
  "Story 3: abort during generation; callback chain terminates promptly."
  :tags '(:e2e-pi)
  (skip-unless (test-pi--available-p))
  (let* ((story (test-e2e-pi--story "pi-e2e-cancel"))
         (timeout (string-to-number
                   (cdr (assoc "TIMEOUT"
                               (plist-get story :properties))))))
    (skip-unless (test-e2e-pi--prerequisites-met story))
    (let ((result (test-e2e-pi--run-story "pi-e2e-cancel")))
      ;; Either complete or error fires — both are acceptable
      ;; terminations.  What we assert is *promptness*: the duration
      ;; should be well under TIMEOUT (the cancel cuts off the long
      ;; generation).
      (should (or (plist-get result :complete)
                  (plist-get result :errored)))
      (should (< (plist-get result :duration) (* 0.9 timeout))))))


(ert-deftest e2e-pi--mcp-buffer-list ()
  "Story 4: Pi LLM invokes emacs_buffer_list via the extension."
  :tags '(:e2e-pi)
  (skip-unless (test-pi--available-p))
  (let ((story (test-e2e-pi--story "pi-e2e-mcp-buffer-list")))
    (skip-unless (test-e2e-pi--prerequisites-met story))
    (test-e2e-pi--assert "pi-e2e-mcp-buffer-list")))


(ert-deftest e2e-pi--mcp-org-property ()
  "Story 5: Pi LLM reads an org property of the fixture via emacs_org_get_property.
This requires the fixture file to be open in the host Emacs (the
extension reads from the running Emacs, not the test sub-process).
We *open* it explicitly here so the assertion target exists."
  :tags '(:e2e-pi)
  (skip-unless (test-pi--available-p))
  (let ((story (test-e2e-pi--story "pi-e2e-mcp-property")))
    (skip-unless (test-e2e-pi--prerequisites-met story))
    ;; Pop the fixture file into the host Emacs so the extension's
    ;; (with-current-buffer "pi-backend-test.org" ...) finds it.
    ;; In batch tests this `find-file-noselect' runs in *this* Emacs
    ;; which is also where the MCP server runs (in interactive use).
    ;; If MCP server is in a separate Emacs, this assertion may fail
    ;; in batch mode — the story is therefore best-effort here and
    ;; primarily for interactive use.
    (let ((buf (find-file-noselect test-e2e-pi--fixture)))
      (unwind-protect
          (test-e2e-pi--assert "pi-e2e-mcp-property")
        (kill-buffer buf)))))


(provide 'test-e2e-pi-backend)
;;; test-e2e-pi-backend.el ends here
