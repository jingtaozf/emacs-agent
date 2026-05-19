# Naming Conventions

Consistent naming makes the codebase greppable and self-documenting.
These rules apply to all Elisp code in `.org` source files and any
`.el` files in the project.

## Prefix table

| Prefix | Module | Visibility |
|--------|--------|------------|
| `claude-agent-` | Core SDK (`claude-agent.org`, `claude-agent-backend.org`) | Public |
| `claude-agent--` | Core SDK internals | Private |
| `code-agent-org-` | Org integration (`code-agent-org.org`, sub-modules) | Public |
| `code-agent-org--` | Org integration internals | Private |
| `emacs-mcp-server-` | MCP server (`emacs-mcp-server.org`) | Public |
| `emacs-mcp-server--` | MCP server internals | Private |

Internal functions use *double-dash* (`--`); public API uses *single-dash*
(`-`). This is enforced by `test-structural-internal-functions-use-double-dash`.

## Variable role-encoding

Names should encode the *role*, not the *type* or a generic label.

```elisp
;; GOOD — encodes the role
(defvar claude-agent--cli-session-id nil)
(defvar claude-agent--ready-pattern-re nil)
(defvar code-agent-org--workspace-heading-pos nil)

;; BAD — generic, ambiguous when multiple values coexist
(defvar claude-agent--id nil)
(defvar claude-agent--pattern nil)
(defvar code-agent-org--pos nil)
```

Ask: "would a newcomer know what this holds from the name alone?" If not,
add the domain qualifier.

## Casing and word separators

- All symbols are *lowercase*. Use *hyphens* between words.
  `request-handler`, never `requestHandler` or `request_handler`.
- Spell out complete words. Avoid abbreviations unless domain-standard
  (`mcp`, `otlp`, `pid`, `re` for regex).
- Sanity check: if you wouldn't say the symbol out loud in conversation,
  it's badly named (`req-hdlr` fails; `request-handler` passes).

## Sigils and special forms

| Form | Meaning | Example |
|------|---------|---------|
| `-p` / `--p` | Predicate (returns boolean) | `claude-agent-ready-p` |
| `--` | Module-private | `code-agent-org--get-section-level` |
| `with-` | Resource-acquiring macro (temporary scope) | `claude-agent-with-session` |
| `make-` | Factory / constructor wrapper | `claude-agent-make-options` |
| `-hook` | Hook variable | `claude-agent-query-complete-hook` |
| `-mode` | Minor/major mode | `code-agent-org-mode` |

Note: Elisp does not use earmuffs (`*name*`) for special variables
(unlike Common Lisp). Dynamic variables are plain `defvar`s; the
binding convention is documented in the variable's docstring.

## Project-specific shapes

| Pattern | Meaning |
|---------|---------|
| `make-foo` | Factory wrapping a constructor (no dispatch) |
| `foo-p` / `has-foo-p` | Predicate, returns generalized boolean |
| `foo-bar` (slot accessor) | Accessor on struct for slot `bar` |
| `start-foo` / `stop-foo` | Lifecycle pair on a singleton |
| `with-foo` | Resource-acquiring macro (acquire → release) |

## Don't repeat the module name in symbol names

The prefix is already a namespace. Don't bake it in twice:

```elisp
;; BAD — "claude-agent" is already in the prefix
(defun claude-agent-get-agent-session-id ...)

;; GOOD — the module prefix provides the namespace
(defun claude-agent-get-session-id ...)
```

## Generic functions vs plain `defun`

- A `cl-defgeneric` names a *verb of a protocol*: `query`, `cancel`,
  `cleanup`. The verb works regardless of receiver class.
- A plain `defun` names an *operation that doesn't dispatch*: factories,
  pure helpers, format functions.

If you write `(defun do-thing-on-foo (foo) ...)` and immediately think
"I'll need a variant for `bar`", you wanted `cl-defgeneric`.

## Avoid

- **Cute mathematical Greek letters** — pretty in papers, hostile to grep.
  Spell out `theta` and `epsilon`.
- **Type info in variable names** — `the-list-of-strings` is noise;
  `names` is enough.
- **Verb suffixes for noun classes** — the struct is `session`, not
  `session-object`.
- **Ambiguous abbreviations** — `upd` could be "update" or "uploaded";
  spell it out.
