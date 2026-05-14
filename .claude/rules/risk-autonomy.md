# Risk → Autonomy Level

Match supervision granularity to task risk. *Don't* run auth changes at L4
autonomous; *don't* approve every line of a refactor at L1.

| Task domain | Required level | What it means |
|-------------|----------------|---------------|
| Auth, secrets, payments, DB migrations, supply-chain (lockfile changes) | **L3 (supervised)** | Every bash/edit step requires explicit approval. Plan mode strongly preferred. |
| Cross-module refactor, protocol changes, performance-sensitive paths | **L3-L4** | Plan mode for design; L4 once plan is approved. |
| Single-module business logic, new feature behind a flag | **L4 (autonomous)** | Agent runs end-to-end; reviewer judges outcomes, not steps. |
| Docs, tests, refactor template / boilerplate, formatting | **L4** | Same as above. |
| Exploration, prototype, throwaway scripts | **L1-L2** | Inline accept (Cursor) or interactive assist (Copilot). |

L3 = "Supervised Agents" (Cursor-style: requires permission per step).
L4 = "Autonomous Agents" (Claude Code-style: end-to-end, review outcome).

## Hard approval gates

Regardless of declared level, destructive ops always ASK:

- `rm -rf`
- DB migration (any ALTER/DROP/CREATE)
- `git push --force` to main/master
- `npm publish` / `cargo publish` / `pip upload`
- `gh pr merge` (especially with `--admin`)
- Files >500 KB
- Dependency manifest changes (lockfile, pyproject.toml, package.json)

Claude Code's default *Bash command requires permission* gate handles most
of these — don't disable.

## Source

Lens #12 in `tasks/ai-codebase-mastery-action-plan.org` and the underlying
research at `~/projects/dummy/notes/ai-codebase-mastery.org` (4-level autonomy
spectrum: L1 Enhanced Autocomplete / L2 Interactive Assistants / L3 Supervised /
L4 Autonomous).
