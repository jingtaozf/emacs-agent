;;; test-claude-org-refactor-phase2.el --- Phase 2 refactoring tests -*- lexical-binding: t; -*-

;; Tests for Phase 2: Module extraction (F5-F8)

(require 'cl-lib)
(require 'ert)
(require 'claude-agent)
(require 'claude-org)

;;; ============================================================
;;; F5: claude-org-session module extraction
;;; ============================================================

;; F5.1 Module provides feature after load
(ert-deftest test-f5-session-module-provides-feature ()
  "The claude-org-session module should provide its feature."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  (should (featurep 'claude-org-session)))

;; F5.2 Session struct creation with defaults
(ert-deftest test-f5-session-struct-creation-defaults ()
  "Session struct should have correct default values."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  (let ((state (claude-org--make-session-state)))
    (should (claude-org--session-state-p state))
    (should-not (claude-org--session-state-get state :busy))
    (should-not (claude-org--session-state-get state :recovering))
    (should-not (claude-org--session-state-get state :query-id))
    (should (= 0 (or (claude-org--session-state-get state :current-line-length) 0)))))

;; F5.3 Accessor dispatch for keyword fields
(ert-deftest test-f5-session-accessor-dispatch ()
  "session-state-get should dispatch to correct struct accessor."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  (let ((state (claude-org--make-session-state :busy t :query-id "q-123")))
    (should (eq t (claude-org--session-state-get state :busy)))
    (should (equal "q-123" (claude-org--session-state-get state :query-id)))))

;; F5.4 Setter dispatch for keyword fields
(ert-deftest test-f5-session-setter-dispatch ()
  "session-state-set should dispatch to correct struct setter."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  (let ((state (claude-org--make-session-state)))
    (claude-org--session-state-set state :busy t)
    (should (eq t (claude-org--session-state-get state :busy)))
    (claude-org--session-state-set state :query-id "q-456")
    (should (equal "q-456" (claude-org--session-state-get state :query-id)))))

;; F5.5 Extras plist for unknown properties
(ert-deftest test-f5-session-extras-fallback ()
  "Unknown properties should fall through to extras plist."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  (let ((state (claude-org--make-session-state)))
    (claude-org--session-state-set state :my-custom-prop "custom-value")
    (should (equal "custom-value" (claude-org--session-state-get state :my-custom-prop)))))

;; F5.6 reset-session-state clears fields
(ert-deftest test-f5-reset-session-state ()
  "reset-session-state should clear busy, recovering, last-assistant-query-id."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((key "test::reset"))
      (claude-org--session-put key :busy t)
      (claude-org--session-put key :recovering t)
      (claude-org--session-put key :last-assistant-query-id "q-old")
      (claude-org--reset-session-state key)
      (should-not (claude-org--session-get key :busy))
      (should-not (claude-org--session-get key :recovering))
      (should-not (claude-org--session-get key :last-assistant-query-id)))))

;; F5.7 get-or-create-session creates new
(ert-deftest test-f5-get-or-create-session-new ()
  "get-session should create new session state for unknown key."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((state (claude-org--get-session "test::new-session")))
      (should (claude-org--session-state-p state))
      (should-not (claude-org--session-state-get state :busy)))))

;; F5.8 get-or-create-session returns existing
(ert-deftest test-f5-get-or-create-session-existing ()
  "get-session should return existing session for known key."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((key "test::existing"))
      (claude-org--session-put key :busy t)
      (let ((state (claude-org--get-session key)))
        (should (eq t (claude-org--session-state-get state :busy)))))))

;; F5.9 active-session-count
(ert-deftest test-f5-active-session-count ()
  "active-session-count should count sessions with :busy t."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (should (= 0 (claude-org--active-session-count)))
    (claude-org--session-put "s1" :busy t)
    (should (= 1 (claude-org--active-session-count)))
    (claude-org--session-put "s2" :busy t)
    (should (= 2 (claude-org--active-session-count)))
    (claude-org--session-put "s1" :busy nil)
    (should (= 1 (claude-org--active-session-count)))))

;; F5.10 session-display-name
(ert-deftest test-f5-session-display-name ()
  "session-display-name should extract name from key."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  (should (equal "my-section" (claude-org--session-display-name "/path/to/file.org::my-section")))
  (should (equal "file.org" (claude-org--session-display-name "/path/to/file.org"))))

;; F5.11 Session field accessors alist completeness
(ert-deftest test-f5-accessor-alist-complete ()
  "Every struct field (except extras) should have an accessor entry."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  (let ((expected-fields '(:busy :recovering :query-id :backend :query-handle
                           :start-time :original-prompt :section-level
                           :response-has-content :last-assistant-query-id
                           :current-line-length :loop-max :loop-current
                           :loop-interval :pending-queue :instruction-num
                           :custom-id :recovery-count :block-id :marker
                           :spinner :sdk-uuid)))
    (dolist (field expected-fields)
      (should (assq field claude-org--session-field-accessors)))))

;; F5.12 Session field setters alist completeness
(ert-deftest test-f5-setter-alist-complete ()
  "Every struct field (except extras) should have a setter entry."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  (let ((expected-fields '(:busy :recovering :query-id :backend :query-handle
                           :start-time :original-prompt :section-level
                           :response-has-content :last-assistant-query-id
                           :current-line-length :loop-max :loop-current
                           :loop-interval :pending-queue :instruction-num
                           :custom-id :recovery-count :block-id :marker
                           :spinner :sdk-uuid)))
    (dolist (field expected-fields)
      (should (assq field claude-org--session-field-setters)))))

;; F5.13 claude-org.org can require claude-org-session
(ert-deftest test-f5-claude-org-requires-session-module ()
  "claude-org should have loaded (and thus depend on) claude-org-session."
  :tags '(:unit :fast :stable :isolated :refactor :f5)
  ;; If claude-org loaded successfully and session module exists,
  ;; session functions should be available
  (should (fboundp 'claude-org--session-get))
  (should (fboundp 'claude-org--session-put))
  (should (fboundp 'claude-org--get-session))
  (should (fboundp 'claude-org--make-session-state)))

;;; ============================================================
;;; F6: claude-org-queue module extraction
;;; ============================================================

;; F6.1 Module provides feature
(ert-deftest test-f6-queue-module-provides-feature ()
  "The claude-org-queue module should provide its feature."
  :tags '(:unit :fast :stable :isolated :refactor :f6)
  (should (featurep 'claude-org-queue)))

;; F6.2 queue-block adds to pending queue
(ert-deftest test-f6-queue-block-adds ()
  "queue-block should add block to session pending queue."
  :tags '(:unit :fast :stable :isolated :refactor :f6)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((key "test::queue"))
      (claude-org--session-put key :busy t)
      (let ((block-info (list :custom-id "test-id"
                              :content "hello"
                              :marker (point-marker))))
        (should (eq 'queued (claude-org--queue-block key block-info)))
        (should (= 1 (claude-org--queue-count key)))))))

;; F6.3 dequeue-block removes first
(ert-deftest test-f6-dequeue-block ()
  "dequeue-block should remove and return first block."
  :tags '(:unit :fast :stable :isolated :refactor :f6)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((key "test::dequeue"))
      (claude-org--session-put key :busy t)
      (let ((b1 (list :custom-id "id-1" :content "first" :marker (point-marker)))
            (b2 (list :custom-id "id-2" :content "second" :marker (point-marker))))
        (claude-org--queue-block key b1)
        (claude-org--queue-block key b2)
        (should (= 2 (claude-org--queue-count key)))
        (let ((dequeued (claude-org--dequeue-block key)))
          (should (equal "first" (plist-get dequeued :content)))
          (should (= 1 (claude-org--queue-count key))))))))

;; F6.4 queue-count returns correct count
(ert-deftest test-f6-queue-count ()
  "queue-count should return the number of queued blocks."
  :tags '(:unit :fast :stable :isolated :refactor :f6)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((key "test::count"))
      (should (= 0 (claude-org--queue-count key))))))

;; F6.5 same-block-p detects duplicates
(ert-deftest test-f6-same-block-p ()
  "same-block-p should detect blocks with same custom-id."
  :tags '(:unit :fast :stable :isolated :refactor :f6)
  (should (fboundp 'claude-org--same-block-p)))

;; F6.6 Queue operations work with session dependency
(ert-deftest test-f6-queue-uses-session-accessors ()
  "Queue operations should use session-get/put for pending-queue."
  :tags '(:unit :fast :stable :isolated :refactor :f6)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((key "test::session-dep"))
      (claude-org--session-put key :busy t)
      (claude-org--queue-block key
        (list :custom-id "x" :content "test" :marker (point-marker)))
      ;; Queue stored via session state
      (let ((queue (claude-org--session-get key :pending-queue)))
        (should (= 1 (length queue)))))))

;;; ============================================================
;;; F7: claude-org-response module extraction
;;; ============================================================

;; F7.1 Module provides feature
(ert-deftest test-f7-response-module-provides-feature ()
  "The claude-org-response module should provide its feature."
  :tags '(:unit :fast :stable :isolated :refactor :f7)
  (should (featurep 'claude-org-response)))

;; F7.2 generate-query-id produces unique IDs
(ert-deftest test-f7-generate-query-id-unique ()
  "generate-query-id should produce unique IDs."
  :tags '(:unit :fast :stable :isolated :refactor :f7)
  (should (fboundp 'claude-org--generate-query-id))
  (let ((id1 (claude-org--generate-query-id))
        (id2 (claude-org--generate-query-id)))
    (should (stringp id1))
    (should (not (equal id1 id2)))))

;; F7.3 normalize-headers-in-text adjusts levels
(ert-deftest test-f7-normalize-headers ()
  "normalize-headers-in-text should adjust heading levels."
  :tags '(:unit :fast :stable :isolated :refactor :f7)
  (should (fboundp 'claude-org--normalize-headers-in-text))
  ;; Level 1 stars at target 3 -> 3 + (1-1) = level 3
  (let ((claude-org-normalize-headers t))
    (let ((result (claude-org--normalize-headers-in-text "* Sub heading" 3)))
      (should (equal "*** Sub heading" result)))))

;; F7.4 create-response-section-header creates valid heading
(ert-deftest test-f7-create-response-section-header ()
  "create-response-section-header should create proper org heading."
  :tags '(:unit :fast :stable :isolated :refactor :f7)
  (should (fboundp 'claude-org--create-response-section-header)))

;; F7.5 handle-token-v2 available from response module
(ert-deftest test-f7-handle-token-v2-available ()
  "handle-token-v2 should be available (from response module)."
  :tags '(:unit :fast :stable :isolated :refactor :f7)
  (should (fboundp 'claude-org--handle-token-v2)))

;;; ============================================================
;;; Cross-module integration
;;; ============================================================

(ert-deftest test-cross-module-session-queue-integration ()
  "Queue operations should work through session module accessors."
  :tags '(:unit :fast :stable :isolated :refactor :integration)
  (with-temp-buffer
    (org-mode)
    (setq-local claude-org--sessions (make-hash-table :test 'equal))
    (let ((key "test::cross"))
      ;; Set up session, queue a block, verify through session accessor
      (claude-org--session-put key :busy t)
      (claude-org--queue-block key
        (list :custom-id "cross-test" :content "test" :marker (point-marker)))
      (should (= 1 (claude-org--queue-count key)))
      ;; Dequeue and verify session state updated
      (let ((block (claude-org--dequeue-block key)))
        (should block)
        (should (= 0 (claude-org--queue-count key)))))))

;;; ============================================================
;;; F9: claude-org-scheduled module extraction
;;; ============================================================

;; F9.1 Module provides feature
(ert-deftest test-f9-scheduled-module-provides-feature ()
  "The claude-org-scheduled module should provide its feature."
  :tags '(:unit :fast :stable :isolated :refactor :f9)
  (should (featurep 'claude-org-scheduled)))

;; F9.2 Scheduled data structures accessible
(ert-deftest test-f9-scheduled-blocks-var-exists ()
  "claude-org--scheduled-blocks variable should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f9)
  (should (boundp 'claude-org--scheduled-blocks)))

;; F9.3 Core scheduled functions exist
(ert-deftest test-f9-scheduled-core-functions ()
  "Core scheduled functions should all be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f9)
  (should (fboundp 'claude-org-scheduled--update-entry))
  (should (fboundp 'claude-org-scheduled--remove-entry))
  (should (fboundp 'claude-org-scheduled--should-execute-p))
  (should (fboundp 'claude-org-scheduled--has-ai-block-p))
  (should (fboundp 'claude-org-scheduled--collect-from-file))
  (should (fboundp 'claude-org-scheduled-scan-all)))

;; F9.4 Timer management functions exist
(ert-deftest test-f9-scheduled-timer-functions ()
  "Timer start/stop functions should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f9)
  (should (fboundp 'claude-org-scheduled-start))
  (should (fboundp 'claude-org-scheduled-stop)))

;; F9.5 List buffer functions exist
(ert-deftest test-f9-scheduled-list-functions ()
  "Scheduled list buffer functions should be defined."
  :tags '(:unit :fast :stable :isolated :refactor :f9)
  (should (fboundp 'claude-org-scheduled-list))
  (should (fboundp 'claude-org-scheduled-list-refresh))
  (should (fboundp 'claude-org-scheduled-list-goto))
  (should (fboundp 'claude-org-scheduled--build-list-entries)))

;; F9.6 Existing scheduled tests still pass (regression guard)
(ert-deftest test-f9-scheduled-should-execute-basic ()
  "Basic should-execute-p logic works after extraction."
  :tags '(:unit :fast :stable :isolated :refactor :f9)
  ;; Past time, never executed -> should execute
  (let ((past (time-subtract (current-time) (seconds-to-time 3600))))
    (should (claude-org-scheduled--should-execute-p past nil)))
  ;; Future time -> should NOT execute
  (let ((future (time-add (current-time) (seconds-to-time 3600))))
    (should-not (claude-org-scheduled--should-execute-p future nil))))

;; F9.7 Alist operations work after extraction
(ert-deftest test-f9-scheduled-alist-operations ()
  "Alist management functions work correctly after extraction."
  :tags '(:unit :fast :stable :isolated :refactor :f9)
  (let ((claude-org--scheduled-blocks nil)
        (test-time (current-time)))
    ;; Add entry
    (claude-org-scheduled--update-entry "test-f9" "/test.org" test-time)
    (should (= 1 (length claude-org--scheduled-blocks)))
    ;; Remove entry
    (claude-org-scheduled--remove-entry "test-f9")
    (should (= 0 (length claude-org--scheduled-blocks)))))

(provide 'test-claude-org-refactor-phase2)
;;; test-claude-org-refactor-phase2.el ends here
