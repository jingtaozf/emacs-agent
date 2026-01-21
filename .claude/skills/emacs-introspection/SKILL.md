---
name: emacs-introspection
description: Emacs introspection via evalElisp MCP tool - discover functions, packages, keybindings, modes, and hooks
allowed-tools: [mcp__emacs__evalElisp]
---

# Emacs Introspection Skill

This skill teaches how to construct elisp code for Emacs introspection, to be executed via the `evalElisp` MCP tool.

## When to Use This Skill

Use this skill when the user wants to:
- Find functions/commands by pattern
- Get function documentation and source
- Discover keybindings
- List packages and features
- Inspect modes and hooks
- Debug Emacs behavior

## Elisp Patterns for Function Introspection

### Describe Function
```elisp
;; Get function documentation
(documentation 'function-name t)

;; Get function signature
(help-function-arglist 'function-name t)

;; Check if function exists
(fboundp 'function-name)

;; Check if interactive (command)
(commandp 'function-name)

;; Get function type
(let ((def (symbol-function 'function-name)))
  (cond
   ((subrp def) "C primitive")
   ((byte-code-function-p def) "byte-compiled")
   ((autoloadp def) "autoload")
   ((macrop 'function-name) "macro")
   (t "interpreted")))

;; Complete function info
(let ((sym 'function-name))
  (list
   :name (symbol-name sym)
   :bound (fboundp sym)
   :interactive (commandp sym)
   :arglist (help-function-arglist sym t)
   :doc (documentation sym t)))
```

### Get Function Source
```elisp
;; Get source location
(let ((loc (find-function-noselect 'function-name t)))
  (when loc
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (list :file (buffer-file-name)
              :line (line-number-at-pos))))))

;; Get actual source code
(let ((loc (find-function-noselect 'function-name t)))
  (when loc
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (buffer-substring-no-properties
         (point)
         (save-excursion (forward-sexp) (point)))))))
```

### Search Functions (Apropos)
```elisp
;; Find functions matching pattern
(mapcar #'symbol-name (apropos-internal "pattern" #'fboundp))

;; Find commands matching pattern
(mapcar #'symbol-name (apropos-internal "pattern" #'commandp))

;; Search by documentation
(let ((results '()))
  (mapatoms
   (lambda (sym)
     (when (and (fboundp sym)
                (let ((doc (documentation sym t)))
                  (and doc (string-match-p "pattern" doc))))
       (push (symbol-name sym) results))))
  (take 50 results))
```

## Keybinding Discovery

### Find Key Binding
```elisp
;; What does this key do?
(key-binding (kbd "C-x C-f"))

;; Get key description
(key-description (kbd "C-x C-f"))

;; What keys run this command?
(where-is-internal 'save-buffer nil t)

;; All keys for a command
(mapcar #'key-description
        (where-is-internal 'save-buffer))
```

### Keymap Inspection
```elisp
;; Get all bindings in a keymap
(let ((bindings '()))
  (map-keymap
   (lambda (key def)
     (when (and (not (keymapp def)) (symbolp def))
       (push (list (key-description (vector key))
                   (symbol-name def))
             bindings)))
   global-map)
  (take 50 bindings))

;; Current local keymap
(current-local-map)

;; Mode-specific keymap
(symbol-value (intern (concat (symbol-name major-mode) "-map")))
```

## Package/Feature Inspection

### List Features
```elisp
;; All loaded features
(mapcar #'symbol-name features)

;; Check if feature loaded
(featurep 'feature-name)

;; Find library file
(locate-library "library-name")
```

### Package Info
```elisp
;; List installed packages
(mapcar #'car package-alist)

;; Get package info
(let ((desc (cadr (assq 'package-name package-alist))))
  (when desc
    (list :version (package-version-join (package-desc-version desc))
          :summary (package-desc-summary desc)
          :status (package-desc-status desc))))
```

## Mode Inspection

### Major Mode Info
```elisp
;; Current major mode
major-mode

;; Mode documentation
(documentation major-mode t)

;; List all major modes
(let ((modes '()))
  (mapatoms
   (lambda (sym)
     (when (and (fboundp sym)
                (string-suffix-p "-mode" (symbol-name sym))
                (not (string-match-p "minor" (symbol-name sym))))
       (push (symbol-name sym) modes))))
  (take 100 modes))
```

### Minor Modes
```elisp
;; Active minor modes
(cl-remove-if-not
 (lambda (mode)
   (and (boundp mode) (symbol-value mode)))
 minor-mode-list)

;; All available minor modes
(mapcar #'symbol-name minor-mode-list)
```

## Hook Inspection

### List Hooks
```elisp
;; Find hooks matching pattern
(let ((hooks '()))
  (mapatoms
   (lambda (sym)
     (when (and (boundp sym)
                (string-match-p "-hook$" (symbol-name sym)))
       (push (symbol-name sym) hooks))))
  (take 50 hooks))

;; Get functions on a hook
(symbol-value 'after-save-hook)
```

## Debugging

### Trace Functions
```elisp
;; Enable trace
(trace-function-background 'function-name)

;; Disable trace
(untrace-function 'function-name)

;; Check trace buffer
(with-current-buffer "*trace-output*"
  (buffer-string))
```

### Find Callers
```elisp
;; Find references (requires xref)
(let ((refs (xref-backend-references (xref-find-backend) 'function-name)))
  (mapcar (lambda (xref)
            (let ((loc (xref-item-location xref)))
              (list :file (xref-location-group loc)
                    :summary (xref-item-summary xref))))
          (take 20 refs)))
```

## Tool Coordination

Use the `evalElisp` MCP tool to execute these elisp expressions.

## Example Usage

To find all commands related to "buffer":
```
evalElisp with code:
(let ((cmds (apropos-internal "buffer" #'commandp)))
  (mapcar (lambda (sym)
            (list :name (symbol-name sym)
                  :key (let ((k (where-is-internal sym nil t)))
                         (and k (key-description k)))))
          (take 20 cmds)))
```

## Important Notes

- Apropos searches can be slow with broad patterns
- Some functions are C primitives without elisp source
- Use `t` argument in `documentation` for substituting command keys
- `take` limits results to prevent huge outputs
