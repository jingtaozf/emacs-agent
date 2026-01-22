;;; test-claude-org-scheduled.el --- Tests for scheduled AI block execution -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for scheduled AI block execution in claude-org.
;; Tests use with-temp-buffer with real org content, NO API calls.

;;; Code:

(require 'ert)
(require 'org)
(require 'claude-org)

;;; Test Helpers

(defmacro test-scheduled-with-org-buffer (content &rest body)
  "Execute BODY in a temp buffer with org CONTENT."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,content)
     (goto-char (point-min))
     ,@body))

;;; Execution Decision Logic Tests

(ert-deftest test-scheduled-should-execute-never-run ()
  "Should execute when LAST_AI_EXECUTED is nil (never executed)."
  :tags '(:unit :fast :stable :isolated :scheduled)
  ;; Scheduled time in the past, never executed
  (let ((scheduled-time (time-subtract (current-time) (seconds-to-time 3600))))
    (should (claude-org-scheduled--should-execute-p scheduled-time nil))
    (should (claude-org-scheduled--should-execute-p scheduled-time ""))))

(ert-deftest test-scheduled-should-execute-already-done ()
  "Should NOT execute when already executed after scheduled time."
  :tags '(:unit :fast :stable :isolated :scheduled)
  ;; Scheduled 1 hour ago, executed 30 minutes ago
  (let* ((scheduled-time (time-subtract (current-time) (seconds-to-time 3600)))
         (last-executed-str (format-time-string "%Y-%m-%d %H:%M:%S"
                                                (time-subtract (current-time)
                                                               (seconds-to-time 1800)))))
    (should-not (claude-org-scheduled--should-execute-p scheduled-time last-executed-str))))

(ert-deftest test-scheduled-should-execute-new-schedule ()
  "Should execute when scheduled time is after last execution."
  :tags '(:unit :fast :stable :isolated :scheduled)
  ;; Executed 2 hours ago, scheduled 1 hour ago (new schedule)
  (let* ((scheduled-time (time-subtract (current-time) (seconds-to-time 3600)))
         (last-executed-str (format-time-string "%Y-%m-%d %H:%M:%S"
                                                (time-subtract (current-time)
                                                               (seconds-to-time 7200)))))
    (should (claude-org-scheduled--should-execute-p scheduled-time last-executed-str))))

(ert-deftest test-scheduled-should-execute-future-schedule ()
  "Should NOT execute when scheduled time is in the future."
  :tags '(:unit :fast :stable :isolated :scheduled)
  ;; Scheduled 1 hour in the future
  (let ((scheduled-time (time-add (current-time) (seconds-to-time 3600))))
    (should-not (claude-org-scheduled--should-execute-p scheduled-time nil))))

;;; Alist Management Tests

(ert-deftest test-scheduled-update-entry-new ()
  "Should add new entry to empty alist."
  :tags '(:unit :fast :stable :isolated :scheduled)
  (let ((claude-org--scheduled-blocks nil)
        (test-time (current-time)))
    (claude-org-scheduled--update-entry "test-id" "/path/to/file.org" test-time)
    (should (= 1 (length claude-org--scheduled-blocks)))
    (should (equal "test-id" (caar claude-org--scheduled-blocks)))
    (should (equal "/path/to/file.org"
                   (plist-get (cdar claude-org--scheduled-blocks) :file)))))

(ert-deftest test-scheduled-update-entry-existing ()
  "Should update existing entry, not add duplicate."
  :tags '(:unit :fast :stable :isolated :scheduled)
  (let* ((old-time (time-subtract (current-time) (seconds-to-time 3600)))
         (new-time (current-time))
         (claude-org--scheduled-blocks
          (list (cons "test-id" (list :file "/old/path.org" :scheduled-time old-time)))))
    (claude-org-scheduled--update-entry "test-id" "/new/path.org" new-time)
    (should (= 1 (length claude-org--scheduled-blocks)))
    (should (equal "/new/path.org"
                   (plist-get (cdar claude-org--scheduled-blocks) :file)))))

(ert-deftest test-scheduled-remove-entry ()
  "Should remove entry from alist."
  :tags '(:unit :fast :stable :isolated :scheduled)
  (let ((claude-org--scheduled-blocks
         (list (cons "id1" (list :file "/path1.org"))
               (cons "id2" (list :file "/path2.org")))))
    (claude-org-scheduled--remove-entry "id1")
    (should (= 1 (length claude-org--scheduled-blocks)))
    (should (equal "id2" (caar claude-org--scheduled-blocks)))))

;;; AI Block Detection Tests

(ert-deftest test-scheduled-has-ai-block-in-subtree ()
  "Should detect AI block within heading subtree."
  :tags '(:unit :fast :stable :isolated :scheduled)
  (test-scheduled-with-org-buffer
   "* Task
SCHEDULED: <2025-01-13 Mon 08:00>
:PROPERTIES:
:CUSTOM_ID: test-task
:END:

#+begin_src ai
Test query
#+end_src
"
   (re-search-forward "^\\* Task")
   (should (claude-org-scheduled--has-ai-block-p))))

(ert-deftest test-scheduled-has-ai-block-not-in-subtree ()
  "Should NOT detect AI block outside heading subtree."
  :tags '(:unit :fast :stable :isolated :scheduled)
  (test-scheduled-with-org-buffer
   "* Task 1
SCHEDULED: <2025-01-13 Mon 08:00>
:PROPERTIES:
:CUSTOM_ID: task1
:END:

No AI block here.

* Task 2

#+begin_src ai
Test query
#+end_src
"
   (re-search-forward "^\\* Task 1")
   (should-not (claude-org-scheduled--has-ai-block-p))))

;;; File Scanning Tests

(ert-deftest test-scheduled-collect-from-file ()
  "Should collect scheduled AI blocks from file."
  :tags '(:unit :fast :stable :isolated :scheduled)
  (let ((temp-file (make-temp-file "test-scheduled" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "* Daily Task
SCHEDULED: <2025-01-13 Mon 08:00>
:PROPERTIES:
:CUSTOM_ID: daily-task
:END:

#+begin_src ai
Test query
#+end_src

* No Schedule Task
:PROPERTIES:
:CUSTOM_ID: no-schedule
:END:

#+begin_src ai
Another query
#+end_src

* No AI Block
SCHEDULED: <2025-01-13 Mon 09:00>
:PROPERTIES:
:CUSTOM_ID: no-ai-block
:END:

Just text.
"))
          (let ((results (claude-org-scheduled--collect-from-file temp-file)))
            ;; Should only find the one with SCHEDULED + CUSTOM_ID + ai block
            (should (= 1 (length results)))
            (should (equal "daily-task" (caar results)))
            (should (equal temp-file (plist-get (cdar results) :file)))))
      (delete-file temp-file))))

;;; Repeater Tests

(ert-deftest test-scheduled-advance-repeater-daily ()
  "Should advance +1d repeater by one day."
  :tags '(:unit :fast :stable :isolated :scheduled :repeater)
  (test-scheduled-with-org-buffer
   "* Daily Task
SCHEDULED: <2026-01-15 Thu 08:00 +1d>
:PROPERTIES:
:CUSTOM_ID: daily-task
:END:

#+begin_src ai
Test query
#+end_src
"
   (re-search-forward "^\\* Daily Task")
   (let ((before (org-entry-get nil "SCHEDULED")))
     (should (string-match-p "2026-01-15" before))
     (should (string-match-p "\\+1d" before))
     ;; Advance the repeater
     (let ((new-time (claude-org-scheduled--advance-repeater)))
       (should new-time)
       (let ((after (org-entry-get nil "SCHEDULED")))
         (should (string-match-p "2026-01-16" after))
         (should (string-match-p "\\+1d" after)))))))

(ert-deftest test-scheduled-advance-repeater-weekly ()
  "Should advance +1w repeater by one week."
  :tags '(:unit :fast :stable :isolated :scheduled :repeater)
  (test-scheduled-with-org-buffer
   "* Weekly Task
SCHEDULED: <2026-01-15 Thu 08:00 +1w>
:PROPERTIES:
:CUSTOM_ID: weekly-task
:END:

#+begin_src ai
Test query
#+end_src
"
   (re-search-forward "^\\* Weekly Task")
   (let ((before (org-entry-get nil "SCHEDULED")))
     (should (string-match-p "2026-01-15" before))
     ;; Advance the repeater
     (let ((new-time (claude-org-scheduled--advance-repeater)))
       (should new-time)
       (let ((after (org-entry-get nil "SCHEDULED")))
         (should (string-match-p "2026-01-22" after))
         (should (string-match-p "\\+1w" after)))))))

(ert-deftest test-scheduled-advance-repeater-none ()
  "Should return nil when no repeater present."
  :tags '(:unit :fast :stable :isolated :scheduled :repeater)
  (test-scheduled-with-org-buffer
   "* One-time Task
SCHEDULED: <2026-01-15 Thu 08:00>
:PROPERTIES:
:CUSTOM_ID: onetime-task
:END:

#+begin_src ai
Test query
#+end_src
"
   (re-search-forward "^\\* One-time Task")
   (should-not (claude-org-scheduled--advance-repeater))
   ;; Timestamp should be unchanged
   (let ((after (org-entry-get nil "SCHEDULED")))
     (should (string-match-p "2026-01-15" after)))))

(ert-deftest test-scheduled-advance-repeater-catch-up ()
  "Should handle .+1d catch-up repeater."
  :tags '(:unit :fast :stable :isolated :scheduled :repeater)
  (test-scheduled-with-org-buffer
   "* Catch-up Task
SCHEDULED: <2026-01-15 Thu 08:00 .+1d>
:PROPERTIES:
:CUSTOM_ID: catchup-task
:END:

#+begin_src ai
Test query
#+end_src
"
   (re-search-forward "^\\* Catch-up Task")
   (let ((new-time (claude-org-scheduled--advance-repeater)))
     (should new-time)
     (let ((after (org-entry-get nil "SCHEDULED")))
       (should (string-match-p "2026-01-16" after))
       (should (string-match-p "\\.\\+1d" after))))))

;;; Mode-Line Indicator Tests

(ert-deftest test-scheduled-mode-line-update-with-blocks ()
  "Mode-line should show count when scheduler has blocks."
  :tags '(:unit :fast :stable :isolated :scheduled :mode-line)
  (let ((claude-org--scheduled-timer (current-time))  ; Fake active timer
        (claude-org--scheduled-blocks
         (list (cons "id1" (list :file "/path1.org" :scheduled-time (current-time)))
               (cons "id2" (list :file "/path2.org" :scheduled-time (current-time)))))
        (claude-org-scheduled-string ""))
    (claude-org-scheduled--update-mode-line)
    (should (string-match-p "\\[S:2\\]" claude-org-scheduled-string))
    (should (get-text-property 0 'help-echo claude-org-scheduled-string))
    (should (get-text-property 0 'local-map claude-org-scheduled-string))))

(ert-deftest test-scheduled-mode-line-update-empty ()
  "Mode-line should be empty when no scheduled blocks."
  :tags '(:unit :fast :stable :isolated :scheduled :mode-line)
  (let ((claude-org--scheduled-timer (current-time))  ; Fake active timer
        (claude-org--scheduled-blocks nil)
        (claude-org-scheduled-string "previous value"))
    (claude-org-scheduled--update-mode-line)
    (should (string-empty-p claude-org-scheduled-string))))

(ert-deftest test-scheduled-mode-line-update-no-timer ()
  "Mode-line should be empty when scheduler not running."
  :tags '(:unit :fast :stable :isolated :scheduled :mode-line)
  (let ((claude-org--scheduled-timer nil)  ; No active timer
        (claude-org--scheduled-blocks
         (list (cons "id1" (list :file "/path1.org"))))
        (claude-org-scheduled-string "previous value"))
    (claude-org-scheduled--update-mode-line)
    (should (string-empty-p claude-org-scheduled-string))))

;;; List Buffer Tests

(ert-deftest test-scheduled-build-list-entries ()
  "Should build tabulated list entries from scheduled blocks."
  :tags '(:unit :fast :stable :isolated :scheduled :list-buffer)
  (let* ((test-time (time-subtract (current-time) (seconds-to-time 3600)))
         (claude-org--scheduled-blocks
          (list (cons "test-block"
                      (list :file "/nonexistent/test.org"
                            :scheduled-time test-time)))))
    (let ((entries (claude-org-scheduled--build-list-entries)))
      (should (= 1 (length entries)))
      (let ((entry (car entries)))
        ;; Entry format: (ID [COL1 COL2 COL3 COL4])
        (should (equal "test-block" (car entry)))
        (let ((cols (cadr entry)))
          (should (= 4 (length cols)))
          ;; First column is ID (propertized)
          (should (string-match-p "test-block" (aref cols 0)))
          ;; Second column is file basename
          (should (equal "test.org" (aref cols 1))))))))

(ert-deftest test-scheduled-format-time ()
  "Should format time correctly."
  :tags '(:unit :fast :stable :isolated :scheduled :list-buffer)
  ;; nil returns "Never"
  (should (equal "Never" (claude-org-scheduled--format-time nil)))
  ;; Non-nil returns formatted time
  (let ((result (claude-org-scheduled--format-time (current-time))))
    (should (string-match-p "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" result))))

(ert-deftest test-scheduled-list-buffer-created ()
  "List command should create buffer with correct mode."
  :tags '(:unit :fast :stable :isolated :scheduled :list-buffer)
  (let ((claude-org--scheduled-blocks nil)
        (claude-org--scheduled-timer (current-time)))
    (unwind-protect
        (progn
          (claude-org-scheduled-list)
          (should (get-buffer "*Claude Scheduled Blocks*"))
          (with-current-buffer "*Claude Scheduled Blocks*"
            (should (eq major-mode 'claude-org-scheduled-list-mode))
            (should (equal tabulated-list-sort-key '("Next Run" . nil)))))
      (when (get-buffer "*Claude Scheduled Blocks*")
        (kill-buffer "*Claude Scheduled Blocks*")))))

(ert-deftest test-scheduled-list-columns ()
  "List buffer should have correct columns."
  :tags '(:unit :fast :stable :isolated :scheduled :list-buffer)
  (let ((claude-org--scheduled-blocks nil))
    (unwind-protect
        (progn
          (claude-org-scheduled-list)
          (with-current-buffer "*Claude Scheduled Blocks*"
            ;; Check column format: [("name" width sortable) ...]
            ;; tabulated-list-format is a vector of lists like ("ID" 25 t)
            (should (= 4 (length tabulated-list-format)))
            (should (equal "ID" (car (aref tabulated-list-format 0))))
            (should (equal "File" (car (aref tabulated-list-format 1))))
            (should (equal "Last Run" (car (aref tabulated-list-format 2))))
            (should (equal "Next Run" (car (aref tabulated-list-format 3))))))
      (when (get-buffer "*Claude Scheduled Blocks*")
        (kill-buffer "*Claude Scheduled Blocks*")))))

;;; Navigation Tests

(ert-deftest test-scheduled-goto-block ()
  "Should navigate to AI block in file."
  :tags '(:unit :fast :stable :isolated :scheduled :navigation)
  (let ((temp-file (make-temp-file "test-nav" nil ".org")))
    (unwind-protect
        (progn
          ;; Create test file
          (with-temp-file temp-file
            (insert "* Before

* Target Task
:PROPERTIES:
:CUSTOM_ID: target-block
:END:

#+begin_src ai
Test query
#+end_src

* After
"))
          ;; Setup scheduled blocks
          (let ((claude-org--scheduled-blocks
                 (list (cons "target-block"
                             (list :file temp-file
                                   :scheduled-time (current-time))))))
            ;; Navigate
            (claude-org-scheduled--goto-block "target-block")
            ;; Verify we're at the right place
            (should (equal temp-file (buffer-file-name)))
            (should (string-match-p "Target Task"
                                    (buffer-substring (line-beginning-position)
                                                      (line-end-position))))))
      (when (get-file-buffer temp-file)
        (kill-buffer (get-file-buffer temp-file)))
      (delete-file temp-file))))

;;; Integration Tests (Start/Stop)

(ert-deftest test-scheduled-start-adds-mode-line ()
  "Starting scheduler should add mode-line indicator."
  :tags '(:unit :fast :stable :isolated :scheduled :integration)
  (let ((claude-org--scheduled-timer nil)
        (claude-org--scheduled-blocks nil)
        (claude-org-scheduled-string "")
        (claude-org-scheduled-files nil)
        (mode-line-misc-info nil))
    (unwind-protect
        (progn
          ;; Mock org-agenda-files to return empty list
          (cl-letf (((symbol-function 'org-agenda-files) (lambda (&rest _) nil)))
            (claude-org-scheduled-start)
            ;; Timer should be set
            (should claude-org--scheduled-timer)
            ;; Mode-line should be in misc-info
            (should (member '(:eval claude-org-scheduled-string) mode-line-misc-info))))
      ;; Cleanup
      (when (timerp claude-org--scheduled-timer)
        (cancel-timer claude-org--scheduled-timer)
        (setq claude-org--scheduled-timer nil)))))

(ert-deftest test-scheduled-stop-removes-mode-line ()
  "Stopping scheduler should remove mode-line indicator."
  :tags '(:unit :fast :stable :isolated :scheduled :integration)
  (let ((claude-org--scheduled-timer (run-at-time nil nil #'ignore))
        (claude-org-scheduled-string " [S:3]")
        (mode-line-misc-info (list '(:eval claude-org-scheduled-string) 'other)))
    (claude-org-scheduled-stop)
    ;; Timer should be nil
    (should-not claude-org--scheduled-timer)
    ;; Mode-line string should be empty
    (should (string-empty-p claude-org-scheduled-string))
    ;; Should be removed from misc-info
    (should-not (member '(:eval claude-org-scheduled-string) mode-line-misc-info))))

(provide 'test-claude-org-scheduled)
;;; test-claude-org-scheduled.el ends here
