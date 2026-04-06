# E2E Quality Team Loop — Proposal

## Overview

A `/loop 30m` agent that acts as a professional E2E quality team:
finds issues via live testing against real cmux + Emacs, fixes them
autonomously, commits, and moves to the next gap. Extends the existing
`quality-loop-prompt.org` with a new **Live E2E** priority section.

## Architecture

```
/loop 30m tests/e2e/quality-loop-prompt.org
         │
         ▼
┌─────────────────────────────────────┐
│  Each 30-min iteration:             │
│  1. Pick highest-priority gap       │
│  2. Add test to workspace-test.org  │
│  3. Execute via evalElisp + cmux    │
│  4. Verify: org buffer + cmux CLI   │
│  5. Fix code if broken              │
│  6. Add simulated test for CI       │
│  7. Record in living-workspace-test │
│  8. Commit and push                 │
└─────────────────────────────────────┘
```

## What Gets Added to quality-loop-prompt.org

### New Section: `** P0-E2E — Live E2E Coverage Gaps`

Placed after existing P4. Ordered by user impact.

### Priority Queue (57 items across 10 journey groups)

#### Group 1: Workspace Lifecycle (P0-E2E, 8 items)
| ID | Test | What it verifies |
|----|------|------------------|
| E01 | Launch fresh workspace | new-workspace → surface created, org props set |
| E02 | Restore existing workspace | ensure-session phase 1: hash tables rebuilt |
| E03 | Recover stale UUID after cmux restart | ensure-session phase 2: name lookup |
| E04 | Launch when no workspace exists | ensure-session phase 3: new workspace |
| E05 | Restart Claude Code in existing tab | claude-org-cmux-restart: /exit + relaunch |
| E06 | Open tab / focus workspace | open-tab: select-workspace + set-app-focus |
| E07 | Close workspace + cleanup | close: hash tables cleared, state removed |
| E08 | Workspace alive-p with dead UUID | alive-p returns nil, no crash |

#### Group 2: Color & Sidebar (P0-E2E, 6 items)
| ID | Test | What it verifies |
|----|------|------------------|
| E09 | Apply named color (Red, Blue, Teal) | set-status pill appears with correct color |
| E10 | Apply hex color (#C0392B) | cmux sidebar-state shows custom_color |
| E11 | Apply color + icon | icon appears in sidebar pill |
| E12 | Color persists after story switch | switch story, color still visible |
| E13 | Color applied early (before wait-for-ready) | color visible while Claude Code loading |
| E14 | set-status / clear-status round-trip | sidebar-state shows/clears key-value |

#### Group 3: Verbose / Streaming (P1-E2E, 7 items)
| ID | Test | What it verifies |
|----|------|------------------|
| E15 | Verbose buffer created on session start | buffer exists, header-line set |
| E16 | Verbose tick captures screen changes | diff-based dedup works |
| E17 | Verbose restart on surface change | old timer cancelled, new started |
| E18 | Verbose menu key dispatch (cancel) | escape key sent to surface |
| E19 | Verbose follow (scroll to end) | window-point at buffer end |
| E20 | Stop verbose on session end | timer cancelled, no orphan timers |
| E21 | Streaming start/stop lifecycle | start-streaming → timer → stop-streaming |

#### Group 4: Execute AI Block (P0-E2E, 6 items)
| ID | Test | What it verifies |
|----|------|------------------|
| E22 | Execute simple query | prompt sent, response in org, busy→ready |
| E23 | Execute with --resume | CLAUDE_CLI_SESSION reused |
| E24 | Execute rejects when busy | error message, no duplicate query |
| E25 | Cancel active query | escape sent, [Cancelled] in org, busy cleared |
| E26 | Queue Block B while A runs | B executes after A completes |
| E27 | Execute with copilot agent type | AGENT_TYPE=copilot, correct launch cmd |

#### Group 5: Session & Properties (P1-E2E, 6 items)
| ID | Test | What it verifies |
|----|------|------------------|
| E28 | Session recovery from org buffer scan | recover-session finds buffer by session ID |
| E29 | CLI session saved by workspace bridge | CLAUDE_CLI_SESSION property set |
| E30 | Copilot uses separate COPILOT_CLI_SESSION | no collision with Claude Code session |
| E31 | Story switch updates ACTIVE_STORY | property set, tab renamed |
| E32 | Permission needed focuses workspace | mode-line alert, workspace selected |
| E33 | Permission resolved clears state | mode-line cleared, busy state updated |

#### Group 6: Launch Command (P1-E2E, 5 items)
| ID | Test | What it verifies |
|----|------|------------------|
| E34 | Claude legacy launch (no profile) | correct flags: --print, --output-format |
| E35 | Claude profile launch | CLAUDE_PROFILE used, --resume if session |
| E36 | Copilot launch | copilot CLI path, COPILOT_CLI_SESSION |
| E37 | System prompt injected | --system-prompt flag with bridge content |
| E38 | Permission mode bypass | --dangerously-skip-permissions flag |

#### Group 7: Loop Execution (P1-E2E, 4 items)
| ID | Test | What it verifies |
|----|------|------------------|
| E39 | Loop send dispatches prompt | loop-send → send-text → enter |
| E40 | Loop cancel guard skips iteration | cancelled session skips cleanly |
| E41 | Loop error guard skips iteration | errored session skips cleanly |
| E42 | Loop from-emacs flag written | status file created before send |

#### Group 8: IDE Server (P2-E2E, 4 items)
| ID | Test | What it verifies |
|----|------|------------------|
| E43 | IDE server starts for Claude Code | lockfile created in ~/.claude/ide/ |
| E44 | IDE server skipped for Copilot | no lockfile when profile says no IDE |
| E45 | /ide sent after ready | send "/ide" + enter after 5s delay |
| E46 | IDE server alive-p check | session-alive-p returns t when running |

#### Group 9: Wait-for-Ready (P2-E2E, 4 items)
| ID | Test | What it verifies |
|----|------|------------------|
| E47 | Wait detects INSERT mode | ready pattern matches, returns |
| E48 | Wait detects hook file ready | hook status "ready", fast return |
| E49 | Wait timeout (slow launch) | timeout reached, returns anyway |
| E50 | Wait with copilot patterns | copilot-specific ready patterns work |

#### Group 10: Edge Cases & Regression (P2-E2E, 7 items)
| ID | Test | What it verifies |
|----|------|------------------|
| E51 | Unicode in story name | workspace created, slug generated |
| E52 | Org metacharacters in heading | no corruption in properties |
| E53 | File-level CLAUDE_BACKEND dispatch | file #+PROPERTY routes to cmux |
| E54 | Special chars in prompt text | brackets, quotes don't break send |
| E55 | TabManager not available recovery | new-window created first, retry |
| E56 | Concurrent permission + query | both handled without crash |
| E57 | Stale verbose timer after workspace relaunch | old timer replaced, no double-tick |

## Implementation Strategy

### Dual-Layer Testing Per Item

Each E2E item produces TWO test artifacts:

1. **Live E2E test** — executed via evalElisp against real cmux,
   recorded in `living-workspace-test.org` with PASS/FAIL/date
2. **Simulated test** — added to `test-cmux-e2e-simulated.el` with
   mock cmux CLI, runs in CI via `make test-cmux`

The live test discovers real-world issues. The simulated test locks in
the fix for CI regression prevention.

### Iteration Workflow (30 min budget)

```
Minutes 0-2:   Pick highest undone E-item, read related source
Minutes 2-5:   Add test workspace/story to workspace-test.org
Minutes 5-12:  Execute live test via evalElisp + cmux CLI
Minutes 12-18: Fix any issue found in source code
Minutes 18-23: Write simulated test for CI
Minutes 23-27: Run make check, verify all green
Minutes 27-30: Record results, commit, push
```

### Rules

- Never ask questions — decide autonomously
- Never enter plan mode — act directly
- One E-item per iteration (depth over breadth)
- Live test first, simulated test second
- If live test finds a bug: fix → retest → add regression test
- After editing .org files, reload via literate-elisp-load
- Run make test-smoke after any .org edit
- Run make check before committing
- Commit with prefix: test: for new tests, fix: for bug fixes
- Record results in living-workspace-test.org
- If cmux is not running, fall back to simulated-only testing
- If a fix breaks > 3 tests, revert and skip to next item
- Skip Phoenix trace assertions if localhost:6006 unreachable

### Fixture Hygiene

- workspace-test.org: append-only, never delete existing sections
- Every new heading: unique CUSTOM_ID (pattern: e2e-<group>-<id>)
- Every workspace: CLAUDE_SESSION_ID, CLAUDE_BACKEND: cmux
- System prompts: realistic project context, not "test"
- AI queries: practical developer tasks

## Expected Outcomes

After a full sweep (~57 items × 30 min = ~28 hours of loop time):

| Metric | Before | After |
|--------|--------|-------|
| Simulated E2E tests (CI) | 80 | ~137 |
| Live E2E tests recorded | 61 | ~118 |
| Functions with zero test coverage | ~25 | ~5 |
| Structural regression guards | 43 | ~55 |
| Coverage of cmux subcommands | 60% | 95% |

## How to Run

```bash
# In Claude Code:
/loop 30m tests/e2e/quality-loop-prompt.org
```

The loop agent reads the priority queue, picks the next undone item,
and works through it autonomously. Progress is tracked by marking
items DONE in the prompt file and recording results in
living-workspace-test.org.

## Approval Checklist

- [ ] Priority ordering makes sense
- [ ] 57 items is the right scope (not too many, not too few)
- [ ] Dual-layer strategy (live + simulated) is correct
- [ ] 30-min iteration budget is realistic
- [ ] Rules are clear enough for autonomous operation
