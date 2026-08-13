<!-- Base agent instructions for non-Claude-Code agents reading the
     AGENTS.md standard.  Keep <= 40 lines; detailed rules live in
     CLAUDE.md. -->

# emacs-agent — AGENTS.md (base)

Emacs MCP server (`lp/sdk/emacs-mcp-server.org`, HTTP at
localhost:9999) + home for custom in-Emacs agents.  Everything else
was moved to the `legacy-2026-08-13` branch on 2026-08-13.

## Where to read more

- **Primary agent rules**: `CLAUDE.md` (repo root).
- **Architecture**: `ARCHITECTURE.org` — module map, invariants.
- **Design queue**: `lp/_drafts/draft.org` — org-ai-agent-pi-topics.
- **Lessons**: `tasks/lessons.md`; **rationale**: `RATIONALE.md`.

## Hard rules (excerpt — see CLAUDE.md for full)

- **NEVER hardcode secrets**; env vars / `~/.local/certs/` only.
- **NEVER commit `.env*`** or real customer data.
- **NEVER include `Co-Authored-By:`** in commit messages.
- **NEVER skip hooks** (`--no-verify`) without explicit ask.
- **ALWAYS** ask before destructive ops (`rm -rf`, `git push --force`).

## Commands

```bash
make lint        # static analysis
make test-unit   # mcp + mode-line + otel unit tests
make check       # lint + test-unit (pre-commit gate)
```
