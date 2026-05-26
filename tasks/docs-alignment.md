# Docs ↔ Code Alignment Task List

Goal: walk every doc under `docs/` (excluding `docs/draft/` source-study material), verify
its claimed status against current code, and update the doc + relevant `INDEX.md`
entry where reality has moved on.

Method per file:
1. Read the doc's stated goals/status.
2. Cross-check against current code (greps, fboundp, recent commits).
3. Mutate the doc: refresh STATUS, append a "Reality check (YYYY-MM-DD)" stanza,
   or note new follow-ups.
4. Refresh the matching row in `INDEX.md` if status changed.
5. Mark the row in this file `[X]`.

Stop conditions:
- A status change requires deeper code work → drop a TODO in the doc and move on.
- Doc covers a feature that was deleted → mark the doc/INDEX row `removed`.

## Status legend

- PASS – doc matches code, no edit needed.
- UPDATED – doc/INDEX rewritten to match code.
- REMOVED – feature gone, doc/INDEX flagged.
- DEFER – needs a separate work item; noted in the doc.

## Top-level docs

- [X] docs/atomic-architecture.org — UPDATED: replaced `claude-org`/`code-agent-org-mode` references with `code-agent-org`. Document is a philosophy/inspiration piece (not architecture-of-record), so only stale-name fixes were needed.
- [X] docs/ralph-architecture.org — UPDATED: renamed all `claude-org` → `code-agent-org`. Doc explicitly self-flags as "future feature, not yet implemented", so no implementation-status edits needed.
- [X] docs/literate-programming-principles.org — PASS: language-agnostic principles, no stale `claude-org` refs.
- [X] docs/ELISP_IDIOMS.org — PASS: language-agnostic idioms, no stale `claude-org` refs.

## design-docs/ (33 files + INDEX)

- [X] docs/design-docs/INDEX.md — UPDATED: comprehensive rewrite; was missing 13 docs; status column now matches code state.
- [X] docs/design-docs/2026-a-slack-bot-for-ai-agant.org — STATUS=not started (no slack module shipped).
- [X] docs/design-docs/2026-autonomous-mode.org — STATUS=partial (loop primitive shipped; circuit-breaker not yet).
- [X] docs/design-docs/2026-backend-extraction.org — STATUS=superseded by Tri-Protocol; iTerm2/native removed.
- [X] docs/design-docs/2026-block-history-all-backends.org — STATUS=removed (history module deleted in 1e09c13).
- [X] docs/design-docs/2026-cmux-emacs-phoenix-improvements.org — STATUS=partial; specific items shipped via other docs.
- [X] docs/design-docs/2026-cmux-live-output-mirror.org — STATUS=shipped (256 KB cap + kill-hook).
- [X] docs/design-docs/2026-cmux-support-backend.org — STATUS=shipped, subsumed by Tri-Protocol.
- [X] docs/design-docs/2026-codebase-review-improvements.org — STATUS=superseded; folded into Tri-Protocol + E2E + Phoenix.
- [X] docs/design-docs/2026-comprehensive-e2e-coverage.org — STATUS=shipped via E2E_TASKS.org.
- [X] docs/design-docs/2026-e2e-test-strategy.org — STATUS=active; reality check pointing at E2E_TASKS.org added.
- [X] docs/design-docs/2026-harness-engineering.org — STATUS=shipped; concrete elements landed across other docs.
- [X] docs/design-docs/2026-iterm2-mode-line-and-query-manager.org — REMOVED: iTerm2 backend deleted in 1038144.
- [X] docs/design-docs/2026-json-stream-backend.org — STATUS=shipped (now agent-family of Tri-Protocol).
- [X] docs/design-docs/2026-json-stream-extraction.org — STATUS=shipped, subsumed by Tri-Protocol.
- [X] docs/design-docs/2026-living-workspace.org — STATUS=shipped.
- [X] docs/design-docs/2026-macos-notification-on-stop.org — STATUS=shipped.
- [X] docs/design-docs/2026-monet-ide-integration.org — STATUS=shipped.
- [X] docs/design-docs/2026-multi-agent-cmux-support.org — STATUS=shipped, subsumed by Tri-Protocol agent-family.
- [X] docs/design-docs/2026-native-claude-code-backend.org — STATUS=superseded.
- [X] docs/design-docs/2026-opencode-acp-backend.org — STATUS=shipped.
- [X] docs/design-docs/2026-opencode-cmux-integration.org — STATUS=shipped (cmux profile).
- [X] docs/design-docs/2026-opencode-serve-mode.org — STATUS=superseded by ACP variant.
- [X] docs/design-docs/2026-phoenix-trace-evaluator.org — STATUS=partial (Phoenix shipped; auto-evaluator not built).
- [X] docs/design-docs/2026-query-manager-live-output.org — STATUS=shipped (basic) / partial (multi-session view).
- [X] docs/design-docs/2026-sdd-story-worktrees.org — STATUS=shipped (template form).
- [X] docs/design-docs/2026-single-root-span.org — STATUS=shipped.
- [X] docs/design-docs/2026-terminal-prompt-parity.org — STATUS=shipped (substantial parity).
- [X] docs/design-docs/2026-terminal-sdd-bridge.org — STATUS=shipped (now `code-agent-org-workspace-bridge`).
- [X] docs/design-docs/2026-tri-protocol-backend-refactor.org — UPDATED: STATUS=shipped; phase table + E2E verification.
- [X] docs/design-docs/2026-unified-tracing.org — STATUS=shipped.
- [X] docs/design-docs/2026-vterm-inside-emacs.org — STATUS=removed (deleted in 1038144).
- [X] docs/design-docs/2026-yasnippet-templates.org — STATUS=shipped.

## research/ (12 files + INDEX)

- [X] docs/research/INDEX.md — UPDATED: cleaned mixed table+bullet rows, added missing entries (vterm, sdd-enhancements, ghostty-features, workflow-redesign), added preamble noting research is point-in-time and pointing to design-docs for current state.
- [X] docs/research/2026-a-slack-bot-for-ai-agant.org — PASS (point-in-time research; design-doc INDEX flags Slack bot as `not started`).
- [X] docs/research/2026-cmux-codebase-study.org — PASS (historical study; refs to `code-agent-org-cmux` describe pre-rename state — left as-is).
- [X] docs/research/2026-cmux-ghostty-best-practices.org — PASS (no in-house symbol refs to update).
- [X] docs/research/2026-cmux-sdd-enhancements.org — PASS (research note; symbol refs describe pre-rename state).
- [X] docs/research/2026-ghostty-features-for-sdd.org — PASS.
- [X] docs/research/2026-harness-engineering.org — PASS (research note paired with design-doc 2026-harness-engineering.org which has the reality-check stanza).
- [X] docs/research/2026-native-claude-code-backend.org — PASS (research note; reality is now in `2026-tri-protocol-backend-refactor.org`).
- [X] docs/research/2026-vterm-inside-emacs.org — PASS (research; the design-doc partner is marked removed).
- [X] docs/research/2026-workflow-redesign.org — PASS (paired with `2026-living-workspace.org` shipped).
- [X] docs/research/claude-code-source-review-ai-core.org — PASS (review of *Anthropic's* claude-code; not our codebase).
- [X] docs/research/claude-code-source-review-architecture.org — PASS (Anthropic source review).
- [X] docs/research/claude-code-source-review-gap-analysis.org — PASS (Anthropic source review).
- [X] docs/research/claude-code-source-review-security-hooks.org — PASS (Anthropic source review).
- [X] docs/research/claude-code-source-review-tools-agents.org — PASS (Anthropic source review).
- [X] docs/research/claude-code-source-review-ui-memory.org — PASS (Anthropic source review).

## product-specs/ + references/

- [X] docs/product-specs/INDEX.md — PASS: legitimately empty (no cross-story product specs exist yet); structure is the placeholder header + table.
- [X] docs/references/INDEX.md — PASS: legitimately empty (no curated external references currently); placeholder structure intact.

## Out of scope

- docs/draft/* — source studies / proposals not subject to "code alignment".
