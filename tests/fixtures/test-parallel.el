;;; test-parallel.el --- Parallel test execution support -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Support for running integration tests in parallel using test sharding.
;; Each shard runs a subset of tests, determined by hashing test names.
;;
;; Usage from Makefile:
;;   emacs --batch ... --eval "(test-claude-run-shard 4 0)"
;;
;; This runs shard 0 of 4 total shards (i.e., ~25% of tests).

;;; Code:

(require 'ert)

(defvar test-claude-parallel-verbose nil
  "When non-nil, print detailed shard assignment info.")

(defun test-claude-get-integration-tests ()
  "Return list of all integration test symbols.
Tests are identified by having :integration in their tags."
  (let ((result nil))
    (mapatoms
     (lambda (sym)
       (when (ert-test-boundp sym)
         (let* ((test (ert-get-test sym))
                (tags (and test (ert-test-tags test))))
           (when (memq :integration tags)
             (push sym result))))))
    (sort result (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defun test-claude-assign-shard (test-sym total-shards)
  "Return shard index (0 to TOTAL-SHARDS-1) for TEST-SYM.
Uses hash of test name for deterministic assignment."
  (mod (sxhash (symbol-name test-sym)) total-shards))

(defun test-claude-tests-for-shard (total-shards shard-index)
  "Return list of test symbols belonging to SHARD-INDEX of TOTAL-SHARDS."
  (let ((all-tests (test-claude-get-integration-tests)))
    (seq-filter
     (lambda (test)
       (= shard-index (test-claude-assign-shard test total-shards)))
     all-tests)))

(defun test-claude-print-shard-distribution (total-shards)
  "Print how tests are distributed across TOTAL-SHARDS."
  (let ((all-tests (test-claude-get-integration-tests)))
    (message "=== Test Shard Distribution ===")
    (message "Total integration tests: %d" (length all-tests))
    (message "Total shards: %d" total-shards)
    (message "")
    (dotimes (i total-shards)
      (let ((shard-tests (test-claude-tests-for-shard total-shards i)))
        (message "Shard %d: %d tests" i (length shard-tests))
        (when test-claude-parallel-verbose
          (dolist (test shard-tests)
            (message "  - %s" test)))))
    (message "===============================")))

(defun test-claude-run-shard (total-shards shard-index)
  "Run integration tests belonging to SHARD-INDEX of TOTAL-SHARDS.
This is the main entry point called from Makefile."
  (let ((tests (test-claude-tests-for-shard total-shards shard-index)))
    (message "")
    (message "========================================")
    (message "Running shard %d of %d (%d tests)"
             shard-index total-shards (length tests))
    (message "========================================")
    (when test-claude-parallel-verbose
      (message "Tests in this shard:")
      (dolist (test tests)
        (message "  - %s" test)))
    (message "")

    (if (null tests)
        (progn
          (message "No tests in this shard - exiting successfully")
          (kill-emacs 0))
      ;; Build a selector using `member' pattern that ERT understands
      ;; ERT accepts: symbol, string, (member sym1 sym2 ...), (tag tagname), etc.
      (let ((selector (cons 'member tests)))
        (ert-run-tests-batch-and-exit selector)))))

(defun test-claude-preview-shards (total-shards)
  "Preview shard distribution without running tests.
Useful for debugging shard balance."
  (test-claude-print-shard-distribution total-shards))

(provide 'test-parallel)
;;; test-parallel.el ends here
