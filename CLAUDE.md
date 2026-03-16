# Claude Agent SDK for Emacs

## Commands

```bash
make test-smoke         # Fast syntax check (< 2s) — run after every edit
make test-unit          # Run all unit tests (~13s)
make test-unit-parallel # Run unit tests in parallel (~4.5s)
make test-agent-unit    # Run claude-agent unit tests only
make test-org-unit      # Run claude-org unit tests only
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
- See `docs/ELISP_IDIOMS.org` for common Emacs Lisp traps

## Architecture

See `ARCHITECTURE.org` for module boundaries, invariants, and extension points.

### Literate Programming

All source code lives in `.org` files using `literate-elisp`:
- `claude-agent.org` — Core SDK: process management, JSON protocol, query API
- `claude-org.org` — Org integration: AI blocks, sessions, streaming
- `emacs-mcp-server.org` — MCP server for Emacs tools

Load with: `(literate-elisp-load "claude-agent.org")`

### Key Layers

| Layer | File | Purpose |
|-------|------|---------|
| Core SDK | `claude-agent.org` | CLI subprocess, JSON stream parsing |
| Org Integration | `claude-org.org` | `#+begin_src ai` blocks, response sections |
| MCP Server | `emacs-mcp-server.org` | Emacs tools exposed to Claude |
| Entry Point | `claude-code.el` | Package requires, autoloads |

### Data Flow

1. User writes query in `#+begin_src ai` block, presses `C-c C-c`
2. `claude-org-execute` validates block, creates session
3. `claude-agent-query` spawns CLI subprocess with `--output-format stream-json`
4. Process filter parses newline-delimited JSON, dispatches to callbacks
5. Tokens stream into response section below the AI block

### Session Management

- Sessions identified by buffer-local session keys
- State stored in `claude-org--sessions` hash table
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
- Internal functions use double-dash: `claude-org--internal-fn`
- Public API uses single-dash: `claude-org-public-fn`

### Literate Elisp Caveats
- `lexical-binding: t` in org headers is **ignored** by literate-elisp
- Use `lexical-let` (from `cl-lib`) for closures in callbacks/timers
- Use `cond` + `equal` instead of `pcase` string patterns (dynamic binding)
- After editing `.org` files, **always reload**: `(literate-elisp-load "file.org")`

### Testing
- All tests in `tests/*.el`, never in `.org` files
- Tests use `:tags` for filtering: `:unit`, `:integration`, `:fast`, `:stable`
- Do NOT run tests via `evalElisp` MCP tool — may hang Emacs
- Use `make test` or `make test-unit` in terminal instead
- Mock CLI tests use `MOCK_SCENARIO` env var for fixture selection

### CI Monitoring
- After every `git push`, monitor GitHub Actions in a background agent
  until the workflow passes (use `gh run list` / `gh run watch`)
- If CI fails, fix the issue and push again

### Error Handling
- Process filters must never signal errors (kills the process)
- Use `condition-case` in all callbacks
- Sentinel runs after process exits — clean up state there

### ARCHITECTURE.org Maintenance
After architectural changes, update `ARCHITECTURE.org`:
- New .org module added → update Module Boundary Diagram
- Dependency changed → update diagram arrows
- New invariant discovered → add to Invariants section
- New extension point created → add to Extension Points

### Harness Feedback Loop
When an agent mistake is not caught by existing tests:
1. Fix the immediate issue
2. Add a structural test to `test-structural.el` that catches this class of mistake
3. Include a `FIX:` message explaining the correct action
4. Update `ARCHITECTURE.org` invariants if it reveals a cross-module rule

The harness grows with each mistake — rules become multipliers.

## Further Reading

| Topic | Location |
|-------|----------|
| Architecture map | `ARCHITECTURE.org` |
| Design docs | `docs/design-docs/` |
| Research findings | `docs/research/` |
| Product specs | `docs/product-specs/` |
| References | `docs/references/` |
| Elisp idioms | `docs/ELISP_IDIOMS.org` |
| Literate programming | `docs/literate-programming-principles.org` |
| Full API docs | `claude-agent.org` section headers |
| Org integration | `claude-org.org` section headers |
| Test fixtures | `tests/fixtures/` |
| Mock CLI | `tests/mock-claude-cli.sh` |
| Docker sandbox | `.devcontainer/` |
| Prompt tags | `prompts/tags/` |
| Reference SDK | `reference/claude-agent-sdk-python/` |
