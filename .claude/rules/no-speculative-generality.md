# No Speculative Generality — YAGNI for Elisp

Minimum code that solves the problem. No features beyond what was asked.
Every abstraction, parameter, and indirection must have ≥1 caller using it
right now — not "might need later".

Adapted from `~/projects/mind-ai/agents/mega/dev-agent/lisp-style.org`
§"YAGNI — no speculative generality".

## `defcustom` without non-default usage = delete

If every caller uses the default value, the option is dead weight. Remove
it. When a second caller appears with a different need, that's the moment
to reintroduce the `defcustom`.

```elisp
;; YAGNI — nobody passes anything other than the default
(defcustom claude-agent-retry-count 3
  "Number of retries." :type 'integer)

;; Better — constant; reintroduce defcustom when a real user need appears
(defvar claude-agent--retry-count 3)
```

## No catch-all `pcase` wildcards when a specific pattern works

Under dynamic binding (literate-elisp), `pcase` with string literal
patterns compiles differently and is error-prone. Prefer `cond` + `equal`
for string matching. When you do use `pcase`, avoid `_ =>` as a catch-all
that swallows unexpected cases silently — explicit exhaustiveness catches
bugs at authoring time.

```elisp
;; BAD — silently swallows any unexpected type
(pcase msg-type
  ("assistant" (handle-assistant msg))
  (_ (message "unknown type: %s" msg-type)))

;; GOOD — cond + equal for string dispatch (literate-elisp safe)
(cond
  ((equal msg-type "assistant") (handle-assistant msg))
  ((equal msg-type "user") (handle-user msg))
  (t (error "Unknown msg-type: %s" msg-type)))
```

## No commented-out code

Two reasons: (a) `git log` keeps it; the comment doesn't. (b) Commented-out
code rots invisibly and provides false confidence ("we already considered
that"). Delete confidently; recover from git when needed.

## No `TODO`/`FIXME` older than 6 months

A `TODO` that hasn't been actioned in 6 months is an artifact, not a plan.
Either close the loop, file a tracking issue and link it here, or delete
the tag as accepted debt.

When adding a new `TODO`, annotate with the author so others know whom to
ask:

```elisp
;; TODO(jingtao 2026-05): batch the session lookups — see PR #42 review.
```

## `&rest` args that only one caller passes = inline the value

Same logic as `defcustom`: if only one call site passes a non-default
value, inline the constant. When a second caller needs a different value,
that's the signal to add the parameter.

```elisp
;; YAGNI — only one caller ever passes :timeout
(claude-agent-query prompt :callbacks cbs :timeout 30)

;; Better — bake it in until a second caller appears
(claude-agent-query prompt :callbacks cbs)
```

## No unused optional parameters

A `&optional` parameter that no caller supplies is speculative. Remove it
and re-add when the need is real.

## When to apply

- Before adding a new `defcustom`, `defvar`, or optional parameter: grep
  the codebase for call sites. If <2 callers use non-default values, don't
  add it.
- During code review, flag any new option/parameter without a concrete
  usage beyond the default.
