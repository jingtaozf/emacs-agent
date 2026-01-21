---
name: emacs-best-practices
description: Best practices for writing reliable Emacs Lisp code - covers data persistence, print settings, Common Lisp compatibility, and common pitfalls
allowed-tools: [mcp__emacs__evalElisp]
---

# Emacs Lisp Best Practices

This skill provides essential patterns for writing reliable, bug-free Emacs Lisp code.

## When to Use This Skill

Use when:
- Persisting Lisp data to files
- Printing/serializing data structures
- Working with Common Lisp compatibility layer
- Debugging mysterious data corruption
- Writing production-quality elisp

## Data Persistence: Print Settings

### The Print-Length Trap

**Problem**: Data gets corrupted when read back due to truncation.

```elisp
;; WRONG - may truncate data with "..." which corrupts on read-back
(pp my-data (current-buffer))

;; CORRECT - ensures complete output
(let ((print-length nil)
      (print-level nil))
  (pp my-data (current-buffer)))
```

**Why**: When `print-length` is set (common in user configs), lists get truncated
with `...` which becomes the symbol `\.\.\.' when read back, corrupting data.

### Safe Data Persistence

```elisp
(defun save-data-safely (data file)
  "Save DATA to FILE without truncation."
  (with-temp-file file
    (insert ";; -*- mode: lisp-data -*-\n")
    (let ((print-length nil)      ; No list truncation
          (print-level nil)       ; No depth truncation
          (print-quoted t)        ; Use 'foo not (quote foo)
          (print-circle t))       ; Handle circular refs
      (pp data (current-buffer)))))

(defun load-data-safely (file)
  "Load data from FILE."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (read (current-buffer)))))
```

### Print Variables Reference

| Variable | Purpose | Safe Value |
|----------|---------|------------|
| `print-length` | Max list elements | `nil` (unlimited) |
| `print-level` | Max nesting depth | `nil` (unlimited) |
| `print-circle` | Handle circular refs | `t` if possible |
| `print-quoted` | Use 'x vs (quote x) | `t` for readability |
| `print-escape-newlines` | Escape \\n in strings | Context-dependent |

## Common Lisp Compatibility

### CL-Lib Best Practices

```elisp
;; Always require cl-lib, not cl
(require 'cl-lib)

;; Use cl- prefixed functions
(cl-loop for i from 1 to 10 collect (* i i))
(cl-remove-if-not #'evenp '(1 2 3 4 5))
(cl-destructuring-bind (a b &rest c) '(1 2 3 4) ...)
```

### Common CL Gotchas

```elisp
;; WRONG: cl-loop variable scope
(cl-loop for item in list
         do (push (lambda () item) funcs))  ; All lambdas share same 'item'!

;; CORRECT: Capture variable
(cl-loop for item in list
         do (let ((captured item))
              (push (lambda () captured) funcs)))

;; WRONG: Modifying list while iterating
(cl-loop for item in my-list
         when (should-remove-p item)
         do (setq my-list (delete item my-list)))  ; Undefined behavior!

;; CORRECT: Collect items to keep
(setq my-list (cl-remove-if #'should-remove-p my-list))
```

## Avoiding Common Pitfalls

### Equality Testing

```elisp
;; Numeric comparison
(= 1 1.0)       ; t - numeric equality
(eql 1 1.0)     ; nil - same type required
(eq 1 1)        ; UNRELIABLE for numbers!

;; String comparison
(equal "a" "a")     ; t - content equality
(eq "a" "a")        ; UNRELIABLE - depends on interning
(string= "a" "a")   ; t - explicit string comparison

;; Symbol comparison
(eq 'foo 'foo)      ; t - symbols are interned

;; List comparison
(equal '(1 2) '(1 2))  ; t - structural equality
(eq '(1 2) '(1 2))     ; nil - different cons cells
```

### Safe Defaults

```elisp
;; Always use lexical binding
;; -*- lexical-binding: t -*-

;; Prefer explicit nil checks
(when x ...)           ; Ok if nil is "false"
(when (not (null x)) ...) ; Explicit nil check

;; Safe alist access
(alist-get key alist)           ; Returns nil if missing
(alist-get key alist 'default)  ; Returns default if missing

;; Safe plist access  
(plist-get plist :key)          ; Returns nil if missing
```

### Buffer Safety

```elisp
;; Always check buffer exists
(when (buffer-live-p buffer)
  (with-current-buffer buffer
    ...))

;; Clean up temp buffers
(let ((temp-buf (generate-new-buffer " *temp*")))
  (unwind-protect
      (with-current-buffer temp-buf
        ...)
    (kill-buffer temp-buf)))

;; Or use with-temp-buffer
(with-temp-buffer
  ...)  ; Auto-cleaned up
```

## Performance Patterns

### Avoid Repeated Computation

```elisp
;; SLOW: Repeated length calculation
(dotimes (i (length long-list))
  (process (nth i long-list)))

;; FAST: Single traversal
(dolist (item long-list)
  (process item))

;; FAST: With index if needed
(cl-loop for item in long-list
         for i from 0
         do (process-with-index i item))
```

### String Building

```elisp
;; SLOW: Repeated concatenation
(let ((result ""))
  (dolist (item items)
    (setq result (concat result item))))

;; FAST: Collect and join
(mapconcat #'identity items "")

;; FAST: Use buffer for complex building
(with-temp-buffer
  (dolist (item items)
    (insert item))
  (buffer-string))
```

## Defensive Coding

### Input Validation

```elisp
(defun my-function (string-arg list-arg)
  "Process STRING-ARG and LIST-ARG."
  (cl-check-type string-arg string)
  (cl-check-type list-arg list)
  ;; Now safe to proceed
  ...)
```

### Error Messages

```elisp
;; Provide context in errors
(unless (file-exists-p file)
  (error "File not found: %s" file))

;; Use user-error for user mistakes
(unless buffer-file-name
  (user-error "Buffer is not visiting a file"))
```

## Quick Checklist

1. **File I/O**: Bind `print-length`/`print-level` to nil
2. **Equality**: Use `equal` for content, `eq` only for symbols
3. **CL functions**: Use `cl-` prefix (cl-loop, cl-remove-if, etc.)
4. **Buffers**: Check `buffer-live-p` before use
5. **Lexical binding**: Add `-*- lexical-binding: t -*-`
6. **Temp buffers**: Use `with-temp-buffer` or `unwind-protect`
7. **Strings**: Use `mapconcat` or buffer for building
