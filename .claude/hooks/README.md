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
(e.g. `LITERATE_AGENT_TANGLE_MAKE_TARGET=tangle-pi-extensions`)
reach the plugin's hook scripts.

## Files in this directory

- `_env.sh` — project-specific environment overrides for the
  plugin hooks.  Post-2026-08-13 cleanup the repo's only tangle is
  the Pi TS extensions (outputs outside the repo), so no in-repo
  tangled files are guarded.
- `README.md` — this file.

## What if I don't load the plugin?

The hooks simply don't fire; LP guardrails (bare-`*` rejection,
structure checks) are absent but nothing breaks.

## Permanent install (after literate-agent is on GitHub)

Once `literate-agent` is published:

```bash
claude plugin marketplace add jingtaozf/literate-agent
claude plugin install literate-agent@literate-agent --scope user
```

Then `--plugin-dir` is no longer needed — the plugin loads every
session for every project, and this project's `_env.sh` still
provides the per-project overrides.
