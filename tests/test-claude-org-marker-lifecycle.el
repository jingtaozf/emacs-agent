;;; test-claude-org-marker-lifecycle.el --- TDD Tests for Marker Lifecycle -*- lexical-binding: t; -*-

;; TDD tests for marker lifecycle management
;; These tests define expected behavior BEFORE implementation
;; Tag: :tdd - written test-first

(require 'ert)
(require 'cl-lib)

;; Note: claude-org.org is loaded via Makefile

;;; Marker Validation Function Tests

(ert-deftest test-marker-valid-p-nil-marker ()
  "TDD: nil marker should be invalid."
  :tags '(:unit :fast :stable :isolated :marker :tdd)
  (should-not (claude-org--marker-valid-p nil)))

(ert-deftest test-marker-valid-p-non-marker ()
  "TDD: Non-marker object should be invalid."
  :tags '(:unit :fast :stable :isolated :marker :tdd)
  (should-not (claude-org--marker-valid-p 42))
  (should-not (claude-org--marker-valid-p "string"))
  (should-not (claude-org--marker-valid-p '(1 2 3))))

(ert-deftest test-marker-valid-p-no-buffer ()
  "TDD: Marker with no buffer should be invalid."
  :tags '(:unit :fast :stable :isolated :marker :tdd)
  (let ((marker (make-marker)))
    ;; Marker not set to any position
    (should-not (claude-org--marker-valid-p marker))))

(ert-deftest test-marker-valid-p-killed-buffer ()
  "TDD: Marker in killed buffer should be invalid."
  :tags '(:unit :fast :stable :isolated :marker :tdd)
  (let* ((buf (generate-new-buffer "*test-marker*"))
         (marker (with-current-buffer buf
                   (insert "test content")
                   (point-marker))))
    ;; Kill the buffer
    (kill-buffer buf)
    ;; Marker should now be invalid
    (should-not (claude-org--marker-valid-p marker))))

(ert-deftest test-marker-valid-p-valid-marker ()
  "TDD: Valid marker in live buffer should be valid."
  :tags '(:unit :fast :stable :isolated :marker :tdd)
  (let* ((buf (generate-new-buffer "*test-marker*"))
         (marker (with-current-buffer buf
                   (insert "test content")
                   (point-marker))))
    (unwind-protect
        (should (claude-org--marker-valid-p marker))
      (kill-buffer buf))))

(ert-deftest test-marker-valid-p-position-nil ()
  "TDD: Marker with nil position should be invalid."
  :tags '(:unit :fast :stable :isolated :marker :tdd)
  (let* ((buf (generate-new-buffer "*test-marker*"))
         (marker (make-marker)))
    (unwind-protect
        (progn
          ;; Set marker to buffer but position is still nil
          ;; This is an edge case that can occur
          (set-marker marker nil buf)
          (should-not (claude-org--marker-valid-p marker)))
      (kill-buffer buf))))

;;; Queue Operations with Invalid Markers

(ert-deftest test-queue-block-handles-invalid-running-marker ()
  "TDD: Queue operations should handle invalid running marker gracefully."
  :tags '(:unit :fast :stable :isolated :marker :queue :tdd)
  (with-temp-buffer
    (org-mode)
    (let ((session-key "test-session"))
      ;; Create a marker and then invalidate it
      (let* ((buf (generate-new-buffer "*dying-buffer*"))
             (marker (with-current-buffer buf
                       (insert "test")
                       (point-marker))))
        ;; Set it as the running marker
        (claude-org--session-put session-key :marker marker)
        ;; Kill the buffer to invalidate marker
        (kill-buffer buf)
        ;; Now try to queue - should not crash
        (let ((new-marker (point-marker))
              (result nil))
          (unwind-protect
              (progn
                (setq result (claude-org--queue-block
                              session-key
                              (list :marker new-marker
                                    :custom-id "test-id"
                                    :content "test")))
                ;; Should successfully queue (not crash)
                (should (eq result 'queued)))
            (claude-org--clear-queue session-key)))))))

(ert-deftest test-queue-dequeue-handles-invalid-marker ()
  "TDD: Dequeue should handle queued items with invalid markers."
  :tags '(:unit :fast :stable :isolated :marker :queue :tdd)
  (with-temp-buffer
    (org-mode)
    (let ((session-key "test-session"))
      ;; Queue a block with a marker that will become invalid
      (let* ((buf (generate-new-buffer "*dying-buffer*"))
             (marker (with-current-buffer buf
                       (insert "test")
                       (point-marker))))
        ;; Queue the block
        (claude-org--session-put session-key :pending-queue
                                  (list (list :marker marker
                                             :custom-id "test-id"
                                             :content "test")))
        ;; Kill buffer to invalidate marker
        (kill-buffer buf)
        ;; Dequeue should not crash
        (let ((block (claude-org--dequeue-block session-key)))
          ;; Block should be returned (even with invalid marker)
          ;; The caller decides what to do with it
          (should block)
          (should (equal (plist-get block :custom-id) "test-id")))))))

;;; Token Insertion with Invalid Markers

(ert-deftest test-handle-token-handles-killed-buffer ()
  "TDD: Token handling should handle killed marker buffer gracefully."
  :tags '(:unit :fast :stable :isolated :marker :streaming :tdd)
  :expected-result :failed
  (let ((session-key "test-session")
        (error-occurred nil))
    ;; Create marker in a buffer that will be killed
    (let* ((buf (generate-new-buffer "*dying-buffer*"))
           (marker (with-current-buffer buf
                     (org-mode)
                     (insert "* Test\n#+begin_src ai\ntest\n#+end_src\n")
                     (point-marker))))
      ;; Set session state
      (claude-org--session-put session-key :marker marker)
      ;; Kill the buffer
      (kill-buffer buf)
      ;; Try to handle a token - should not error
      (condition-case err
          (claude-org--handle-token session-key "test token")
        (error (setq error-occurred t)))
      ;; Should not have thrown an error
      (should-not error-occurred))))

;;; Concurrent Buffer Operations

(ert-deftest test-marker-survives-buffer-modification ()
  "TDD: Marker should remain valid through buffer modifications."
  :tags '(:unit :fast :stable :isolated :marker :tdd)
  (with-temp-buffer
    (org-mode)
    (insert "* Heading\n\nContent here\n")
    (let ((marker (point-marker)))
      ;; Modify buffer before marker
      (goto-char (point-min))
      (insert "New line\n")
      ;; Marker should still be valid
      (should (claude-org--marker-valid-p marker))
      ;; And should have adjusted position
      (should (> (marker-position marker) 10)))))

;;; Edge Cases

(ert-deftest test-marker-at-beginning-of-buffer ()
  "TDD: Marker at position 1 should be valid."
  :tags '(:unit :fast :stable :isolated :marker :tdd)
  (with-temp-buffer
    (insert "content")
    (let ((marker (copy-marker 1)))
      (should (claude-org--marker-valid-p marker)))))

(ert-deftest test-marker-at-end-of-buffer ()
  "TDD: Marker at end of buffer should be valid."
  :tags '(:unit :fast :stable :isolated :marker :tdd)
  (with-temp-buffer
    (insert "content")
    (let ((marker (point-max-marker)))
      (should (claude-org--marker-valid-p marker)))))

(ert-deftest test-set-exec-status-invalid-marker ()
  "TDD: set-exec-status should handle invalid marker gracefully."
  :tags '(:unit :fast :stable :isolated :marker :tdd)
  (let ((buf (generate-new-buffer "*dying-buffer*"))
        (error-occurred nil))
    (let ((marker (with-current-buffer buf
                    (org-mode)
                    (insert "* Test\n")
                    (point-marker))))
      ;; Kill the buffer
      (kill-buffer buf)
      ;; Try to set status - should not crash
      (condition-case err
          (claude-org--set-exec-status "executing" marker)
        (error (setq error-occurred t)))
      ;; Should not have crashed
      (should-not error-occurred))))

(provide 'test-claude-org-marker-lifecycle)
;;; test-claude-org-marker-lifecycle.el ends here
