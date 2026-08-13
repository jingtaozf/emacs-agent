# emacs-agent — Emacs MCP server + custom in-Emacs agents

Scope after the 2026-08-13 cleanup: this repo ships the **Emacs MCP
server** (plus its OTel trace macros and the Pi TS extensions that
consume it), and is the home for new custom in-Emacs agents — first
up: **org-ai-agent-pi-topics** (`lp/_drafts/draft.org`
§ 2026-08-13-org-ai-agent-pi-topics).  Everything else (cmux/tmux/orca
backends, org workspace layer, python bridge, IDE bridge) lives on the
`legacy-2026-08-13` branch — recover from there, do not rewrite from
memory.

## Setup + shared LP doctrine

Clone `literate-agent` (LP doctrine + plugin + shared scripts) then
launch Claude Code with `--plugin-dir`:

```bash
git clone https://github.com/jingtaozf/literate-agent.git ~/projects/literate-agent
claude --plugin-dir ~/projects/literate-agent ...
```

LP rules load via `.claude/rules/literate-agent` — a gitignored,
machine-local symlink to `~/projects/literate-agent/rules/` (set up once:
`ln -s ~/projects/literate-agent/rules .claude/rules/literate-agent`).
Override `LITERATE_AGENT_HOME` if cloned elsewhere.

## Commands

```bash
make lint               # Static analysis (undefined functions/variables)
make test-unit          # All unit tests (mcp + mode-line + otel)
make test-mcp-unit      # MCP server unit tests only
make check              # lint + test-unit (pre-commit gate)
make tangle-pi-extensions  # Tangle Pi TS extensions → ~/.pi/agent/extensions/
```

## Verification sequence (after every code change)

1. Save the file
2. `make check`
3. Reload in Emacs: `evalElisp` with
   `(literate-elisp-load "lp/sdk/emacs-mcp-server.org")`
4. Exercise the actual feature; inspect real results
5. Only then report to user, quoting actual output

The single most important rule: **always use real tools** — run
commands, call `evalElisp`, never simulate when real execution is
possible.  Before claiming code is buggy, evaluate the expression via
`evalElisp` to confirm behaviour; see `ELISP-IDIOMS.org` for common
Emacs Lisp traps.

## Modules

| File | Purpose |
|------|---------|
| `lp/trace/code-agent-trace.org` | OTel span macros (loaded first) |
| `lp/sdk/emacs-mcp-server.org` | MCP HTTP server at `localhost:9999` — Emacs tools for external agents |
| `lp/backend/code-agent-pi-extensions.org` | Pi TS extensions (tangle): `emacs-mcp.ts` + `doom-loop.ts` |
| `code-agent.el` | Package entry — loads the modules above via literate-elisp |

Load with `(require 'code-agent)` or per-file `literate-elisp-load`.
`ARCHITECTURE.org` holds the meta-map; per-module design lives in each
.org file's prose (design-stays-in-org rule).

## Rules

### Code style
- `defcustom` with `:type` for user-facing options; `defvar` for hooks
- Internal functions double-dash: `emacs-mcp-server--internal-fn`
- Macro re-expansion: when a macro in `code-agent-trace.org` changes,
  reload every module that uses it — old bodies keep the old expansion

### Testing
- All tests in `tests/*.el`, never in `.org` files
- Do NOT run test suites via `evalElisp` (blocks Emacs) — use `make`
- `make check` is the pre-commit gate; the git hook runs it

### Error handling
- Process filters must never signal errors (kills the process)
- Use `condition-case` in all callbacks

### Secrets — NEVER hardcode
API keys, tokens, paths with usernames, customer data: env vars /
`~/.local/certs/` / `${{ secrets.X }}` only.  Detection layers:
pre-commit gitleaks, CI gitleaks, release full-history sweep.  Full
list: `.claude/rules/secrets.md`.  If a secret leaks, rotate it.

### Lessons file (`tasks/lessons.md`)
Every user correction or runtime trap not caught by tests → 4-line
entry (date / mistake / context / rule).  Recur ≥3 times → promote to
a CLAUDE.md rule.

### CI
After every `git push`, monitor GitHub Actions until the workflow
passes (`gh run list` / `gh run watch`); fix and re-push on failure.

## Current focus

The org-ai-agent-pi-topics design (`lp/_drafts/draft.org`): org
headings as concurrent Pi chat topics — Goal/Result durable in org,
live chat via embedded `pi-coding-agent` (`reference/pi-coding-agent`),
session record in Pi's JSONL store, GTD-aligned lifecycle.  Research
references live in `reference/pi` (Pi monorepo) and
`reference/pi-coding-agent` (Emacs frontend).
