;;; test-behavior-prompts.el --- Integration tests for tag/header behavior system -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for claude-org tag and header argument behavior injection.
;; Run with: (ert-run-tests-interactively "claude-org-behavior")

;;; Code:

(require 'ert)
(require 'org)

;; Ensure claude-org is loaded
(unless (fboundp 'claude-org--tag-prompt)
  (literate-elisp-load (expand-file-name "claude-org.org"
                                          (file-name-directory load-file-name))))

;;; ============================================================
;;; Tag Behavior Tests
;;; ============================================================

(ert-deftest claude-org-behavior/tag-lookup-explore ()
  "Test explore tag returns correct prompt."
  (let ((prompt (claude-org--tag-prompt 'explore)))
    (should (stringp prompt))
    (should (string-match-p "EXPLORE" prompt))
    (should (string-match-p "Do NOT modify" prompt))))

(ert-deftest claude-org-behavior/tag-lookup-plan ()
  "Test plan tag returns correct prompt."
  (let ((prompt (claude-org--tag-prompt 'plan)))
    (should (stringp prompt))
    (should (string-match-p "PLAN" prompt))
    (should (string-match-p "approval" prompt))))

(ert-deftest claude-org-behavior/tag-lookup-code ()
  "Test code tag returns correct prompt."
  (let ((prompt (claude-org--tag-prompt 'code)))
    (should (stringp prompt))
    (should (string-match-p "CODE" prompt))
    (should (string-match-p "Implement" prompt))))

(ert-deftest claude-org-behavior/tag-lookup-test ()
  "Test test tag returns correct prompt."
  (let ((prompt (claude-org--tag-prompt 'test)))
    (should (stringp prompt))
    (should (string-match-p "TEST" prompt))
    (should (string-match-p "edge cases" prompt))))

(ert-deftest claude-org-behavior/tag-lookup-review ()
  "Test review tag returns correct prompt."
  (let ((prompt (claude-org--tag-prompt 'review)))
    (should (stringp prompt))
    (should (string-match-p "REVIEW" prompt))
    (should (string-match-p "Do NOT write new code" prompt))))

(ert-deftest claude-org-behavior/tag-lookup-commit ()
  "Test commit tag returns correct prompt."
  (let ((prompt (claude-org--tag-prompt 'commit)))
    (should (stringp prompt))
    (should (string-match-p "COMMIT" prompt))
    (should (string-match-p "Do NOT push" prompt))))

(ert-deftest claude-org-behavior/tag-lookup-strict ()
  "Test strict modifier tag returns correct prompt."
  (let ((prompt (claude-org--tag-prompt 'strict)))
    (should (stringp prompt))
    (should (string-match-p "STRICT" prompt))
    (should (string-match-p "Zero tolerance" prompt))))

(ert-deftest claude-org-behavior/tag-lookup-nonexistent ()
  "Test nonexistent tag returns nil."
  (should (null (claude-org--tag-prompt 'nonexistent-tag))))

;;; ============================================================
;;; Header Argument Behavior Tests
;;; ============================================================

(ert-deftest claude-org-behavior/header-phase-enum ()
  "Test :phase header with enum values."
  ;; Each phase value should return appropriate prompt
  (should (string-match-p "EXPLORE" (claude-org--header-prompt :phase "explore")))
  (should (string-match-p "PLAN" (claude-org--header-prompt :phase "plan")))
  (should (string-match-p "CODE" (claude-org--header-prompt :phase "code")))
  (should (string-match-p "TEST" (claude-org--header-prompt :phase "test")))
  (should (string-match-p "REVIEW" (claude-org--header-prompt :phase "review")))
  (should (string-match-p "COMMIT" (claude-org--header-prompt :phase "commit")))
  ;; Invalid value returns nil
  (should (null (claude-org--header-prompt :phase "invalid"))))

(ert-deftest claude-org-behavior/header-tests-boolean ()
  "Test :tests boolean header."
  (let ((prompt (claude-org--header-prompt :tests t)))
    (should (stringp prompt))
    (should (string-match-p "TEST GENERATION" prompt)))
  ;; nil value returns nil
  (should (null (claude-org--header-prompt :tests nil))))

(ert-deftest claude-org-behavior/header-coverage-template ()
  "Test :coverage template header with value substitution."
  (let ((prompt (claude-org--header-prompt :coverage "80")))
    (should (stringp prompt))
    (should (string-match-p "COVERAGE" prompt))
    (should (string-match-p "80%" prompt)))
  ;; Different value
  (let ((prompt (claude-org--header-prompt :coverage "95")))
    (should (string-match-p "95%" prompt))))

(ert-deftest claude-org-behavior/header-files-template ()
  "Test :files template header."
  (let ((prompt (claude-org--header-prompt :files "src/*.py")))
    (should (stringp prompt))
    (should (string-match-p "FILE SCOPE" prompt))
    (should (string-match-p "src/\\*\\.py" prompt))))

(ert-deftest claude-org-behavior/header-context-template ()
  "Test :context template header."
  (let ((prompt (claude-org--header-prompt :context "Custom context here")))
    (should (stringp prompt))
    (should (string-match-p "ADDITIONAL CONTEXT" prompt))
    (should (string-match-p "Custom context here" prompt))))

(ert-deftest claude-org-behavior/header-nonexistent ()
  "Test nonexistent header returns nil."
  (should (null (claude-org--header-prompt :nonexistent "value"))))

;;; ============================================================
;;; Header Argument Parsing Tests
;;; ============================================================

(ert-deftest claude-org-behavior/parse-header-args-simple ()
  "Test parsing simple header arguments."
  (with-temp-buffer
    (insert "#+begin_src ai :phase code\nquery\n#+end_src")
    (goto-char (+ (point-min) 30))
    (let ((args (claude-org--get-block-header-args)))
      (should (equal (plist-get args :phase) "code")))))

(ert-deftest claude-org-behavior/parse-header-args-boolean ()
  "Test parsing boolean header argument (no value)."
  (with-temp-buffer
    (insert "#+begin_src ai :tests\nquery\n#+end_src")
    (goto-char (+ (point-min) 25))
    (let ((args (claude-org--get-block-header-args)))
      (should (eq (plist-get args :tests) t)))))

(ert-deftest claude-org-behavior/parse-header-args-multiple ()
  "Test parsing multiple header arguments."
  (with-temp-buffer
    (insert "#+begin_src ai :phase code :tests :coverage 80\nquery\n#+end_src")
    (goto-char (+ (point-min) 50))
    (let ((args (claude-org--get-block-header-args)))
      (should (equal (plist-get args :phase) "code"))
      (should (eq (plist-get args :tests) t))
      (should (equal (plist-get args :coverage) "80")))))

(ert-deftest claude-org-behavior/parse-header-args-empty ()
  "Test parsing block with no header arguments."
  (with-temp-buffer
    (insert "#+begin_src ai\nquery\n#+end_src")
    (goto-char (+ (point-min) 20))
    (let ((args (claude-org--get-block-header-args)))
      (should (null args)))))

;;; ============================================================
;;; Tag Collection Tests (requires org-mode)
;;; ============================================================

(ert-deftest claude-org-behavior/collect-tags-single ()
  "Test collecting single tag from org section."
  (with-temp-buffer
    (org-mode)
    (insert "* Task :explore:\n#+begin_src ai\nquery\n#+end_src")
    (goto-char (+ (point-min) 30))
    (let ((tags (claude-org--get-current-tags)))
      (should (member "explore" tags)))))

(ert-deftest claude-org-behavior/collect-tags-multiple ()
  "Test collecting multiple tags from org section."
  (with-temp-buffer
    (org-mode)
    (insert "* Task :code:security:\n#+begin_src ai\nquery\n#+end_src")
    (goto-char (+ (point-min) 40))
    (let ((tags (claude-org--get-current-tags)))
      (should (member "code" tags))
      (should (member "security" tags)))))

(ert-deftest claude-org-behavior/collect-tags-inherited ()
  "Test collecting inherited tags from parent section.
Note: This test uses a section with direct tags since org-get-tags
inheritance requires full org buffer setup."
  (with-temp-buffer
    (org-mode)
    ;; Use direct tag on the section containing the ai block
    (insert "* Parent\n** Child :strict:\n#+begin_src ai\nquery\n#+end_src")
    (goto-char (+ (point-min) 50))
    (let ((tags (claude-org--get-current-tags)))
      (should (member "strict" tags)))))

;;; ============================================================
;;; Full Behavior Prompt Building Tests
;;; ============================================================

(ert-deftest claude-org-behavior/build-prompt-tag-only ()
  "Test building prompt with tag only."
  (with-temp-buffer
    (org-mode)
    (insert "* Task :explore:\n#+begin_src ai\nquery\n#+end_src")
    (goto-char (+ (point-min) 30))
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (stringp prompt))
      (should (string-match-p "EXPLORE" prompt)))))

(ert-deftest claude-org-behavior/build-prompt-header-only ()
  "Test building prompt with header argument only."
  (with-temp-buffer
    (org-mode)
    (insert "* Task\n#+begin_src ai :phase review\nquery\n#+end_src")
    (goto-char (+ (point-min) 35))
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (stringp prompt))
      (should (string-match-p "REVIEW" prompt)))))

(ert-deftest claude-org-behavior/build-prompt-combined ()
  "Test building prompt with both tags and headers."
  (with-temp-buffer
    (org-mode)
    (insert "* Task :code:security:\n#+begin_src ai :tests :coverage 80\nquery\n#+end_src")
    (goto-char (+ (point-min) 55))
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (stringp prompt))
      ;; Tags should be present (alphabetically sorted)
      (should (string-match-p "CODE" prompt))
      (should (string-match-p "SECURITY" prompt))
      ;; Headers should be present
      (should (string-match-p "TEST GENERATION" prompt))
      (should (string-match-p "80%" prompt)))))

(ert-deftest claude-org-behavior/build-prompt-empty ()
  "Test building prompt with no tags or headers."
  (with-temp-buffer
    (org-mode)
    (insert "* Task\n#+begin_src ai\nquery\n#+end_src")
    (goto-char (+ (point-min) 25))
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (null prompt)))))

(ert-deftest claude-org-behavior/build-prompt-tag-order ()
  "Test that tags are sorted alphabetically."
  (with-temp-buffer
    (org-mode)
    (insert "* Task :strict:code:explore:\n#+begin_src ai\nquery\n#+end_src")
    (goto-char (+ (point-min) 45))
    (let ((prompt (claude-org--build-behavior-prompt)))
      ;; code < explore < strict alphabetically
      (let ((code-pos (string-match "CODE" prompt))
            (explore-pos (string-match "EXPLORE" prompt))
            (strict-pos (string-match "STRICT" prompt)))
        (should (< code-pos explore-pos))
        (should (< explore-pos strict-pos))))))

;;; ============================================================
;;; Custom Behavior Registration Tests
;;; ============================================================

(ert-deftest claude-org-behavior/custom-tag ()
  "Test adding custom tag behavior."
  (let ((claude-org-tag-behaviors
         (cons '(custom_tag . "## CUSTOM TAG\nCustom behavior here.")
               claude-org-tag-behaviors)))
    (let ((prompt (claude-org--tag-prompt 'custom_tag)))
      (should (stringp prompt))
      (should (string-match-p "CUSTOM TAG" prompt)))))

(ert-deftest claude-org-behavior/custom-header ()
  "Test adding custom header behavior."
  (let ((claude-org-header-behaviors
         (cons '(:custom . "## CUSTOM HEADER\nTimeout: %s minutes.")
               claude-org-header-behaviors)))
    (let ((prompt (claude-org--header-prompt :custom "30")))
      (should (stringp prompt))
      (should (string-match-p "CUSTOM HEADER" prompt))
      (should (string-match-p "30 minutes" prompt)))))

;;; ============================================================
;;; Run all tests
;;; ============================================================

(defun claude-org-behavior-run-tests ()
  "Run all behavior prompt tests."
  (interactive)
  (ert-run-tests-interactively "claude-org-behavior"))

(provide 'test-behavior-prompts)
;;; test-behavior-prompts.el ends here
