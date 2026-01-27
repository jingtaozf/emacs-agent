;;; test-claude-agent-permissions.el --- Tests for Permission Functions System -*- lexical-binding: t; -*-

;; Test the permission functions hook system for Claude Agent SDK

(require 'ert)
(require 'cl-lib)

;; Note: claude-agent.org is loaded via Makefile before this file is loaded

;;; Helper Functions

(defun test-claude-skip-unless-cli-available ()
  "Skip test if Claude CLI is not available."
  (unless (executable-find "claude")
    (ert-skip "Claude CLI not found - skipping integration test")))

;;; Unit Tests - Permission Functions Infrastructure

(ert-deftest test-permission-functions-variable-exists ()
  "Test that permission functions variable is defined."
  :tags '(:unit :fast :stable :isolated :permissions)
  (should (boundp 'claude-agent-permission-functions))
  (should (listp claude-agent-permission-functions)))

(ert-deftest test-permission-patterns-variables-exist ()
  "Test that allow/deny pattern variables are defined."
  :tags '(:unit :fast :stable :isolated :permissions)
  (should (boundp 'claude-agent-allow-patterns))
  (should (boundp 'claude-agent-deny-patterns)))

(ert-deftest test-run-permission-functions-empty ()
  "Test running permission functions with empty list."
  :tags '(:unit :fast :stable :isolated :permissions)
  (let ((claude-agent-permission-functions nil))
    (let ((result (claude-agent--run-permission-functions
                   "Read" '(:file_path "/tmp/test.txt") nil)))
      ;; Empty list should allow by default
      (should (equal (plist-get result :behavior) "allow")))))

(ert-deftest test-run-permission-functions-allow ()
  "Test permission function that allows."
  :tags '(:unit :fast :stable :isolated :permissions)
  (let ((claude-agent-permission-functions
         (list (lambda (_tool-name _tool-input _context)
                 '(:behavior "allow")))))
    (let ((result (claude-agent--run-permission-functions
                   "Read" '(:file_path "/tmp/test.txt") nil)))
      (should (equal (plist-get result :behavior) "allow")))))

(ert-deftest test-run-permission-functions-deny ()
  "Test permission function that denies."
  :tags '(:unit :fast :stable :isolated :permissions)
  (let ((claude-agent-permission-functions
         (list (lambda (_tool-name _tool-input _context)
                 '(:behavior "deny" :message "Test denial")))))
    (let ((result (claude-agent--run-permission-functions
                   "Write" '(:file_path "/tmp/test.txt") nil)))
      (should (equal (plist-get result :behavior) "deny"))
      (should (equal (plist-get result :message) "Test denial")))))

(ert-deftest test-run-permission-functions-chain ()
  "Test that first non-nil result is used."
  :tags '(:unit :fast :stable :isolated :permissions)
  (let* ((fn1-called nil)
         (fn2-called nil)
         (fn3-called nil)
         (claude-agent-permission-functions
          (list
           ;; First function returns nil (pass through)
           (lambda (_tool-name _tool-input _context)
             (setq fn1-called t)
             nil)
           ;; Second function returns allow
           (lambda (_tool-name _tool-input _context)
             (setq fn2-called t)
             '(:behavior "allow"))
           ;; Third function should not be called
           (lambda (_tool-name _tool-input _context)
             (setq fn3-called t)
             '(:behavior "deny")))))
    (let ((result (claude-agent--run-permission-functions
                   "Read" '(:file_path "/tmp/test.txt") nil)))
      (should fn1-called)
      (should fn2-called)
      (should-not fn3-called)
      (should (equal (plist-get result :behavior) "allow")))))

(ert-deftest test-permission-check-patterns-allow ()
  "Test pattern-based allow."
  :tags '(:unit :fast :stable :isolated :permissions)
  (let ((claude-agent-allow-patterns '("Read" "Grep" "Glob"))
        (claude-agent-deny-patterns nil))
    (let ((result (claude-agent-permission-check-patterns
                   "Read" '(:file_path "/tmp/test.txt") nil)))
      (should (equal (plist-get result :behavior) "allow")))))

(ert-deftest test-permission-check-patterns-deny ()
  "Test pattern-based deny."
  :tags '(:unit :fast :stable :isolated :permissions)
  (let ((claude-agent-allow-patterns nil)
        (claude-agent-deny-patterns '("Write" "Edit")))
    (let ((result (claude-agent-permission-check-patterns
                   "Write" '(:file_path "/tmp/test.txt") nil)))
      (should (equal (plist-get result :behavior) "deny")))))

(ert-deftest test-permission-check-patterns-passthrough ()
  "Test pattern check returns nil for unlisted tools."
  :tags '(:unit :fast :stable :isolated :permissions)
  (let ((claude-agent-allow-patterns '("Read"))
        (claude-agent-deny-patterns nil))
    (let ((result (claude-agent-permission-check-patterns
                   "Write" '(:file_path "/tmp/test.txt") nil)))
      ;; Should return nil to let next function decide
      (should (null result)))))

(ert-deftest test-permission-auto-allow ()
  "Test auto-allow function."
  :tags '(:unit :fast :stable :isolated :permissions)
  (let ((result (claude-agent-permission-auto-allow
                 "Bash" '(:command "rm -rf /") nil)))
    (should (equal (plist-get result :behavior) "allow"))))

(ert-deftest test-permission-prompt-context ()
  "Test that permission prompt receives correct context."
  :tags '(:unit :fast :stable :isolated :permissions)
  ;; We can't easily test the interactive prompt, but we can verify
  ;; the function signature works
  (should (fboundp 'claude-agent-permission-prompt)))

;;; Org File Protection Tests

(ert-deftest test-org-permission-protect-blocks-edit ()
  "Test that org protection blocks Edit on .org files."
  :tags '(:unit :fast :stable :isolated :permissions :org)
  (let ((result (claude-org-permission-protect-org
                 "Edit" '(:file_path "/tmp/test.org") nil)))
    (should (equal (plist-get result :behavior) "deny"))
    (should (string-match-p "evalElisp" (plist-get result :message)))))

(ert-deftest test-org-permission-protect-blocks-write ()
  "Test that org protection blocks Write on .org files."
  :tags '(:unit :fast :stable :isolated :permissions :org)
  (let ((result (claude-org-permission-protect-org
                 "Write" '(:file_path "/home/user/notes.org") nil)))
    (should (equal (plist-get result :behavior) "deny"))))

(ert-deftest test-org-permission-protect-allows-non-org ()
  "Test that org protection allows non-.org files."
  :tags '(:unit :fast :stable :isolated :permissions :org)
  (let ((result (claude-org-permission-protect-org
                 "Edit" '(:file_path "/tmp/test.txt") nil)))
    (should (null result))))

(ert-deftest test-org-permission-protect-allows-other-tools ()
  "Test that org protection allows other tools on .org files."
  :tags '(:unit :fast :stable :isolated :permissions :org)
  (let ((result (claude-org-permission-protect-org
                 "Read" '(:file_path "/tmp/test.org") nil)))
    (should (null result))))

(ert-deftest test-org-permission-protect-handles-path-variations ()
  "Test protection with various .org path patterns."
  :tags '(:unit :fast :stable :isolated :permissions :org)
  ;; Should block
  (should (claude-org-permission-protect-org
           "Edit" '(:file_path "file.org") nil))
  (should (claude-org-permission-protect-org
           "Write" '(:file_path "/path/to/file.ORG") nil))
  ;; Should allow (not .org)
  (should-not (claude-org-permission-protect-org
               "Edit" '(:file_path "file.org.bak") nil))
  (should-not (claude-org-permission-protect-org
               "Edit" '(:file_path "orgfile.txt") nil)))

;;; Installation/Removal Tests

(ert-deftest test-org-install-protection ()
  "Test installing org protection in permission functions."
  :tags '(:unit :fast :stable :isolated :permissions :org)
  (let ((claude-agent-permission-functions nil))
    (claude-org--install-protection)
    (should (memq #'claude-org-permission-protect-org
                  claude-agent-permission-functions))
    ;; Clean up
    (setq claude-agent-permission-functions nil)))

(ert-deftest test-org-remove-protection ()
  "Test removing org protection from permission functions."
  :tags '(:unit :fast :stable :isolated :permissions :org)
  (let ((claude-agent-permission-functions
         (list #'claude-org-permission-protect-org
               #'claude-agent-permission-prompt)))
    ;; Simulate no claude-org-mode buffers
    (let ((claude-org-mode nil))
      (claude-org--remove-protection)
      (should-not (memq #'claude-org-permission-protect-org
                        claude-agent-permission-functions)))))

;;; Bash Command Detection Tests

(ert-deftest test-bash-modifies-org-sed-inplace ()
  "Test that sed -i on .org files is detected."
  :tags '(:unit :fast :stable :isolated :permissions :org :bash)
  (should (claude-org--bash-modifies-org-p "sed -i 's/old/new/g' file.org"))
  (should (claude-org--bash-modifies-org-p "sed -i.bak 's/x/y/' notes.org"))
  (should (claude-org--bash-modifies-org-p "sed --in-place 's/a/b/' test.org")))

(ert-deftest test-bash-modifies-org-perl-inplace ()
  "Test that perl -i on .org files is detected."
  :tags '(:unit :fast :stable :isolated :permissions :org :bash)
  (should (claude-org--bash-modifies-org-p "perl -i -pe 's/old/new/' file.org"))
  (should (claude-org--bash-modifies-org-p "perl -pi -e 's/x/y/' notes.org")))

(ert-deftest test-bash-modifies-org-redirect ()
  "Test that output redirection to .org files is detected."
  :tags '(:unit :fast :stable :isolated :permissions :org :bash)
  (should (claude-org--bash-modifies-org-p "echo 'content' > file.org"))
  (should (claude-org--bash-modifies-org-p "cat tmp >> notes.org"))
  (should (claude-org--bash-modifies-org-p "echo hi > /path/to/file.org"))
  (should (claude-org--bash-modifies-org-p "cmd 2> error.org")))

(ert-deftest test-bash-modifies-org-cp-mv ()
  "Test that cp/mv to .org files is detected."
  :tags '(:unit :fast :stable :isolated :permissions :org :bash)
  (should (claude-org--bash-modifies-org-p "cp temp.txt file.org"))
  (should (claude-org--bash-modifies-org-p "mv draft.txt final.org"))
  (should (claude-org--bash-modifies-org-p "cp -f source target.org"))
  (should (claude-org--bash-modifies-org-p "install -m 644 src dest.org")))

(ert-deftest test-bash-modifies-org-tee ()
  "Test that tee to .org files is detected."
  :tags '(:unit :fast :stable :isolated :permissions :org :bash)
  (should (claude-org--bash-modifies-org-p "echo x | tee file.org"))
  (should (claude-org--bash-modifies-org-p "cmd | tee -a notes.org")))

(ert-deftest test-bash-modifies-org-temp-swap ()
  "Test that temp file swap pattern is detected."
  :tags '(:unit :fast :stable :isolated :permissions :org :bash)
  (should (claude-org--bash-modifies-org-p "awk '{print}' f > tmp && mv tmp file.org"))
  (should (claude-org--bash-modifies-org-p "sort f > t && mv t notes.org")))

(ert-deftest test-bash-modifies-org-allows-readonly ()
  "Test that read-only commands on .org files are allowed."
  :tags '(:unit :fast :stable :isolated :permissions :org :bash)
  ;; These should NOT be blocked (return nil)
  (should-not (claude-org--bash-modifies-org-p "cat file.org"))
  (should-not (claude-org--bash-modifies-org-p "grep pattern file.org"))
  (should-not (claude-org--bash-modifies-org-p "head -n 10 notes.org"))
  (should-not (claude-org--bash-modifies-org-p "tail -f log.org"))
  (should-not (claude-org--bash-modifies-org-p "wc -l *.org"))
  (should-not (claude-org--bash-modifies-org-p "ls *.org"))
  (should-not (claude-org--bash-modifies-org-p "find . -name '*.org'"))
  ;; sed without -i is read-only (outputs to stdout)
  (should-not (claude-org--bash-modifies-org-p "sed 's/x/y/' file.org")))

(ert-deftest test-bash-modifies-org-no-org-reference ()
  "Test that commands without .org reference are allowed."
  :tags '(:unit :fast :stable :isolated :permissions :org :bash)
  (should-not (claude-org--bash-modifies-org-p "echo 'hello' > file.txt"))
  (should-not (claude-org--bash-modifies-org-p "sed -i 's/x/y/' file.txt"))
  (should-not (claude-org--bash-modifies-org-p "cp a.txt b.txt"))
  (should-not (claude-org--bash-modifies-org-p nil))
  (should-not (claude-org--bash-modifies-org-p "")))

(ert-deftest test-bash-modifies-org-edge-cases ()
  "Test edge cases for bash command detection."
  :tags '(:unit :fast :stable :isolated :permissions :org :bash)
  ;; Quoted paths should still be detected
  (should (claude-org--bash-modifies-org-p "echo x > \"my file.org\""))
  (should (claude-org--bash-modifies-org-p "cp tmp 'notes.org'"))
  ;; .org.bak should NOT be blocked (not a .org file)
  (should-not (claude-org--bash-modifies-org-p "cp file.org file.org.bak")))

(ert-deftest test-org-permission-protect-blocks-bash-sed ()
  "Test that org protection blocks bash sed -i on .org files."
  :tags '(:unit :fast :stable :isolated :permissions :org :bash)
  (let ((result (claude-org-permission-protect-org
                 "Bash" '(:command "sed -i 's/x/y/' file.org") nil)))
    (should (equal (plist-get result :behavior) "deny"))
    (should (string-match-p "evalElisp" (plist-get result :message)))))

(ert-deftest test-org-permission-protect-blocks-bash-redirect ()
  "Test that org protection blocks bash redirect to .org files."
  :tags '(:unit :fast :stable :isolated :permissions :org :bash)
  (let ((result (claude-org-permission-protect-org
                 "Bash" '(:command "echo 'test' > notes.org") nil)))
    (should (equal (plist-get result :behavior) "deny"))))

(ert-deftest test-org-permission-protect-allows-bash-readonly ()
  "Test that org protection allows read-only bash on .org files."
  :tags '(:unit :fast :stable :isolated :permissions :org :bash)
  (should-not (claude-org-permission-protect-org
               "Bash" '(:command "cat file.org") nil))
  (should-not (claude-org-permission-protect-org
               "Bash" '(:command "grep pattern notes.org") nil)))

(ert-deftest test-org-deny-message-contains-stop-instruction ()
  "Test that deny message contains instruction to stop if evalElisp unavailable."
  :tags '(:unit :fast :stable :isolated :permissions :org)
  (let ((result (claude-org-permission-protect-org
                 "Edit" '(:file_path "/tmp/test.org") nil)))
    (should (string-match-p "report this as an error and stop"
                            (plist-get result :message)))))

;;; AskUserQuestion Tool Tests

(ert-deftest test-ask-user-question-function-exists ()
  "Test that AskUserQuestion permission function exists."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (should (fboundp 'claude-agent-permission-ask-user-question)))

(ert-deftest test-ask-user-question-ignores-other-tools ()
  "Test that function returns nil for non-AskUserQuestion tools."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (should-not (claude-agent-permission-ask-user-question
               "Read" '(:file_path "/tmp/test.txt") nil))
  (should-not (claude-agent-permission-ask-user-question
               "Write" '(:file_path "/tmp/test.txt") nil))
  (should-not (claude-agent-permission-ask-user-question
               "Bash" '(:command "ls") nil)))

(ert-deftest test-format-question-options-basic ()
  "Test formatting question options for completing-read."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (let ((options (list (list :label "Option1" :description "First option")
                       (list :label "Option2" :description "Second option"))))
    (let ((formatted (claude-agent--format-question-options options)))
      (should (= 2 (length formatted)))
      (should (equal (car (nth 0 formatted)) "Option1 - First option"))
      (should (equal (cdr (nth 0 formatted)) "Option1"))
      (should (equal (car (nth 1 formatted)) "Option2 - Second option"))
      (should (equal (cdr (nth 1 formatted)) "Option2")))))

(ert-deftest test-format-question-options-no-description ()
  "Test formatting options without descriptions."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (let ((options (list (list :label "JustLabel"))))
    (let ((formatted (claude-agent--format-question-options options)))
      (should (= 1 (length formatted)))
      (should (equal (car (nth 0 formatted)) "JustLabel"))
      (should (equal (cdr (nth 0 formatted)) "JustLabel")))))

(ert-deftest test-format-question-options-empty ()
  "Test formatting empty options list."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (let ((formatted (claude-agent--format-question-options nil)))
    (should (null formatted))))

(ert-deftest test-ask-user-question-with-mock-single-select ()
  "Test AskUserQuestion with mocked completing-read for single-select."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt _choices &rest _args)
               "Summary - Brief overview")))
    (let* ((tool-input (list :questions
                             (list (list :question "How should I format?"
                                        :header "Format"
                                        :options (list (list :label "Summary"
                                                            :description "Brief overview")
                                                      (list :label "Detailed"
                                                            :description "Full info"))
                                        :multiSelect nil))))
           (result (claude-agent-permission-ask-user-question
                    "AskUserQuestion" tool-input nil)))
      (should result)
      (should (equal (plist-get result :behavior) "allow"))
      (let* ((updated (plist-get result :updated-input))
             (answers (plist-get updated :answers)))
        (should answers)
        ;; answers is an alist
        (should (equal (cdr (assoc "How should I format?" answers)) "Summary"))))))

(ert-deftest test-ask-user-question-with-mock-multi-select ()
  "Test AskUserQuestion with mocked completing-read-multiple for multi-select."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (_prompt _choices &rest _args)
               '("Option1 - First" "Option2 - Second"))))
    (let* ((tool-input (list :questions
                             (list (list :question "Which features?"
                                        :header "Features"
                                        :options (list (list :label "Option1"
                                                            :description "First")
                                                      (list :label "Option2"
                                                            :description "Second"))
                                        :multiSelect t))))
           (result (claude-agent-permission-ask-user-question
                    "AskUserQuestion" tool-input nil)))
      (should result)
      (should (equal (plist-get result :behavior) "allow"))
      (let* ((updated (plist-get result :updated-input))
             (answers (plist-get updated :answers)))
        (should answers)
        ;; Multi-select joins labels with ", "
        (should (equal (cdr (assoc "Which features?" answers)) "Option1, Option2"))))))

(ert-deftest test-ask-user-question-other-free-text ()
  "Test AskUserQuestion when user chooses 'Other' for free-text."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (let ((read-string-called nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _choices &rest _args)
                 "Other (type your answer)"))
              ((symbol-function 'read-string)
               (lambda (_prompt)
                 (setq read-string-called t)
                 "My custom answer")))
      (let* ((tool-input (list :questions
                               (list (list :question "Pick something"
                                          :header "Pick"
                                          :options (list (list :label "A" :description "Option A"))
                                          :multiSelect nil))))
             (result (claude-agent-permission-ask-user-question
                      "AskUserQuestion" tool-input nil)))
        (should read-string-called)
        (should result)
        (let* ((updated (plist-get result :updated-input))
               (answers (plist-get updated :answers)))
          (should (equal (cdr (assoc "Pick something" answers)) "My custom answer")))))))

(ert-deftest test-ask-user-question-passes-through-questions ()
  "Test that original questions are passed through in response."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt _choices &rest _args) "Test - desc")))
    (let* ((questions (list (list :question "Test question"
                                 :header "Test"
                                 :options (list (list :label "Test" :description "desc"))
                                 :multiSelect nil)))
           (tool-input (list :questions questions))
           (result (claude-agent-permission-ask-user-question
                    "AskUserQuestion" tool-input nil)))
      (let* ((updated (plist-get result :updated-input))
             (returned-questions (plist-get updated :questions)))
        ;; Should pass through original questions
        (should (equal returned-questions questions))))))

(ert-deftest test-ask-user-question-user-cancel ()
  "Test AskUserQuestion returns deny when user cancels with C-g."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt _choices &rest _args)
               (signal 'quit nil))))
    (let* ((tool-input (list :questions
                             (list (list :question "Test"
                                        :header "T"
                                        :options (list (list :label "X"))
                                        :multiSelect nil))))
           (result (claude-agent-permission-ask-user-question
                    "AskUserQuestion" tool-input nil)))
      (should result)
      (should (equal (plist-get result :behavior) "deny"))
      (should (string-match-p "cancelled" (plist-get result :message))))))

(provide 'test-claude-agent-permissions)
;;; test-claude-agent-permissions.el ends here
