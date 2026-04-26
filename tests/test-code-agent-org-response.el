;;; test-code-agent-org-response.el --- Tests for timestamped response sections -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; Unit tests for timestamped response section functionality in code-agent-org.
;; Tests use with-temp-buffer with real org content, NO API calls.

;;; Code:

(require 'ert)
(require 'org)
(require 'code-agent-org)

;;; Test Helpers

(defmacro test-response-with-org-buffer (content &rest body)
  "Execute BODY in a temp buffer with org CONTENT."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,content)
     (goto-char (point-min))
     ,@body))

;;; Boundary Detection Tests

(ert-deftest test-response-boundary-stops-at-instruction ()
  "Boundary should stop at non-:ai_output: sibling (next Instruction)."
  :tags '(:unit :fast :stable :isolated :response)
  (test-response-with-org-buffer
   "* Parent
** Instruction 1 :ai_instruction:
#+begin_src ai
query
#+end_src

** Response 1 :ai_output:
response 1

** Response 1 :ai_output:
response 2

** Instruction 2 :ai_instruction:
#+begin_src ai
another query
#+end_src
"
   (re-search-forward "^\\*\\* Instruction 1")
   (let ((boundary (code-agent-org--find-response-boundary)))
     ;; Should stop at Instruction 2, not go past it
     (save-excursion
       (goto-char boundary)
       (should (looking-at "\\*\\* Instruction 2"))))))

(ert-deftest test-response-boundary-stops-at-parent ()
  "Boundary should stop at higher-level heading (parent boundary)."
  :tags '(:unit :fast :stable :isolated :response)
  (test-response-with-org-buffer
   "* Parent Section
** Instruction 1 :ai_instruction:
#+begin_src ai
query
#+end_src

** Response 1 :ai_output:
response

* Next Parent Section
Content here
"
   (re-search-forward "^\\*\\* Instruction 1")
   (let ((boundary (code-agent-org--find-response-boundary)))
     (save-excursion
       (goto-char boundary)
       (should (looking-at "\\* Next Parent Section"))))))

(ert-deftest test-response-boundary-returns-point-max ()
  "Boundary should return point-max when no boundary found."
  :tags '(:unit :fast :stable :isolated :response)
  (test-response-with-org-buffer
   "* Parent
** Instruction 1 :ai_instruction:
#+begin_src ai
query
#+end_src

** Response 1 :ai_output:
response
"
   (re-search-forward "^\\*\\* Instruction 1")
   (let ((boundary (code-agent-org--find-response-boundary)))
     (should (= boundary (point-max))))))

;;; Find Last Response Tests

(ert-deftest test-response-find-last-output-multiple ()
  "Should find the last of multiple :ai_output: siblings."
  :tags '(:unit :fast :stable :isolated :response)
  (test-response-with-org-buffer
   "* Parent
** Instruction 1 :ai_instruction:
#+begin_src ai
query
#+end_src

** Response 1 (2025-01-13 08:00) :ai_output:
first response

** Response 1 (2025-01-14 08:00) :ai_output:
second response

** Instruction 2 :ai_instruction:
#+begin_src ai
next query
#+end_src
"
   (re-search-forward "^\\*\\* Instruction 1")
   (let ((last-output-end (code-agent-org--find-last-ai-output-sibling)))
     (should last-output-end)
     ;; Should be at or after end of "second response" line but before "Instruction 2"
     (should (>= last-output-end (save-excursion
                                   (re-search-forward "second response" nil t)
                                   (line-end-position))))
     (should (< last-output-end (save-excursion
                                  (re-search-forward "Instruction 2" nil t)
                                  (point)))))))

(ert-deftest test-response-find-last-output-none ()
  "Should return nil when no :ai_output: sections exist."
  :tags '(:unit :fast :stable :isolated :response)
  (test-response-with-org-buffer
   "* Parent
** Instruction 1 :ai_instruction:
#+begin_src ai
query
#+end_src

** Instruction 2 :ai_instruction:
#+begin_src ai
next query
#+end_src
"
   (re-search-forward "^\\*\\* Instruction 1")
   (should-not (code-agent-org--find-last-ai-output-sibling))))

;;; Insert Point Tests

(ert-deftest test-response-insert-point-after-outputs ()
  "Insert point should be after existing :ai_output: sections."
  :tags '(:unit :fast :stable :isolated :response)
  (test-response-with-org-buffer
   "* Parent
** Instruction 1 :ai_instruction:
#+begin_src ai
query
#+end_src

** Response 1 (2025-01-13 08:00) :ai_output:
existing response
"
   (re-search-forward "^\\*\\* Instruction 1")
   (let ((insert-point (code-agent-org--find-response-insert-point)))
     (should insert-point)
     ;; Should be at or after end of "existing response" line
     (should (>= insert-point (save-excursion
                                (re-search-forward "existing response" nil t)
                                (line-end-position)))))))

(ert-deftest test-response-insert-point-after-block ()
  "Insert point should be after #+end_src when no responses exist."
  :tags '(:unit :fast :stable :isolated :response)
  (test-response-with-org-buffer
   "* Parent
** Instruction 1 :ai_instruction:
#+begin_src ai
query
#+end_src
"
   (re-search-forward "^\\*\\* Instruction 1")
   (let ((insert-point (code-agent-org--find-response-insert-point)))
     (should insert-point)
     ;; Should be at end of #+end_src line
     (should (= insert-point (save-excursion
                               (re-search-forward "#\\+end_src" nil t)
                               (line-end-position)))))))

;;; Response Header Creation Tests

(ert-deftest test-response-create-header-basic ()
  "Should create response header with timestamp."
  :tags '(:unit :fast :stable :isolated :response)
  (test-response-with-org-buffer
   "* Parent
** Instruction 1 :ai_instruction:
#+begin_src ai
query
#+end_src
"
   (re-search-forward "^\\*\\* Instruction 1")
   ;; Pass section-level=2 explicitly (matching the ** Instruction level)
   (let ((header (code-agent-org--create-response-section-header 1 "2025-01-13 08:00:15" nil 2)))
     (should (string-match-p "\\*\\* Response 1 (2025-01-13 08:00) :ai_output:" header))
     ;; Should trim seconds
     (should-not (string-match-p "08:00:15" header)))))

(ert-deftest test-response-create-header-with-loop ()
  "Should create response header with loop info."
  :tags '(:unit :fast :stable :isolated :response)
  (test-response-with-org-buffer
   "* Parent
** Instruction 1 :ai_instruction:
#+begin_src ai
query
#+end_src
"
   (re-search-forward "^\\*\\* Instruction 1")
   ;; Pass section-level=2 explicitly (matching the ** Instruction level)
   (let ((header (code-agent-org--create-response-section-header 1 "2025-01-13 08:00:15" '(2 . 5) 2)))
     (should (string-match-p "Response 1(2/5)" header)))))

(provide 'test-code-agent-org-response)
;;; test-code-agent-org-response.el ends here
