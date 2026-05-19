---
description: Audit one .org file's prose against the lp-prose-no-self-narration rule. Reports paragraphs that fail the deletion test (self-narration, filler parentheticals, mechanism-without-action). User-invocable only — do NOT auto-trigger on every edit.
when_to_use: invoke as `/audit-prose <file.org>` or `/audit-prose <module-name>` when the user wants a focused prose-quality pass on one literate org module. Typical triggers: "audit the prose in X", "check this org file for filler", "lint the prose".
disable-model-invocation: true
user-invocable: true
argument-hint: <file-or-module>
allowed-tools: Read Grep Bash
paths: "**/*.org"
---

# /audit-prose — focused prose lint for one .org file

This is a **manual** companion to the `/docs-first` skill.
`docs-first` fires automatically whenever a literate .org file is
edited; `/audit-prose` is a deliberate one-shot pass over an
existing module to find dead prose. Two-skill split rationale:
auto-firing a prose-audit on every edit would flood context with
nits unrelated to the change in flight.

## Argument

`$ARGUMENTS` — a file path or a module short name. If it's a path
ending in `.org`, use it directly. Otherwise resolve to
`/Users/jingtao/projects/claude-agent/<name>.org` (e.g. `process`
→ `code-agent-org-process.org` first, fall back to
`claude-agent-<name>.org`).

## Live target preview

```!
echo "Target file: $ARGUMENTS"
ls -la /Users/jingtao/projects/claude-agent/*"$ARGUMENTS"*.org 2>/dev/null | head -3
```

## What to look for

Apply the deletion test paragraph-by-paragraph. The canonical rule
lives at `.claude/rules/lp-prose-no-self-narration.md`
— consult it for the full taxonomy. The high-value failure modes:

1. **Self-narration immediately after the artefact.**
   - `(Source: foo.svg — GitHub renders the SVG inline.)` after an
     org link. The link IS the source.
   - `The table above shows ...` repeating the table content.
   - `This section provides ...` restating the heading.

2. **Mechanism-without-action.** Explaining *how* something works
   when the explanation neither warns the reader of a trap nor
   changes what they do next.
   - `The :tangle path resolves relative to the .org file.` →
     delete. Only keep this if it carries a warning ("a `git mv`
     of the .org silently breaks tangling").

3. **Filler parentheticals.** `(see below)`, `(for details)`,
   `(note that ...)`, `(as mentioned earlier)` when the referent
   is already in the reader's working memory.

4. **Pleasantries & meta-narration.** `First, let's understand…`,
   `In this section we will…`, `Hopefully this clarifies…`.

5. **Restating the heading.** A first sentence that just says what
   the heading already said. Either delete or merge into the
   heading.

## Procedure

1. Read the target file end-to-end.
2. For each paragraph (prose between `#+END_SRC` and the next
   heading, or between a heading and the next `#+BEGIN_SRC`):
   - Apply the deletion test: "if I delete this paragraph, does
     the reader's understanding of the system degrade?"
   - If no, it's a violation. Capture: line range + first-12-words
     + which category (1-5 above).
3. **Do not auto-apply deletions.** Output a report only. The
   human decides which deletions land.

## Output shape

A table grouped by category, plus a one-line summary at the top:

```
audit-prose: <file.org> — N violations across M paragraphs

| Lines  | Category | First 12 words                                | Suggested action |
|--------|----------|-----------------------------------------------|------------------|
| 42-45  | (1) self-narration | "(Source: architecture.svg — GitHub …)"      | delete |
| 78-80  | (3) filler         | "(See the next section for the routing logic.)" | delete |
| 120-128| (2) mechanism-no-action | "The :tangle path resolves relative to the .org" | delete OR add warning |

Run with --apply to land all "delete" suggestions in one commit (NOT
implemented in this version; manual apply for now).
```

## Trigger phrases for autocomplete

The `description` + `when_to_use` frontmatter cover:

- "audit the prose in X"
- "lint the prose"
- "check this org file for filler"
- "run prose audit"
- "find self-narration in <module>"
