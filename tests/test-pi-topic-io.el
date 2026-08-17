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
The fixture registers the temp file as both the capture file and the
agenda, so the file-set heuristics can reach it, and starts from an
empty location registry."
  (let* ((file (make-temp-file "pi-topic-io-" nil ".org" content))
         (pi-topic-file file)
         (org-agenda-files (list file)))
    (clrhash pi-topic--id-locations)
    (unwind-protect
        (funcall fn file)
      (clrhash pi-topic--id-locations)
      (test-pi-topic-io--cleanup file))))

(defun test-pi-topic-io--with-unlisted-file (content fn)
  "Call FN with a temp org file that no file-set heuristic can reach.
It is neither the capture file nor an agenda file — the situation a
user creates simply by writing a topic in an org file of their own."
  (let* ((file (make-temp-file "pi-topic-io-unlisted-" nil ".org" content))
         (capture (make-temp-file "pi-topic-io-capture-" nil ".org" ""))
         (pi-topic-file capture)
         (org-agenda-files nil))
    (clrhash pi-topic--id-locations)
    (unwind-protect
        (funcall fn file)
      (clrhash pi-topic--id-locations)
      (test-pi-topic-io--cleanup file)
      (test-pi-topic-io--cleanup capture))))

(defun test-pi-topic-io--engage (file id)
  "Do what session creation does: visit FILE and ask for ID's environment.
Returns the buffer now visiting FILE."
  (let ((buffer (find-file-noselect file)))
    (pi-topic-io-env id)
    buffer))

(defun test-pi-topic-io--kill (buffer)
  "Kill BUFFER the way a user closing a file would."
  (with-current-buffer buffer
    (set-buffer-modified-p nil))
  (kill-buffer buffer))

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

;;; Regression: a topic must stay reachable after its buffer is gone

(ert-deftest test-pi-topic-io-reaches-topic-after-buffer-killed ()
  "The registry keeps a topic writable once its buffer has been killed."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-file
   test-pi-topic-io--two-topics
   (lambda (file)
     (test-pi-topic-io--kill (test-pi-topic-io--engage file "pi-1000-aaaa"))
     (should-not (find-buffer-visiting file))
     ;; The registry answers on its own, before any file-set scan.
     (should (pi-topic--find-in-registry "pi-1000-aaaa"))
     (should (pi-topic-write-result "pi-1000-aaaa" "Answered after the kill."))
     ;; Asserted in the buffer, not on disk: the probe above re-opened the
     ;; file, so the write found it already open and — correctly — left
     ;; saving to whoever opened it.
     (should (equal "Answered after the kill."
                    (test-pi-topic-io--section file "pi-1000-aaaa" "Result"))))))

(ert-deftest test-pi-topic-io-reaches-topic-in-unlisted-file ()
  "A topic in nobody's agenda is still reachable once it has been engaged.
This is the live-run defect: the file-set heuristics cannot know about
an org file the user never listed anywhere."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-unlisted-file
   test-pi-topic-io--two-topics
   (lambda (file)
     (test-pi-topic-io--kill (test-pi-topic-io--engage file "pi-1000-aaaa"))
     ;; Neither heuristic can see this file…
     (should-not (member file (pi-topic--topic-files)))
     (should-not (pi-topic--find-in-files "pi-1000-aaaa"))
     (should-not (pi-topic--find-in-buffers "pi-1000-aaaa"))
     ;; …and the write lands anyway.
     (should (pi-topic-write-result "pi-1000-aaaa" "Reached the unlisted file."))
     (should (string-match-p "Reached the unlisted file\\."
                             (test-pi-topic-io--file-contents file)))
     ;; The registry claims nothing it has not seen: the sibling topic in
     ;; the same file was never engaged and has no entry.  (It is findable
     ;; now only because the write re-opened the file.)
     (should-not (gethash "pi-1000-bbbb" pi-topic--id-locations)))))

(ert-deftest test-pi-topic-io-stale-entry-returns-nil ()
  "A registry entry whose buffer and file are both gone answers nil."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-unlisted-file
   test-pi-topic-io--two-topics
   (lambda (file)
     (test-pi-topic-io--kill (test-pi-topic-io--engage file "pi-1000-aaaa"))
     (delete-file file)
     (should-not (pi-topic--find-by-id "pi-1000-aaaa"))
     (should-not (pi-topic-write-result "pi-1000-aaaa" "nowhere"))
     (should (equal 1 (hash-table-count pi-topic--id-locations)))
     ;; Recording any other topic sweeps the unusable entry out, so the
     ;; table cannot grow forever across a long session.
     (let ((other (make-temp-file
                   "pi-topic-io-other-" nil ".org"
                   (concat "* Other\n:PROPERTIES:\n:PI_STATE: todo\n"
                           ":PI_TOPIC_ID: pi-3000-dddd\n:END:\n"
                           "** Goal\ng\n** Result\n"))))
       (unwind-protect
           (progn
             (test-pi-topic-io--engage other "pi-3000-dddd")
             (should-not (gethash "pi-1000-aaaa" pi-topic--id-locations))
             (should (equal 1 (hash-table-count pi-topic--id-locations))))
         (test-pi-topic-io--cleanup other)))
     ;; Re-create it so the fixture's cleanup has something to delete.
     (write-region "" nil file))))

(ert-deftest test-pi-topic-io-registry-does-not-grow-on-re-engage ()
  "Engaging the same topic twice replaces its entry instead of adding one."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-file
   test-pi-topic-io--two-topics
   (lambda (file)
     (test-pi-topic-io--engage file "pi-1000-aaaa")
     (should (equal 1 (hash-table-count pi-topic--id-locations)))
     (test-pi-topic-io--engage file "pi-1000-aaaa")
     (should (equal 1 (hash-table-count pi-topic--id-locations)))
     ;; A second, genuinely different topic does take its own slot.
     (test-pi-topic-io--engage file "pi-1000-bbbb")
     (should (equal 2 (hash-table-count pi-topic--id-locations))))))

;;; Regression: agent-written headings must nest, not escape

(defun test-pi-topic-io--top-level-count (file)
  "Return the number of level-1 headings org parses in FILE's buffer."
  (with-current-buffer (find-file-noselect file)
    (org-with-wide-buffer
     (length (org-map-entries (lambda () t) "LEVEL=1")))))

(defun test-pi-topic-io--buffer-text (file)
  "Return FILE's buffer text — the write may not have been saved."
  (with-current-buffer (find-file-noselect file)
    (org-with-wide-buffer
     (buffer-substring-no-properties (point-min) (point-max)))))

(ert-deftest test-pi-topic-io-agent-headings-nest-under-the-section ()
  "A level-1 heading in the agent's text lands under Result, not beside it."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-file
   test-pi-topic-io--two-topics
   (lambda (file)
     ;; Counting first opens the file, so the write lands in that buffer
     ;; and — correctly — leaves saving to whoever opened it.  Every
     ;; assertion below therefore reads the buffer, not the disk.
     (let ((before (test-pi-topic-io--top-level-count file)))
       (should (pi-topic-write-result
                "pi-1000-aaaa"
                "* Options\nOne.\n** Trade-offs\nTwo.\n"))
       ;; The topic is at level 1, Result at 2, so the text starts at 3…
       (let ((text (test-pi-topic-io--buffer-text file)))
         (should (string-match-p "^\\*\\*\\* Options$" text))
         ;; …and relative depth is preserved: Trade-offs was one deeper.
         (should (string-match-p "^\\*\\*\\*\\* Trade-offs$" text)))
       ;; The property that actually matters: the outline did not gain a
       ;; sibling, so the topic was not torn in two.
       (should (equal before (test-pi-topic-io--top-level-count file)))
       ;; And the whole write is inside Result's own subtree — org reads
       ;; it back as the section body, shifted, not as anything adrift.
       (should (equal "*** Options\nOne.\n**** Trade-offs\nTwo."
                      (test-pi-topic-io--section file "pi-1000-aaaa" "Result")))))))

(ert-deftest test-pi-topic-io-headless-text-is-written-unchanged ()
  "Text with no heading at all goes in exactly as written."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-file
   test-pi-topic-io--two-topics
   (lambda (file)
     (should (pi-topic-write-result
              "pi-1000-aaaa"
              "Recommendation: pgvector.\n\n- ops cost\n- p95 latency"))
     (should (equal "Recommendation: pgvector.\n\n- ops cost\n- p95 latency"
                    (test-pi-topic-io--section file "pi-1000-aaaa" "Result"))))))

(ert-deftest test-pi-topic-io-asterisks-in-src-blocks-are-escaped ()
  "A column-0 asterisk inside a source block is protected, not shifted."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-file
   test-pi-topic-io--two-topics
   (lambda (file)
     (should (pi-topic-write-result
              "pi-1000-aaaa"
              (concat "* Sketch\n"
                      "#+begin_src org\n"
                      "* not a real heading\n"
                      "** nor this one\n"
                      "#+end_src\n"
                      "** After the block\n")))
     (let ((text (test-pi-topic-io--file-contents file)))
       ;; The real headings moved…
       (should (string-match-p "^\\*\\*\\* Sketch$" text))
       (should (string-match-p "^\\*\\*\\*\\* After the block$" text))
       ;; …and the sample kept its own level, behind org's comma.
       (should (string-match-p "^,\\* not a real heading$" text))
       (should (string-match-p "^,\\*\\* nor this one$" text))))))

(ert-deftest test-pi-topic-io-adjust-clamps-and-preserves-depth ()
  "The helper itself: baseline, relative depth, floor and ceiling."
  :tags '(:unit :pi-topic)
  ;; First heading becomes the target; the second keeps its offset.
  (should (equal "*** A\ntext\n**** B\n"
                 (pi-topic--adjust-heading-levels "* A\ntext\n** B\n" 3)))
  ;; Shifting up cannot rise above level 1.
  (should (equal "* A\n* B\n"
                 (pi-topic--adjust-heading-levels "*** A\n* B\n" 1)))
  ;; Nothing sinks deeper than the target plus five.
  (should (equal "*** A\n******** B\n"
                 (pi-topic--adjust-heading-levels "* A\n******************* B\n" 3)))
  ;; No heading at all: identity, untouched.
  (should (equal "just prose\n" (pi-topic--adjust-heading-levels "just prose\n" 3)))
  ;; A block-only asterisk is not a baseline — it is escaped instead.
  (should (equal "#+begin_src org\n,* sample\n#+end_src\n"
                 (pi-topic--adjust-heading-levels
                  "#+begin_src org\n* sample\n#+end_src\n" 3)))
  ;; Escaping is idempotent: a line that already carries the comma is
  ;; left exactly as the author wrote it.
  (should (equal "#+begin_src org\n,* sample\n#+end_src\n"
                 (pi-topic--adjust-heading-levels
                  "#+begin_src org\n,* sample\n#+end_src\n" 3))))

;;; Regression: a code sample must not be able to split the topic

(defun test-pi-topic-io--src-block-value (file)
  "Return the body of the first src block in FILE's buffer, as org reads it.
`org-element' strips the protective comma, so this is the sample the
author wrote."
  (with-current-buffer (find-file-noselect file)
    (org-with-wide-buffer
     (goto-char (point-min))
     (search-forward "#+begin_src")
     (org-element-property :value (org-element-at-point)))))

(ert-deftest test-pi-topic-io-src-block-cannot-split-the-topic ()
  "The exact payload that split a two-topic file leaves it with two.
Asserted through `org-map-entries', because the parser is the thing
being fooled: string matching would agree with the broken version."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-file
   test-pi-topic-io--two-topics
   (lambda (file)
     (let ((before (test-pi-topic-io--top-level-count file)))
       (should (equal 2 before))
       (should (pi-topic-write-result
                "pi-1000-aaaa"
                (concat "* Options\nprose\n** Trade-offs\nmore\n"
                        "#+begin_src elisp\n* not a heading\n#+end_src\ntail")))
       (should (equal before (test-pi-topic-io--top-level-count file)))
       ;; The tail after the block is still inside the topic, which is
       ;; what a stray headline would have taken away.
       (should (string-match-p
                "tail" (test-pi-topic-io--section file "pi-1000-aaaa" "Result")))
       ;; The sample survives byte for byte once org strips the comma.
       (should (equal "* not a heading\n"
                      (test-pi-topic-io--src-block-value file)))
       ;; And on disk it carries the comma that makes that possible.
       (should (string-match-p "^,\\* not a heading$"
                               (test-pi-topic-io--buffer-text file)))))))

(ert-deftest test-pi-topic-io-escaping-is-not-repeated ()
  "Re-writing already-escaped text does not grow a second comma."
  :tags '(:unit :pi-topic)
  (test-pi-topic-io--with-file
   test-pi-topic-io--two-topics
   (lambda (file)
     (let ((payload (concat "* Sketch\n#+begin_src elisp\n"
                            ",* already escaped\n#+end_src\n")))
       (should (pi-topic-write-result "pi-1000-aaaa" payload))
       (let ((text (test-pi-topic-io--buffer-text file)))
         (should (string-match-p "^,\\* already escaped$" text))
         (should-not (string-match-p "^,,\\* already escaped$" text)))
       ;; org still reads the author's line back unchanged.
       (should (equal "* already escaped\n"
                      (test-pi-topic-io--src-block-value file)))))))

(provide 'test-pi-topic-io)
;;; test-pi-topic-io.el ends here
