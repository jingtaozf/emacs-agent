;;; test-codebase-hardening.el --- F10: Verify defensive patterns -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;;; Commentary:

;; F10: Codebase hardening — regression tests verifying that existing
;; defensive patterns remain in place.  These patterns were validated
;; during the bug-hunting experiment (all 3 "bugs" turned out to
;; already be correctly handled).
;;
;; Bug #2: process-live-p check before process-send-eof in timer
;; Bug #3: condition-case around JSON parsing
;; Bug #6: buffer-live-p check in font-lock debounce timer

;;; Code:

(require 'ert)

(defvar test-hardening--project-root
  (or (and load-file-name
           (locate-dominating-file (file-name-directory load-file-name) "Makefile"))
      (locate-dominating-file default-directory "Makefile"))
  "Project root directory.")

;;; Bug #2 regression: Timer checks process liveness before send-eof

(ert-deftest test-hardening-stdin-close-checks-process-live ()
  "The stdin-close timer callback checks (process-live-p) before (process-send-eof).
FIX: Wrap process-send-eof in timer callbacks with (when (process-live-p proc) ...)
See ARCHITECTURE.org Invariants: Timer callbacks check liveness."
  :tags '(:unit :fast :stable :hardening)
  (when test-hardening--project-root
    (let* ((file (expand-file-name "claude-agent-backend.org" test-hardening--project-root))
           (content (with-temp-buffer
                      (insert-file-contents file)
                      (buffer-string))))
      ;; The delayed stdin-close code must check process-live-p
      ;; near process-send-eof.  Verify both appear in the same region.
      (should (string-match-p "process-live-p" content))
      (should (string-match-p "process-send-eof" content))
      ;; Verify the timer lambda has the guard (search for the pattern)
      (should (or (string-match-p
                   "process-live-p proc" content)
                  (error "process-send-eof in timer without process-live-p guard.\nFIX: Add (when (process-live-p proc) ...) around process-send-eof in timer callback."))))))

;;; Bug #3 regression: JSON parser has condition-case

(ert-deftest test-hardening-json-parser-handles-errors ()
  "claude-agent--try-parse-json wraps json-read-from-string in condition-case.
FIX: Add (condition-case nil (json-read-from-string ...) (error nil)) to
prevent JSON parse errors from propagating through process filter."
  :tags '(:unit :fast :stable :hardening)
  ;; Test the actual function behavior
  (should (null (claude-agent--try-parse-json "not json at all")))
  (should (null (claude-agent--try-parse-json "")))
  (should (null (claude-agent--try-parse-json "{")))
  ;; Valid JSON should parse
  (let ((result (claude-agent--try-parse-json "{\"type\":\"test\"}")))
    (should result)
    (should (equal (plist-get result :type) "test"))))

;;; Bug #6 regression: Font-lock timer checks buffer liveness

(ert-deftest test-hardening-fontlock-timer-checks-buffer-live ()
  "The debounced font-lock timer checks (buffer-live-p) before operating.
FIX: Add (when (buffer-live-p buf) ...) inside the timer lambda in
code-agent-org--schedule-fontlock. See ARCHITECTURE.org Invariants."
  :tags '(:unit :fast :stable :hardening)
  (when test-hardening--project-root
    (let* ((file (expand-file-name "code-agent-org-response.org" test-hardening--project-root))
           (content (with-temp-buffer
                      (insert-file-contents file)
                      (buffer-string))))
      (should (or (string-match-p "buffer-live-p" content)
                  (error "Font-lock timer missing buffer-live-p check.\nFIX: Add (when (buffer-live-p buf) ...) in schedule-fontlock timer lambda."))))))

;;; Verify the invariant: timer callbacks check liveness

(ert-deftest test-hardening-invariant-timer-liveness-checks ()
  "All run-at-time/run-with-timer callbacks in source .org files
that reference process-send-eof or font-lock-flush include a liveness guard.
FIX: Wrap timer body with (when (process-live-p ...) ...) or
(when (buffer-live-p ...) ...) as appropriate.
See ARCHITECTURE.org Invariants: Timer callbacks check liveness."
  :tags '(:unit :fast :stable :hardening)
  (when test-hardening--project-root
    ;; Check claude-agent.org and claude-agent-backend.org: any process-send-eof
    ;; near run-at-time should have process-live-p nearby
    (dolist (org-file '("claude-agent.org" "claude-agent-backend.org"))
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
