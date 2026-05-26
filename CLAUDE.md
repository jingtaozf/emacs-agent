# Claude Agent SDK for Emacs

## Setup + shared LP doctrine

Clone `literate-agent` (LP doctrine + plugin + shared scripts) then
launch Claude Code with `--plugin-dir`:

```bash
git clone https://github.com/jingtaozf/literate-agent.git ~/projects/literate-agent
claude --plugin-dir ~/projects/literate-agent ...
```

The `@`-import below pulls in 23 rules + language hints +
build-command conventions from literate-agent:

@~/projects/literate-agent/CLAUDE.md

Override `LITERATE_AGENT_HOME` if cloned elsewhere. Project-specific
overrides + code-agent-only rules continue below.

## Commands

```bash
make test-smoke         # Fast syntax check (< 2s) — run after every edit
make test-unit          # Run all unit tests (~13s)
make test-unit-parallel # Run unit tests in parallel (~4.5s)
make test-agent-unit    # Run code-agent unit tests only
make test-org-unit      # Run code-agent-org unit tests only
make test-backend-unit  # Run backend protocol unit tests
make test-mock          # Run mock CLI tests (no API, fast)
make test-integration   # Run integration tests (requires API key)
make lint               # Static analysis (undefined functions/variables)
make test-python        # Run Python CLI tool tests
make check              # lint + test-unit + test-python (pre-commit gate)
```

## Verification

After editing .org files:
```bash
make test-smoke        # Syntax check — loads all .org files (< 2s)
```

After any code change:
```bash
make test-unit         # Full unit tests (< 5s parallel)
make check             # lint + test-unit (pre-commit gate)
```

Before claiming code is buggy:
- Evaluate the expression via `evalElisp` to confirm behavior
- See `ELISP-IDIOMS.org` for common Emacs Lisp traps

## Environment: cmux + Emacs + Phoenix

You are running inside a **cmux workspace** — a terminal multiplexer for AI agents.
The full environment stack:

| Layer | Tool | What It Provides |
|-------|------|------------------|
| Terminal | cmux CLI | Workspace/pane/surface management, terminal I/O, browser automation |
| Editor | `evalElisp` MCP | Full Emacs control — org-mode, buffers, variables, arbitrary Elisp |
| Tracing | Phoenix (`localhost:6006`) | Execution traces, spans, latency — the experience store |

**cmux** — read any terminal, send commands, manage workspaces:
- `cmux tree` / `cmux identify --json` — discover workspace topology
- `cmux read-screen --surface <ref> --scrollback --lines N` — read terminal output
- `cmux send --surface <ref> "cmd"` + `cmux send-key enter` — execute commands
- `cmux browser <surface> snapshot --interactive` — browser DOM inspection
- See `/cmux` and `/cmux-browser` skills for full reference

**evalElisp** — read/modify Emacs state directly:
- Org properties, headings, buffer contents
- Session state, variables, function calls
- Reload code: `(literate-elisp-load "file.org")`

**Phoenix** — trace every AI block execution:
- Every execution produces spans: execute-ai-block, cmux-execute, send-text
- Query traces: `curl -s -X POST http://localhost:6006/graphql ...`
- Use `/phoenix-span` skill or check Phoenix UI at `http://localhost:6006`
- Traces are the experience store — inspect them to diagnose failures

## Tool-Use Protocol

### Core Rule: Real Execution Over Simulation

You have access to cmux CLI, `evalElisp` MCP, Phoenix traces, and shell commands.
**Use them.** Every claim must be backed by actual tool output.

Violations (NEVER do these):
- Writing "this should produce..." without running the command
- Creating a mock test when real execution is available
- Describing what `evalElisp` would return without calling it
- Saying "the buffer should contain..." without reading it via `evalElisp`
- Guessing cmux workspace state without running `cmux tree` or `cmux status`

### Show Your Evidence

In every response, include actual tool output supporting your claims.
Format: "I ran `[command]` and got `[actual output]`" — not "this should work."

### Greedy Debugging Protocol

When investigating any issue:
1. Reproduce with a real command (not by reading code alone)
2. Inspect actual state: `evalElisp` for Emacs variables, `cmux` for terminals
3. Form hypothesis, test it with another real command
4. Fix and verify with real execution
5. Never fix based on code reading alone

### Verification Sequence (after every code change)

1. Save the file
2. `make test-smoke` — syntax check
3. Reload in Emacs: `evalElisp` with `(literate-elisp-load "file.org")`
4. Execute the actual feature to verify it works
5. Inspect real results (buffer contents, cmux output, Phoenix traces)
6. Only then report to user with actual output

## Design Principles (read before editing)

LP doctrine + OOP protocol style live in `literate-agent` (imported
at the top of this file). code-agent-specific application:

`code-agent-backend.org` defines the canonical protocol
(`code-agent-backend-query`, `-cancel`, `-cleanup`,
`-classify-error`, …); `code-agent-acp-backend` and
`code-agent-claude-code-backend` each `cl-defmethod` those generics.
Callers in `code-agent-org.org` dispatch on the backend instance —
never branch on a string or symbol discriminator. New modules MUST
follow the same pattern.

**Tri-protocol refactor shipped** (2026-04-24): backend layer is
three protocols — lifecycle, agent wire, multiplexer wire — plus
org-integration; agent-family (Claude Code, OpenCode, Gemini, Codex)
and multiplexer-family (cmux, tmux) are symmetric siblings. See
`code-agent-backend.org` § "Tri-Protocol Architecture" +
`ARCHITECTURE.org`. No `CLAUDE_BACKEND` string-match branches in the
frontend.

## Architecture

See `ARCHITECTURE.org` for module boundaries, invariants, and extension points.

### Key modules

LP source lives in `.org` files loaded via `literate-elisp`:

| Layer | File | Purpose |
|-------|------|---------|
| Core SDK | `code-agent.org` | CLI subprocess, JSON stream parsing |
| Org Integration | `code-agent-org.org` | `#+begin_src ai` blocks, response sections |
| MCP Server | `emacs-mcp-server.org` | Emacs tools exposed to Claude / Pi |
| Pi (default-loaded; ext opt-in) | `code-agent-pi-{backend,extension}.org` | pi.dev RPC backend (auto-load) + TS extension tangling to `~/.pi/agent/extensions/emacs-mcp.ts`; `:CLAUDE_BACKEND: pi` |
| Entry Point | `code-agent.el` | Package requires, autoloads |

Load with: `(literate-elisp-load "code-agent.org")`. Data flow:
user writes a query in `#+begin_src ai`, hits `C-c C-c` →
`code-agent-org-execute` validates + creates a session →
`code-agent-query` spawns the CLI with `--output-format stream-json`
→ process filter parses newline-delimited JSON → tokens stream into
the response section below the AI block.

### Session Management

- Sessions identified by buffer-local session keys
- State stored in `code-agent-org--sessions` hash table
- SDK UUID maps Emacs sessions to Claude CLI sessions
- File-based session persistence via org properties

## Rules

### State Ownership: Emacs Stateful, Python Stateless
- **Emacs owns all state** — org properties, session data, CLI session IDs
- **Python scripts are stateless functions** — they receive state as parameters
  (CLI args, env vars) and return results; they do NOT independently read org
  properties to make decisions
- Example: `--resume <id>` is decided by Emacs (reads `CLAUDE_CLI_SESSION`
  property), passed as a CLI arg. Python `claude_sdd.py` just forwards it.
  Python must NOT call MCP to read the property and decide independently.
- Example: `SDD_SESSION_ID` env var is set by Emacs, read by Python hooks.
  Python hooks use it to identify which story they're serving.

### Code Style
- Use `defvar` for hooks (not `defcustom`) for existing hooks
- Use `defcustom` with `:type` keyword for new user-facing options
- Internal functions use double-dash: `code-agent-org--internal-fn`
- Public API uses single-dash: `code-agent-org-public-fn`

### Literate Elisp Caveats

See `~/projects/literate-agent/hints/elisp.org` — auto-activated by
the `lp-hint-elisp` skill when editing `.el` files or `.org` files
with Elisp src blocks. Project-specific addendum:

- **Macro re-expansion** (code-agent-specific): when a macro
  defined in `code-agent-trace.org` changes, ALL modules that USE
  that macro must also be reloaded — the old function bodies still
  carry the old macro expansion until each module reloads.

### Testing
- All tests in `tests/*.el`, never in `.org` files
- Tests use `:tags` for filtering: `:unit`, `:integration`, `:fast`, `:stable`
- Do NOT run tests via `evalElisp` MCP tool — may hang Emacs
- Use `make test` or `make test-unit` in terminal instead
- Mock CLI tests use `MOCK_SCENARIO` env var for fixture selection

### CI Monitoring
- After every `git push`, monitor GitHub Actions in a background agent
  until the workflow passes (use `gh run list` / `gh run watch`)

### Phoenix Trace Analysis
- When investigating bugs or unexpected behavior, check Phoenix traces at
  `http://localhost:6006` for the `emacs-agent` project
- Use the `/phoenix-span` skill or query the GraphQL API directly:
  ```bash
  curl -s -X POST http://localhost:6006/graphql -H "Content-Type: application/json" \
    -d '{"query": "query { node(id: \"UHJvamVjdDoy\") { ... on Project { spans(first: 10, sort: {col: startTime, dir: desc}) { edges { node { name spanId parentId spanKind statusCode startTime latencyMs attributes } } } } } }"}' | jq '.'
  ```
- Every AI block execution produces a trace with spans for: execute-ai-block,
  cmux-execute, send-text, permission events, response handling
- Span attributes include input.value, output.value, session IDs, tool names
- Use traces to verify: correct parent-child relationships, timing, errors
- If CI fails, fix the issue and push again

### Error Handling
- Process filters must never signal errors (kills the process)
- Use `condition-case` in all callbacks
- Sentinel runs after process exits — clean up state there

### ARCHITECTURE.org + Harness Feedback Loop

After architectural changes, update `ARCHITECTURE.org` (new module →
Module Boundary Diagram; new invariant → Invariants; new extension
point → Extension Points). When an agent mistake escapes the existing
tests: fix it, add a structural test to `tests/test-structural.el`
with a `FIX:` message, update `ARCHITECTURE.org` invariants if it
reveals a cross-module rule. The harness grows with each mistake.

### Secrets & sensitive data — **NEVER hardcode**

**NEVER** commit, log, or hardcode API keys, tokens, credentials, private
keys, `.env`-like bundles, absolute user paths, or real customer data.
Always use env vars / `~/.local/certs/` / `${{ secrets.X }}`.

If a secret leaks: **rotate it immediately** (`git rebase` does not erase it
from remote history).

Three detection layers run automatically:
**pre-commit** (`.pre-commit-config.yaml` → gitleaks),
**CI** (`.github/workflows/ci.yml` → gitleaks-action),
**release** (`gitleaks detect --no-banner --redact` full-history sweep).

Full prohibition list, MCP audit, and detection details:
[`.claude/rules/secrets.md`](.claude/rules/secrets.md) and
the *Security Audit* section of [`emacs-mcp-server.org`](emacs-mcp-server.org).

### Lessons file (`tasks/lessons.md`)

Every user correction or runtime trap not caught by tests → append a
4-line entry (date / mistake / context / rule) to `tasks/lessons.md`.
Recur ≥3 times → promote to a `CLAUDE.md` rule + add structural check to
`tests/test-structural.el`. Unknowns section: review quarterly, promote
high-frequency items into the most relevant code .org as a "Future Design"
subsection (the LP migration emptied `docs/design-docs/`).

Don't put new rules straight in CLAUDE.md — context rot is real (lens #5).

### Risk → Autonomy Level (lens #12)

See [`.claude/rules/risk-autonomy.md`](.claude/rules/risk-autonomy.md)
for the task-domain → required level table and hard approval gates. TL;DR:
auth/payments/migrations → **L3 supervised**; refactor/docs/tests → **L4
autonomous**; exploration → **L1-L2 inline**.

## Further Reading

| Topic | Location |
|-------|----------|
| Architecture map | `ARCHITECTURE.org` |
| Tech-debt backlog | `CODEBASE-REVIEW.org` |
| Design rationale ("why") log | `RATIONALE.md` |
| Tri-protocol refactor (shipped) | `code-agent-backend.org` → "Tri-Protocol Architecture" |
| Research findings | woven into the relevant code .org as Background / Research subsections (the LP migration emptied docs/research/; SDD workflow auto-recreates the dir per-story when needed) |
| Elisp idioms | `ELISP-IDIOMS.org` |
| Literate programming | `.claude/rules/literate-programming-document-first.md` |
| Full API docs | `code-agent.org` section headers |
| Org integration | `code-agent-org.org` section headers |
| Test fixtures | `tests/fixtures/` |
| Mock CLI | `tests/mock-claude-cli.sh` |
| Docker sandbox | `.devcontainer/` |
| Prompt tags | `prompts/tags/` |
| Reference SDK | `reference/code-agent-sdk-python/`; pi.dev source `reference/pi/` (submodule); Pi E2E `make test-e2e-pi` |

## Final Reminder

The single most important rule in this project: **always use real tools.**
Run commands. Call `evalElisp`. Execute cmux operations. Check Phoenix traces.
Never simulate, never mock when real execution is possible, never guess when
you can check.
