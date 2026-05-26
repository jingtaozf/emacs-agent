# code-agent hooks — loaded via literate-agent plugin

This project's LP hooks (block edits to tangled `.py`, auto-tangle on
`.org` save, bare-`*` rejection, etc.) are not stored here — they
live in the `literate-agent` plugin at
`~/projects/literate-agent/hooks/`.

## How they load

literate-agent is loaded as a Claude Code plugin via the
`--plugin-dir` flag at session start:

```bash
claude --plugin-dir ~/projects/literate-agent
```

The plugin's `hooks/hooks.json` registers PreToolUse / PostToolUse
hooks. Each hook is wrapped to source `_env.sh` (this directory)
**if it exists** — that's how project-specific env overrides
(e.g. `LITERATE_AGENT_TANGLE_MAKE_TARGET=tangle-python`) reach
the plugin's hook scripts.

## Files in this directory

- `_env.sh` — project-specific environment overrides for the
  plugin hooks. Sourced by the literate-agent hooks before they run.
  Tune for code-agent's single-repo Python LP layout (`.org` at
  root, `make tangle-python` target).
- `README.md` — this file.

## What if I don't load the plugin?

The hooks simply don't fire. Edit/Write/MultiEdit on tangled `.py`
files won't be blocked, auto-tangle won't run on `.org` saves.
Nothing breaks, but the LP guardrails are absent.

## Permanent install (after literate-agent is on GitHub)

Once `literate-agent` is published:

```bash
claude plugin marketplace add jingtaozf/literate-agent
claude plugin install literate-agent@literate-agent --scope user
```

Then `--plugin-dir` is no longer needed — the plugin loads every
session for every project, and this project's `_env.sh` still
provides the per-project overrides.
