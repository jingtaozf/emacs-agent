# Org-Mode Docs-First — concrete section shape

> Companion reference to the `.claude/skills/docs-first/SKILL.md`
> auto-trigger skill.  Most public Claude Code guidance assumes
> markdown; this file translates docs-first into the specific
> shape an `.org` literate file must carry.

## The four-part section shape

Every concept-level section (depth 2 `**` or 3 `***`) follows the
same four-part structure.  Open one of the 14 extracted modules
under `code-agent-org-*.org` for a live example.

```
,** <Concept Name>                          ← 1. heading: names a CONCEPT,
:PROPERTIES:                                     not a phase like "Functions"
:CUSTOM_ID: <kebab-case-anchor>             ← 2. stable cross-file anchor
:END:

<1–3 sentence prose preamble.  Quotes the          ← 3. PROSE COMES FIRST
constraint or trade-off this code embodies.        It answers WHY.
Names any rejected alternative in one sentence.>

,#+BEGIN_SRC elisp                          ← 4. src block: the WHAT
(defun ...)
,#+END_SRC
```

The four parts always appear in this order.  Reversing parts 3-4
(code first, comment afterwards) is the failure mode docs-first
exists to prevent.

## Why heading-as-concept, not heading-as-phase

The user-level rule `~/projects/dummy/claude/rules/lp-prose-no-self-narration.md`
(and the project rule `.claude/rules/literate-programming-document-first.md`)
both call out generic phase headings ("Functions", "Helpers",
"Utilities", "Implementation", "Misc") as failures.  Heading
should name *what role* the section plays in the system, not the
mechanical category of what's inside.

| Bad heading        | Good heading                          |
|--------------------|---------------------------------------|
| `** Functions`     | `** Persistent Client Registry`       |
| `** Helpers`       | `** Marker Lifecycle Validation`      |
| `** Implementation`| `** Query-ID Based Response Lookup`   |
| `** Misc`          | `** macOS Notification on Complete`   |

If you cannot name the role, you don't yet know what the section
*is*.  Stop and think before writing the heading.

## CUSTOM_ID conventions

`:CUSTOM_ID:` is the cross-file anchor — survives prose edits that
shift line numbers, lets other modules link via
`[[file:foo.org::#overview][label]]`.

Conventions used by the 14 extracted modules:

| Section | CUSTOM_ID |
|---------|-----------|
| `* Overview` (top of every module) | `overview` (literal) |
| `** Concerns owned` / `** Concerns` | `concerns` |
| `** Load-order constraint` | `load-order` |
| `** Dependencies` | (usually none — section is mechanical) |
| Body sections | `<kebab-case-of-heading>` |

The `overview` anchor is universal — `[[file:X.org::#overview]]`
works for any extracted module.  ARCHITECTURE.org's module table
relies on this.

When you add a body section that you EXPECT to be cross-linked
from elsewhere (e.g. the registry class, a public function group),
add a `:CUSTOM_ID:` matching the heading slug.  When the section
is internal-only and only its file links to it, omit `:CUSTOM_ID:`
— org-mode's anchor falls back to the heading text, which is
stable enough for in-file refs.

## Prose voice: instruction, not narration

Per the project's `lp-prose-no-self-narration.md` rule and the
public Claude Code skill-authoring guidance ("instructions fire
more reliably than descriptions"), the prose voice is:

- **Active verbs** referring to what the code does, not what the
  section *is*.
  - ✗ "This section provides functions for managing markers."
  - ✓ "Markers can become invalid when their buffer is killed.
    These helpers validate before use and free them on
    completion."

- **Quote the trade-off** when one exists.
  - ✓ "Loading customize first means none of them ever sees an
    unbound symbol — the load-order risk that blocks the rest
    of the Tier-2 module-extraction sequence."

- **Name the rejected alternative** in one sentence if non-obvious.
  - ✓ "Earlier versions kept state in a bare hash table plus
    seven free functions — the classic 'wrap the hash in a
    class' smell."

## `#+NAME:` and `#+CALL:` for cross-block reuse

When two code blocks share a non-trivial helper that itself
deserves prose, give the helper block a `#+NAME:` and reference
it from the calling block via `:noweb yes` or `#+CALL:`.

```
,#+NAME: ansi-strip
,#+BEGIN_SRC elisp
(defun --strip-ansi (chunk) ...)
,#+END_SRC

Used by both the cmux and tmux verbose-buffer filters:

,#+BEGIN_SRC elisp :noweb yes
(defun cmux-verbose-filter (chunk)
  <<ansi-strip>>
  ...)
,#+END_SRC
```

This is the org-babel equivalent of "extract a function and
reference it" — but with prose in between, so the reuse is
*explained*, not just present.

In practice this repo doesn't use `:noweb yes` heavily; the more
common pattern is to define the helper at the top of the module
and let normal Elisp / Python scoping handle reuse.  Mention
`#+NAME:` when the *prose* explicitly says "Used by X and Y".

## Property drawers vs file-level `#+PROPERTY:`

Section-level `:PROPERTIES:` drawers apply to all blocks within
the section, useful for `:tangle` paths, `:dir`, language-specific
header-args:

```
,*** Module: token bridge
:PROPERTIES:
:header-args:elisp: :tangle ./python-claude-agent/bridge.el
:END:
```

File-level `#+PROPERTY:` at the very top sets defaults for the
entire file:

```
,#+PROPERTY: header-args:python :tangle ./python/claude_agent/foo.py :mkdirp yes
```

Docs-first rule: when you change a `:tangle` target or
`header-args`, *write a one-sentence note above the property
drawer* explaining what the new target file holds.  Property
drawers without context are the kind of thing readers re-grep
months later to remember why something exists.

## What this rule does NOT cover

- Markdown-first projects → consult standard CLAUDE.md guides.
- Python-only tangle without org → use Sphinx docstrings, not org
  literate programming.
- One-shot scripts where prose-as-comment overhead exceeds the
  comprehension benefit → not literate, just code.

This rule applies specifically to the `.org` source-of-truth files
in this repo (`code-agent-org-*.org`, `claude-agent-*.org`,
`claude-agent-python.org`) and any new `.org` files added under
`/Users/jingtao/projects/claude-agent/`.

## See also

- [`literate-programming-document-first.md`](./literate-programming-document-first.md) — the project's general LP rule.
- `~/projects/dummy/claude/rules/lp-prose-no-self-narration.md` — user-level deletion-test taxonomy.
- [Org Babel — Literate Programming Tutorial (Howard Abrams)](https://www.howardism.org/Technical/Emacs/literate-programming-tutorial.html) — original source for the four-part shape and `:comments org` mechanism.
