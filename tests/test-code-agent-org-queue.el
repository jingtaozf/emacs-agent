;;; test-code-agent-org-queue.el --- Tests for pending block queue -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for the pending block queue feature in code-agent-org.
;; Tests queue operations, header line display, and cancellation.

;;; Code:

(require 'ert)
(require 'org)
(require 'code-agent-org)

;;; Queue Operations Tests

(ert-deftest test-code-agent-org-queue-add ()
  "Test adding blocks to the pending queue."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-queue.org::test-session"))
      ;; Initially empty
      (should (= 0 (code-agent-org--queue-count session-key)))
      ;; Add first block
      (code-agent-org--queue-block session-key '(:custom-id "block-1" :content "test 1"))
      (should (= 1 (code-agent-org--queue-count session-key)))
      ;; Add second block
      (code-agent-org--queue-block session-key '(:custom-id "block-2" :content "test 2"))
      (should (= 2 (code-agent-org--queue-count session-key))))))

(ert-deftest test-code-agent-org-queue-dequeue-fifo ()
  "Test that dequeue returns blocks in FIFO order."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-queue.org::test-session"))
      ;; Add blocks in order
      (code-agent-org--queue-block session-key '(:custom-id "first" :content "1"))
      (code-agent-org--queue-block session-key '(:custom-id "second" :content "2"))
      (code-agent-org--queue-block session-key '(:custom-id "third" :content "3"))
      ;; Dequeue should return in FIFO order
      (let ((block1 (code-agent-org--dequeue-block session-key)))
        (should (equal "first" (plist-get block1 :custom-id))))
      (should (= 2 (code-agent-org--queue-count session-key)))
      (let ((block2 (code-agent-org--dequeue-block session-key)))
        (should (equal "second" (plist-get block2 :custom-id))))
      (should (= 1 (code-agent-org--queue-count session-key)))
      (let ((block3 (code-agent-org--dequeue-block session-key)))
        (should (equal "third" (plist-get block3 :custom-id))))
      (should (= 0 (code-agent-org--queue-count session-key))))))

(ert-deftest test-code-agent-org-queue-dequeue-empty ()
  "Test that dequeue returns nil for empty queue."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-queue.org::test-session"))
      ;; Empty queue returns nil
      (should (null (code-agent-org--dequeue-block session-key)))
      ;; After adding and removing, still returns nil
      (code-agent-org--queue-block session-key '(:custom-id "temp" :content "x"))
      (code-agent-org--dequeue-block session-key)
      (should (null (code-agent-org--dequeue-block session-key))))))

(ert-deftest test-code-agent-org-queue-clear ()
  "Test clearing the pending queue."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-queue.org::test-session"))
      ;; Add multiple blocks
      (code-agent-org--queue-block session-key '(:custom-id "a"))
      (code-agent-org--queue-block session-key '(:custom-id "b"))
      (code-agent-org--queue-block session-key '(:custom-id "c"))
      (should (= 3 (code-agent-org--queue-count session-key)))
      ;; Clear all
      (code-agent-org--clear-queue session-key)
      (should (= 0 (code-agent-org--queue-count session-key)))
      (should (null (code-agent-org--dequeue-block session-key))))))

(ert-deftest test-code-agent-org-total-queue-count ()
  "Test total queue count across all sessions."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session1 "/tmp/test-queue.org::session1")
          (session2 "/tmp/test-queue.org::session2"))
      ;; Initially zero
      (should (= 0 (code-agent-org--total-queue-count)))
      ;; Add to session 1
      (code-agent-org--queue-block session1 '(:custom-id "s1-a"))
      (code-agent-org--queue-block session1 '(:custom-id "s1-b"))
      (should (= 2 (code-agent-org--total-queue-count)))
      ;; Add to session 2
      (code-agent-org--queue-block session2 '(:custom-id "s2-a"))
      (should (= 3 (code-agent-org--total-queue-count)))
      ;; Clear session 1
      (code-agent-org--clear-queue session1)
      (should (= 1 (code-agent-org--total-queue-count))))))

;;; Queue Isolation Tests

(ert-deftest test-code-agent-org-queue-session-isolation ()
  "Test that queues are isolated per session."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session1 "/tmp/test-queue.org::session1")
          (session2 "/tmp/test-queue.org::session2"))
      ;; Add to different sessions
      (code-agent-org--queue-block session1 '(:custom-id "s1-block"))
      (code-agent-org--queue-block session2 '(:custom-id "s2-block"))
      ;; Each session has its own count
      (should (= 1 (code-agent-org--queue-count session1)))
      (should (= 1 (code-agent-org--queue-count session2)))
      ;; Dequeue from session1 doesn't affect session2
      (code-agent-org--dequeue-block session1)
      (should (= 0 (code-agent-org--queue-count session1)))
      (should (= 1 (code-agent-org--queue-count session2))))))

;;; Queue With Busy State Tests

(ert-deftest test-code-agent-org-queue-busy-state-integration ()
  "Test that busy state affects queue processing."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-queue.org::test-session"))
      ;; Set busy state
      (code-agent-org-session-put session-key :busy t)
      ;; Queue should still work
      (code-agent-org--queue-block session-key '(:custom-id "queued"))
      (should (= 1 (code-agent-org--queue-count session-key)))
      ;; Verify busy state
      (should (code-agent-org-session-get session-key :busy))
      ;; Clear busy
      (code-agent-org-session-put session-key :busy nil)
      (should (not (code-agent-org-session-get session-key :busy))))))

;;; Duplicate Prevention Tests

(ert-deftest test-code-agent-org-queue-no-duplicate-by-marker ()
  "Test that the same block (same marker position) cannot be queued twice."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue-dup.org")
    (insert "* Test\n#+begin_src ai\ntest\n#+end_src\n")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-queue-dup.org::test-session")
          (marker (save-excursion
                    (goto-char (point-min))
                    (re-search-forward "begin_src ai" nil t)
                    (copy-marker (point)))))
      ;; Queue block first time
      (code-agent-org--queue-block session-key
                               (list :custom-id "block-1"
                                     :content "test"
                                     :marker marker))
      (should (= 1 (code-agent-org--queue-count session-key)))
      ;; Queue the SAME block again (same marker position)
      (let ((marker2 (copy-marker (marker-position marker))))
        (code-agent-org--queue-block session-key
                                 (list :custom-id "block-1"
                                       :content "test"
                                       :marker marker2))
        ;; Should still be 1, not 2
        (should (= 1 (code-agent-org--queue-count session-key)))))))

(ert-deftest test-code-agent-org-queue-allows-different-blocks ()
  "Test that different blocks can still be queued."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue-diff.org")
    (insert "* Block A\n#+begin_src ai\nA\n#+end_src\n")
    (insert "* Block B\n#+begin_src ai\nB\n#+end_src\n")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-queue-diff.org::test-session"))
      ;; Queue block A
      (let ((marker-a (save-excursion
                        (goto-char (point-min))
                        (re-search-forward "begin_src ai" nil t)
                        (copy-marker (point)))))
        (code-agent-org--queue-block session-key
                                 (list :custom-id "block-a"
                                       :content "A"
                                       :marker marker-a)))
      (should (= 1 (code-agent-org--queue-count session-key)))
      ;; Queue block B (different block)
      (let ((marker-b (save-excursion
                        (goto-char (point-min))
                        (search-forward "Block B" nil t)
                        (re-search-forward "begin_src ai" nil t)
                        (copy-marker (point)))))
        (code-agent-org--queue-block session-key
                                 (list :custom-id "block-b"
                                       :content "B"
                                       :marker marker-b)))
      ;; Both should be queued
      (should (= 2 (code-agent-org--queue-count session-key))))))

;;; Cancel Behavior Tests

(ert-deftest test-code-agent-org-cancel-queue-only-preserves-running ()
  "Test that cancel-queue only clears queued blocks, not the running one."
  :tags '(:unit :fast :stable :isolated :org :queue :cancel)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-cancel.org")
    (insert "* Test\n#+begin_src ai\ntest\n#+end_src\n")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    ;; Navigate into AI block so code-agent-org-current-session-key works
    (goto-char (point-min))
    (re-search-forward "begin_src ai" nil t)
    (forward-line 1)
    ;; Get the actual session key that will be computed
    (let ((session-key (code-agent-org-current-session-key)))
      ;; Simulate running query
      (code-agent-org-session-put session-key :busy t)
      (code-agent-org-session-put session-key :process-state 'fake-process)
      ;; Queue some blocks
      (code-agent-org--queue-block session-key '(:custom-id "q1"))
      (code-agent-org--queue-block session-key '(:custom-id "q2"))
      (should (= 2 (code-agent-org--queue-count session-key)))
      (should (code-agent-org-session-get session-key :busy))
      ;; Cancel queue only
      (code-agent-org-cancel-queue)
      ;; Queue should be empty but session should still be busy
      ;; (running query not interrupted)
      (should (= 0 (code-agent-org--queue-count session-key)))
      (should (code-agent-org-session-get session-key :busy)))))

(ert-deftest test-code-agent-org-queue-duplicate-prevention-integration ()
  "Integration test: same block position cannot be queued multiple times."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-dup-int.org")
    (insert "* Block 1\n#+begin_src ai\nfirst\n#+end_src\n")
    (insert "* Block 2\n#+begin_src ai\nsecond\n#+end_src\n")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let* ((session-key "/tmp/test-dup-int.org::test-session")
           ;; Get marker for first block
           (marker1 (save-excursion
                      (goto-char (point-min))
                      (re-search-forward "#\\+begin_src ai" nil t)
                      (copy-marker (line-beginning-position)))))
      ;; Queue first block
      (code-agent-org--queue-block session-key
                               (list :custom-id "b1" :marker marker1))
      (should (= 1 (code-agent-org--queue-count session-key)))
      ;; Try to queue same block again (different marker object, same position)
      (let ((marker1-copy (save-excursion
                            (goto-char (point-min))
                            (re-search-forward "#\\+begin_src ai" nil t)
                            (copy-marker (line-beginning-position)))))
        (code-agent-org--queue-block session-key
                                 (list :custom-id "b1" :marker marker1-copy))
        ;; Should still be 1, not 2 - duplicate rejected
        (should (= 1 (code-agent-org--queue-count session-key))))
      ;; But different block should be allowed
      (let ((marker2 (save-excursion
                       (goto-char (point-min))
                       (search-forward "Block 2" nil t)
                       (re-search-forward "#\\+begin_src ai" nil t)
                       (copy-marker (line-beginning-position)))))
        (code-agent-org--queue-block session-key
                                 (list :custom-id "b2" :marker marker2))
        ;; Now should be 2
        (should (= 2 (code-agent-org--queue-count session-key)))))))

(ert-deftest test-code-agent-org-queue-block-returns-status ()
  "Test that queue-block returns whether block was added."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-return.org")
    (insert "* Test\n#+begin_src ai\ntest\n#+end_src\n")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let* ((session-key "/tmp/test-return.org::test-session")
           (marker (save-excursion
                     (goto-char (point-min))
                     (re-search-forward "#\\+begin_src ai" nil t)
                     (copy-marker (line-beginning-position)))))
      ;; First add should return t (or non-nil)
      (let ((result1 (code-agent-org--queue-block session-key
                                              (list :custom-id "b1" :marker marker))))
        (should result1))
      ;; Duplicate add should return 'in-queue (not 'queued)
      (let ((marker2 (copy-marker (marker-position marker))))
        (let ((result2 (code-agent-org--queue-block session-key
                                                (list :custom-id "b1" :marker marker2))))
          (should (eq result2 'in-queue)))))))

(ert-deftest test-code-agent-org-queue-running-block-rejected ()
  "Test that the currently running block cannot be queued.
If Block A is running (its custom-id stored in session), trying to
queue the same block should be rejected."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-running.org")
    (insert "* Test\n#+begin_src ai\ntest\n#+end_src\n")
    (setq-local code-agent-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-running.org::test-session"))
      ;; Simulate that this block is already running with custom-id
      (code-agent-org-session-put session-key :busy t)
      (code-agent-org-session-put session-key :custom-id "b1")
      ;; Queue should be empty
      (should (= 0 (code-agent-org--queue-count session-key)))
      ;; Now try to queue the SAME block (same custom-id)
      ;; This simulates user pressing C-c C-c on the running block
      (let ((result (code-agent-org--queue-block session-key
                                              (list :custom-id "b1"
                                                    :content "test"))))
        ;; Should be rejected - returns 'running (not 'queued)
        (should (eq result 'running)))
      ;; Queue should still be empty
      (should (= 0 (code-agent-org--queue-count session-key))))))

(provide 'test-code-agent-org-queue)
;;; test-code-agent-org-queue.el ends here
