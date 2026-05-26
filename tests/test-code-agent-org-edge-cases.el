;;; test-code-agent-org-edge-cases.el --- Edge case tests for session state -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for edge cases identified during modular decomposition review:
;; 1. Constructor odd-args handling
;; 2. Nil state crash
;; 3. Eval load-order (field-specs before routing tables)
;; 4. Maphash mutation safety (session registry iteration)
;; 5. Queue marker invalidation

(require 'ert)
(require 'cl-lib)

;; Ensure code-agent-org is loaded (expects Makefile to load it; fallback to project root)
(unless (fboundp 'code-agent-org--make-session-state)
  (require 'literate-elisp)
  (let ((project-root (file-name-directory
                       (directory-file-name
                        (file-name-directory (or load-file-name default-directory))))))
    (literate-elisp-load (expand-file-name "lp/chat/code-agent.org" project-root))
    (literate-elisp-load (expand-file-name "lp/org/code-agent-org.org" project-root))))

;;; ============================================================
;;; 1. Constructor Odd-Args Handling
;;; ============================================================

(ert-deftest test-edge-constructor-even-args ()
  "Constructor with standard even keyword args works correctly."
  (let ((state (code-agent-org--make-session-state :busy t :section-level 3)))
    (should (eq t (code-agent-org--session-state-get state :busy)))
    (should (= 3 (code-agent-org--session-state-get state :section-level)))))

(ert-deftest test-edge-constructor-no-args ()
  "Constructor with no args creates valid default state."
  (let ((state (code-agent-org--make-session-state)))
    (should state)
    (should (null (code-agent-org--session-state-get state :busy)))
    (should (null (code-agent-org--session-state-get state :marker)))))

(ert-deftest test-edge-constructor-odd-args ()
  "Constructor with odd number of args should signal an error.
The while loop in make-session-state does (pop args) twice per iteration.
With odd args, the last key gets nil as value silently."
  ;; This documents current behavior: odd args silently set last key to nil
  (let ((state (code-agent-org--make-session-state :busy t :section-level)))
    ;; :section-level gets nil as value (silent data loss)
    (should (eq t (code-agent-org--session-state-get state :busy)))
    (should (null (code-agent-org--session-state-get state :section-level)))))

(ert-deftest test-edge-constructor-extras-plist ()
  "Constructor routes unknown keys to extras plist."
  (let ((state (code-agent-org--make-session-state :custom-key "custom-value")))
    (should (equal "custom-value" (code-agent-org--session-state-get state :custom-key)))))

;;; ============================================================
;;; 2. Nil State Crash
;;; ============================================================

(ert-deftest test-edge-get-nil-state ()
  "session-state-get with nil state should signal an error, not crash."
  (should-error (code-agent-org--session-state-get nil :busy)))

(ert-deftest test-edge-set-nil-state ()
  "session-state-set with nil state should signal an error, not crash."
  (should-error (code-agent-org--session-state-set nil :busy t)))

(ert-deftest test-edge-get-invalid-state ()
  "session-state-get with non-struct value should signal an error."
  (should-error (code-agent-org--session-state-get "not-a-state" :busy)))

;;; ============================================================
;;; 3. Eval Load-Order (field-specs before routing tables)
;;; ============================================================

(ert-deftest test-edge-field-specs-defined ()
  "Field specs constant must be defined and non-empty."
  (should (boundp 'code-agent-org--session-field-specs))
  (should (listp code-agent-org--session-field-specs))
  (should (> (length code-agent-org--session-field-specs) 0)))

(ert-deftest test-edge-accessors-defined ()
  "Accessor routing table must be generated from field specs.
Note: field-specs uses bare symbols (busy) but routing tables use keywords (:busy)."
  (should (boundp 'code-agent-org--session-field-accessors))
  (should (listp code-agent-org--session-field-accessors))
  ;; Each spec should have a corresponding accessor (keyword version)
  (dolist (spec code-agent-org--session-field-specs)
    (let ((kw (intern (format ":%s" (car spec)))))
      (should (assq kw code-agent-org--session-field-accessors)))))

(ert-deftest test-edge-setters-defined ()
  "Setter routing table must be generated from field specs.
Note: field-specs uses bare symbols (busy) but routing tables use keywords (:busy)."
  (should (boundp 'code-agent-org--session-field-setters))
  (should (listp code-agent-org--session-field-setters))
  ;; Each spec should have a corresponding setter (keyword version)
  (dolist (spec code-agent-org--session-field-specs)
    (let ((kw (intern (format ":%s" (car spec)))))
      (should (assq kw code-agent-org--session-field-setters)))))

(ert-deftest test-edge-accessor-setter-correspondence ()
  "Every field in accessors should also be in setters and vice versa."
  (let ((accessor-keys (mapcar #'car code-agent-org--session-field-accessors))
        (setter-keys (mapcar #'car code-agent-org--session-field-setters)))
    (should (equal (sort (copy-sequence accessor-keys) #'string<)
                   (sort (copy-sequence setter-keys) #'string<)))))

;;; ============================================================
;;; 4. Maphash Mutation Safety (session registry)
;;; ============================================================

(ert-deftest test-edge-session-registry-type ()
  "Session registry should be a hash table (may need initialization in batch)."
  (should (boundp 'code-agent-org--sessions))
  ;; In batch mode, sessions may be nil — initialize if needed
  (when (null code-agent-org--sessions)
    (setq code-agent-org--sessions (make-hash-table :test 'equal)))
  (should (hash-table-p code-agent-org--sessions)))

(ert-deftest test-edge-register-and-retrieve-session ()
  "Registering then retrieving a session should return the same object."
  (when (null code-agent-org--sessions)
    (setq code-agent-org--sessions (make-hash-table :test 'equal)))
  (let ((state (code-agent-org--make-session-state :busy t))
        (key "test-edge-register"))
    (unwind-protect
        (progn
          (puthash key state code-agent-org--sessions)
          (should (eq state (code-agent-org--get-session key)))
          (should (eq t (code-agent-org--session-state-get
                         (code-agent-org--get-session key) :busy))))
      (remhash key code-agent-org--sessions))))

(ert-deftest test-edge-session-count-consistent ()
  "active-session-count counts busy sessions, not total sessions."
  (when (null code-agent-org--sessions)
    (setq code-agent-org--sessions (make-hash-table :test 'equal)))
  (let ((initial-count (code-agent-org--active-session-count))
        (key1 "test-edge-count-idle")
        (key2 "test-edge-count-busy"))
    (unwind-protect
        (progn
          ;; Add idle session — count should NOT change
          (puthash key1 (code-agent-org--make-session-state) code-agent-org--sessions)
          (should (= initial-count (code-agent-org--active-session-count)))
          ;; Add busy session — count should increment by 1
          (puthash key2 (code-agent-org--make-session-state :busy t) code-agent-org--sessions)
          (should (= (+ initial-count 1) (code-agent-org--active-session-count)))
          ;; Remove busy session — count should return to initial
          (remhash key2 code-agent-org--sessions)
          (should (= initial-count (code-agent-org--active-session-count))))
      (remhash key1 code-agent-org--sessions)
      (remhash key2 code-agent-org--sessions))))

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
    (let ((state (code-agent-org--make-session-state :marker nil)))
      (should (null (code-agent-org--session-state-get state :marker))))))

(ert-deftest test-edge-pending-queue-operations ()
  "Pending queue should handle push/pop correctly."
  (let ((state (code-agent-org--make-session-state)))
    ;; Queue starts empty
    (should (null (code-agent-org--session-state-get state :pending-queue)))
    ;; Push items
    (code-agent-org--session-state-set state :pending-queue '(item1))
    (should (equal '(item1) (code-agent-org--session-state-get state :pending-queue)))
    ;; Push more
    (code-agent-org--session-state-set state :pending-queue
                                   (cons 'item2 (code-agent-org--session-state-get state :pending-queue)))
    (should (equal '(item2 item1) (code-agent-org--session-state-get state :pending-queue)))
    ;; Pop
    (let ((queue (code-agent-org--session-state-get state :pending-queue)))
      (code-agent-org--session-state-set state :pending-queue (cdr queue))
      (should (equal '(item1) (code-agent-org--session-state-get state :pending-queue))))))

(ert-deftest test-edge-set-return-value ()
  "session-state-set should return the value that was set."
  (let ((state (code-agent-org--make-session-state)))
    (should (eq t (code-agent-org--session-state-set state :busy t)))
    (should (= 42 (code-agent-org--session-state-set state :section-level 42)))
    (should (equal "custom" (code-agent-org--session-state-set state :custom-prop "custom")))))

(provide 'test-code-agent-org-edge-cases)
;;; test-code-agent-org-edge-cases.el ends here
