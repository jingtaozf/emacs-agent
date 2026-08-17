;;; test-pi-topic-workflow.el --- Tests for the pi-topic workflow layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for lp/org/pi-topic-workflow.org — capture, agenda-file
;; discovery, the topic list, and reap.
;;
;; Every test runs against real temp .org files: the capture test drives
;; `org-capture' end to end, and the list test scans real buffers.  No pi
;; process is involved anywhere — the workflow layer never talks to one.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-capture)
(require 'pi-topic)
(require 'pi-topic-chat)
(require 'pi-topic-workflow)
(require 'test-pi-topic)

(defun test-pi-topic-workflow--temp-org (content)
  "Return a fresh temp .org file holding CONTENT."
  (make-temp-file "pi-topic-wf-" nil ".org" content))

(defun test-pi-topic-workflow--cleanup (files)
  "Kill any buffer visiting FILES, then delete them."
  (dolist (file files)
    (let ((buffer (find-buffer-visiting file)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer)))
    (when (file-exists-p file)
      (delete-file file)))
  (let ((list-buffer (get-buffer "*Pi Topics*")))
    (when (buffer-live-p list-buffer)
      (kill-buffer list-buffer))))

(defun test-pi-topic-workflow--member-file (file files)
  "Return non-nil when FILE names the same file as some entry of FILES."
  (and (seq-some (lambda (candidate) (file-equal-p candidate file)) files) t))

(defun test-pi-topic-workflow--list-rows ()
  "Return the (STATE . HEADING) rows currently rendered in *Pi Topics*."
  (with-current-buffer "*Pi Topics*"
    (save-excursion
      (goto-char (point-min))
      (let ((rows nil))
        (while (re-search-forward "^\\([a-z]+\\) +\\([^ ]+\\) " nil t)
          (push (cons (match-string 1) (match-string 2)) rows))
        (nreverse rows)))))

;;; Test 1: the capture template lands a real topic in the resolved file

(ert-deftest test-pi-topic-workflow-capture-creates-topic ()
  "`org-capture' through the template writes a topic into the target file."
  :tags '(:unit :pi-topic)
  (let* ((target (test-pi-topic-workflow--temp-org ""))
         (pi-topic-file target))
    (unwind-protect
        (let ((template (pi-topic-capture-template)))
          ;; The target is the resolver, so it follows the project.
          (should (equal (list 'file 'pi-topic--capture-file) (nth 3 template)))
          (should (equal target (pi-topic--capture-file)))
          (should (equal target (org-capture-expand-file 'pi-topic--capture-file)))
          (let ((org-capture-templates (list template)))
            (org-capture nil "p")
            (insert "Compare pgvector and qdrant.")
            (org-capture-finalize))
          (with-current-buffer (find-file-noselect target)
            (goto-char (point-min))
            (should (re-search-forward "^\\* " nil t))
            (beginning-of-line)
            (should (pi-topic-p))
            (should (equal "todo" (pi-topic-state)))
            (should (equal "Compare pgvector and qdrant." (pi-topic-goal)))
            (should (equal "" (pi-topic-result)))))
      (test-pi-topic-workflow--cleanup (list target)))))

;;; Test 2: registration is idempotent and never steals an existing key

(ert-deftest test-pi-topic-workflow-add-capture-template-is-idempotent ()
  "`pi-topic-add-capture-template' adds once and never clobbers \"p\"."
  :tags '(:unit :pi-topic)
  (let ((org-capture-templates nil))
    (pi-topic-add-capture-template)
    (should (equal 1 (length org-capture-templates)))
    (should (equal "p" (car (car org-capture-templates))))
    (pi-topic-add-capture-template)
    (should (equal 1 (length org-capture-templates))))
  ;; A user who already owns "p" keeps it.
  (let* ((mine (list "p" "Mine" 'entry (list 'file "/tmp/mine.org") "* %?"))
         (org-capture-templates (list mine)))
    (pi-topic-add-capture-template)
    (should (equal (list mine) org-capture-templates))))

;;; Test 3: agenda scanning is filtered by the property, not by extension

(ert-deftest test-pi-topic-workflow-agenda-files-filters-by-property ()
  "Only agenda files that actually carry a PI_STATE are worth scanning."
  :tags '(:unit :pi-topic)
  (let* ((with-topic (test-pi-topic-workflow--temp-org
                      "* Has one\n:PROPERTIES:\n:PI_STATE: todo\n:END:\n"))
         (without-topic (test-pi-topic-workflow--temp-org
                         "* Plain heading\nJust prose.\n"))
         (capture (test-pi-topic-workflow--temp-org ""))
         (pi-topic-file capture)
         (org-agenda-files (list with-topic without-topic)))
    (unwind-protect
        (let ((files (pi-topic-agenda-files)))
          (should (test-pi-topic-workflow--member-file capture files))
          (should (test-pi-topic-workflow--member-file with-topic files))
          (should-not (test-pi-topic-workflow--member-file without-topic files)))
      (test-pi-topic-workflow--cleanup
       (list with-topic without-topic capture)))))

;;; Test 4: the list spans files and is ordered by the lifecycle

(ert-deftest test-pi-topic-workflow-list-orders-by-lifecycle ()
  "`pi-topic-list' collects topics from every file, lifecycle-ordered."
  :tags '(:unit :pi-topic)
  (let* ((first (test-pi-topic-workflow--temp-org
                 (concat "* Alpha\n:PROPERTIES:\n:PI_STATE: review\n:END:\n"
                         "* Bravo\n:PROPERTIES:\n:PI_STATE: todo\n:END:\n")))
         (second (test-pi-topic-workflow--temp-org
                  "* Charlie\n:PROPERTIES:\n:PI_STATE: next\n:END:\n"))
         (pi-topic-file first)
         (org-agenda-files (list first second)))
    (unwind-protect
        (progn
          (pi-topic-list)
          ;; todo before next before review — the order work moves in,
          ;; and Charlie comes from the second file.
          (should (equal '(("todo" . "Bravo")
                           ("next" . "Charlie")
                           ("review" . "Alpha"))
                         (test-pi-topic-workflow--list-rows)))
          ;; Refreshing rebuilds rather than appending.
          (pi-topic-list)
          (should (equal 3 (length (test-pi-topic-workflow--list-rows)))))
      (test-pi-topic-workflow--cleanup (list first second)))))

;;; Test 5: reaping a topic that has no session is a report, not an error

(ert-deftest test-pi-topic-workflow-reap-without-session-reports ()
  "`pi-topic-reap' answers nil and leaves PI_SESSION alone."
  :tags '(:unit :pi-topic)
  (test-pi-topic--run
   test-pi-topic--topic
   (lambda ()
     (goto-char (point-min))
     ;; A topic that never had a session at all.
     (should-not (pi-topic-reap))
     (should-not (pi-topic--property "PI_SESSION"))
     ;; A topic whose transcript exists but whose session is gone.
     (pi-topic--set-property "PI_SESSION" "/gone/session.jsonl")
     (should-not (pi-topic-reap))
     (should (equal "/gone/session.jsonl" (pi-topic--property "PI_SESSION")))
     (should (equal "todo" (pi-topic-state))))))

;;; Where topics are filed is the user's choice

(defmacro test-pi-topic-workflow--no-prompt (&rest body)
  "Run BODY with `read-file-name' rigged to fail the test if called."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'read-file-name)
              (lambda (&rest _) (error "pi-topic prompted when it must not"))))
     ,@body))

(ert-deftest test-pi-topic-workflow-capture-file-string-never-prompts ()
  "A configured file name is used verbatim, without asking."
  :tags '(:unit :pi-topic)
  (let ((pi-topic-file "/tmp/pinned-topics.org")
        (pi-topic--remembered-file nil))
    (test-pi-topic-workflow--no-prompt
      (should (equal "/tmp/pinned-topics.org" (pi-topic--capture-file)))
      ;; Reading uses it too, and still does not ask.
      (should (equal "/tmp/pinned-topics.org" (pi-topic--known-capture-file))))
    ;; Asking never happened, so nothing was remembered.
    (should-not pi-topic--remembered-file)))

(ert-deftest test-pi-topic-workflow-capture-file-function-is-called ()
  "A function value is called for the file name, without asking."
  :tags '(:unit :pi-topic)
  (let* ((calls 0)
         (pi-topic-file (lambda ()
                          (setq calls (1+ calls))
                          "/tmp/computed-topics.org"))
         (pi-topic--remembered-file nil))
    (test-pi-topic-workflow--no-prompt
      (should (equal "/tmp/computed-topics.org" (pi-topic--capture-file)))
      (should (equal 1 calls))
      (should (equal "/tmp/computed-topics.org" (pi-topic--capture-file)))
      (should (equal 2 calls)))))

(ert-deftest test-pi-topic-workflow-capture-file-asks-once-then-remembers ()
  "With nil, the first call asks and every later call reuses the answer."
  :tags '(:unit :pi-topic)
  (let ((pi-topic-file nil)
        (pi-topic--remembered-file nil)
        (prompts 0)
        (offered nil))
    (cl-letf (((symbol-function 'read-file-name)
               (lambda (_prompt &optional _dir default &rest _)
                 (setq prompts (1+ prompts)
                       offered default)
                 "/tmp/picked-topics.org")))
      (should (equal "/tmp/picked-topics.org" (pi-topic--capture-file)))
      (should (equal 1 prompts))
      ;; The offered default is the project topics.org it used to hardcode.
      (should (equal "topics.org" (file-name-nondirectory offered))))
    ;; Second call: no prompt at all, same answer.
    (test-pi-topic-workflow--no-prompt
      (should (equal "/tmp/picked-topics.org" (pi-topic--capture-file)))
      (should (equal "/tmp/picked-topics.org" (pi-topic--known-capture-file))))
    (should (equal 1 prompts))))

(ert-deftest test-pi-topic-workflow-template-target-stays-a-function ()
  "Building the template resolves nothing and therefore asks nothing."
  :tags '(:unit :pi-topic)
  (let ((pi-topic-file nil)
        (pi-topic--remembered-file nil))
    (test-pi-topic-workflow--no-prompt
      (let ((template (pi-topic-capture-template)))
        ;; The target is the resolver itself, so the question waits for a
        ;; capture rather than for init.el.
        (should (equal (list 'file 'pi-topic--capture-file) (nth 3 template)))
        (should (functionp (nth 1 (nth 3 template))))
        ;; Registration is equally quiet.
        (let ((org-capture-templates nil))
          (pi-topic-add-capture-template)
          (should (equal (list 'file 'pi-topic--capture-file)
                         (nth 3 (car org-capture-templates)))))))
    (should-not pi-topic--remembered-file)))

(provide 'test-pi-topic-workflow)
;;; test-pi-topic-workflow.el ends here
