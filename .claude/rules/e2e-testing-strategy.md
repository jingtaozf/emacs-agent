# E2E Testing Strategy: Real Harness + Simulated Speed

## Rule: Always maintain a real E2E harness

Set up a harness dev environment so we can run E2E tests against actual
iTerm2 + Claude Code + Emacs. This is how we discover real-world behaviors
and issues that mocks cannot reproduce (e.g., `save-buffer` failing in
temp buffers, `org-up-heading-safe` skipping the current heading,
`call-process` mixing stderr into stdout).

## Rule: Simulate external tools, never Emacs

When converting real E2E tests into fast repeatable tests:

1. **Mock only external dependencies** (iTerm2 API, Claude Code CLI) —
   use fixture data captured from actual E2E runs.
2. **Always use real Emacs** — real org buffers, real `org-entry-get`,
   real `org-set-property`, real `save-buffer`. Never mock org-mode
   internals.
3. **Use file-backed buffers** in tests (`make-temp-file` +
   `find-file-noselect`), not `with-temp-buffer`, when the code under
   test calls `save-buffer` or reads `buffer-file-name`.

## Workflow

1. Build and run real E2E tests first (Layer 4: iTerm2 + Claude + Emacs).
2. Capture fixture data (session IDs, status JSON, screen output).
3. Write simulated tests that mock only the single external call point
   (e.g., `claude-org-iterm2--call`) using captured fixtures.
4. When a user reports a bug that simulated tests missed, reproduce it
   in the real harness first, then add a regression test to both layers.

## Rationale

Mocking Emacs internals hides integration bugs. Every user-reported bug
in the iTerm2 backend (empty session ID, wrong heading lookup, stderr
in stdout, save-buffer in temp buffer) was invisible to pure-mock tests
but immediately caught by real org buffer interactions.
