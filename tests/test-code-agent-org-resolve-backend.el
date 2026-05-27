;;; test-code-agent-org-resolve-backend.el --- Backend cache invalidation tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for `code-agent-org--resolve-backend' — the property-aware
;; backend cache layer that prevents the 2026-05-25 "switching
;; :CLAUDE_BACKEND: silently keeps using the old backend" bug.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'code-agent-org)


(defvar test-resolve--cleanup-calls nil
  "Records (cleanup BACKEND) calls so tests can assert cache invalidation.")


(defmacro test-resolve--with-buffer (claude-backend-property &rest body)
  "Run BODY in an org buffer whose CLAUDE_BACKEND property is set to
CLAUDE-BACKEND-PROPERTY (a string).  Buffer is killed unconditionally."
  (declare (indent 1) (debug t))
  `(let ((buf (generate-new-buffer "*resolve-backend-test*")))
     (unwind-protect
         (with-current-buffer buf
           (org-mode)
           (insert "* Test heading\n"
                   ":PROPERTIES:\n"
                   ":CUSTOM_ID: test-resolve\n"
                   ":CLAUDE_BACKEND: " ,claude-backend-property "\n"
                   ":END:\n")
           (goto-char (point-min))
           (re-search-forward ":CUSTOM_ID: test-resolve")
           ,@body)
       (kill-buffer buf))))


(defmacro test-resolve--with-fake-registry (&rest body)
  "Run BODY against a stub `code-agent-org-backend-registry' that
returns simple structs.  Restores the original registry afterwards.

Records cleanup calls in `test-resolve--cleanup-calls'."
  (declare (indent 0) (debug t))
  `(let ((saved-registry code-agent-org-backend-registry)
         (test-resolve--cleanup-calls nil))
     (cl-letf* (((symbol-function 'code-agent-backend-cleanup)
                 (lambda (backend)
                   (push (list 'cleanup backend) test-resolve--cleanup-calls))))
       (unwind-protect
           (let ((code-agent-org-backend-registry
                  `(("alpha" . ,(lambda (sk _opts)
                                  (list :tag 'alpha :session-key sk)))
                    ("beta"  . ,(lambda (sk _opts)
                                  (list :tag 'beta  :session-key sk)))
                    ;; The fallback used when the registry lookup misses;
                    ;; `--make-default-backend' references it by string.
                    ("claude-code" . ,(lambda (sk _opts)
                                        (list :tag 'fallback :session-key sk))))))
             ,@body)
         (setq code-agent-org-backend-registry saved-registry)))))


(ert-deftest test-resolve--first-call-builds-and-caches ()
  "First resolve on a fresh session constructs backend + caches both slots."
  :tags '(:unit :fast :stable)
  (test-resolve--with-fake-registry
    (test-resolve--with-buffer "alpha"
      (let* ((sk "test-sk-first")
             (result (code-agent-org--resolve-backend sk nil)))
        (should (equal '(:tag alpha :session-key "test-sk-first") result))
        (should (equal result
                       (code-agent-org-session-get sk :backend)))
        (should (equal "alpha"
                       (code-agent-org-session-get sk :backend-property)))
        ;; No cleanup on first dispatch (nothing to invalidate).
        (should (null test-resolve--cleanup-calls))))))


(ert-deftest test-resolve--second-call-with-same-property-reuses-cache ()
  "If property is unchanged, the cached backend is returned (eq)."
  :tags '(:unit :fast :stable)
  (test-resolve--with-fake-registry
    (test-resolve--with-buffer "alpha"
      (let* ((sk "test-sk-reuse")
             (first  (code-agent-org--resolve-backend sk nil))
             (second (code-agent-org--resolve-backend sk nil)))
        (should (eq first second))
        ;; Cleanup must NOT have fired — we did not rebuild.
        (should (null test-resolve--cleanup-calls))))))


(ert-deftest test-resolve--property-change-invalidates-and-rebuilds ()
  "Changing CLAUDE_BACKEND fires cleanup on the old backend AND returns
a freshly-built one.  This is the 2026-05-25 regression test.

`code-agent-org--sessions' is `defvar-local', so the test must mutate
the property within ONE buffer to simulate the real-life flow (edit
the property, re-execute the same block) — not move across buffers."
  :tags '(:unit :fast :stable)
  (test-resolve--with-fake-registry
    (test-resolve--with-buffer "alpha"
      (let* ((sk "test-sk-switch")
             (cached-alpha (code-agent-org--resolve-backend sk nil)))
        ;; Edit the property in place — alpha → beta — same buffer,
        ;; same session table.
        (save-excursion
          (goto-char (point-min))
          (re-search-forward "^:CLAUDE_BACKEND: alpha$")
          (replace-match ":CLAUDE_BACKEND: beta" t t)
          ;; Move point back under the heading so `org-entry-get' resolves
          ;; the new value.
          (re-search-backward "\\* Test heading"))
        (let ((rebuilt (code-agent-org--resolve-backend sk nil)))
          (should (equal '(:tag beta :session-key "test-sk-switch") rebuilt))
          (should (not (eq rebuilt cached-alpha)))
          (should (equal 1 (length test-resolve--cleanup-calls)))
          (should (equal (list 'cleanup cached-alpha)
                         (car test-resolve--cleanup-calls)))
          (should (equal rebuilt
                         (code-agent-org-session-get sk :backend)))
          (should (equal "beta"
                         (code-agent-org-session-get sk :backend-property))))))))


(ert-deftest test-resolve--unknown-property-falls-back-and-caches-string ()
  "Unknown property string still produces the fallback backend; the
cache stores the unknown string so a SUBSEQUENT change away from it
correctly invalidates."
  :tags '(:unit :fast :stable)
  (test-resolve--with-fake-registry
    (test-resolve--with-buffer "no-such-backend"
      (let* ((sk "test-sk-unknown")
             (result (code-agent-org--resolve-backend sk nil)))
        ;; Hit the "claude-code" fallback (per --make-default-backend).
        (should (equal '(:tag fallback :session-key "test-sk-unknown") result))
        (should (equal "no-such-backend"
                       (code-agent-org-session-get sk :backend-property)))))))


(ert-deftest test-resolve--cleanup-error-is-swallowed ()
  "Cleanup throwing must not block rebuild — the user's switch attempt
should still succeed even if the old backend's teardown errors."
  :tags '(:unit :fast :stable)
  (let ((saved code-agent-org-backend-registry)
        (test-resolve--cleanup-calls nil))
    (cl-letf (((symbol-function 'code-agent-backend-cleanup)
               (lambda (_b) (error "boom from cleanup"))))
      (unwind-protect
          (let ((code-agent-org-backend-registry
                 `(("alpha" . ,(lambda (sk _o) (list :tag 'alpha :session-key sk)))
                   ("beta"  . ,(lambda (sk _o) (list :tag 'beta  :session-key sk)))
                   ("claude-code" . ,(lambda (sk _o)
                                       (list :tag 'fallback :session-key sk))))))
            (let ((sk "test-sk-cleanup-err"))
              (test-resolve--with-buffer "alpha"
                (code-agent-org--resolve-backend sk nil))
              (test-resolve--with-buffer "beta"
                (let ((rebuilt (code-agent-org--resolve-backend sk nil)))
                  (should (equal '(:tag beta :session-key "test-sk-cleanup-err")
                                 rebuilt))))))
        (setq code-agent-org-backend-registry saved)))))


(provide 'test-code-agent-org-resolve-backend)
;;; test-code-agent-org-resolve-backend.el ends here
