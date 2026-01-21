---
name: emacs-debugging
description: Debug Emacs Lisp code using edebug, trace, profiler, and error handling - use when encountering elisp errors or performance issues
allowed-tools: [mcp__emacs__evalElisp]
---

# Emacs Lisp Debugging Skill

This skill teaches debugging patterns for Emacs Lisp, executed via the `evalElisp` MCP tool.

## When to Use This Skill

Use when:
- Encountering mysterious elisp errors
- Functions not behaving as expected
- Performance issues in elisp code
- Debugging macro expansions
- Tracing function calls

## Edebug: Interactive Stepping

### Instrument a Function

```elisp
;; Instrument function for debugging (C-u C-M-x on defun)
(edebug-instrument-function 'my-function)

;; Remove instrumentation
(edebug-remove-instrumentation 'my-function)

;; Check if instrumented
(get 'my-function 'edebug)
```

### Edebug Commands (when stepping)

| Key | Action |
|-----|--------|
| SPC | Step to next expression |
| n | Step over (next) |
| i | Step into function |
| o | Step out of current function |
| g | Go (continue to next breakpoint) |
| q | Quit debugging |
| e | Eval expression |
| ? | Help |

### Set Breakpoints Programmatically

```elisp
;; Add breakpoint condition
(defun my-function (x)
  (edebug-set-breakpoint t)  ; Always break here
  (when (> x 10)
    (edebug-set-breakpoint nil))  ; Conditional break
  (do-something x))
```

## Trace: Non-Interactive Function Logging

### Basic Tracing

```elisp
;; Trace function calls and returns
(trace-function 'my-function)

;; Trace to background (no popup)
(trace-function-background 'my-function)

;; Untrace
(untrace-function 'my-function)

;; Untrace all
(untrace-all)

;; View trace output
(with-current-buffer "*trace-output*"
  (buffer-string))
```

### Trace with Filter

```elisp
;; Custom trace output
(trace-function 'my-function
  (lambda (func args)
    (message "Called %s with %S" func args)))
```

## Error Handling and Debugging

### Condition-Case for Error Capture

```elisp
;; Catch and inspect errors
(condition-case err
    (dangerous-operation)
  (error
   (list :error-type (car err)
         :error-data (cdr err)
         :backtrace (with-output-to-string (backtrace)))))
```

### Debug on Error

```elisp
;; Enter debugger on any error
(setq debug-on-error t)

;; Debug on specific errors
(setq debug-on-error '(void-function wrong-type-argument))

;; Debug on quit (C-g)
(setq debug-on-quit t)

;; Disable all debug modes (IMPORTANT for MCP)
(setq debug-on-error nil
      debug-on-quit nil)
```

### Signal Custom Errors

```elisp
;; Define error type
(define-error 'my-custom-error "My custom error")

;; Signal it
(signal 'my-custom-error '("error details"))

;; Catch specifically
(condition-case err
    (my-operation)
  (my-custom-error
   (handle-my-error err))
  (error
   (handle-generic-error err)))
```

## Profiler: Performance Analysis

### CPU Profiling

```elisp
;; Start CPU profiler
(profiler-start 'cpu)

;; Run code to profile
(my-slow-function)

;; Stop and get report
(profiler-stop)

;; Get profiler report as string
(with-current-buffer (profiler-report-cpu)
  (buffer-string))
```

### Memory Profiling

```elisp
;; Start memory profiler
(profiler-start 'mem)

;; Run code
(my-memory-hungry-function)

;; Stop and report
(profiler-stop)
(with-current-buffer (profiler-report-memory)
  (buffer-string))
```

### Benchmark

```elisp
;; Time a single expression
(benchmark-run 100
  (my-function-to-test))
;; Returns (TOTAL-TIME GC-COUNT GC-TIME)

;; Benchmark with GC disabled
(let ((gc-cons-threshold most-positive-fixnum))
  (benchmark-run 100
    (my-function-to-test)))
```

## Macro Debugging

### Expand Macros

```elisp
;; Single-level expansion
(macroexpand '(when condition body))

;; Full expansion (all nested macros)
(macroexpand-all '(when condition (unless other body)))

;; Pretty-print expansion
(pp (macroexpand-all '(cl-loop for i from 1 to 10 collect i)))
```

### Debug Macro at Use Site

```elisp
;; Check what macro expands to
(defun debug-macro-expansion (form)
  (let ((expanded (macroexpand-all form)))
    (list :original form
          :expanded expanded
          :diff (not (equal form expanded)))))

(debug-macro-expansion '(push item list))
```

## Common Elisp Errors and Fixes

### void-function

```elisp
;; Error: Symbol's function definition is void: my-func
;; Cause: Function not defined or not loaded
;; Fix:
(require 'my-package)  ; Load the package
;; or check spelling:
(fboundp 'my-func)     ; Returns nil if not defined
```

### void-variable

```elisp
;; Error: Symbol's value as variable is void: my-var
;; Cause: Variable not set
;; Fix:
(boundp 'my-var)       ; Check if bound
(defvar my-var nil)    ; Define with default
```

### wrong-type-argument

```elisp
;; Error: Wrong type argument: stringp, 123
;; Cause: Function expected string, got number
;; Debug:
(defun debug-types (&rest args)
  (mapcar (lambda (arg)
            (list :value arg
                  :type (type-of arg)))
          args))
```

### wrong-number-of-arguments

```elisp
;; Error: Wrong number of arguments
;; Debug: Check function signature
(help-function-arglist 'my-function t)
```

## Debugging in MCP Context

### Safe Debugging (Won't Block Emacs)

```elisp
;; IMPORTANT: Disable interactive debugging for MCP
(let ((debug-on-error nil)
      (debug-on-quit nil)
      (edebug-all-defs nil))
  (condition-case err
      (my-operation)
    (error
     (list :error (error-message-string err)
           :type (car err)))))
```

### Capture Backtrace Non-Interactively

```elisp
(defun capture-backtrace ()
  "Capture current backtrace as string."
  (with-temp-buffer
    (let ((standard-output (current-buffer)))
      (backtrace))
    (buffer-string)))

;; Use in error handler
(condition-case err
    (failing-function)
  (error
   (list :error err
         :backtrace (capture-backtrace))))
```

### Log Function Calls

```elisp
;; Simple call logger
(defvar my-call-log nil)

(defun log-call (func &rest args)
  (push (list :time (current-time)
              :func func
              :args args)
        my-call-log))

;; Advice to log calls
(advice-add 'my-function :before #'log-call)

;; Remove logging
(advice-remove 'my-function #'log-call)

;; View log
(pp my-call-log)
```

## Quick Debug Checklist

1. **Check if defined**: `(fboundp 'func)` / `(boundp 'var)`
2. **Check type**: `(type-of value)`
3. **Check signature**: `(help-function-arglist 'func t)`
4. **Trace calls**: `(trace-function-background 'func)`
5. **Expand macros**: `(macroexpand-all 'form)`
6. **Profile**: `(profiler-start 'cpu)` ... `(profiler-stop)`
7. **Catch errors**: `(condition-case err ... (error ...))`
