# TODO — claude-do: simplify emacs-agent to org-driven workspace manager

Delegated to workspace `Emacs-claude dev2` (workspace:15, surface:31).
Decisions: (a) audience = maintainer only → aggressive deletion OK;
(b) Pi = cmux agent profile only (`:AGENT_TYPE: pi`), drop RPC backend deep integration.
Constraint: NO git commit/push — leave all changes in working tree.
Verifier snapshots `git diff` to /tmp/claude-do/unitN.diff after each pass.

## Unit 0 — fix python test baseline (make check currently RED) — DONE
- [x] Root cause was env, not deleted module: `uv run pytest` missing `--extra dev`;
      Makefile test-python now `uv run --extra dev pytest -v`. 3 orphan approved.txt deleted.
- [x] VERIFIED by me: `make check` exit 0, `109 passed in 0.93s`. Diff scope: Makefile + 3 snapshots.
- Acceptance: `make check` exits 0. ✅

## Unit 1 — remove dead response-sync code in cmux.org — DONE
- [x] Removed dead Response Delivery section + stale refs in code-agent-python.org,
      E2E_TASKS.org; deleted dead fixture loop-autonomous-response-test.org;
      kept one-way dispatch pipeline + handle_permission bridge.
- [x] VERIFIED by me: grep → 0 hits; `make check` exit 0 (109 passed).
- Note: executor flagged `code-agent-org-cmux--query-completed` as possibly caller-less
      (handle_response was its only known invoker) — investigate in a later unit.
- Acceptance: grep 0 hits; `make check` 0. ✅

## Unit 1.5 — fix test-org-unit baseline (pre-existing, product-surface tests) — DONE
- [x] 167/41-failing → 131/0. Deleted dead test files (plugin-discovery, slash-completion),
      rewrote workspace tests; added 4 NEW tests for `code-agent-org-new-workspace` (had zero coverage).
- [x] Fixed REAL production bug: header-line.org:226 unconditionally called deleted
      `--total-queue-count` → enabling code-agent-org-mode threw void-function. Queue badge removed.
- [x] `make check` now gates org-surface tests (Makefile:646).
- [x] VERIFIED by me: `Ran 131 tests, 131 results as expected, 0 unexpected`; check exit 0.
- Acceptance ✅

## Unit 2.5 — delete unreachable cmux execute-ai-block pipeline (executor-flagged)
- [x] Unreachability CONFIRMED (generic has zero call sites; C-c C-c unbound; no org-babel `ai`
      registration; `code-agent-org-execute` never existed). Deleted Execution section +
      pre-flight hook-verification subsection (~355 lines) + cmux backend execute-block override.
      Kept shared generic (tmux still specializes it).
- [x] VERIFIED by me: acceptance grep → 2 doc-mention hits only; `make check` exit 0.
- Acceptance ✅  — DONE

## Unit 2 — remove Verbose Output live mirror — DONE
- [x] Deleted whole mirror section + 4 wiring sites; fixed stale prose claiming mirror/Stop-hook alive.
- [x] Shared-plumbing audit: status detection reads hook-status FILE (one-shot capture-pane fallback),
      query-completion is MCP Stop-hook driven — no mirror dependency. multiplexer.org's shared
      verbose defcustom left for tmux (cross-backend, out of scope).
- [x] VERIFIED by me: 0 verbose defuns in cmux.org (3 doc-only hits); `make check` exit 0.
- Acceptance ✅

## Unit 3 — delete ACP backend family — DONE
- [x] Deleted 4 ACP profiles + code-agent-jsonrpc.org (verdict: every jsonrpc caller was
      ACP-internal; pi-backend has its own transport) + 4 ACP test files + Makefile plumbing
      + README ACP section (~142 lines) + backend registry entries.
- [x] VERIFIED by me: `ls lp/backend/ | grep -i acp` → 0; grep → 2 removal-note hits only;
      `make check` exit 0 (rerun after one FLAKY `test-error-timeout-hung` failure —
      3 consecutive clean re-runs prove timing flake, unrelated to ACP).
- Note: flaky `test-error-timeout-hung` (tests/, timing-sensitive) — candidate for a
      dedicated de-flake unit. Stray untracked lp/org/code-agent-org-cmux.org.bak still
      contains ACP strings; left per no-delete rule — ask user to rm.
- Acceptance ✅

## Unit 4 — Pi trim to cmux profile — DONE
- [x] Deleted pi-backend.org + pi-ui.org + 9 pi RPC test files + 6 Makefile targets + registry
      entry + the `p` menu entry (live void-function risk). jsonrpc already gone in Unit 3.
- [x] DEVIATION (justified): pi-extensions.org KEPT — global Pi extension serving the kept
      cmux `:AGENT_TYPE: pi` profile (emacs_eval tool callbacks); onboarding doc moved into it.
- [x] Pre-existing bug found: `attachCmuxResponseBridge(pi);` dangling call (impl deleted by
      b029157 at HEAD) → removed call site + Known-gap comment. Terminal-typed prompt
      round-trip was ALREADY broken pre-session; now fails cleanly. Needs its own design unit.
- [x] VERIFIED by me: backend dir has only pi-extensions.org; live grep clean; pi profile
      intact (3 hits); `make check` all 4 phases PASSED.
- Acceptance ✅ (criterion 1 amended: pi-extensions.org justified keep)

## Unit 5 — chat/ + ide/ trim — DONE
- [x] Deleted chat/translate/refine + 2 test files + 2 translate test sections + README
      chat tutorial step (steps renumbered). code-agent.org (core SDK) kept — load-bearing.
- [x] claude-ide.org VERDICT: KEEP — launch/restore/restart all call `--ensure-ide-server`
      → claude-ide-start-server-in-directory; per-profile gate `:supports-ide t` (claude only).
      Zero dead fringes. IDE file-context is a differentiator vs plain orchestrators.
- [x] code-agent-title.org: kept per instruction but PROVEN UNUSED (only caller was the
      deleted execute pipeline) — decide later: delete or rewire onto new-workspace auto-title.
- [x] VERIFIED by me: chat dir = {code-agent, title, README}; grep 4 removal-notes only;
      `make check` all phases PASSED.
- Acceptance ✅

## Unit 6 — README north-star rewrite — DONE
- [x] 2232 → 339 lines. North Star up top; Quickstart = new-workspace n/r/s/I flow;
      every claimed command/property verified against live code (fboundp/boundp batch);
      agent-profile + permission tables transcribed from source, not paraphrased.
- [x] Cut sections whose code is dead (scheduled exec, link resolution, templates, tags,
      output formatting, system-prompt delivery — Python side severed).
- [x] VERIFIED by me: `make test-smoke` 3/3; `make check` all PASSED; acceptance grep 0;
      read the README head — on-message.
- Acceptance ✅

## Open flags for maintainer (from this run)
- [x] code-agent-title.org — DELETED 2026-07-09 per maintainer ("go 1 delete"), incl.
      loader line, README/INDEX/backend prose, static-analysis + structural allowlists.
      `code-agent-query-accumulate` kept (tested standalone SDK utility).
- [x] Stray lp/org/code-agent-org-cmux.org.bak — rm'd per maintainer ("4 rm").
- [ ] Pi terminal-typed prompt round-trip: broken since b029157 (pre-session); fails
      cleanly with Known-gap note in code-agent-pi-extensions.org — needs a design unit.
- [ ] Flaky `test-error-timeout-hung` (timing) — de-flake candidate.
- Committed + pushed on feat/pi-in-cmux per maintainer instruction 2026-07-09.

---

# Archive — claude-do: omp features not in default pi (DONE)

Delegated to workspace `Emacs-claude dev2` (workspace:30, surface:48).

## Unit 1 — Feature-diff research: oh-my-pi (omp) vs default Pi — DONE
- [x] Executor researched features present in oh-my-pi (can1357 fork) but
      absent in default Pi (`@earendil-works/pi-coding-agent`).
- [x] Grounded each claim in a source; self-reported benchmarks flagged UNVERIFIED.
- [x] Wrote structured findings to `/tmp/claude-do/omp-features.md`.
- [x] Wrote marker `/tmp/claude-do/omp-features.done.json` (status success).
- [x] VERIFIED by me: 4/4 spot-checks matched `reference/pi` source
      (7-tool set, usage.md:304 omissions, ACP-absent/RPC-present, no LSP/DAP).

### Acceptance (verified by ME, not the marker)
- Findings file exists, non-trivial, structured as a feature list.
- Spot-check ≥3 claims against `reference/pi` source / research doc — no hallucinated features.
- Each "omp-only" feature is plausibly absent in default pi (cross-check tool set).

---

# claude-do: dead-code removal — instances management (2026-07-11)

Delegated to workspace `Emacs-claude dev2` (workspace:15, surface:27).
Plan approved by user: ~/.claude/plans/glittery-baking-starfish.md
Discipline: no commit; make test-smoke after every edit; locate by
heading name (line numbers shifted by prior deletions).

Already done by planner (this session, verified green):
- [x] U0 periphery: 11 *~ backups, workspace-hooks.json(+~),
      prompts/refine-prompt.org deleted; Makefile SOURCES/compile/clean/
      all/INTEGRATION_TESTS fixed. Gate: test-smoke 3/3, test-unit
      246+56+68 all expected.
- [x] U1 (partial): backend.org dead Protocol 3 generic sections deleted
      (Specialisation table + Execute Block…Todos Update; Open Terminal
      Tab kept; intro rewritten); tmux-backend.org `** Protocol 3 — Org
      Integration` (execute-block + ready-banner-regex + wait helper +
      cancel-from-org) deleted; cmux-backend.org `*** Cancel From Org`
      deleted.

Remaining units (executor):
- [x] U1-finish: backend.org Message Event Hooks trim (keep
      code-agent-invocation-hook only; delete pre/post-tool-use-functions,
      stop-functions, `*** Event Dispatch Functions`); trim
      tests/test-backend-protocol3.el to open-terminal-tab + inheritance.
      Gate: make test-smoke && make test-backend-unit.
- [x] U2 verbose subsystem (backend.org Verbose Output; chat
      queries-show-verbose + badge; structural whitelist; backend.el trim).
      Gate: make test-org-unit test-backend-unit.
- [x] U3 engine core (backend.org bulk delete + 3 relocations;
      org-process registry fallback→cmux; 11 test files deleted + 5
      trimmed; Makefile/pre-commit sync). Gate: make test-unit test-org-unit.
- [x] U4 permission.org whole file + preset defcustom relocation.
      Gate: make check.
- [x] U5 lp/org+ide zero-caller functions (11). Gate: make test-org-unit.
- [x] U6 docs/prose sync + final gates.

All units completed 2026-07-11. Final gates (run by planner):
test-smoke 3/3, lint 7/7, test 30+8+68+119 all 0 unexpected,
cold-load (require 'code-agent) exit 0.
Cumulative: 46 files changed, 481 insertions(+), 11848 deletions(-),
15 files git-rm'd. Uncommitted per no-commit rule.
Follow-ups flagged by executor: backend.org Capability Matrix still
lists pre-pivot agent columns (pre-existing staleness);
code-agent-backend-filter-callbacks has zero test coverage (re-add
with cmux fixture); no python test for workspace_bridge.py.
