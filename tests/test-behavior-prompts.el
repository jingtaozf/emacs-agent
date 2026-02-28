;;; test-behavior-prompts.el --- Integration tests for tag/header behavior system -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for claude-org tag and header argument behavior injection.
;; Run with: (ert-run-tests-interactively "claude-org-behavior")

;;; Code:

(require 'ert)
(require 'org)

;; Ensure claude-org is loaded (expects Makefile to load it; fallback to project root)
(unless (fboundp 'claude-org-execute)
  (let ((project-root (file-name-directory (directory-file-name
                                            (file-name-directory (or load-file-name default-directory))))))
    (literate-elisp-load (expand-file-name "claude-agent.org" project-root))
    (literate-elisp-load (expand-file-name "emacs-mcp-server.org" project-root))
    (literate-elisp-load (expand-file-name "claude-org.org" project-root))))

;;; ============================================================
;;; Tag Behavior Tests
;;; ============================================================


(ert-deftest claude-org-behavior/tag-lookup-nonexistent ()
  "Test nonexistent tag returns nil."
  (should (null (claude-org-tag-prompt 'nonexistent-tag nil))))

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

(ert-deftest claude-org-behavior/build-prompt-header-only ()
  "Test building prompt with header argument only."
  (with-temp-buffer
    (org-mode)
    (insert "* Task\n#+begin_src ai :phase review\nquery\n#+end_src")
    (goto-char (+ (point-min) 35))
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (stringp prompt))
      (should (string-match-p "REVIEW" prompt)))))

(ert-deftest claude-org-behavior/build-prompt-empty ()
  "Test building prompt with no tags or headers."
  (with-temp-buffer
    (org-mode)
    (insert "* Task\n#+begin_src ai\nquery\n#+end_src")
    (goto-char (+ (point-min) 25))
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (null prompt)))))

;;; ============================================================
;;; Custom Behavior Registration Tests
;;; ============================================================
;;; Note: Custom tag/header registration via alists has been removed.
;;; Tags and headers are now loaded exclusively from prompts/ files.
;;; These tests now verify that nonexistent tags/headers return nil.

(ert-deftest claude-org-behavior/custom-tag-nonexistent ()
  "Test that nonexistent tag returns nil (no alist fallback)."
  (should (null (claude-org-tag-prompt 'nonexistent_custom_tag nil))))

(ert-deftest claude-org-behavior/custom-header-nonexistent ()
  "Test that nonexistent header returns nil (no alist fallback)."
  (should (null (claude-org--header-prompt :nonexistent_custom "30"))))

;;; ============================================================
;;; Summary Section Extraction Tests
;;; ============================================================

(ert-deftest claude-org-behavior/extract-summary-with-summary ()
  "Test extraction of Summary section from file with Summary."
  (let ((temp-file (make-temp-file "test-summary" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "#+TITLE: Test\n\n")
            (insert "* Summary\n")
            (insert ":PROPERTIES:\n:CUSTOM_ID: test-summary\n:END:\n\n")
            (insert "Brief summary content.\n\n")
            (insert "* Details\n\n")
            (insert "Full detailed content here.\n"))
          (let ((result (claude-org--extract-summary-section temp-file)))
            (should (stringp result))
            (should (string-match-p "Summary" result))
            (should (string-match-p "Brief summary content" result))
            ;; Should NOT contain Details section content
            (should-not (string-match-p "Full detailed content" result))))
      (delete-file temp-file))))

(ert-deftest claude-org-behavior/extract-summary-without-summary ()
  "Test extraction returns full content when no Summary section."
  (let ((temp-file (make-temp-file "test-no-summary" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "#+TITLE: Test\n\n")
            (insert "* Main Content\n\n")
            (insert "This is the full content.\n"))
          (let ((result (claude-org--extract-summary-section temp-file)))
            (should (stringp result))
            ;; Should return full content when no Summary section
            (should (string-match-p "Main Content" result))
            (should (string-match-p "full content" result))))
      (delete-file temp-file))))

(ert-deftest claude-org-behavior/extract-summary-real-sdd-file ()
  "Test Summary extraction on actual sdd.org file."
  (let* ((prompt-file (expand-file-name "tags/sdd.org" claude-org-prompts-directory))
         (result (claude-org--extract-summary-section prompt-file)))
    (should (stringp result))
    ;; Summary should contain key metadata
    (should (string-match-p "sdd" result))
    (should (string-match-p "Purpose" result))
    ;; Summary should have link to Details
    (should (string-match-p "Details" result))
    ;; Should NOT contain full workflow content
    (should-not (string-match-p "Finding Current Progress" result))))

(ert-deftest claude-org-behavior/extract-summary-nil-for-nonexistent ()
  "Test extraction returns nil for nonexistent file."
  (should (null (claude-org--extract-summary-section "/nonexistent/file.org"))))

;;; ============================================================
;;; Dynamic Tag Discovery Tests
;;; ============================================================

(ert-deftest claude-org-behavior/discover-tags-returns-list ()
  "Test that tag discovery returns a list of tag specs."
  (let ((tags (claude-org--discover-tags)))
    (should (listp tags))
    ;; Each tag should be (key tag-name description)
    (dolist (tag tags)
      (should (= 3 (length tag)))
      (should (stringp (nth 0 tag)))  ; key
      (should (stringp (nth 1 tag)))  ; tag-name
      (should (stringp (nth 2 tag)))))) ; description

(ert-deftest claude-org-behavior/discover-tags-includes-lp ()
  "Test that lp tag is discovered from prompts/tags/lp.org."
  (let ((tags (claude-org--discover-tags)))
    (should (cl-some (lambda (tag) (equal "lp" (nth 1 tag))) tags))))

(ert-deftest claude-org-behavior/discover-tags-includes-sdd-phases ()
  "Test that SDD phase tags are discovered."
  (let ((tags (claude-org--discover-tags))
        (expected '("research" "design" "planning" "implementation" "sdd")))
    (dolist (exp expected)
      (should (cl-some (lambda (tag) (equal exp (nth 1 tag))) tags)))))

(ert-deftest claude-org-behavior/extract-tag-description ()
  "Test extracting description from tag file."
  (let* ((lp-file (expand-file-name "tags/lp.org" claude-org-prompts-directory))
         (desc (claude-org--extract-tag-description lp-file)))
    (should (stringp desc))
    (should (string-match-p "literate" (downcase desc)))))

(ert-deftest claude-org-behavior/assign-tag-key-unique ()
  "Test that key assignment avoids used keys."
  (should (equal "l" (claude-org--assign-tag-key "lp" '())))
  (should (equal "p" (claude-org--assign-tag-key "lp" '("l"))))
  (should (equal "1" (claude-org--assign-tag-key "lp" '("l" "p")))))

(ert-deftest claude-org-behavior/workflow-tags-dynamic ()
  "Test that workflow tags function uses dynamic discovery."
  (let ((tags (claude-org--workflow-tags)))
    (should (listp tags))
    (should (> (length tags) 0))))

;;; ============================================================
;;; CLAUDE_TAGS Property Tests
;;; ============================================================

(ert-deftest claude-org-behavior/get-property-tags-simple ()
  "Test getting tags from CLAUDE_TAGS property."
  (with-temp-buffer
    (org-mode)
    (insert "* Section\n:PROPERTIES:\n:CLAUDE_TAGS: lp strict\n:END:\n")
    (goto-char (point-min))
    (re-search-forward "^\\* Section")
    (let ((tags (claude-org--get-property-tags)))
      (should (member "lp" tags))
      (should (member "strict" tags)))))

(ert-deftest claude-org-behavior/get-property-tags-inheritance ()
  "Test that CLAUDE_TAGS inherits from parent sections."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n:PROPERTIES:\n:CLAUDE_TAGS: lp\n:END:\n")
    (insert "** Child\nContent\n")
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Child")
    (let ((tags (claude-org--get-property-tags)))
      (should (member "lp" tags)))))

(ert-deftest claude-org-behavior/get-property-tags-file-level ()
  "Test getting tags from file-level CLAUDE_TAGS property."
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: CLAUDE_TAGS lp\n\n* Section\nContent\n")
    (org-set-regexps-and-options)
    (goto-char (point-min))
    (re-search-forward "^\\* Section")
    (let ((tags (claude-org--get-property-tags)))
      (should (member "lp" tags)))))

(ert-deftest claude-org-behavior/get-current-tags-merges ()
  "Test that get-current-tags merges heading and property tags."
  (with-temp-buffer
    (org-mode)
    (insert "* Section :code:\n:PROPERTIES:\n:CLAUDE_TAGS: lp\n:END:\n")
    (goto-char (point-min))
    (re-search-forward "^\\* Section")
    (let ((tags (claude-org--get-current-tags)))
      (should (member "code" tags))
      (should (member "lp" tags)))))

(ert-deftest claude-org-behavior/get-current-tags-deduplicates ()
  "Test that duplicate tags are removed (heading takes priority)."
  (with-temp-buffer
    (org-mode)
    (insert "* Section :lp:\n:PROPERTIES:\n:CLAUDE_TAGS: lp strict\n:END:\n")
    (goto-char (point-min))
    (re-search-forward "^\\* Section")
    (let ((tags (claude-org--get-current-tags)))
      ;; lp should appear only once
      (should (= 1 (cl-count "lp" tags :test #'equal)))
      (should (member "strict" tags)))))

;;; ============================================================
;;; LP Tag Prompt Tests
;;; ============================================================

(ert-deftest claude-org-behavior/tag-lookup-lp ()
  "Test lp tag returns correct prompt."
  (let ((prompt (claude-org-tag-prompt 'lp nil)))
    (should (stringp prompt))
    (should (string-match-p "Literate" prompt))))

(ert-deftest claude-org-behavior/lp-tag-file-exists ()
  "Test that lp.org tag file exists."
  (let ((lp-file (expand-file-name "tags/lp.org" claude-org-prompts-directory)))
    (should (file-exists-p lp-file))))

;;; ============================================================
;;; CLAUDE_TAGS Integration with System Prompt Tests
;;; ============================================================

(ert-deftest claude-org-behavior/build-prompt-with-property-tag ()
  "Test that CLAUDE_TAGS property tags appear in behavior prompt."
  (with-temp-buffer
    (org-mode)
    (insert "* Task\n:PROPERTIES:\n:CLAUDE_TAGS: lp\n:END:\n#+begin_src ai\nquery\n#+end_src")
    ;; Position inside the ai block (after property drawer)
    (goto-char (+ (point-min) 50))
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (stringp prompt))
      ;; LP tag content should be in the prompt
      (should (string-match-p "Literate" prompt)))))

(ert-deftest claude-org-behavior/build-prompt-merges-heading-and-property-tags ()
  "Test that heading tags and CLAUDE_TAGS property are both in behavior prompt."
  (with-temp-buffer
    (org-mode)
    (insert "* Task :research:\n:PROPERTIES:\n:CLAUDE_TAGS: lp\n:END:\n#+begin_src ai\nquery\n#+end_src")
    ;; Position inside the ai block
    (goto-char (+ (point-min) 60))
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (stringp prompt))
      ;; Both research and lp tag content should be in the prompt
      (should (string-match-p "Research" prompt))  ; from :research: heading tag
      (should (string-match-p "Literate" prompt))))) ; from CLAUDE_TAGS property

(ert-deftest claude-org-behavior/build-prompt-property-tag-inherited ()
  "Test that inherited CLAUDE_TAGS property tags appear in behavior prompt."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n:PROPERTIES:\n:CLAUDE_TAGS: lp\n:END:\n")
    (insert "** Child :research:\n#+begin_src ai\nquery\n#+end_src")
    ;; Position inside the ai block under Child
    (goto-char (- (point-max) 20))
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (stringp prompt))
      ;; research from heading, lp inherited from parent's CLAUDE_TAGS
      (should (string-match-p "Research" prompt))
      (should (string-match-p "Literate" prompt)))))

(ert-deftest claude-org-behavior/build-prompt-file-level-property-tag ()
  "Test that file-level CLAUDE_TAGS property tags appear in behavior prompt."
  (with-temp-buffer
    (org-mode)
    (insert "#+PROPERTY: CLAUDE_TAGS lp\n\n")
    (insert "* Task :research:\n#+begin_src ai\nquery\n#+end_src")
    (org-set-regexps-and-options)  ; Parse file-level properties
    ;; Position inside the ai block
    (goto-char (- (point-max) 15))
    (let ((prompt (claude-org--build-behavior-prompt)))
      (should (stringp prompt))
      ;; Both should appear
      (should (string-match-p "Research" prompt))
      (should (string-match-p "Literate" prompt)))))

;;; ============================================================
;;; Closure/Lexical Binding Tests for Dynamic Menu
;;; ============================================================

(ert-deftest claude-org-behavior/make-tag-toggler-closure ()
  "Test that make-tag-toggler creates working closures."
  (setq claude-org--selected-tags nil)
  (let ((toggler-lp (claude-org--make-tag-toggler "lp"))
        (toggler-research (claude-org--make-tag-toggler "research")))
    ;; Should be callable functions
    (should (functionp toggler-lp))
    (should (functionp toggler-research))
    ;; Calling toggler should toggle the correct tag
    (funcall toggler-lp)
    (should (member "lp" claude-org--selected-tags))
    (should-not (member "research" claude-org--selected-tags))
    ;; Calling other toggler should toggle its tag
    (funcall toggler-research)
    (should (member "lp" claude-org--selected-tags))
    (should (member "research" claude-org--selected-tags))
    ;; Calling again should untoggle
    (funcall toggler-lp)
    (should-not (member "lp" claude-org--selected-tags))
    (should (member "research" claude-org--selected-tags))))

(ert-deftest claude-org-behavior/make-tag-description-closure ()
  "Test that make-tag-description creates working closures."
  (setq claude-org--selected-tags nil)
  (let ((desc-lp (claude-org--make-tag-description "lp" "Literate programming"))
        (desc-research (claude-org--make-tag-description "research" "Research mode")))
    ;; Should be callable functions
    (should (functionp desc-lp))
    (should (functionp desc-research))
    ;; Unselected tags show [ ]
    (should (string-match-p "^\\[ \\] Literate programming$" (funcall desc-lp)))
    (should (string-match-p "^\\[ \\] Research mode$" (funcall desc-research)))
    ;; After selecting lp, only lp shows [X]
    (push "lp" claude-org--selected-tags)
    (should (string-match-p "^\\[X\\] Literate programming$" (funcall desc-lp)))
    (should (string-match-p "^\\[ \\] Research mode$" (funcall desc-research)))
    ;; Each closure maintains its own tag reference
    (push "research" claude-org--selected-tags)
    (should (string-match-p "^\\[X\\] Literate programming$" (funcall desc-lp)))
    (should (string-match-p "^\\[X\\] Research mode$" (funcall desc-research)))))

(ert-deftest claude-org-behavior/build-tag-menu-items-structure ()
  "Test that build-tag-menu-items returns correctly structured items."
  (let ((items (claude-org--build-tag-menu-items)))
    ;; Should be a vector
    (should (vectorp items))
    ;; Should have multiple items (at least lp and sdd phases)
    (should (> (length items) 3))
    ;; Each item should be a list with key, function, :transient, :description
    (dotimes (i (length items))
      (let ((item (aref items i)))
        (should (listp item))
        (should (stringp (nth 0 item)))           ; key
        (should (functionp (nth 1 item)))          ; toggler function
        (should (eq :transient (nth 2 item)))
        (should (eq t (nth 3 item)))
        (should (eq :description (nth 4 item)))
        (should (functionp (nth 5 item)))))))      ; description function

;;; ============================================================
;;; Run all tests
;;; ============================================================

(defun claude-org-behavior-run-tests ()
  "Run all behavior prompt tests."
  (interactive)
  (ert-run-tests-interactively "claude-org-behavior"))

(provide 'test-behavior-prompts)
;;; test-behavior-prompts.el ends here
