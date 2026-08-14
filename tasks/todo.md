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
- [ ] BLOCKER for U3/U4: pi-coding-agent v2.7 needs `md-ts-mode`,
      `markdown-table-wrap`, `transient>=0.9`, none installed — batch load
      fails with `Cannot open load file: md-ts-mode`. Plan: project-local
      `package-user-dir` under `.cache/elpa` for tests (no change to the
      user's Emacs); user installs from MELPA separately for interactive use.
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
