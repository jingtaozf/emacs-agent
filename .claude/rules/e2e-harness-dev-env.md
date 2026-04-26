# E2E Harness Dev Environment

For any feature, prepare or reuse test workspaces and test stories in the
E2E test org file and update the instruction org file about how to test
this feature.

## Files

| File | Purpose |
|------|---------|
| `tests/e2e/org/workspace-test.org` | Living test org file with workspaces and stories |
| `tests/e2e/living-workspace-test.org` | Instruction runbook: how to test each feature |

## Rules

- **Never reset** `workspace-test.org` — it is a living file with real cmux state
- **Add new stories** for new features instead of overwriting existing ones
- **Test with actual cmux + Emacs** via evalElisp MCP and cmux CLI — no mocks
- **Record results** in `living-workspace-test.org` with pass/fail and date
- **Reproduce bugs first** using the test org file before fixing
- **Verify fixes** using the same test org file after fixing

## Workflow

1. Open `workspace-test.org` in Emacs (already has code-agent-org-mode)
2. Navigate to relevant test workspace/story
3. Execute ai block or call functions via evalElisp
4. Verify results via evalElisp + cmux CLI commands
5. Document test in `living-workspace-test.org`
