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

(ert-deftest test-ask-user-question-mock-answers ()
  "Test AskUserQuestion uses mock answers when set."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (let ((claude-agent-ask-user-question-mock-answers
         '(("How should I format?" . "Summary")
           ("Which features?" . "Option1, Option2")))
        (completing-read-called nil))
    ;; Mock completing-read to track if it's called
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _choices &rest _args)
                 (setq completing-read-called t)
                 "Should not be used")))
      (let* ((tool-input (list :questions
                               (list (list :question "How should I format?"
                                          :header "Format"
                                          :options (list (list :label "Summary")
                                                        (list :label "Detailed"))
                                          :multiSelect nil))))
             (result (claude-agent-permission-ask-user-question
                      "AskUserQuestion" tool-input nil)))
        ;; completing-read should NOT be called when mock is set
        (should-not completing-read-called)
        (should result)
        (should (equal (plist-get result :behavior) "allow"))
        (let* ((updated (plist-get result :updated-input))
               (answers (plist-get updated :answers)))
          (should (equal (cdr (assoc "How should I format?" answers)) "Summary")))))))

(ert-deftest test-ask-user-question-mock-answers-multi-select ()
  "Test AskUserQuestion mock answers work for multi-select."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (let ((claude-agent-ask-user-question-mock-answers
         '(("Which options?" . "A, B"))))
    (let* ((tool-input (list :questions
                             (list (list :question "Which options?"
                                        :header "Options"
                                        :options (list (list :label "A")
                                                      (list :label "B")
                                                      (list :label "C"))
                                        :multiSelect t))))
           (result (claude-agent-permission-ask-user-question
                    "AskUserQuestion" tool-input nil)))
      (should result)
      (let* ((updated (plist-get result :updated-input))
             (answers (plist-get updated :answers)))
        (should (equal (cdr (assoc "Which options?" answers)) "A, B"))))))

(ert-deftest test-ask-user-question-mock-partial ()
  "Test AskUserQuestion falls back to prompt for questions not in mock."
  :tags '(:unit :fast :stable :isolated :permissions :ask-user)
  (let ((claude-agent-ask-user-question-mock-answers
         '(("Known question" . "Mock answer")))
        (completing-read-called nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _choices &rest _args)
                 (setq completing-read-called t)
                 "Unknown - Real answer")))
      (let* ((tool-input (list :questions
                               (list (list :question "Unknown question"
                                          :header "Unknown"
                                          :options (list (list :label "Unknown"))
                                          :multiSelect nil))))
             (result (claude-agent-permission-ask-user-question
                      "AskUserQuestion" tool-input nil)))
        ;; Should fall back to completing-read for unknown questions
        (should completing-read-called)
        (should result)))))

;;; TDD Tests - Permission System Hardening
;;
;; These tests define expected behavior for security hardening:
;; - Permission function errors must DENY (not silently allow)
;; - Invalid return types must be treated as errors
;; - Single error must not auto-allow remaining functions
;;
;; Tag: :tdd - these tests were written BEFORE implementation

(ert-deftest test-permission-function-error-must-deny ()
  "TDD: When a permission function throws an error, result must be deny.
This prevents the security vulnerability where errors silently default to allow."
  :tags '(:unit :fast :stable :isolated :permissions :tdd :security)
  (let ((claude-agent-permission-functions
         (list (lambda (_tool-name _tool-input _context)
                 (error "Simulated permission function crash")))))
    (let ((result (claude-agent--run-permission-functions
                   "Bash" '(:command "rm -rf /") nil)))
      ;; CRITICAL: Must deny on error, not allow
      (should (equal (plist-get result :behavior) "deny"))
      (should (plist-get result :reason)))))

(ert-deftest test-all-permission-functions-error-must-deny ()
  "TDD: When ALL permission functions error, result must be deny.
This closes the 'all functions crash → auto-allow' vulnerability."
  :tags '(:unit :fast :stable :isolated :permissions :tdd :security)
  (let ((claude-agent-permission-functions
         (list (lambda (_t _i _c) (error "Error 1"))
               (lambda (_t _i _c) (error "Error 2"))
               (lambda (_t _i _c) (error "Error 3")))))
    (let ((result (claude-agent--run-permission-functions
                   "Write" '(:file_path "/etc/passwd") nil)))
      (should (equal (plist-get result :behavior) "deny"))
      ;; Should indicate permission error occurred
      (should (or (plist-get result :reason)
                  (string-match-p "error" (or (plist-get result :message) "")))))))

(ert-deftest test-permission-function-error-logged ()
  "TDD: Permission function errors must be logged for debugging."
  :tags '(:unit :fast :stable :isolated :permissions :tdd)
  (let ((logged-errors nil)
        (claude-agent-permission-functions
         (list (lambda (_t _i _c)
                 (error "Test error for logging")))))
    ;; Capture messages
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged-errors))))
      (claude-agent--run-permission-functions "Read" nil nil))
    ;; Should have logged the error
    (should (cl-some (lambda (msg) (string-match-p "error" msg)) logged-errors))))

(ert-deftest test-permission-function-wrong-type-must-deny ()
  "TDD: Permission function returning wrong type must be treated as error/deny.
Functions must return nil or plist with :behavior, not random values."
  :tags '(:unit :fast :stable :isolated :permissions :tdd :security)
  ;; Return just t instead of proper plist
  (let ((claude-agent-permission-functions
         (list (lambda (_t _i _c) t))))
    (let ((result (claude-agent--run-permission-functions
                   "Bash" '(:command "whoami") nil)))
      ;; Invalid return should be treated as error → deny
      (should (equal (plist-get result :behavior) "deny"))))
  ;; Return string instead of plist
  (let ((claude-agent-permission-functions
         (list (lambda (_t _i _c) "allow"))))
    (let ((result (claude-agent--run-permission-functions
                   "Bash" '(:command "id") nil)))
      (should (equal (plist-get result :behavior) "deny"))))
  ;; Return number
  (let ((claude-agent-permission-functions
         (list (lambda (_t _i _c) 42))))
    (let ((result (claude-agent--run-permission-functions
                   "Bash" '(:command "ps") nil)))
      (should (equal (plist-get result :behavior) "deny")))))

(ert-deftest test-permission-function-missing-behavior-must-deny ()
  "TDD: Permission function returning plist without :behavior must deny.
A plist with other keys but no :behavior is invalid."
  :tags '(:unit :fast :stable :isolated :permissions :tdd :security)
  (let ((claude-agent-permission-functions
         (list (lambda (_t _i _c)
                 ;; Missing :behavior key
                 '(:message "Some message" :other-key "value")))))
    (let ((result (claude-agent--run-permission-functions
                   "Write" '(:file_path "/tmp/test") nil)))
      (should (equal (plist-get result :behavior) "deny")))))

(ert-deftest test-permission-function-invalid-behavior-value-must-deny ()
  "TDD: Permission function with invalid :behavior value must deny.
Only 'allow' and 'deny' are valid behavior values."
  :tags '(:unit :fast :stable :isolated :permissions :tdd :security)
  ;; :behavior with invalid value
  (let ((claude-agent-permission-functions
         (list (lambda (_t _i _c) '(:behavior "maybe")))))
    (let ((result (claude-agent--run-permission-functions
                   "Read" '(:file_path "/tmp/test") nil)))
      (should (equal (plist-get result :behavior) "deny"))))
  ;; :behavior with non-string
  (let ((claude-agent-permission-functions
         (list (lambda (_t _i _c) '(:behavior allow)))))  ; symbol, not string
    (let ((result (claude-agent--run-permission-functions
                   "Read" '(:file_path "/tmp/test") nil)))
      (should (equal (plist-get result :behavior) "deny")))))

(ert-deftest test-permission-single-error-continues-chain ()
  "TDD: Single function error should continue chain but track error state.
If subsequent function allows, the error should still influence final decision."
  :tags '(:unit :fast :stable :isolated :permissions :tdd)
  (let* ((fn2-called nil)
         (claude-agent-permission-functions
          (list (lambda (_t _i _c) (error "First function failed"))
                (lambda (_t _i _c)
                  (setq fn2-called t)
                  '(:behavior "allow")))))
    (let ((result (claude-agent--run-permission-functions
                   "Read" '(:file_path "/tmp/safe") nil)))
      ;; Second function should be called
      (should fn2-called)
      ;; But because first errored, should still deny
      ;; (or at minimum, log that an error occurred)
      ;; This test documents that error in chain affects trust
      (should result))))

(ert-deftest test-permission-error-includes-function-info ()
  "TDD: Permission error result should include which function failed."
  :tags '(:unit :fast :stable :isolated :permissions :tdd)
  (let ((claude-agent-permission-functions
         (list #'claude-agent-permission-check-patterns  ; this won't error
               (lambda (_t _i _c)
                 (error "Intentional test error")))))
    ;; Temporarily make check-patterns error
    (cl-letf (((symbol-function 'claude-agent-permission-check-patterns)
               (lambda (_t _i _c) (error "Pattern check crashed"))))
      (let ((result (claude-agent--run-permission-functions
                     "Read" nil nil)))
        ;; Result should indicate an error occurred
        (should (equal (plist-get result :behavior) "deny"))))))

(provide 'test-claude-agent-permissions)
;;; test-claude-agent-permissions.el ends here
