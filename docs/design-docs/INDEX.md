# Design Docs Index

Status legend: `shipped`, `partial`, `superseded`, `removed`, `draft`, `not started`.
Updated 2026-04-27 to align with current code (see `tasks/docs-alignment.md`).

| Date | Title | Status |
|------|-------|--------|
| 2026-03-02 | Harness Engineering | shipped (concrete elements landed across other docs) |
| 2026-03-03 | Native Claude Code Backend | superseded (Tri-Protocol + iTerm2/native removed) |
| 2026-03-06 | Terminal SDD Bridge | shipped (now `code-agent-org-workspace-bridge`) |
| 2026-03-08 | iTerm2 Mode-Line and Query Manager | removed (iTerm2 backend deleted in 1038144) |
| 2026-03-08 | Block History for All Backends | removed (history module deleted in 1e09c13) |
| 2026-03-08 | macOS Notification on Query Completion | shipped |
| 2026-03-08 | IDE Integration for SDD Stories (monet) | shipped (`claude-ide.org` + `claude-agent-ide.org`) |
| 2026-03-09 | Extract JSON Stream Code from claude-agent.org | shipped (subsumed by Tri-Protocol) |
| 2026-03-10 | Extract iTerm2/Native Backends | superseded (subsumed by Tri-Protocol) |
| 2026-03-12 | Codebase Review — Architecture, Quality, and Harness | superseded (folded into Tri-Protocol + E2E + Phoenix) |
| 2026-03-12 | Terminal-Typed Prompt Feature Parity | shipped (substantial parity; minor gaps may remain) |
| 2026-03-12 | VTerm Inside Emacs | removed (in-Emacs vterm/eat backend deleted in 1038144) |
| 2026-03-13 | JSON Stream Backend — Business Logic and Redesign | shipped (now agent-family of Tri-Protocol) |
| 2026-03-13 | Slack Bot for AI Agent | not started |
| 2026-03-13 | Unified Tracing — Cross-Process Observability | shipped (`claude-agent-trace.org` + Phoenix) |
| 2026-03-15 | Single Root Span Per AI Block Execution | shipped |
| 2026-03-15 | cmux Backend — Architecture, Integration, and Roadmap | shipped (subsumed by Tri-Protocol) |
| 2026-03-15 | SDD Story Worktrees | shipped (template form per v3) |
| 2026-03-17 | Migrate AI Block Templates to yasnippet | shipped (snippets under `snippets/org-mode/`) |
| 2026-03-20 | cmux Live Output Mirror | shipped (`*cmux: <id>*` buffer + 256 KB cap) |
| 2026-03-21 | Query Manager with Live Output Monitoring | shipped (basic) / partial (no unified multi-session view) |
| 2026-03-26 | The Living Workspace | shipped |
| 2026-03-26 | Autonomous Mode — TODO + Circuit Breaker | partial (loop primitive shipped; auto-stop not yet) |
| 2026-03-27 | Comprehensive Feature E2E Test Coverage | shipped (`tests/e2e/E2E_TASKS.org`) |
| 2026-03-27 | Phoenix Traces as Automatic Evaluator | partial (Phoenix shipped; auto-evaluator not built) |
| 2026-03-28 | E2E Test Strategy | active |
| 2026-04-01 | Multi-Agent Support in cmux Backend | shipped (subsumed by Tri-Protocol agent-family) |
| 2026-04-10 | cmux-Emacs-Phoenix System Improvements (Claude × Codex debate) | partial (specific items shipped piecemeal) |
| 2026-04-17 | OpenCode Serve Mode (JSON Stream Backend) | superseded by 2026-opencode-acp-backend |
| 2026-04-17 | OpenCode Integration via cmux Backend | shipped (cmux profile) + superseded for direct use |
| 2026-04-19 | OpenCode ACP Backend (Direct Protocol Integration) | shipped |
| 2026-04-24 | Tri-Protocol Backend Refactor (agents + multiplexers, tmux) | shipped (all phases incl. 4b) |
