# E2E Trace Verification via Live Emacs

When debugging Phoenix tracing issues, verify fixes end-to-end using a real
AI block execution — not just unit tests or manual curl.

## Steps

1. **Create a temp org file** under `tests/fixtures/`:
   ```elisp
   (find-file "/path/to/tests/fixtures/trace-test.org")
   ```

2. **Insert an SDD story** with `code-agent-org-insert-sdd` or manually:
   ```org
   * Trace Test
   :PROPERTIES:
   :CLAUDE_SESSION_ID: sdd-trace-test-TIMESTAMP
   :CLAUDE_BACKEND: cmux
   :END:
   ** Workflow :sdd:
   #+begin_src ai
   echo hello trace test
   #+end_src
   ```

3. **Open terminal tab** via `code-agent-org-cmux-open-tab` or menu

4. **Execute the AI block** via `code-agent-org-execute` (C-c C-c)

5. **Check Phoenix** for root spans:
   ```bash
   curl -s -X POST http://localhost:6006/graphql \
     -H "Content-Type: application/json" \
     -d '{"query": "query { node(id: \"UHJvamVjdDoy\") { ... on Project { spans(first: 10, sort: {col: startTime, dir: desc}) { edges { node { name parentId startTime } } } } } }"}' \
     | python3 -c "import sys,json; [print(f'{s[\"node\"][\"name\"]:40s} parent={s[\"node\"][\"parentId\"] or \"NULL(root)\"}') for s in json.load(sys.stdin)['data']['node']['spans']['edges']]"
   ```

6. **Verify**: At least one span with `parent=NULL(root)` should appear

## When to use

- After modifying `code-agent-trace.org` (span creation)
- After modifying `python/code_agent/otel_bridge.py` (span export)
- After modifying `python/code_agent/otel_setup.py` (OTel configuration)
- When root spans are missing from Phoenix UI

## Key services

| Service | URL | Purpose |
|---------|-----|---------|
| Phoenix UI | http://localhost:6006 | Trace viewer |
| OTel Bridge | http://localhost:7331 | Elisp → OTel relay |
| Bridge health | http://localhost:7331/health | Liveness check |

## cmux Dev Build

To test against a locally-built cmux:

```bash
# Build (first time — needs zig, Xcode, Metal Toolchain)
cd reference/cmux
./scripts/setup.sh
./scripts/reload.sh --tag emacs-test

# Relaunch with open socket (allowAll mode for dev)
pkill -f "cmux DEV emacs-test"
open -g "path/to/cmux DEV emacs-test.app" \
  --env CMUX_SOCKET_MODE=allowAll \
  --env CMUX_SOCKET_PATH=/tmp/cmux-debug-emacs-test.sock
```

Then in Emacs:
```elisp
(setq code-agent-org-cmux-socket-path "/tmp/cmux-debug-emacs-test.sock")
;; To switch back: (setq code-agent-org-cmux-socket-path nil)
```

## Cleanup

Test fixtures in `tests/fixtures/` are committed — don't delete them.
