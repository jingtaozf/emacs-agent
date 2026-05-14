# Secrets & sensitive data — full list

## What never to commit

- API keys / tokens (Anthropic, OpenAI, GitHub, npm, PyPI, Bitbucket, Slack, Linear, …)
- Database credentials, connection strings (including SQLite paths in CI artifacts)
- Cookies, session IDs, OAuth client secrets, refresh tokens
- Private keys (`*.pem`, `*.key`, `*.p12`, SSH keys, GPG passphrases)
- `.env` / `.envrc` / Doppler / 1Password secret bundles — keep these in
  `~/.local/certs/` or env vars only
- User home paths (`/Users/<name>`) or absolute project paths in committed
  files (use `~` or env vars)
- Phone numbers, email addresses, real customer names — use synthetic data
  in fixtures

## What to do instead

Reference secrets via:

- Python: `os.environ[...]` / `os.getenv(...)`
- Elisp: `(getenv ...)`
- GitHub Actions: `${{ secrets.X }}`
- CI artifacts: load from a secret store (1Password / Doppler / Vault), never
  inline

## Rotation

If a secret leaks into a commit, **rotate it immediately**. `git rebase -i`
to remove the line is **not** enough — the value is in remote history. Treat
any push to `origin` as a permanent leak.

## Detection layers (in order)

1. **Pre-commit hook**: `gitleaks` via `.pre-commit-config.yaml`. Fast, runs
   on every commit, catches staged content. Activate locally with:
   `pip install pre-commit && pre-commit install`.

2. **CI**: `gitleaks-action` job in `.github/workflows/ci.yml`. Runs on push
   and PR; full history scan with `fetch-depth: 0`.

3. **Pre-release**: manual full-history sweep:

   ```bash
   gitleaks detect --no-banner --redact
   ```

## Source

Lens #10 in `tasks/ai-codebase-mastery-action-plan.org`. OWASP LLM Top 10
ranks Sensitive Information Disclosure as #2.
