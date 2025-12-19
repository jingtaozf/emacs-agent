# Claude Agent SDK - Test Suite

This directory contains the test suite for the Claude Agent SDK.

## Test Structure

```
tests/
├── test-claude-agent-unit.el         # Unit tests for claude-agent.org
├── test-claude-agent-integration.el  # Integration tests for claude-agent.org
├── test-claude-org-unit.el           # Unit tests for claude-org.org
├── test-claude-org-integration.el    # Integration tests for claude-org.org
├── fixtures/
│   ├── test-session.org              # Demo org file for integration tests
│   └── test-config.el                # Shared test configuration and helpers
└── README.md                         # This file
```

## Test Types

### Unit Tests

Unit tests do **not** make actual API calls. They test:
- Data structure creation and validation
- JSON parsing and protocol handling
- Session management logic
- Permission system
- IDE context collection
- Org property parsing
- Block detection
- Utility functions

**Run unit tests:**
```bash
make test-unit
```

Or for specific components:
```bash
make test-agent-unit    # claude-agent unit tests only
make test-org-unit      # claude-org unit tests only
```

### Integration Tests

Integration tests make **real API calls** to Claude. They verify:
- End-to-end query execution
- Session continuity and recovery
- Tool use (Read, Glob, etc.)
- Multi-session concurrency
- Error handling and recovery
- Permission modes
- Org-mode workflow

**Run integration tests:**
```bash
make test-integration
```

⚠️ **Requirements for integration tests:**
- Valid `ANTHROPIC_API_KEY` environment variable
- Network connectivity
- May incur API usage costs

## Running Tests

### Quick Start

```bash
# Run all unit tests (fast, no API calls)
make test-unit

# Run all tests (unit + integration)
make test

# Run specific test file
emacs -Q --batch -L . -L tests \
  --eval "(require 'literate-elisp)" \
  --eval "(literate-elisp-load \"claude-agent.org\")" \
  -l tests/test-claude-agent-unit.el \
  -f ert-run-tests-batch-and-exit
```

### Interactive Testing

To run tests in Emacs UI for debugging:

```bash
make test-interactive
```

This opens Emacs with all test files loaded and runs `M-x ert`.

### Continuous Testing

Watch for file changes and auto-run tests:

```bash
make watch
```

(Requires `fswatch`: `brew install fswatch`)

## Writing Tests

### Unit Test Template

```elisp
(ert-deftest test-feature-name ()
  "Test that feature works correctly."
  (let ((result (my-function arg1 arg2)))
    (should (equal expected result))
    (should-not (null result))))
```

### Integration Test Template

```elisp
(ert-deftest test-integration-feature ()
  "Test feature with real API."
  ;; Skip if no API key
  (test-claude-skip-unless-api-key)

  ;; Use temporary fixture
  (test-claude-with-fixture
   (lambda (org-file)
     (let ((response (test-claude-execute-and-wait org-file 1)))
       (test-claude-assert-response-not-empty response)
       (test-claude-assert-response-contains response "expected text")))))
```

## Test Fixtures

### test-session.org

The main integration test fixture contains:

1. **Basic Query Tests** - Simple Q&A to verify execution
2. **Session Scope Tests** - Multiple independent sessions
3. **Tool Use Tests** - Read, Glob, and other tools
4. **Multi-Session Concurrency** - Parallel execution
5. **Error Recovery Tests** - Session expiry and recovery
6. **Permission Mode Tests** - Different permission levels
7. **Block Insertion Tests** - Auto-numbering features

You can manually test features by:
1. Opening `tests/fixtures/test-session.org`
2. Enabling `claude-org-mode`
3. Executing AI blocks with `C-c C-c`

## Test Helpers

The `test-config.el` file provides:

- `test-claude-skip-unless-api-key` - Skip test if no API key
- `test-claude-with-fixture` - Execute with temporary org file
- `test-claude-execute-and-wait` - Execute instruction and wait
- `test-claude-assert-*` - Assertion helpers
- `test-claude-wait-for-completion` - Wait for query completion

## Coverage

Current test coverage:

### claude-agent.org
- [x] Data structures (options, blocks, messages)
- [x] JSON protocol parsing
- [x] Session management (keys, UUID mapping)
- [x] Permission system
- [x] IDE context collection
- [x] Query cancellation
- [x] CLI argument building
- [ ] Interactive client (planned)
- [ ] Hook system (planned)
- [ ] Usage mode-line (planned)

### claude-org.org
- [x] Session ID management
- [x] SDK UUID storage
- [x] Session recovery
- [x] Block detection
- [x] Project configuration
- [x] Permission modes
- [x] Environment variables
- [x] Session state
- [x] Block insertion
- [ ] Execution workflow (integration)
- [ ] Multi-session concurrency (integration)
- [ ] Header line updates (integration)

## Continuous Integration

TODO: Add CI configuration for:
- GitHub Actions workflow
- Automated test runs on push
- Coverage reporting
- Integration test scheduling (to manage API costs)

## Debugging Tests

### View Test Output

```bash
# Run with verbose output
EMACSLOADPATH=. emacs -Q --batch -L tests \
  --eval "(setq ert-batch-backtrace-right-margin 200)" \
  -l tests/test-claude-agent-unit.el \
  -f ert-run-tests-batch-and-exit
```

### Run Single Test

```elisp
;; In Emacs
M-x ert RET test-name RET

;; Or from command line
emacs -Q --batch -L . -L tests \
  -l tests/test-claude-agent-unit.el \
  --eval "(ert-run-tests-batch-and-exit 'test-claude-agent-options-construction)"
```

### Debug Test Failures

1. Run test interactively: `M-x ert RET test-name RET`
2. If failed, press `b` to show backtrace
3. Press `l` to show messages log
4. Press `r` to re-run test with debugger

## Best Practices

1. **Unit tests first** - Write unit tests before integration tests
2. **One assertion per test** - Keep tests focused and specific
3. **Descriptive names** - Use clear test names describing what is tested
4. **Clean up** - Always clean up resources (files, buffers, processes)
5. **Fast feedback** - Keep unit tests fast (< 1s each)
6. **API limits** - Be mindful of integration test API usage
7. **Deterministic** - Tests should produce same results every run
8. **Isolated** - Tests should not depend on each other

## Contributing

When adding new features:

1. Add unit tests for core logic
2. Add integration tests for end-to-end workflows
3. Update this README with coverage status
4. Ensure all tests pass: `make test-unit`
5. Run integration tests before committing: `make test-integration`

## License

Same as the main project.
