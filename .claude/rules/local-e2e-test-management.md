# Local E2E Test Management

## Principle

Maintain E2E tests that verify features work in the real environment (Phoenix,
cmux, Claude Code). These tests are **excluded from CI** (GitHub Actions) but
run on the developer's local machine.

## Structure

| Directory | Purpose | CI? |
|-----------|---------|-----|
| `tests/test-e2e-local-*.el` | Elisp E2E tests (`:local-e2e` tag) | No |
| `tests/fixtures/trace-e2e-test.org` | Fixture org file for trace tests | No |
| `make test-e2e-local` | Run all local E2E tests | No |
| `make test-unit` | Unit tests (fast, no external deps) | Yes |
| `make check` | Pre-commit gate (lint + unit + python) | Yes |

## When to create local E2E tests

- After fixing a tracing bug (verify spans appear in Phoenix)
- After changing terminal backend execution paths
- After modifying the OTel bridge or exporter
- When a bug can only be reproduced with real services

## How to run

```bash
# Ensure services are running
make phoenix-start      # Phoenix at :6006
make otel-server &      # Bridge at :7331

# Run local E2E tests
make test-e2e-local
```

## Tag convention

- `:local-e2e` — requires Phoenix + OTel bridge (skip-unless checks liveness)
- `:local-cmux` — requires cmux CLI (future)
- `:local-iterm2` — requires iTerm2 (future)

## Test fixtures

Keep test fixtures in `tests/fixtures/` — they are committed to git so other
developers can use them. Tests use `skip-unless` to gracefully skip when
services are not running.
