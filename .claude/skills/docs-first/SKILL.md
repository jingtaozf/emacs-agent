---
description: Prose drives code in this literate-elisp / literate-python repo. Use BEFORE editing any .org file under /Users/jingtao/projects/claude-agent — claude-agent*.org, code-agent-org-*.org, claude-agent-python.org. Auto-activates when the user asks for a feature, change, refactor, or fix in those files, and when they say "explain", "document", "draft a section", "write up", "rationale".
when_to_use: editing literate .org files; adding a new defun, defcustom, class, or method; refactoring an existing section; user says "add", "write", "implement", "refactor", "explain why", "document".
disable-model-invocation: false
allowed-tools: Read Edit Write Grep Glob Bash
paths: "**/*.org"
---

# Docs-First — prose drives code in this literate repo

This repo's .org files ARE the source. Code is woven into prose, not
the other way around. Write the *why* first; the code is evidence
that backs up the explanation.

## The reflex to override

Claude's default reflex on "add feature X" is to find a src block,
edit it, and append a docstring or comment. That is wrong here.

The correct order is:

1. Locate the section the change belongs in.
2. Edit the *prose preamble* first — one to three sentences naming
   the *why* / the *trade-off* / the *rejected alternative*.
3. THEN edit the `#+BEGIN_SRC` body beneath it.
4. Reload (`(literate-elisp-load "FILE.org")` for Elisp,
   `make tangle-python` for Python).
5. Run the matching test suite via Bash, not evalElisp.

## What the prose must answer

For every changed or added section, the surrounding prose must let
a reader who cannot run the code understand:

- **What** this code does (one clause, often the heading already
  says it — don't repeat the heading).
- **Why** this shape was chosen — the constraint, the trade-off,
  the failure mode it prevents.
- **What was rejected** — when a different approach was tried first
  or considered, name it in one sentence so future readers don't
  re-litigate.

If you cannot answer "why this shape", stop. The change is not
ready to write.

## The deletion test

After every paragraph you write, ask: *"if I delete this paragraph,
does the reader's understanding degrade?"* If no — delete it.

Common failures:

- "(Source: foo.org — GitHub renders it inline.)" after an org link
  → delete; the link IS the source.
- "The function above does X." → delete; the docstring already says
  that.
- "First, let's understand…" / "In this section we will…" →
  narrator voice, no system fact. Delete.
- Mechanism explanations that don't change reader action (e.g.
  "the :tangle path is relative to the .org file") → delete unless
  it warns of a real trap.

The rule lives at `~/projects/dummy/claude/rules/lp-prose-no-self-narration.md`
— consult it when in doubt.

## Bypass conditions

State the bypass explicitly before skipping prose:

- **Typo / formatter / whitespace**: "trivial; skipping prose."
- **Dependency bump with no behavior change**: "mechanical; no prose
  needed."
- **Test rewrite that doesn't change production code**: "test-only;
  prose unchanged."
- **Reverting a commit verbatim**: "revert; prose owned by the
  reverted commit."

Anything else — including 1-line behaviour fixes — gets at least
one sentence of prose explaining the trap that the fix closes.

## Section shape for .org files

When adding a new section, write all four parts in this order:

```
,** <Concept Name>                          ← name a concept, not "Functions"
:PROPERTIES:
:CUSTOM_ID: <kebab-case-anchor>             ← stable cross-file link target
:END:

<1–3 sentence prose preamble explaining the *why*,
naming any rejected alternative, quoting a trap if relevant>

,#+BEGIN_SRC elisp
(defun ...)
,#+END_SRC
```

If the file has a `* Overview` section, EVERY new top-level section
gets a one-line entry in that overview's concerns table.

## Cross-file links

When the prose references another module, use a real org link, not
plain text:

```
See [[file:code-agent-org-process.org::#overview][process module]] for ...
```

Plain-text `=code-agent-org-process.org=` references degrade to grep
targets. Real links make Emacs jump-to-definition work and let
GitHub render them as clickable.

## Verification gate before declaring done

Before saying "feature added":

1. `make test-smoke` (always — < 2 s)
2. `make test-org-unit` (if Elisp .org touched)
3. `make tangle-python` followed by `make test-python` (if Python
   .org touched)
4. Visually confirm the prose-block-then-src-block ordering in the
   edited section. The diff should show prose lines BEFORE src
   lines.

## Onboarding sanity check

If you are a new contributor reading this skill cold: run

```bash
ls /Users/jingtao/projects/claude-agent/code-agent-org-*.org
```

and open any one of them. The first three sections of each are
`* Overview` with `:CUSTOM_ID: overview`, then a table of concerns,
then `** Dependencies` with a tiny `#+BEGIN_SRC elisp (require ...)`
block. That is the target shape — copy it.
