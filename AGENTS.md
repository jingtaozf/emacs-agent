<!-- This file is the BASE agent instructions for OpenCode / Cursor / other
     non-Claude-Code agents reading the AGENTS.md standard.
     Keep this <= 60 lines. Detailed rules live in CLAUDE.md and docs/.

     KNOWN BUG (2026-04-30): opencode_workspace.py prepends ephemeral
     session instructions ABOVE this base, then atexit restore writes the
     polluted content back, causing self-perpetuating bloat. Fix tracked
     in tasks/lessons.md → "AGENTS.md 被错误 commit". Until fixed, treat
     anything between BEGIN/END markers as transient noise. -->

# claude-agent — AGENTS.md (base)

A Claude Agent SDK for Emacs: org-mode-driven AI workflows backed by Claude Code,
ACP-compatible agents (Codex, Gemini, OpenCode), and a tri-protocol backend.

## Where to read more

- **Primary agent rules**: `CLAUDE.md` (this repo's root). Read it first.
- **Architecture**: `ARCHITECTURE.org` — module boundaries, invariants, extension points.
- **Lessons**: `tasks/lessons.md` — past mistakes promoted into rules.
- **Design docs**: `docs/design-docs/` — why the code is shaped this way.

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
