;;; test-claude-org-query-id.el --- Tests for query-id based response tracking -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for the marker-free query-id architecture.

;;; Code:

(require 'ert)

;; Load the code under test
(let ((project-root (file-name-directory
                     (directory-file-name
                      (file-name-directory load-file-name)))))
  (load (expand-file-name "claude-org.org" project-root) nil t))

;;; Query-ID Generation Tests

(ert-deftest test-query-id-format ()
  "Query ID should have format YYYYMMDD-HHMMSS-XXXX."
  (let ((id (claude-org--generate-query-id)))
    (should (stringp id))
    (should (string-match-p "^[0-9]\\{8\\}-[0-9]\\{6\\}-[a-f0-9]\\{4\\}$" id))))

(ert-deftest test-query-id-uniqueness ()
  "Each query ID should be unique."
  (let ((ids (list (claude-org--generate-query-id)
                   (claude-org--generate-query-id)
                   (claude-org--generate-query-id)
                   (claude-org--generate-query-id)
                   (claude-org--generate-query-id))))
    (should (= (length ids) (length (delete-dups (copy-sequence ids)))))))

;;; Response Section Tests

(ert-deftest test-find-response-by-query-id ()
  "Should find response section by query-id property."
  (with-temp-buffer
    (org-mode)
    (insert "* Test\n")
    (insert "** Response 1 :ai_output:\n")
    (insert ":PROPERTIES:\n")
    (insert ":QUERY_ID: 20260204-120000-abcd\n")
    (insert ":QUERY_TYPE: normal\n")
    (insert ":END:\n\n")
    (insert "Response content here.\n")
    ;; Test finding the section
    (let ((pos (claude-org--find-response-by-query-id "20260204-120000-abcd")))
      (should pos)
      (goto-char pos)
      (should (looking-at "\\*\\* Response 1")))))

(ert-deftest test-find-response-not-found ()
  "Should return nil for non-existent query-id."
  (with-temp-buffer
    (org-mode)
    (insert "* Test\n")
    (insert "** Response 1 :ai_output:\n")
    (insert ":PROPERTIES:\n")
    (insert ":QUERY_ID: 20260204-120000-abcd\n")
    (insert ":END:\n\n")
    ;; Test finding non-existent ID
    (let ((pos (claude-org--find-response-by-query-id "20260204-999999-zzzz")))
      (should (null pos)))))

;;; Insert at Response Tests

(ert-deftest test-insert-at-response ()
  "Should insert text at end of response section."
  (with-temp-buffer
    (org-mode)
    (insert "* Test\n")
    (insert "** Response 1 :ai_output:\n")
    (insert ":PROPERTIES:\n")
    (insert ":QUERY_ID: 20260204-120000-test\n")
    (insert ":QUERY_TYPE: normal\n")
    (insert ":END:\n\n")
    ;; Set up session state
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (puthash "test-session" (list :query-id "20260204-120000-test") claude-org--sessions)
    ;; Insert text
    (claude-org--insert-at-response "test-session" "Hello, World!")
    ;; Verify insertion
    (goto-char (point-min))
    (should (search-forward "Hello, World!" nil t))))

;;; Token Handler v2 Tests

(ert-deftest test-handle-token-v2-inserts-text ()
  "Token handler v2 should insert text using query-id lookup."
  (with-temp-buffer
    (org-mode)
    (insert "* Test\n")
    (insert "** Response 1 :ai_output:\n")
    (insert ":PROPERTIES:\n")
    (insert ":QUERY_ID: 20260204-130000-v2test\n")
    (insert ":QUERY_TYPE: normal\n")
    (insert ":END:\n\n")
    ;; Set up session state
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (puthash "v2-session"
             (list :query-id "20260204-130000-v2test"
                   :section-level 1
                   :current-line-length 0)
             claude-org--sessions)
    ;; Process a token
    (claude-org--handle-token-v2 "v2-session" "Test token content")
    ;; Verify token was inserted
    (goto-char (point-min))
    (should (search-forward "Test token content" nil t))))

;;; Response Section Creation Tests

(ert-deftest test-create-response-section-normal ()
  "Should create normal response section with correct properties."
  (with-temp-buffer
    (org-mode)
    (insert "* Instruction :instruction:\n")
    (insert "#+begin_src ai\nQuery\n#+end_src\n")
    ;; Set up session state
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (puthash "create-test"
             (list :section-level 1
                   :instruction-num 1)
             claude-org--sessions)
    ;; Create response section
    (goto-char (point-max))
    (claude-org--create-response-section "create-test" "20260204-140000-create" 'normal)
    ;; Verify structure
    (goto-char (point-min))
    (should (search-forward ":QUERY_ID: 20260204-140000-create" nil t))
    (should (search-forward ":QUERY_TYPE: normal" nil t))))

(ert-deftest test-create-response-section-recovery ()
  "Should create recovery response section with parent reference."
  (with-temp-buffer
    (org-mode)
    (insert "* Instruction :instruction:\n")
    (insert "#+begin_src ai\nQuery\n#+end_src\n")
    ;; Set up session state
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (puthash "recovery-test"
             (list :section-level 1
                   :instruction-num 1
                   :recovery-count 0)
             claude-org--sessions)
    ;; Create recovery response section
    (goto-char (point-max))
    (claude-org--create-response-section
     "recovery-test" "20260204-150000-recov" 'recovery
     "20260204-140000-parent" "session_expired")
    ;; Verify structure
    (goto-char (point-min))
    (should (search-forward ":QUERY_ID: 20260204-150000-recov" nil t))
    (should (search-forward ":QUERY_TYPE: recovery" nil t))
    (should (search-forward ":PARENT_QUERY_ID: 20260204-140000-parent" nil t))
    (should (search-forward ":RECOVERY_REASON: session_expired" nil t))))

(provide 'test-claude-org-query-id)
;;; test-claude-org-query-id.el ends here
