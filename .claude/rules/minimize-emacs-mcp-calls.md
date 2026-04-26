# Minimize Emacs MCP Calls — Only Contact Emacs When It Has State to Update

Emacs is single-threaded. The MCP server runs on the main thread, so every
synchronous `evalElisp` call blocks the entire editor — redisplay, input,
timers, other MCP callers — until Emacs finishes evaluating the form.

When multiple cmux sessions (or long-running tools) fire hooks concurrently,
their MCP calls queue up on Emacs's single main loop. A fast 30ms call can
end up waiting 1–2 seconds behind other queued calls. The user experiences
this as Emacs hanging.

## Rule

**Only call into Emacs MCP when Emacs actually has state to update.**

Before adding an `evalElisp` call from a hook, subprocess, or Python helper,
prove that Emacs owns state that must change. If the call would be a no-op
most of the time, don't make it at all.

## Known interactive tools (these genuinely need Emacs)

| Tool | Why Emacs needs to know |
|------|------------------------|
| `AskUserQuestion` | Show a "permission needed" alert in Emacs |
| `ExitPlanMode` | Same — user must approve exit from plan mode |

For every other tool (`Read`, `Grep`, `Bash`, `Edit`, `Write`, etc.) Emacs
holds no per-tool state. No MCP call is warranted.

## Enforcement layers

Hooks should filter at multiple layers so we pay the minimum cost:

1. **Claude Code hook matcher** — cheapest. `hooks/hooks.json` uses
   `"matcher": "AskUserQuestion|ExitPlanMode"` so the CLI never even spawns
   the subprocess for non-interactive tools.

2. **Python handler early-return** — defense in depth. If a hook fires
   anyway (e.g. different hook config downstream), the handler checks
   `tool_name in _INTERACTIVE_TOOLS` and returns before touching MCP.

3. **Elisp dispatcher** — last line of defense. `code-agent-org--terminal-*`
   dispatchers `cond`-out when the session isn't in the workspace hash
   table, so even an errant MCP call is cheap.

## Historical case (April 2026)

`hooks/hooks.json` registered `PreToolUse` → `workspace-bridge permission`
and `PostToolUse` → `workspace-bridge permission-clear` with no matcher.
Every single tool invocation in every cmux session fired a Python subprocess
that synchronously called Emacs MCP.

Phoenix aggregate over ~5 minutes with two concurrent sessions:

| span | count | avg | total blocking |
|------|-------|-----|----------------|
| `handle-permission-clear` | 46 | 1353ms | **62 seconds** |
| `handle-permission` (early-returned) | 58 | 0ms | 0 (no MCP call) |
| `mcp-evalElisp` actual Emacs work | 13 | 45ms | 596ms |

The Emacs work was always fast. The wall-clock time came from MCP queuing
behind other pending calls. Fix removed 90%+ of the MCP traffic by skipping
non-interactive tools at both the matcher and handler layers.

## Diagnosing similar bottlenecks

Phoenix aggregate query — group spans by name with count × avg × total:

```bash
curl -s -X POST http://localhost:6006/graphql -H "Content-Type: application/json" \
  -d '{"query": "query { node(id: \"UHJvamVjdDoy\") { ... on Project { spans(first: 300, sort: {col: startTime, dir: desc}) { edges { node { name latencyMs } } } } } }"}' \
  | python3 -c "
import sys, json
from collections import Counter
d = json.load(sys.stdin)
by_name = Counter(); lats = {}
for s in d['data']['node']['spans']['edges']:
    n = s['node']['name']; lat = s['node']['latencyMs'] or 0
    by_name[n] += 1; lats.setdefault(n, []).append(lat)
for name, count in by_name.most_common(15):
    L = lats[name]; avg = sum(L)/len(L)
    print(f'{name:40s} count={count:4d} avg={avg:7.1f}ms total={sum(L):8.0f}ms')
"
```

High `count × avg` values reveal the hottest path. Sort by total blocking
time, not per-call latency — a 50ms call that runs 100× hurts more than a
2-second call that runs once.

## When adding a new hook handler

Ask and answer in the commit message:

1. Does Emacs hold state that this tool will mutate? (If no: do not call MCP.)
2. Will this hook fire per-tool-use, per-session, or once per conversation?
3. If per-tool-use, is a matcher possible to limit which tools trigger it?
4. Can the Python handler return early before any MCP call?

## Sibling rule: no synchronous subprocess calls in periodic timers

The same principle applies to Emacs's own periodic timers that shell out to
CLI tools (`cmux`, `git`, `curl`, etc.). A timer that fires every N seconds
and calls `call-process` synchronously blocks Emacs's main thread every N
seconds for the full duration of the subprocess.

### Rule

**Timers that invoke external processes MUST use `start-process` + sentinel
(async).** Never `call-process` from `run-at-time` or `run-with-timer`.

### Historical case (April 2026)

`code-agent-org-cmux--stream-tick` fired every 2 seconds while Claude was running,
calling `cmux pipe-pane --command cat` synchronously via `call-process`. Each
tick blocked Emacs 200–1500 ms. The user experienced this as Emacs "hanging"
intermittently for the entire duration of every Claude query.

Worse, the insertion marker (`code-agent-org-cmux--stream-marker`) was declared
`defvar-local` but never initialised to an actual marker. The guard
`(when (and code-agent-org-cmux--stream-marker ...))` was always nil, so every
tick captured output, stripped ANSI, and then silently discarded the result.

The whole subsystem was vestigial — response text was already being delivered
via the `Stop` hook → `handle_response` → `insert-response` path. Deletion
was the correct fix; the verbose buffer (separate subsystem, async,
correctly implemented via `start-process` + sentinel) continued to show live
terminal output.

### Checklist before adding a new timer

1. Does it spawn a subprocess? If so, it MUST use `start-process`, not
   `call-process`.
2. Is there already an async subsystem (like `verbose-tick`) doing a similar
   job? If so, reuse or extend it rather than creating a parallel one.
3. Does the callback actually do something? (If it writes to a marker/buffer,
   verify that marker/buffer is ever initialised — not just declared.)
4. Is there a cheaper event-driven alternative (hook, sentinel, watcher)
   that doesn't need polling at all?

The `Stop`-hook delivery path is usually the right answer for "I want the
response in the org buffer" — structured, one-shot, no polling needed.
