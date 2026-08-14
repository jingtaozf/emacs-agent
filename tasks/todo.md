# TODO — org-ai-agent-pi-topics

Repo narrowed 2026-08-13 to the Emacs MCP server (RATIONALE.md § 7);
full pre-cleanup tree on `legacy-2026-08-13`.  Current focus: the
pi-topics design, `lp/_drafts/draft.org` § 2026-08-13-org-ai-agent-pi-topics.

## In flight

- [x] Research (pi RPC / session store / extensions / pi-coding-agent embed API / GTD)
- [x] Proposal v2 written + diagrams (docs/images/pi-topics-*.svg)
- [x] Repo cleanup: master = MCP server only; legacy-2026-08-13 branch created
- [x] Grilling session done 2026-08-14 — 13 decisions in proposal § Grilling
      decisions; STATUS → accepted.  Shape: small extension to any org buffer,
      `pi-topic-*` commands + `PI_*` properties
- [x] Platform proposal (`draft.org` § 2026-08-14-emacs-agent-platform) — org
      is one L2 surface; pi-do dropped; upstream-first strategy
- [ ] /grill-log the 3 overriding answers (Q3 permission, Q4 display, shape)

## P0 — driven via /orca-do (planner = this session, executor = `exectutor` tab)

Environment facts (2026-08-14): pi CLI 0.80.6 installed; pi-coding-agent NOT
installed as an Emacs package. The public APIs we need landed in v2.6.0
(needs pi ≥ 0.75.5) — v2.7.0 wants pi ≥ 0.81 only for thinking levels.
Dev/test runs against the vendored submodule on load-path; end users install
from MELPA.

- [x] U1 — submodule at v2.7.0 + `tasks/pi-topic-embed-map.md`. VERIFIED by
      planner: all 22 cited symbols present at the cited lines (0 bad), phase
      hook 5-arg signature confirmed. Result: 3 needs public-only (resume,
      send, reap), 3 need private symbols (create-with-dir, named lookup,
      final text) → upstream PR queue recorded in the platform proposal.
- [x] Dependency blocker resolved by the planner: pi-coding-agent (+ md-ts-mode,
      markdown-table-wrap) installed into a PROJECT-LOCAL `.cache/elpa`
      (`package-user-dir`), MELPA snapshot 20260809.2332. The user's
      `~/.emacs.d` was NOT touched; `rm -rf .cache/elpa` reverts it. For
      interactive use the user installs from MELPA themselves.
- [x] U2 — `lp/org/pi-topic.org` pure org layer. VERIFIED: `make check` green
      plus 16 planner-written checks against real temp-file org buffers.
- [x] U3 — `lp/org/pi-topic-chat.org` engine layer (id, cwd, engine guard,
      display style, chat/abort, activity-phase hook). VERIFIED: `make check`;
      planner confirmed `pi-coding-agent-abort` and `--input-buffer` exist in
      the INSTALLED package, not just in the stubs.
- [x] U4 — PI_SESSION stamped from `pi-coding-agent--state` `:session-file`
      (gap the planner's own U3 spec had missed). VERIFIED: `make check` 16/16.
- [x] U5 — fixed: creating a topic inside an existing topic's subtree stamped
      the ANCESTOR (found by live E2E). 3 regression tests.
- [x] U6 — fixed: resume via `open-session-file` landed in the shared unnamed
      buffer and lost the topic identity permanently (found by live E2E).
      Now: named session + `switch_session` RPC + refresh/load history, plus
      `file-truename` on cwd for the /var ↔ /private/var mismatch.
- [x] P0 E2E VERDICT (real pi 0.80.6, two concurrent topics): 20/20 checks
      pass — two distinct processes, no cross-talk, waiting→review via the
      real activity hook, keyword mirrored, PI_SESSION stamped to existing
      files, reap, resume into the SAME named session with history replayed
      and the Goal not re-sent. Committed as `e761ca7`.

## Next

- [ ] P1 — capture template, agenda dashboard, transient menu, reap command
- [ ] P2 — `org_result` / `org_goal` tools in `emacs-mcp.ts` + per-topic
      system prompt via `before_agent_start`; then `pi-topic-refresh-result`
- [ ] Upstream PRs (retire 5 private symbols): named-session lookup,
      create-session with explicit dir, final assistant text at turn end,
      resume into a named session
- [ ] U2 — `lp/org/pi-topic.org` pure-org layer: `PI_*` property helpers,
      `pi-topic--state` get/set (+ TODO-keyword mirroring), `pi-topic-new`;
      `tests/test-pi-topic.el`; wired into `code-agent.el` + Makefile.
      Acceptance: `make check` exits 0 with the new tests running.
- [ ] U3 — `pi-topic-chat` (spawn/resume, split display, auto-send Goal),
      `pi-topic-abort`, turn-finished → `PI_STATE: review` + `PI_SESSION`,
      per U1's map. Acceptance: `make check` green + stub-driven tests.
- [ ] U4 — E2E: two concurrent topics against real pi, no cross-talk.
- [ ] P1: GTD keywords + capture template + agenda dashboard + reap/resume
- [ ] P2: org_result tool + per-topic system prompt + permission routing
- [ ] P3: fork⇢subtree, stats column view, upstream PR (agent-end hook), bump
      vendored pi-coding-agent v2.3.1 → v2.7.x

## Housekeeping

- [ ] Delete untracked stub `scripts/human_owned_guard.py` after this Claude
      session ends (kept on disk only because the session's PreToolUse hook
      list may be cached; registration already removed from .claude/settings.json)
