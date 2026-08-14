;;; test-pi-topic.el --- Tests for the pi-topic org layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for lp/org/pi-topic.org — the pure org layer of pi-topics
;; (no Pi process, no pi-coding-agent).
;;
;; Every test runs against a REAL org buffer backed by a real temp file
;; (`make-temp-file' + `find-file-noselect'), never `with-temp-buffer':
;; the code under test reads `default-directory', walks the outline, and
;; writes property drawers, and all three behave differently in a buffer
;; with no file.

;;; Code:

(require 'ert)
(require 'org)
(require 'pi-topic)

(defvar test-pi-topic--todo-header
  "#+TODO: SOMEDAY TODO NEXT WAITING REVIEW | DONE CANCELLED\n\n"
  "File header opting a test buffer into the full pi-topics keyword set.")

(defvar test-pi-topic--topic
  "* Untitled topic
:PROPERTIES:
:PI_STATE: todo
:END:
** Goal
Compare pgvector and qdrant.
** Result
"
  "A hand-written topic, independent of what `pi-topic-new' produces.")

(defun test-pi-topic--run (content fn)
  "Call FN in a real org buffer visiting a temp file that holds CONTENT."
  (let* ((file (make-temp-file "pi-topic-test-" nil ".org" content))
         (buffer (find-file-noselect file)))
    (unwind-protect
        (with-current-buffer buffer
          (should (derived-mode-p 'org-mode))
          (funcall fn))
      (with-current-buffer buffer
        (set-buffer-modified-p nil))
      (kill-buffer buffer)
      (delete-file file))))

;;; Test 1: pi-topic-new builds the three sections and the drawer

(ert-deftest test-pi-topic-new-creates-skeleton ()
  "`pi-topic-new' inserts heading, Goal, Result and a PI_STATE drawer."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   ""
   (lambda ()
     (goto-char (point-max))
     (pi-topic-new)
     (let ((text (buffer-string)))
       (should (string-match-p "^\\* Untitled topic$" text))
       (should (string-match-p "^\\*\\* Goal$" text))
       (should (string-match-p "^\\*\\* Result$" text)))
     ;; Point is left on the Goal placeholder line.
     (should (equal pi-topic--goal-placeholder
                    (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
     ;; The drawer is on the topic heading, reachable from inside Goal.
     (should (pi-topic-p))
     (should (equal "todo" (pi-topic-state))))))

;;; Test 2: state round-trips through the PI_STATE property

(ert-deftest test-pi-topic-state-round-trips-through-property ()
  "`pi-topic-set-state' writes PI_STATE and `pi-topic-state' reads it back."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   test-pi-topic--topic
   (lambda ()
     (goto-char (point-min))
     (should (equal "todo" (pi-topic-state)))
     (pi-topic-set-state "waiting")
     (should (equal "waiting" (pi-topic-state)))
     (should (equal "waiting" (org-entry-get (point-min) "PI_STATE")))
     ;; A symbol is accepted and stored lower-case.
     (pi-topic-set-state 'REVIEW)
     (should (equal "review" (pi-topic-state))))))

;;; Test 3: the keyword mirror fires when the buffer defines the keyword

(ert-deftest test-pi-topic-state-mirrors-todo-keyword ()
  "State is mirrored onto the TODO keyword when the buffer defines it."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   (concat test-pi-topic--todo-header test-pi-topic--topic)
   (lambda ()
     (should (member "WAITING" org-todo-keywords-1))
     (goto-char (point-min))
     (re-search-forward "^\\* Untitled topic$")
     (beginning-of-line)
     (pi-topic-set-state "waiting")
     (should (equal "WAITING" (org-get-todo-state)))
     (should (equal "waiting" (pi-topic-state)))
     (pi-topic-set-state "review")
     (should (equal "REVIEW" (org-get-todo-state))))))

;;; Test 4: no keyword, no error — the property still wins

(ert-deftest test-pi-topic-state-without-matching-keyword ()
  "In a buffer lacking the keyword, state neither errors nor sets one."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   test-pi-topic--topic
   (lambda ()
     (should-not (member "WAITING" org-todo-keywords-1))
     (goto-char (point-min))
     (re-search-forward "^\\* Untitled topic$")
     (beginning-of-line)
     (pi-topic-set-state "waiting")
     (should (equal "waiting" (pi-topic-state)))
     (should-not (org-get-todo-state)))))

;;; Test 5: goal/result read back what pi-topic-new inserted

(ert-deftest test-pi-topic-goal-and-result-read-back ()
  "`pi-topic-goal' and `pi-topic-result' read the sections `new' created."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   ""
   (lambda ()
     (goto-char (point-max))
     (pi-topic-new)
     (should (equal pi-topic--goal-placeholder (pi-topic-goal)))
     ;; Result exists but is empty — distinct from a missing section.
     (should (equal "" (pi-topic-result)))
     ;; Edited Goal text is what comes back.
     (goto-char (point-max))
     (re-search-backward (regexp-quote pi-topic--goal-placeholder))
     (delete-region (line-beginning-position) (line-end-position))
     (insert "Compare pgvector and qdrant.")
     (should (equal "Compare pgvector and qdrant." (pi-topic-goal))))))

;;; Test 6: a plain heading is not a topic

(ert-deftest test-pi-topic-p-nil-on-plain-heading ()
  "`pi-topic-p' is nil on a heading without PI_STATE."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   "* Plain heading\nSome prose.\n"
   (lambda ()
     (goto-char (point-min))
     (should-not (pi-topic-p))
     (should-not (pi-topic-state))
     (should-not (pi-topic-goal))
     (goto-char (point-max))
     (should-not (pi-topic-p)))))

;;; Regression: creating a topic while inside one (live two-topic run)

(defun test-pi-topic--pi-states ()
  "Return the PI_STATE of every heading that carries one, in document order."
  (delq nil (org-map-entries (lambda () (org-entry-get nil "PI_STATE")))))

(ert-deftest test-pi-topic-new-inside-topic-keeps-parent-state ()
  "A second topic gets its own drawer; the first keeps the state it had.
`pi-topic-new' used to route the drawer through the climbing wrapper,
which stamped the enclosing topic instead of the new heading."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   ""
   (lambda ()
     (goto-char (point-max))
     (pi-topic-new)
     (goto-char (point-min))
     (pi-topic-set-state "waiting")
     ;; Point at end of buffer is inside the first topic's Result section.
     (goto-char (point-max))
     (pi-topic-new)
     (should (equal '("waiting" "todo") (test-pi-topic--pi-states))))))

(ert-deftest test-pi-topic-new-nested-topic-is-its-own-topic ()
  "A topic created inside another is a topic, with independent state."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   ""
   (lambda ()
     (goto-char (point-max))
     (let ((parent (copy-marker (pi-topic-new))))
       (goto-char (point-max))
       (let ((child (copy-marker (pi-topic-new))))
         (goto-char child)
         (should (pi-topic-p))
         (should (equal "todo" (pi-topic-state)))
         (pi-topic-set-state "review")
         ;; The parent did not move with it.
         (goto-char parent)
         (should (pi-topic-p))
         (should (equal "todo" (pi-topic-state)))
         (pi-topic-set-state "waiting")
         ;; Nor did the child move with the parent.
         (goto-char child)
         (should (equal "review" (pi-topic-state))))))))

(ert-deftest test-pi-topic-new-nested-goal-is-not-the-parent-goal ()
  "`pi-topic-goal' on a nested topic returns the child's own Goal."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   ""
   (lambda ()
     (goto-char (point-max))
     (let ((parent (copy-marker (pi-topic-new))))
       ;; `pi-topic-new' leaves point on the Goal placeholder.
       (delete-region (line-beginning-position) (line-end-position))
       (insert "Parent goal.")
       (goto-char (point-max))
       (let ((child (copy-marker (pi-topic-new))))
         (delete-region (line-beginning-position) (line-end-position))
         (insert "Child goal.")
         (goto-char child)
         (should (equal "Child goal." (pi-topic-goal)))
         (goto-char parent)
         (should (equal "Parent goal." (pi-topic-goal))))))))

(provide 'test-pi-topic)
;;; test-pi-topic.el ends here
