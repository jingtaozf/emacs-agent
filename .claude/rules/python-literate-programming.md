# Python Literate Programming — org as Single Source of Truth

`claude-agent-python.org` at the project root is the **single source of
truth** for all Python code. The `.py` files are generated artefacts
produced by `org-babel-tangle`.

Adapted from `~/projects/mind-ai/agents/mega/skill-scout-server/.claude/rules/literate-programming-document-first.md`.

## NEVER-touch list

- **NEVER** edit any `.py` file directly. The PreToolUse hook
  (`.claude/hooks/block-python-tangled-edit.sh`) rejects Edit/Write/MultiEdit
  on ALL `.py` files. Edit `claude-agent-python.org` instead.
- **NEVER** introduce a heading at depth > 5 in the .org file.
  `make check-python-structure` enforces this.
- **NEVER** open a section that tangles to a `.py` with `#+begin_src`
  directly — at least one prose line must come first.
  `make check-python-structure` enforces this.

## Required section structure

Each Python module gets its own section in the .org file. The hierarchy:

| Module piece | Heading depth | Example |
|---|---|---|
| Package-level grouping | `*` | `* Observability` |
| Individual module | `**` | `** Tracer Factory` |
| Sub-module concept | `***` | `*** TraceContextStore` |

Every tangle section uses:
```org
** <Concept Name>
:PROPERTIES:
:header-args: :tangle ./python/claude_agent/<module>.py :mkdirp yes
:END:

(prose before code)
#+begin_src python
...
#+end_src
```

## Four principles

1. **Intent before implementation.** Explain *why* before showing *how*.
   Prose drives; code illustrates.

2. **Psychological order, not execution order.** Present concepts in the
   order easiest for a human to learn from. The tangler handles
   mechanical reordering.

3. **Structure follows narrative logic.** Hierarchy mirrors the reader's
   mental model: top-level = what this module does, second level = what
   concepts make it work, third level = concrete pieces.

4. **Org files are the design record.** Every design decision, tradeoff,
   and "why not the other approach" belongs in the .org as prose.

## Auto-tangle lifecycle

Two paths:

1. **PostToolUse hook** (`.claude/hooks/tangle-python-org.sh`) — fires
   when Claude edits `claude-agent-python.org`. Prefers host Emacs,
   falls back to `make tangle-python`.
2. **Manual** — `make tangle-python` whenever you want to refresh.

Escape hatch: `LITERATE_ORG_NO_AUTO_TANGLE=1` skips the hook.

## LP commands

```bash
make tangle-python           # tangle claude-agent-python.org to .py
make check-python-structure  # depth <= 5, no grab-bag, prose before src
make build-python-index      # generate INDEX-python.org
```

## Self-check before committing

1. Does the section heading describe a *concept*, not a phase?
2. Is there prose between the heading and the first `#+begin_src`?
3. If you stripped every code block, would the prose alone explain the module?
4. Is each `def` / `class` accompanied by a docstring?

## NL outline for long functions

When a Python function body exceeds **40 lines**, add inline
`# # <one-clause summary>` comments that partition the body into
narrative steps. Each summary covers >=3 source lines.

## Byte-equivalence gate

After tangling, `git diff --stat python/` MUST be empty. A non-empty
diff means the .org src blocks diverged from the .py source.

```bash
make tangle-python
git diff --stat python/   # MUST be empty
```
