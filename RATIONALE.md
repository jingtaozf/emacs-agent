# Design Rationale Index

**First seeded:** 2026-05-01 (lens #19 — tribal knowledge mining)

This file is the **first 5 entries** of a design-rationale backfill. Each
entry answers a *why* question that doesn't show up in commit messages,
chat threads, or the design-docs/ directory. The goal is to surface
"only-in-Jingtao's-head" decisions before they evaporate.

Format per entry:

```
## NN. <decision in 5-10 words>
- decision-date: YYYY-MM-DD (or approximate)
- alternative considered: <what we rejected, in 1 line>
- reason: <why we picked this, 2-3 sentences>
- followup: <what this implies / open question>
```

When you find yourself answering "why did we …?" to an agent or new dev for
the *third* time, write a new entry here.

---

## 1. Strict literate-elisp + .org files (not Python notebooks / nbdev / quarto)

- decision-date: ~2024 (project inception); revisited 2026-04-30
- alternative considered: nbdev (.ipynb as source-of-truth) / Quarto-with-emacs / plain .el with docstrings
- reason: literate-elisp loads `.org` *directly* — no separate tangle
  step strips the prose, so when an agent edits a function, it's editing
  inside the function's own justification. Notebooks treat code as
  primary with cells; in our codebase prose is primary, code is
  evidence. Lens #5/#11 in the AI mastery research validates this:
  AGENTS.md / CLAUDE.md ≤60 lines + per-module prose IS the agent's
  effective context.
- followup: For Python parts (workspace_bridge.py and friends),
  `~/projects/literate-org` provides org-tangle-to-Python; we don't
  use it yet because Python modules are small and stable enough that
  flat .py + thorough docstrings beats the tangle/load complexity.
  Re-evaluate when any single .py exceeds 1000 lines.

## 2. cmux access mode = `automation`, not `cmuxOnly` (after 2026-04-30)

- decision-date: 2026-04-30 (driven by broken-pipe symptom in lessons.md)
- alternative considered: cmuxOnly (default; `isDescendant(pid)` ancestry
  check); allowAll (no auth at all)
- reason: cmuxOnly fails when Emacs.app is launched from Dock/Finder —
  parent chain goes through launchd, not cmux. Every cmux daemon
  restart breaks Emacs → cmux RPC for *any* old Emacs process whose
  ppid chain depended on the previous daemon's pid. allowAll widens
  too much (any local user). automation = "no ancestry check, but
  same-uid-only" matches the actual security model: the threat is
  not other macOS users on this machine; it's ephemeral pid changes.
- followup: this is a per-user setting (`defaults write
  com.cmuxterm.app socketControlMode automation`), not encoded in
  the project. New developer needs to set it once. Document in
  `.claude/rules/cmux-dev-build.md`.

## 3. `hooks/hooks.json` matcher = `AskUserQuestion|ExitPlanMode` only

- decision-date: ~2026-04 (Phoenix span analysis caught the regression)
- alternative considered: no matcher (run hook on every tool call); per-tool
  allowlist (matcher on each interactive tool name explicitly)
- reason: every PreToolUse hook serializes through Emacs's single-threaded
  MCP server. Without a matcher, every Read/Bash/Edit fires a Python
  subprocess → blocking MCP call → queues behind other agents'
  parallel work → 1-2s latency *per tool call*. Phoenix aggregate
  caught 62 sec of synchronous Emacs blocking over 5 minutes from
  this one cause. Matcher on AskUserQuestion|ExitPlanMode (the only
  tools where Emacs genuinely needs to know) drops 90%+ traffic.
- followup: If we add another tool requiring Emacs-side state mutation
  (e.g. a "show-progress" tool), extend the matcher; do NOT default
  back to "match-all".

## 4. Tri-protocol backend (root lifecycle / agent wire / multiplexer wire)

- decision-date: 2026-04-24 (refactor shipped 2026-04-27)
- alternative considered: keep single backend protocol; string-match dispatch
  in code-agent-org.org based on `CLAUDE_BACKEND` value
- reason: agent family (Claude Code / OpenCode / Codex / Gemini) and
  multiplexer family (cmux / tmux) vary independently. A single protocol
  forces every backend to implement every method even when meaningless;
  string-match dispatch in the frontend bleeds backend identity into
  the org integration. Splitting into 3 protocols + receiver-dispatched
  cl-defmethods made the "I want to add a new agent on cmux" flow a
  one-file change. Smalltalk-flavoured OOP (cl-defstruct + cl-defgeneric)
  per the imported `oop-smalltalk-protocols` rule (literate-agent).
- followup: see `claude-agent-backend.org` → "Tri-Protocol
  Architecture" for the authoritative description. New backends
  must NOT add `CLAUDE_BACKEND`-string branches in code-agent-org.org;
  extend the protocol method on the backend receiver instead.

## 5. AGENTS.md is ephemeral session inject, not project governance doc

- decision-date: 2026-05-01 (after self-perpetuating bloat caught it)
- alternative considered: keep AGENTS.md as a 60-line base + ephemeral
  prepend block; or: full ephemeral (`.cache/agents-md.tmp` +
  `OPENCODE_AGENTS_FILE=...`)
- reason: We picked the 60-line base path because it preserves the
  AGENTS.md *standard* (60k+ projects use the file by name) for new
  contributors who don't yet have OpenCode installed. The prepend
  remains because OpenCode auto-reads `AGENTS.md` at the project root
  and we have no documented way to point it elsewhere. The
  self-perpetuating bug was fixed via content-driven idempotent
  cleanup (commit a6e9d21).
- followup: if OpenCode adds a `--system-prompt-file` flag (or
  similar), switch to truly ephemeral path and unbase AGENTS.md.

---

## How to add a new entry

When the same "why" question comes up 3 times across sessions or PRs, add
a numbered entry above. Keep the format small — 4 lines is enough. Don't
turn this into a book; if the rationale needs more than 5 lines of prose,
spin out a separate `docs/design-docs/<topic>.org` and link to it here.
