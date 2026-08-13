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
- followup: see `code-agent-backend.org` → "Tri-Protocol
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

## 6. No third-party token-saving tool — rely on native spill + `concise` output-style

- decision-date: 2026-06-05 (3-round eval in the `emacs-claude-dev1` session)
- alternative considered: Headroom (proxy/CCR, *touches the API key* →
  subscription-ban risk), RTK (PreToolUse hook, known data-loss bugs
  #2271/#2253 + sec hole #2262), ecotokens (hook, unverified single
  maintainer), chop (PreToolUse hook, lossy-by-design), or a self-written
  lossless PostToolUse hook
- reason: measured against a real 2.48M-tool-token transcript, the numbers
  remove the case for *any* added tool —
  - Claude Code (v2.1.163) already spills tool output over
    `maxResultSizeChars` (Bash = 30000 chars; global default = 50000) to
    `<transcript>/tool-results/*.txt` **losslessly** — full output on disk +
    ~2KB preview + `Read` to recover. 187 spill files already on disk. The
    one place big *lossless* savings live is already covered, first-party, free.
  - After spill, the residual is the 2–30KB mid-band (~58% of tool-output).
    A provably-lossless hook (trailing-ws trim + fold-repeats + collapse-blanks)
    caps at ~5% (2–10KB) / ~15% (10–30KB) → **~3% of total context** — not
    worth a hook in the request path plus maintenance.
  - The "50–90%" of RTK/chop is **all lossy** (truncation / fingerprint dedup /
    per-command summary) — exactly the regression this project rejects.
  - tool-output is 51.7% of context; the agent's own output is 44.6% — the
    bigger half is already cut by the active `concise` output-style. The
    biggest lever is already installed.
- followup: revisit only if a task profile becomes dominated by
  high-volume-low-info commands (test runners, verbose logs) where a *vetted
  per-command* summarizer (chop's error-float + no-gain-fallback rails) earns
  its regression surface. Note: Claude Code hooks don't cover the Pi backend
  (separate RPC) regardless.

## 7. 2026-08-13 repo narrowed to the MCP server (legacy-2026-08-13 branch)

- decision: delete everything except the Emacs MCP server (+ trace macros,
  Pi TS extensions, proposal queue); full pre-cleanup tree lives on the
  `legacy-2026-08-13` branch.
- why: the terminal-backend generation (cmux/tmux/orca org workspaces,
  python bridge, IDE bridge) went unused — the user drives coding agents
  through Orca directly. Unused code was pure drift surface. New focus:
  custom in-Emacs agents (org-ai-agent-pi-topics, draft.org 2026-08-13).
- rejected: keeping modules dormant on master "for reference" — git
  branches are the reference; dead code on master taxes every audit.
- followup: pi-topics re-grows a minimal protocol layer as needed instead
  of resurrecting the tri-protocol generics wholesale.

---

## How to add a new entry

When the same "why" question comes up 3 times across sessions or PRs, add
a numbered entry above. Keep the format small — 4 lines is enough. Don't
turn this into a book; if the rationale needs more than 5 lines of prose,
spin out a separate `docs/design-docs/<topic>.org` and link to it here.
