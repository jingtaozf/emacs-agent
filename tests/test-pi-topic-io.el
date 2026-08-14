;;; test-pi-topic-io.el --- Tests for the pi-topic write-back path -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for lp/org/pi-topic-io.org — addressing a topic by its
;; PI_TOPIC_ID and writing a section body back into it.
;;
;; Real temp .org files throughout: the module distinguishes a buffer it
;; opened itself from one the user already had, and that distinction only
;; exists for file-backed buffers.

;;; Code:

(require 'ert)
(require 'org)
(require 'pi-topic)
(require 'pi-topic-io)

(defvar test-pi-topic-io--two-topics
  "* First topic
:PROPERTIES:
:PI_STATE: waiting
:PI_TOPIC_ID: pi-1000-aaaa
:END:
** Goal
Compare pgvector and qdrant.
** Result
Nothing yet.
* Second topic
:PROPERTIES:
:PI_STATE: todo
:PI_TOPIC_ID: pi-1000-bbbb
:END:
** Goal
Untouched goal.
** Result
Untouched result.
"
  "Two sibling topics, each with its own id, Goal and Result.")

(defun test-pi-topic-io--cleanup (file)
  "Kill any buffer visiting FILE, then delete it."
  (let ((buffer (find-buffer-visiting file)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (set-buffer-modified-p nil))
      (kill-buffer buffer)))
  (when (file-exists-p file)
    (delete-file file)))

(defun test-pi-topic-io--with-file (content fn)
  "Call FN with a temp org file holding CONTENT, reachable by topic id.
`pi-topic--find-by-id' only opens files the workflow layer lists, so the
fixture registers the temp file as both the capture file and the agenda."
  (let* ((file (make-temp-file "pi-topic-io-" nil ".org" content))
         (pi-topic-file file)
         (org-agenda-files (list file)))
    (unwind-protect
        (funcall fn file)
      (test-pi-topic-io--cleanup file))))

(defun test-pi-topic-io--file-contents (file)
  "Return the current on-disk text of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun test-pi-topic-io--section (file id name)
  "Return topic ID's NAME section text as it stands in FILE's buffer."
  (with-current-buffer (find-file-noselect file)
    (org-with-wide-buffer
     (goto-char (marker-position (pi-topic--find-by-id id)))
     (pi-topic--section-text name))))

;;; Test 1: a write replaces one body and nothing else

(ert-deftest test-pi-topic-io-write-result-touches-only-that-section ()
  "Writing Result leaves Goal, the drawer and the sibling topic alone."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-file
   test-pi-topic-io--two-topics
   (lambda (file)
     (should (equal t (pi-topic-write-result "pi-1000-aaaa"
                                             "Recommendation: pgvector.")))
     (should (equal "Recommendation: pgvector."
                    (test-pi-topic-io--section file "pi-1000-aaaa" "Result")))
     (should (equal "Compare pgvector and qdrant."
                    (test-pi-topic-io--section file "pi-1000-aaaa" "Goal")))
     ;; The drawer survived intact.
     (with-current-buffer (find-file-noselect file)
       (goto-char (marker-position (pi-topic--find-by-id "pi-1000-aaaa")))
       (should (equal "waiting" (pi-topic-state)))
       (should (equal "pi-1000-aaaa" (pi-topic--property "PI_TOPIC_ID"))))
     ;; The sibling topic is untouched.
     (should (equal "Untouched result."
                    (test-pi-topic-io--section file "pi-1000-bbbb" "Result")))
     (should (equal "Untouched goal."
                    (test-pi-topic-io--section file "pi-1000-bbbb" "Goal")))
     ;; The write opened the file itself, so it was saved.
     (should (string-match-p "Recommendation: pgvector\\."
                             (test-pi-topic-io--file-contents file))))))

;;; Test 2: an unknown id is a nil, not a signal

(ert-deftest test-pi-topic-io-unknown-id-returns-nil ()
  "Writing to an id nobody owns answers nil and changes nothing."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-file
   test-pi-topic-io--two-topics
   (lambda (file)
     (let ((before (test-pi-topic-io--file-contents file)))
       (should-not (pi-topic--find-by-id "pi-9999-zzzz"))
       (should-not (pi-topic-write-result "pi-9999-zzzz" "nowhere"))
       (should-not (pi-topic-write-goal nil "nowhere"))
       (should-not (pi-topic-write-result "" "nowhere"))
       (should (equal before (test-pi-topic-io--file-contents file)))))))

;;; Test 3: a missing section is created at the child level

(ert-deftest test-pi-topic-io-creates-missing-section-at-child-level ()
  "A topic with no Result gets one, one level below its own heading."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-file
   (concat "* Project\n"
           "** Nested topic\n"
           ":PROPERTIES:\n:PI_STATE: waiting\n"
           ":PI_TOPIC_ID: pi-2000-cccc\n:END:\n"
           "*** Goal\nDo the nested thing.\n")
   (lambda (file)
     (should (pi-topic-write-result "pi-2000-cccc" "Nested answer."))
     ;; The topic sits at level 2, so Result must be a level-3 heading.
     (should (string-match-p "^\\*\\*\\* Result$"
                             (test-pi-topic-io--file-contents file)))
     (should (equal "Nested answer."
                    (test-pi-topic-io--section file "pi-2000-cccc" "Result")))
     ;; Goal is still there and still readable at its own level.
     (should (equal "Do the nested thing."
                    (test-pi-topic-io--section file "pi-2000-cccc" "Goal"))))))

;;; Test 4: a live buffer beats the copy on disk

(ert-deftest test-pi-topic-io-prefers-live-buffer-over-disk ()
  "The write lands in the user's unsaved buffer and does not save it."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-file
   test-pi-topic-io--two-topics
   (lambda (file)
     (let ((buffer (find-file-noselect file)))
       ;; The user edits the topic and has not saved.
       (with-current-buffer buffer
         (goto-char (point-min))
         (should (re-search-forward "^Nothing yet\\.$" nil t))
         (replace-match "Edited in the buffer.")
         (should (buffer-modified-p)))
       (should (pi-topic-write-result "pi-1000-aaaa" "Written by the agent."))
       ;; The buffer got the write…
       (should (equal "Written by the agent."
                      (test-pi-topic-io--section file "pi-1000-aaaa" "Result")))
       ;; …and stayed unsaved, so the disk still holds the original.
       (should (buffer-modified-p buffer))
       (let ((on-disk (test-pi-topic-io--file-contents file)))
         (should (string-match-p "Nothing yet\\." on-disk))
         (should-not (string-match-p "Written by the agent\\." on-disk)))))))

;;; Test 5: the environment carries the id

(ert-deftest test-pi-topic-io-env-carries-topic-id ()
  "`pi-topic-io-env' returns PI_TOPIC_ID and PI_TOPIC_FILE entries."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-file
   test-pi-topic-io--two-topics
   (lambda (file)
     ;; Open it so the id resolves to a live buffer with a file name.
     (find-file-noselect file)
     (let ((env (pi-topic-io-env "pi-1000-aaaa")))
       (should (member "PI_TOPIC_ID=pi-1000-aaaa" env))
       (should (member (format "PI_TOPIC_FILE=%s" file) env))
       ;; Prepending it is what a spawning caller does.
       (let ((process-environment (append env process-environment)))
         (should (equal "pi-1000-aaaa" (getenv "PI_TOPIC_ID")))))
     ;; An unknown id still yields a usable, file-less pair.
     (should (member "PI_TOPIC_FILE=" (pi-topic-io-env "pi-9999-zzzz"))))))

(provide 'test-pi-topic-io)
;;; test-pi-topic-io.el ends here
