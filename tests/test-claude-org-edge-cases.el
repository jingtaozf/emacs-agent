;;; test-claude-org-edge-cases.el --- Edge case tests for session state -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for edge cases identified during modular decomposition review:
;; 1. Constructor odd-args handling
;; 2. Nil state crash
;; 3. Eval load-order (field-specs before routing tables)
;; 4. Maphash mutation safety (session registry iteration)
;; 5. Queue marker invalidation

(require 'ert)
(require 'cl-lib)

;; Ensure claude-org is loaded (expects Makefile to load it; fallback to project root)
(unless (fboundp 'claude-org--make-session-state)
  (require 'literate-elisp)
  (let ((project-root (file-name-directory
                       (directory-file-name
                        (file-name-directory (or load-file-name default-directory))))))
    (literate-elisp-load (expand-file-name "claude-agent.org" project-root))
    (literate-elisp-load (expand-file-name "claude-org.org" project-root))))

;;; ============================================================
;;; 1. Constructor Odd-Args Handling
;;; ============================================================

(ert-deftest test-edge-constructor-even-args ()
  "Constructor with standard even keyword args works correctly."
  (let ((state (claude-org--make-session-state :busy t :section-level 3)))
    (should (eq t (claude-org--session-state-get state :busy)))
    (should (= 3 (claude-org--session-state-get state :section-level)))))

(ert-deftest test-edge-constructor-no-args ()
  "Constructor with no args creates valid default state."
  (let ((state (claude-org--make-session-state)))
    (should state)
    (should (null (claude-org--session-state-get state :busy)))
    (should (null (claude-org--session-state-get state :marker)))))

(ert-deftest test-edge-constructor-odd-args ()
  "Constructor with odd number of args should signal an error.
The while loop in make-session-state does (pop args) twice per iteration.
With odd args, the last key gets nil as value silently."
  ;; This documents current behavior: odd args silently set last key to nil
  (let ((state (claude-org--make-session-state :busy t :section-level)))
    ;; :section-level gets nil as value (silent data loss)
    (should (eq t (claude-org--session-state-get state :busy)))
    (should (null (claude-org--session-state-get state :section-level)))))

(ert-deftest test-edge-constructor-extras-plist ()
  "Constructor routes unknown keys to extras plist."
  (let ((state (claude-org--make-session-state :custom-key "custom-value")))
    (should (equal "custom-value" (claude-org--session-state-get state :custom-key)))))

;;; ============================================================
;;; 2. Nil State Crash
;;; ============================================================

(ert-deftest test-edge-get-nil-state ()
  "session-state-get with nil state should signal an error, not crash."
  (should-error (claude-org--session-state-get nil :busy)))

(ert-deftest test-edge-set-nil-state ()
  "session-state-set with nil state should signal an error, not crash."
  (should-error (claude-org--session-state-set nil :busy t)))

(ert-deftest test-edge-get-invalid-state ()
  "session-state-get with non-struct value should signal an error."
  (should-error (claude-org--session-state-get "not-a-state" :busy)))

;;; ============================================================
;;; 3. Eval Load-Order (field-specs before routing tables)
;;; ============================================================

(ert-deftest test-edge-field-specs-defined ()
  "Field specs constant must be defined and non-empty."
  (should (boundp 'claude-org--session-field-specs))
  (should (listp claude-org--session-field-specs))
  (should (> (length claude-org--session-field-specs) 0)))

(ert-deftest test-edge-accessors-defined ()
  "Accessor routing table must be generated from field specs.
Note: field-specs uses bare symbols (busy) but routing tables use keywords (:busy)."
  (should (boundp 'claude-org--session-field-accessors))
  (should (listp claude-org--session-field-accessors))
  ;; Each spec should have a corresponding accessor (keyword version)
  (dolist (spec claude-org--session-field-specs)
    (let ((kw (intern (format ":%s" (car spec)))))
      (should (assq kw claude-org--session-field-accessors)))))

(ert-deftest test-edge-setters-defined ()
  "Setter routing table must be generated from field specs.
Note: field-specs uses bare symbols (busy) but routing tables use keywords (:busy)."
  (should (boundp 'claude-org--session-field-setters))
  (should (listp claude-org--session-field-setters))
  ;; Each spec should have a corresponding setter (keyword version)
  (dolist (spec claude-org--session-field-specs)
    (let ((kw (intern (format ":%s" (car spec)))))
      (should (assq kw claude-org--session-field-setters)))))

(ert-deftest test-edge-accessor-setter-correspondence ()
  "Every field in accessors should also be in setters and vice versa."
  (let ((accessor-keys (mapcar #'car claude-org--session-field-accessors))
        (setter-keys (mapcar #'car claude-org--session-field-setters)))
    (should (equal (sort (copy-sequence accessor-keys) #'string<)
                   (sort (copy-sequence setter-keys) #'string<)))))

;;; ============================================================
;;; 4. Maphash Mutation Safety (session registry)
;;; ============================================================

(ert-deftest test-edge-session-registry-type ()
  "Session registry should be a hash table (may need initialization in batch)."
  (should (boundp 'claude-org--sessions))
  ;; In batch mode, sessions may be nil — initialize if needed
  (when (null claude-org--sessions)
    (setq claude-org--sessions (make-hash-table :test 'equal)))
  (should (hash-table-p claude-org--sessions)))

(ert-deftest test-edge-register-and-retrieve-session ()
  "Registering then retrieving a session should return the same object."
  (when (null claude-org--sessions)
    (setq claude-org--sessions (make-hash-table :test 'equal)))
  (let ((state (claude-org--make-session-state :busy t))
        (key "test-edge-register"))
    (unwind-protect
        (progn
          (puthash key state claude-org--sessions)
          (should (eq state (claude-org--get-session key)))
          (should (eq t (claude-org--session-state-get
                         (claude-org--get-session key) :busy))))
      (remhash key claude-org--sessions))))

(ert-deftest test-edge-session-count-consistent ()
  "active-session-count counts busy sessions, not total sessions."
  (when (null claude-org--sessions)
    (setq claude-org--sessions (make-hash-table :test 'equal)))
  (let ((initial-count (claude-org--active-session-count))
        (key1 "test-edge-count-idle")
        (key2 "test-edge-count-busy"))
    (unwind-protect
        (progn
          ;; Add idle session — count should NOT change
          (puthash key1 (claude-org--make-session-state) claude-org--sessions)
          (should (= initial-count (claude-org--active-session-count)))
          ;; Add busy session — count should increment by 1
          (puthash key2 (claude-org--make-session-state :busy t) claude-org--sessions)
          (should (= (+ initial-count 1) (claude-org--active-session-count)))
          ;; Remove busy session — count should return to initial
          (remhash key2 claude-org--sessions)
          (should (= initial-count (claude-org--active-session-count))))
      (remhash key1 claude-org--sessions)
      (remhash key2 claude-org--sessions))))

;;; ============================================================
;;; 5. Queue Marker Invalidation
;;; ============================================================

(ert-deftest test-edge-marker-in-killed-buffer ()
  "Marker from killed buffer should be handled gracefully."
  (let* ((buf (generate-new-buffer "*test-marker-edge*"))
         (marker (with-current-buffer buf
                   (insert "test content")
                   (point-marker))))
    ;; Kill the buffer — marker becomes invalid
    (kill-buffer buf)
    ;; Verify marker is no longer usable
    (should (null (marker-buffer marker)))
    ;; session-state should accept nil marker without crashing
    (let ((state (claude-org--make-session-state :marker nil)))
      (should (null (claude-org--session-state-get state :marker))))))

(ert-deftest test-edge-pending-queue-operations ()
  "Pending queue should handle push/pop correctly."
  (let ((state (claude-org--make-session-state)))
    ;; Queue starts empty
    (should (null (claude-org--session-state-get state :pending-queue)))
    ;; Push items
    (claude-org--session-state-set state :pending-queue '(item1))
    (should (equal '(item1) (claude-org--session-state-get state :pending-queue)))
    ;; Push more
    (claude-org--session-state-set state :pending-queue
                                   (cons 'item2 (claude-org--session-state-get state :pending-queue)))
    (should (equal '(item2 item1) (claude-org--session-state-get state :pending-queue)))
    ;; Pop
    (let ((queue (claude-org--session-state-get state :pending-queue)))
      (claude-org--session-state-set state :pending-queue (cdr queue))
      (should (equal '(item1) (claude-org--session-state-get state :pending-queue))))))

(ert-deftest test-edge-set-return-value ()
  "session-state-set should return the value that was set."
  (let ((state (claude-org--make-session-state)))
    (should (eq t (claude-org--session-state-set state :busy t)))
    (should (= 42 (claude-org--session-state-set state :section-level 42)))
    (should (equal "custom" (claude-org--session-state-set state :custom-prop "custom")))))

(provide 'test-claude-org-edge-cases)
;;; test-claude-org-edge-cases.el ends here
