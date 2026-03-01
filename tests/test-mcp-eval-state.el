;;; test-mcp-eval-state.el --- Tests for MCP evalElisp state protection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: tests

;;; Commentary:

;; TDD tests for emacs-mcp-server--eval-with-state-preservation.
;;
;; Verifies that each evalElisp call runs in full isolation:
;; - Point is restored after eval
;; - Narrowing (restriction) is restored after eval
;; - Window-start (scroll position) is restored after eval
;; - Current buffer is restored after eval
;; - Mark is not polluted
;; - Point restoration uses markers (tracks insertions correctly)

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; Test Helpers

(defmacro test-mcp-eval-state--with-temp-buffer (initial-content &rest body)
  "Create a temp buffer with INITIAL-CONTENT, run BODY in it.
Buffer is killed after BODY completes."
  (declare (indent 1) (debug t))
  `(let ((buf (generate-new-buffer " *test-mcp-eval-state*")))
     (unwind-protect
         (with-current-buffer buf
           (insert ,initial-content)
           (goto-char (point-min))
           ,@body)
       (when (buffer-live-p buf)
         (kill-buffer buf)))))

;;; Tests: Point Preservation

(ert-deftest test-mcp-eval-state-preserves-point ()
  "TDD: Point must be restored to original position after eval."
  :tags '(:unit :fast :stable :tdd :mcp-eval-state)
  (test-mcp-eval-state--with-temp-buffer "abcdefghij"
    (goto-char 5)
    (let ((orig-point (point)))
      (emacs-mcp-server--eval-with-state-preservation
       '(goto-char (point-max)))
      (should (= (point) orig-point)))))

(ert-deftest test-mcp-eval-state-point-tracks-insertion ()
  "TDD: Point restoration must use markers that track text insertion.
If eval inserts text BEFORE the saved point, the restored point should
shift forward by the insertion length (marker behavior), not land inside
the inserted text (absolute position behavior)."
  :tags '(:unit :fast :stable :tdd :mcp-eval-state)
  (test-mcp-eval-state--with-temp-buffer "abcdefghij"
    (goto-char 5)  ; between 'd' and 'e'
    (emacs-mcp-server--eval-with-state-preservation
     '(progn
        (goto-char 1)
        (insert "XYZ")))  ; inserts 3 chars before position 5
    ;; With markers: point should now be at 8 (5 + 3)
    ;; With absolute goto-char: point would be at 5 (inside "XYZ" — wrong)
    (should (= (point) 8))
    ;; Verify the char after point is still 'e' (what was originally there)
    (should (= (char-after (point)) ?e))))

;;; Tests: Narrowing (Restriction) Preservation

(ert-deftest test-mcp-eval-state-preserves-narrowing ()
  "TDD: Buffer narrowing must be restored after eval."
  :tags '(:unit :fast :stable :tdd :mcp-eval-state)
  (test-mcp-eval-state--with-temp-buffer "abcdefghij"
    (narrow-to-region 3 7)
    (let ((orig-min (point-min))
          (orig-max (point-max)))
      (emacs-mcp-server--eval-with-state-preservation
       '(widen))
      (should (= (point-min) orig-min))
      (should (= (point-max) orig-max)))))

(ert-deftest test-mcp-eval-state-preserves-no-narrowing ()
  "TDD: When buffer is NOT narrowed, eval that narrows must not leave narrowing."
  :tags '(:unit :fast :stable :tdd :mcp-eval-state)
  (test-mcp-eval-state--with-temp-buffer "abcdefghij"
    (should-not (buffer-narrowed-p))
    (emacs-mcp-server--eval-with-state-preservation
     '(narrow-to-region 3 7))
    (should-not (buffer-narrowed-p))))

;;; Tests: Current Buffer Preservation

(ert-deftest test-mcp-eval-state-preserves-current-buffer ()
  "TDD: Current buffer must be restored after eval switches buffers."
  :tags '(:unit :fast :stable :tdd :mcp-eval-state)
  (test-mcp-eval-state--with-temp-buffer "content"
    (let ((orig-buffer (current-buffer))
          (other-buffer (generate-new-buffer " *test-other*")))
      (unwind-protect
          (progn
            (emacs-mcp-server--eval-with-state-preservation
             `(set-buffer ,other-buffer))
            (should (eq (current-buffer) orig-buffer)))
        (when (buffer-live-p other-buffer)
          (kill-buffer other-buffer))))))

;;; Tests: Window-Start Preservation

(ert-deftest test-mcp-eval-state-preserves-window-start ()
  "TDD: Window-start (scroll position) must be restored after eval."
  :tags '(:unit :fast :stable :tdd :mcp-eval-state)
  ;; This test requires a real window, so only run if we have one
  (let ((buf (generate-new-buffer " *test-window-start*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            ;; Insert enough lines to make scrolling meaningful
            (dotimes (i 200)
              (insert (format "line %d\n" i))))
          ;; Display buffer in a window
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            ;; Scroll down to line 100
            (goto-char (point-min))
            (forward-line 100)
            (set-window-start (selected-window) (point) t)
            (let ((orig-window-start (window-start (selected-window))))
              ;; Eval code that scrolls to top
              (emacs-mcp-server--eval-with-state-preservation
               '(progn
                  (goto-char (point-min))
                  (set-window-start (selected-window) (point-min) t)))
              ;; Window-start should be restored
              (should (= (window-start (selected-window)) orig-window-start)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; Tests: Mark Preservation

(ert-deftest test-mcp-eval-state-preserves-mark ()
  "TDD: Mark position must be preserved after eval that uses search."
  :tags '(:unit :fast :stable :tdd :mcp-eval-state)
  (test-mcp-eval-state--with-temp-buffer "hello world foo bar"
    (set-mark 3)
    (let ((orig-mark (mark t)))
      (emacs-mcp-server--eval-with-state-preservation
       '(progn
          (goto-char (point-min))
          (re-search-forward "foo" nil t)))
      (should (= (mark t) orig-mark)))))

;;; Tests: Tool Description

(ert-deftest test-mcp-eval-state-description-mentions-isolation ()
  "TDD: Tool description must inform agent that context resets between calls."
  :tags '(:unit :fast :stable :tdd :mcp-eval-state)
  (let ((tool (cl-find-if (lambda (t) (equal (alist-get 'name t) "evalElisp"))
                          emacs-mcp-server--builtin-tools)))
    (should tool)
    (let ((desc (alist-get 'description tool)))
      ;; Description must mention that state doesn't persist between calls
      (should (string-match-p "isolated\\|isolation\\|does NOT persist\\|not persist" desc)))))

(ert-deftest test-mcp-eval-state-param-description-mentions-narrowing ()
  "TDD: save_current_state param description must mention narrowing protection."
  :tags '(:unit :fast :stable :tdd :mcp-eval-state)
  (let* ((tool (cl-find-if (lambda (t) (equal (alist-get 'name t) "evalElisp"))
                           emacs-mcp-server--builtin-tools))
         (schema (alist-get 'inputSchema tool))
         (props (alist-get 'properties schema))
         (save-state-prop (alist-get 'save_current_state props))
         (desc (alist-get 'description save-state-prop)))
    (should (string-match-p "narrow" desc))))

(provide 'test-mcp-eval-state)
;;; test-mcp-eval-state.el ends here
