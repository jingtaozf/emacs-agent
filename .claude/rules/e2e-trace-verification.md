# E2E Trace Verification via Live Emacs

When debugging Phoenix tracing issues, verify fixes end-to-end using a real
AI block execution — not just unit tests or manual curl.

## Steps

1. **Create a temp org file** under `tests/fixtures/`:
   ```elisp
   (find-file "/path/to/tests/fixtures/trace-test.org")
   ```

2. **Insert an SDD story** with `claude-org-insert-sdd` or manually:
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

3. **Open terminal tab** via `claude-org-cmux-open-tab` or menu

4. **Execute the AI block** via `claude-org-execute` (C-c C-c)

5. **Check Phoenix** for root spans:
   ```bash
   curl -s -X POST http://localhost:6006/graphql \
     -H "Content-Type: application/json" \
     -d '{"query": "query { node(id: \"UHJvamVjdDoy\") { ... on Project { spans(first: 10, sort: {col: startTime, dir: desc}) { edges { node { name parentId startTime } } } } } }"}' \
     | python3 -c "import sys,json; [print(f'{s[\"node\"][\"name\"]:40s} parent={s[\"node\"][\"parentId\"] or \"NULL(root)\"}') for s in json.load(sys.stdin)['data']['node']['spans']['edges']]"
   ```

6. **Verify**: At least one span with `parent=NULL(root)` should appear

## When to use

- After modifying `claude-agent-trace.org` (span creation)
- After modifying `python/claude_agent/otel_bridge.py` (span export)
- After modifying `python/claude_agent/otel_setup.py` (OTel configuration)
- When root spans are missing from Phoenix UI

## Key services

| Service | URL | Purpose |
|---------|-----|---------|
| Phoenix UI | http://localhost:6006 | Trace viewer |
| OTel Bridge | http://localhost:7331 | Elisp → OTel relay |
| Bridge health | http://localhost:7331/health | Liveness check |

## Cleanup

Delete the temp org file after verification.
