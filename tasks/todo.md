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
- [ ] /grill-log the 3 overriding answers (Q3 permission, Q4 display, shape)
- [ ] P0 step 0: MELPA install pi-coding-agent ≥2.7, re-verify 4 embed points
- [ ] P0: `lp/org/pi-topic.org` — pi-topic-new/chat/abort, agent_end advice →
      PI_STATE review + PI_SESSION saved (E2E: two concurrent topics)
- [ ] P1: GTD keywords + capture template + agenda dashboard + reap/resume
- [ ] P2: org_result tool + per-topic system prompt + permission routing
- [ ] P3: fork⇢subtree, stats column view, upstream PR (agent-end hook), bump
      vendored pi-coding-agent v2.3.1 → v2.7.x

## Housekeeping

- [ ] Delete untracked stub `scripts/human_owned_guard.py` after this Claude
      session ends (kept on disk only because the session's PreToolUse hook
      list may be cached; registration already removed from .claude/settings.json)
