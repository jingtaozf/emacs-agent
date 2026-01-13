---
name: emacs-async
description: Use when writing async elisp code with callbacks, timers, or process filters - provides patterns for safe cursor-position handling and state preservation
---

# Emacs Async Elisp Patterns

## The Cursor Position Problem

Many Emacs functions depend on the current cursor position (point). When writing async code
(callbacks, timers, process filters), the cursor may have moved since the async operation started.

### Cursor-Dependent Functions (DANGER in async contexts)

These functions use `nil` to mean "current position" and will return wrong results if cursor moved:

```elisp
;; Org-mode functions that depend on cursor position
(org-entry-get nil "PROPERTY" t)     ; Gets property at CURRENT point
(org-entry-put nil "PROPERTY" "val") ; Sets property at CURRENT point
(org-get-tags nil t)                 ; Gets tags at CURRENT point
(org-at-heading-p)                   ; Checks if CURRENT point is at heading
(org-back-to-heading t)              ; Goes to heading containing CURRENT point
(org-current-level)                  ; Level of heading at CURRENT point

;; General Emacs functions
(point)                              ; Current cursor position
(current-buffer)                     ; May not be the expected buffer
(buffer-substring beg end)           ; If beg/end are relative to wrong point
```

## Pattern: Use Markers for Async Operations

Markers track buffer positions even as text is inserted/deleted:

```elisp
;; GOOD: Capture marker at start, use in callback
(defun my-async-operation ()
  (let ((marker (point-marker)))  ; Capture position NOW
    (my-start-process
     :on-complete (lambda (result)
                    (when (marker-buffer marker)  ; Check buffer still exists
                      (with-current-buffer (marker-buffer marker)
                        (save-excursion
                          (goto-char marker)
                          ;; Now org-entry-get etc. work correctly
                          (org-entry-get nil "PROPERTY" t))))))))
```

## Pattern: Pass Session/Context Keys Explicitly

Don't recalculate context in callbacks - pass it from the original call:

```elisp
;; BAD: Recalculates session-key in callback (cursor may have moved!)
(defun bad-send-request (prompt)
  (start-async-process prompt
    :on-complete (lambda (result)
                   ;; DANGER: This calculates from CURRENT cursor position
                   (let ((session-key (get-session-key-from-cursor)))
                     (handle-result session-key result)))))

;; GOOD: Capture session-key upfront, pass to callback
(defun good-send-request (prompt)
  (let ((session-key (get-session-key-from-cursor)))  ; Capture NOW
    (start-async-process prompt
      :on-complete (lambda (result)
                     ;; Uses the captured session-key, not current cursor
                     (handle-result session-key result)))))
```

## Pattern: lexical-let for Variable Capture

Use `lexical-let` (or lexical binding) to capture variables for callbacks:

```elisp
(require 'cl-lib)

(defun my-operation ()
  (let ((session-key (calculate-session-key))
        (marker (point-marker)))
    ;; lexical-let ensures these are captured, not dynamic lookup
    (lexical-let ((session-key session-key)
                  (marker marker))
      (run-at-time 5 nil
                   (lambda ()
                     ;; session-key and marker have correct values here
                     (process-with-context session-key marker))))))
```

## Pattern: Chain Functions Must Pass Context

When function A calls function B from an async context, B must receive context explicitly:

```elisp
;; BAD: handle-error recalculates context
(defun handle-error (error)
  (let ((session-key (get-session-from-cursor)))  ; WRONG in async!
    (recover-session session-key)))

;; GOOD: handle-error receives session-key from caller
(defun handle-error (session-key error)
  (recover-session session-key))

;; Callback passes session-key through the chain
:on-error (lambda (err)
            (handle-error session-key err))
```

## Pattern: Position Cursor Before Calling Dependent Functions

When you must call cursor-dependent functions in async context:

```elisp
(defun async-handler (session-key)
  (let ((marker (get-session-marker session-key)))
    (when (and marker (marker-buffer marker))
      (with-current-buffer (marker-buffer marker)
        ;; Position cursor BEFORE calling org-entry-get
        (save-excursion
          (goto-char marker)
          ;; NOW these functions work correctly
          (let ((prop (org-entry-get nil "PROPERTY" t))
                (tags (org-get-tags nil t)))
            (process-data prop tags)))))))
```

## Checklist for Async Code Review

When reviewing elisp code with async operations, check:

1. **Marker Usage**: Are positions captured as markers before async starts?
2. **Context Passing**: Is session-key/context passed explicitly to callbacks?
3. **Buffer Validation**: Does callback check `(marker-buffer marker)` before use?
4. **Cursor Positioning**: Before `org-entry-get` etc., is cursor positioned with `goto-char`?
5. **Variable Capture**: Are variables properly captured with lexical binding?

## Common Async Entry Points

Watch for cursor-position bugs in code called from:

- `:on-complete`, `:on-error`, `:on-token` callbacks
- `run-at-time`, `run-with-timer` functions
- Process filters (`set-process-filter`)
- Process sentinels (`set-process-sentinel`)
- `url-retrieve` callbacks
- `async-start` callbacks
- Hook functions that may run async

## Real-World Example: Loop Iteration Fix

Before (BUG - cursor may have moved during loop):
```elisp
(defun execute-loop-iteration (...)
  ;; Called via run-at-time, cursor position unknown
  (let ((session-key (get-key-from-cursor)))  ; WRONG!
    (send-request prompt query-ctx)))
```

After (FIXED - uses captured session-key):
```elisp
(defun execute-loop-iteration (session-key ...)
  ;; session-key passed explicitly from original call
  (let ((marker (get-session-marker session-key)))
    (when (marker-buffer marker)
      (with-current-buffer (marker-buffer marker)
        (send-request prompt query-ctx session-key)))))
```

## Testing Async Code

Unit tests should verify:

1. Functions accept explicit context parameters
2. Callbacks don't recalculate cursor-dependent values
3. Marker-buffer is checked before use

```elisp
(ert-deftest test-callback-uses-explicit-session-key ()
  "Verify callback doesn't recalculate session-key."
  (let ((fn-str (format "%s" (symbol-function 'my-callback))))
    ;; Should NOT contain cursor-dependent calculation
    (should-not (string-match "get-key-from-cursor" fn-str))
    ;; Should use explicit session-key parameter
    (should (string-match "session-key" fn-str))))
```
