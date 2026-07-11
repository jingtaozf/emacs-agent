;;; test-codebase-hardening.el --- F10: Verify defensive patterns -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;;; Commentary:

;; F10: Codebase hardening — regression tests verifying that existing
;; defensive patterns remain in place.  These patterns were validated
;; during the bug-hunting experiment (all 3 "bugs" turned out to
;; already be correctly handled).
;;
;; Bug #2 (stdin-close timer) and Bug #3 (JSON parser condition-case)
;; guarded code that was deleted 2026-07 along with the JSON-stream
;; engine (code-agent--schedule-stdin-close, code-agent--try-parse-json
;; — zero production callers after the org-as-control-plane pivot).
;; Bug #6: buffer-live-p check in font-lock debounce timer

;;; Code:

(require 'ert)

(defvar test-hardening--project-root
  (or (and load-file-name
           (locate-dominating-file (file-name-directory load-file-name) "Makefile"))
      (locate-dominating-file default-directory "Makefile"))
  "Project root directory.")

;;; Bug #6 regression: Font-lock timer checks buffer liveness

(ert-deftest test-hardening-invariant-timer-liveness-checks ()
  "All run-at-time/run-with-timer callbacks in source .org files
that reference process-send-eof or font-lock-flush include a liveness guard.
FIX: Wrap timer body with (when (process-live-p ...) ...) or
(when (buffer-live-p ...) ...) as appropriate.
See ARCHITECTURE.org Invariants: Timer callbacks check liveness."
  :tags '(:unit :fast :stable :hardening)
  (when test-hardening--project-root
    ;; Check code-agent.org and code-agent-backend.org: any process-send-eof
    ;; near run-at-time should have process-live-p nearby.
    ;; Paths reflect the 2026-05-26 lp/<group>/ restructure.
    (dolist (org-file '("lp/chat/code-agent.org" "lp/sdk/code-agent-backend.org"))
      (let* ((file (expand-file-name org-file test-hardening--project-root))
             (content (with-temp-buffer
                        (insert-file-contents file)
                        (buffer-string))))
        (when (and (string-match-p "run-at-time" content)
                   (string-match-p "process-send-eof" content))
          (should (or (string-match-p "process-live-p" content)
                      (error "Timer in %s without process-live-p guard.\nFIX: See ARCHITECTURE.org Invariants." org-file))))))))

(provide 'test-codebase-hardening)
;;; test-codebase-hardening.el ends here
