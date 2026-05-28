<!-- This file is the BASE agent instructions for OpenCode / Cursor /
     other non-Claude-Code agents reading the AGENTS.md standard.
     Keep this <= 60 lines.  Detailed rules live in CLAUDE.md and the
     literate-agent imports it pulls in.  Per-agent ephemeral context
     gets wrapped in BEGIN_EMACS_AGENT_INJECT / END_EMACS_AGENT_INJECT
     markers by opencode_workspace.py + copilot_workspace.py, written
     at session start and stripped at session end via the content-
     driven idempotent cleanup landed in commit a6e9d21 (2026-04-30
     pollution fix; see lp/backend/code-agent-pi-extensions.org and
     code-agent-python.org § workspace_launcher for the helpers). -->

# code-agent — AGENTS.md (base)

A Claude Agent SDK for Emacs: org-mode-driven AI workflows backed by Claude Code,
ACP-compatible agents (Codex, Gemini, OpenCode), and a tri-protocol backend.

## Where to read more

- **Onboarding**: `ONBOARDING.md` — 60-second docs-first pitch for new contributors.
- **Primary agent rules**: `CLAUDE.md` (this repo's root). Read it after onboarding.
- **Architecture**: `ARCHITECTURE.org` — module boundaries, invariants, extension points.
- **Lessons**: `tasks/lessons.md` — past mistakes promoted into rules.
- **Design rationale**: `RATIONALE.md` — why-we-decided-X log.
- **Tech-debt backlog**: `CODEBASE-REVIEW.org` — prioritised review findings.
- **Per-module design**: prose woven into the relevant code .org file (the docs/design-docs/ migration absorbed the historical separate design docs into LP-style preambles). New design notes live next to their code.

## Hard rules (excerpt — see CLAUDE.md for full)

- **NEVER hardcode secrets** (API keys, tokens, credentials, real user data).
  Use env vars / `~/.local/certs/` / GitHub Actions secrets.
- **NEVER commit `.env*`** or files containing real customer data.
- **NEVER include `Co-Authored-By:` lines** in commit messages.
- **NEVER `git checkout` for branch analysis** — use `/git-worktree` skill or
  `git show branch:file` (preserves working state).
- **NEVER skip hooks** (`--no-verify`, `--no-gpg-sign`) without explicit ask.
- **ALWAYS** prefer reversible actions; ask before destructive ops
  (`rm -rf`, DB migrations, `git push --force`, `npm publish`).

## Commands

```bash
make test-smoke   # < 2s — syntax check after every edit
make test-unit    # ~5s parallel — full unit tests
make check        # pre-commit gate (lint + unit + python)
make lint         # static analysis only
```

## Tools available in this workspace

- **cmux**: terminal multiplexer with browser surfaces. `cmux tree` to see topology.
- **evalElisp** (MCP): execute Emacs Lisp on host Emacs (`localhost:9999/mcp`).
- **Phoenix** (`localhost:6006`): trace viewer for every AI block execution.

## Risk → autonomy level (when running this codebase)

| Task | Required autonomy level |
|------|------------------------|
| auth / payments / DB migrations | L3 (supervised, every step approved) |
| business logic / refactor non-trivial | L3-L4 |
| docs / tests / refactor template | L4 (autonomous, review outcome) |
| exploration / prototype | L1-L2 (inline accept) |

For more detail (review protocol, telemetry, lessons-learned promotion process,
documentation-as-context), see CLAUDE.md.
