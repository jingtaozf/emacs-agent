;;; test-claude-org-window-start.el --- Tests for window-start preservation -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; TDD tests for window-start preservation during SDD section updates.
;; The spec says: save `window-start` before `save-excursion`, restore after
;; with `(set-window-start nil ws t)`.
;;
;; In batch mode, window-start doesn't change during org-link navigation,
;; so we simulate the interactive recentering by advising
;; `org-link-open-from-string` to change window-start as a side effect.

;;; Code:

(require 'ert)
(require 'org)
(require 'claude-org)

;;; Test Helpers

(defun test-ws--make-scrollable-buffer ()
  "Create a buffer with enough content to be scrollable.
Returns the buffer.  Buffer has a Spec section with CUSTOM_ID
after 100 lines of filler content."
  (let ((buf (generate-new-buffer "*test-ws*")))
    (with-current-buffer buf
      (org-mode)
      (insert "* Feature\n")
      ;; Lots of filler so window-start can be offset
      (dotimes (i 100)
        (insert (format "Line %d of filler content for scrolling.\n" i)))
      (insert "\n** Spec :spec:\n")
      (insert ":PROPERTIES:\n")
      (insert ":CUSTOM_ID: test-ws-spec-sdd-12345\n")
      (insert ":END:\n\n")
      (insert "*** Goals\n\n- Old Goal 1\n- Old Goal 2\n\n")
      (insert "*** Non-Goals\n\n- Non-goal 1\n"))
    buf))

;;; Unit Tests - Point Preservation

(ert-deftest test-ws-update-subsection-preserves-point ()
  "Test that claude-org-update-or-create-subsection preserves point."
  :tags '(:unit :fast :stable :isolated :org :sdd :window-start)
  (let ((buf (test-ws--make-scrollable-buffer)))
    (unwind-protect
        (with-current-buffer buf
          ;; Position point at a specific filler line
          (goto-char (point-min))
          (forward-line 50)
          (let ((original-point (point)))
            ;; Update a section
            (claude-org-update-or-create-subsection
             "test-ws-spec-sdd-12345"
             "Goals"
             "*** Goals\n\n- New Goal A\n- New Goal B")
            ;; Point should be unchanged
            (should (= original-point (point)))))
      (kill-buffer buf))))

(ert-deftest test-ws-update-subsection-preserves-point-at-beginning ()
  "Test point preservation when point is at buffer beginning."
  :tags '(:unit :fast :stable :isolated :org :sdd :window-start)
  (let ((buf (test-ws--make-scrollable-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (let ((original-point (point)))
            (claude-org-update-or-create-subsection
             "test-ws-spec-sdd-12345"
             "Goals"
             "*** Goals\n\n- Updated Goal")
            (should (= original-point (point)))))
      (kill-buffer buf))))

;;; Unit Tests - Window-Start Preservation (simulated recentering)
;;
;; In interactive Emacs, `org-link-open-from-string` can trigger recentering
;; which changes window-start.  In batch mode this doesn't happen, so we
;; simulate it by wrapping the function to set window-start to point after
;; navigation.

(ert-deftest test-ws-update-restores-window-start-after-navigation ()
  "Test window-start is restored even when internal navigation changes it.
Simulates interactive recentering that occurs during org-link navigation."
  :tags '(:unit :fast :stable :isolated :org :sdd :window-start)
  (let ((buf (test-ws--make-scrollable-buffer)))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            ;; Scroll to middle of filler content
            (goto-char (point-min))
            (forward-line 50)
            (set-window-start (selected-window) (point))
            (let ((original-ws (window-start (selected-window)))
                  (original-fn (symbol-function 'org-link-open-from-string)))
              (should (> original-ws 1))
              ;; Wrap org-link-open-from-string to simulate recentering
              (cl-letf (((symbol-function 'org-link-open-from-string)
                         (lambda (link &rest args)
                           (apply original-fn link args)
                           ;; Simulate the recentering side effect
                           (set-window-start (selected-window) (point)))))
                (claude-org-update-or-create-subsection
                 "test-ws-spec-sdd-12345"
                 "Goals"
                 "*** Goals\n\n- New Goal A\n- New Goal B")
                ;; Window-start should be restored despite navigation
                (should (= original-ws (window-start (selected-window))))))))
      (kill-buffer buf))))

(ert-deftest test-ws-update-restores-window-start-on-create ()
  "Test window-start restored when creating new subsection with simulated recentering."
  :tags '(:unit :fast :stable :isolated :org :sdd :window-start)
  (let ((buf (test-ws--make-scrollable-buffer)))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (goto-char (point-min))
            (forward-line 30)
            (set-window-start (selected-window) (point))
            (let ((original-ws (window-start (selected-window)))
                  (original-fn (symbol-function 'org-link-open-from-string)))
              (should (> original-ws 1))
              (cl-letf (((symbol-function 'org-link-open-from-string)
                         (lambda (link &rest args)
                           (apply original-fn link args)
                           (set-window-start (selected-window) (point)))))
                (claude-org-update-or-create-subsection
                 "test-ws-spec-sdd-12345"
                 "Technical Design"
                 "*** Technical Design\n\n- Design element 1")
                (should (= original-ws (window-start (selected-window))))))))
      (kill-buffer buf))))

(ert-deftest test-ws-update-restores-window-start-on-error ()
  "Test window-start restored even when update fails (invalid ID)."
  :tags '(:unit :fast :stable :isolated :org :sdd :window-start)
  (let ((buf (test-ws--make-scrollable-buffer)))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (goto-char (point-min))
            (forward-line 40)
            (set-window-start (selected-window) (point))
            (let ((original-ws (window-start (selected-window)))
                  (original-fn (symbol-function 'org-link-open-from-string)))
              (should (> original-ws 1))
              ;; Even with simulated recentering, error path should restore
              (cl-letf (((symbol-function 'org-link-open-from-string)
                         (lambda (link &rest args)
                           ;; This will error for nonexistent IDs, which
                           ;; changes window-start before the error
                           (set-window-start (selected-window) 1)
                           (apply original-fn link args))))
                (claude-org-update-or-create-subsection
                 "nonexistent-id-12345"
                 "Goals"
                 "*** Goals\n\n- Goal 1")
                (should (= original-ws (window-start (selected-window))))))))
      (kill-buffer buf))))

(ert-deftest test-ws-multiple-updates-restore-window-start ()
  "Test window-start preserved across multiple updates with simulated recentering."
  :tags '(:unit :fast :stable :isolated :org :sdd :window-start)
  (let ((buf (test-ws--make-scrollable-buffer)))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (goto-char (point-min))
            (forward-line 60)
            (set-window-start (selected-window) (point))
            (let ((original-ws (window-start (selected-window)))
                  (original-fn (symbol-function 'org-link-open-from-string)))
              (should (> original-ws 1))
              (cl-letf (((symbol-function 'org-link-open-from-string)
                         (lambda (link &rest args)
                           (apply original-fn link args)
                           (set-window-start (selected-window) (point)))))
                (claude-org-update-or-create-subsection
                 "test-ws-spec-sdd-12345"
                 "Goals"
                 "*** Goals\n\n- Updated Goal 1")
                (claude-org-update-or-create-subsection
                 "test-ws-spec-sdd-12345"
                 "Non-Goals"
                 "*** Non-Goals\n\n- Updated Non-goal 1")
                (claude-org-update-or-create-subsection
                 "test-ws-spec-sdd-12345"
                 "Technical Design"
                 "*** Technical Design\n\n- New Design")
                (should (= original-ws (window-start (selected-window))))))))
      (kill-buffer buf))))

;;; Unit Tests - Content Correctness (no regression)

(ert-deftest test-ws-update-content-correct-after-preserve ()
  "Test that content is correctly updated even with window-start preservation."
  :tags '(:unit :fast :stable :isolated :org :sdd :window-start)
  (let ((buf (test-ws--make-scrollable-buffer)))
    (unwind-protect
        (with-current-buffer buf
          ;; Update Goals
          (claude-org-update-or-create-subsection
           "test-ws-spec-sdd-12345"
           "Goals"
           "*** Goals\n\n- Brand New Goal\n- Another Goal")
          ;; Verify content was actually updated
          (goto-char (point-min))
          (should (re-search-forward "Brand New Goal" nil t))
          (goto-char (point-min))
          (should (re-search-forward "Another Goal" nil t))
          ;; Old content should be gone
          (goto-char (point-min))
          (should-not (re-search-forward "Old Goal" nil t))
          ;; Siblings should be intact
          (goto-char (point-min))
          (should (re-search-forward "Non-goal 1" nil t)))
      (kill-buffer buf))))

(provide 'test-claude-org-window-start)
;;; test-claude-org-window-start.el ends here
