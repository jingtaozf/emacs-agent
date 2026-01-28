;;; test-claude-org-queue.el --- Tests for pending block queue -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for the pending block queue feature in claude-org.
;; Tests queue operations, header line display, and cancellation.

;;; Code:

(require 'ert)
(require 'org)
(require 'claude-org)

;;; Queue Operations Tests

(ert-deftest test-claude-org-queue-add ()
  "Test adding blocks to the pending queue."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-queue.org::test-session"))
      ;; Initially empty
      (should (= 0 (claude-org--queue-count session-key)))
      ;; Add first block
      (claude-org--queue-block session-key '(:custom-id "block-1" :content "test 1"))
      (should (= 1 (claude-org--queue-count session-key)))
      ;; Add second block
      (claude-org--queue-block session-key '(:custom-id "block-2" :content "test 2"))
      (should (= 2 (claude-org--queue-count session-key))))))

(ert-deftest test-claude-org-queue-dequeue-fifo ()
  "Test that dequeue returns blocks in FIFO order."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-queue.org::test-session"))
      ;; Add blocks in order
      (claude-org--queue-block session-key '(:custom-id "first" :content "1"))
      (claude-org--queue-block session-key '(:custom-id "second" :content "2"))
      (claude-org--queue-block session-key '(:custom-id "third" :content "3"))
      ;; Dequeue should return in FIFO order
      (let ((block1 (claude-org--dequeue-block session-key)))
        (should (equal "first" (plist-get block1 :custom-id))))
      (should (= 2 (claude-org--queue-count session-key)))
      (let ((block2 (claude-org--dequeue-block session-key)))
        (should (equal "second" (plist-get block2 :custom-id))))
      (should (= 1 (claude-org--queue-count session-key)))
      (let ((block3 (claude-org--dequeue-block session-key)))
        (should (equal "third" (plist-get block3 :custom-id))))
      (should (= 0 (claude-org--queue-count session-key))))))

(ert-deftest test-claude-org-queue-dequeue-empty ()
  "Test that dequeue returns nil for empty queue."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-queue.org::test-session"))
      ;; Empty queue returns nil
      (should (null (claude-org--dequeue-block session-key)))
      ;; After adding and removing, still returns nil
      (claude-org--queue-block session-key '(:custom-id "temp" :content "x"))
      (claude-org--dequeue-block session-key)
      (should (null (claude-org--dequeue-block session-key))))))

(ert-deftest test-claude-org-queue-clear ()
  "Test clearing the pending queue."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-queue.org::test-session"))
      ;; Add multiple blocks
      (claude-org--queue-block session-key '(:custom-id "a"))
      (claude-org--queue-block session-key '(:custom-id "b"))
      (claude-org--queue-block session-key '(:custom-id "c"))
      (should (= 3 (claude-org--queue-count session-key)))
      ;; Clear all
      (claude-org--clear-queue session-key)
      (should (= 0 (claude-org--queue-count session-key)))
      (should (null (claude-org--dequeue-block session-key))))))

(ert-deftest test-claude-org-total-queue-count ()
  "Test total queue count across all sessions."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((session1 "/tmp/test-queue.org::session1")
          (session2 "/tmp/test-queue.org::session2"))
      ;; Initially zero
      (should (= 0 (claude-org--total-queue-count)))
      ;; Add to session 1
      (claude-org--queue-block session1 '(:custom-id "s1-a"))
      (claude-org--queue-block session1 '(:custom-id "s1-b"))
      (should (= 2 (claude-org--total-queue-count)))
      ;; Add to session 2
      (claude-org--queue-block session2 '(:custom-id "s2-a"))
      (should (= 3 (claude-org--total-queue-count)))
      ;; Clear session 1
      (claude-org--clear-queue session1)
      (should (= 1 (claude-org--total-queue-count))))))

;;; Queue Isolation Tests

(ert-deftest test-claude-org-queue-session-isolation ()
  "Test that queues are isolated per session."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((session1 "/tmp/test-queue.org::session1")
          (session2 "/tmp/test-queue.org::session2"))
      ;; Add to different sessions
      (claude-org--queue-block session1 '(:custom-id "s1-block"))
      (claude-org--queue-block session2 '(:custom-id "s2-block"))
      ;; Each session has its own count
      (should (= 1 (claude-org--queue-count session1)))
      (should (= 1 (claude-org--queue-count session2)))
      ;; Dequeue from session1 doesn't affect session2
      (claude-org--dequeue-block session1)
      (should (= 0 (claude-org--queue-count session1)))
      (should (= 1 (claude-org--queue-count session2))))))

;;; Queue With Busy State Tests

(ert-deftest test-claude-org-queue-busy-state-integration ()
  "Test that busy state affects queue processing."
  :tags '(:unit :fast :stable :isolated :org :queue)
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/test-queue.org")
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((session-key "/tmp/test-queue.org::test-session"))
      ;; Set busy state
      (claude-org--session-put session-key :busy t)
      ;; Queue should still work
      (claude-org--queue-block session-key '(:custom-id "queued"))
      (should (= 1 (claude-org--queue-count session-key)))
      ;; Verify busy state
      (should (claude-org--session-get session-key :busy))
      ;; Clear busy
      (claude-org--session-put session-key :busy nil)
      (should (not (claude-org--session-get session-key :busy))))))

(provide 'test-claude-org-queue)
;;; test-claude-org-queue.el ends here
