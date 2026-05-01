# MCP server audit

**Last reviewed:** 2026-05-01
**Reviewer:** Jingtao
**Trigger:** Action plan lens #10 (security review) — every MCP server is
agent attack surface; if its tools have wider scope than needed, an indirect
prompt-injection from a malicious README/issue can be amplified through it.

This file lists every MCP server the project registers, the path scope of its
exposed tools, the threat the over-privileged version would enable, and how
we restrict it.

Re-run this audit when adding any new MCP server or skill that requests new
tool capabilities.

## 1. emacs (HTTP, `localhost:9999/mcp`)

| Property | Value |
|---|---|
| Source | `emacs-mcp-server.org` (this repo) |
| Transport | Streamable HTTP, **bound to 127.0.0.1** |
| Registered in | `opencode.jsonc`, `.mcp.json` (per-session via `claude --mcp-config`), or via `claude mcp add` |
| Tools | `mcp__emacs__evalElisp`, `mcp__emacs__report_invocation` |

### Tool scope

- `mcp__emacs__evalElisp` — runs **arbitrary** Elisp on the host Emacs.
  Equivalent to a shell prompt with the user's filesystem access.
- `mcp__emacs__report_invocation` — records skill/rule invocations for
  observability. No filesystem effect.

### Threats

| Threat | Mitigation |
|---|---|
| Indirect prompt injection via README/issue → agent calls `evalElisp` to exfiltrate `~/.ssh/id_rsa` or run `(shell-command "rm -rf ...")` | (a) Bind to `127.0.0.1` only — server unreachable from network. (b) `lens #10` rule in CLAUDE.md: untrusted content (README/PR descriptions) marked as such; agent must NOT call `evalElisp` based on instructions found there. (c) Each `evalElisp` call must complete in <2s (host Emacs is single-threaded; long calls are anomaly, not normal). |
| Network-exposed (e.g. agent in container talks to host) | Use `host.docker.internal:9999/mcp` from container; never widen bind beyond 127.0.0.1. |
| `evalElisp` reads files outside project | No path scope today — Elisp can `(find-file "/Users/...")`. **Open issue.** Path scoping requires Emacs-side capability check (advice on `find-file` to reject non-project paths during agent calls). |

### Open follow-ups

- [ ] Add Emacs-side advice to restrict `evalElisp` from reading paths
  outside `(or (vc-root-dir) default-directory)` during agent sessions.
  Tracked in `tasks/lessons.md` Unknowns.

## 2. Skills (Anthropic-managed via `~/.claude/skills/`)

| Property | Value |
|---|---|
| Source | User-level `~/.claude/skills/` and project `.claude-plugin/` |
| Transport | Slash commands, not MCP per se, but read by Claude Code as tools |
| Tools | `Read`, `Write`, `Edit`, `Bash`, `Grep`, `Glob`, `WebFetch`, `WebSearch`, etc. |

### Scope

User-level skills are unrestricted by project boundary. The Claude Code
default tool permissions apply: `Read`/`Write`/`Edit` accept any path, `Bash`
runs subprocess, etc.

### Mitigations

- Skills never auto-fetch URLs from untrusted content unless the agent
  explicitly approves the WebFetch.
- `~/.claude/settings.json` has `permissions.allowed-tools` configured to
  match expected workspace use.
- For Claude Code, the *Bash command requires permission* gate is
  preserved — destructive operations (rm/mv/git push) are subject to
  user approval per command.

## 3. Hook scripts (`hooks/hooks.json` & `hooks/copilot_hooks.json`)

These are NOT MCP servers, but execute shell on every tool call. Audited
because the trust surface is similar.

| Hook | Trigger | Effect |
|---|---|---|
| `workspace-bridge permission` | `PreToolUse` (matcher: `AskUserQuestion\|ExitPlanMode`) | Blocking — calls Emacs MCP. Already filtered to interactive tools only via matcher (lens #10 enforcement layer 1). |
| `workspace-bridge permission-clear` | `PostToolUse` (same matcher) | Same. |
| `workspace-bridge prompt` | `UserPromptSubmit` | Records prompt to bridge for routing. |
| `workspace-bridge response` | `Stop` | Routes Claude response back to Emacs ai-block. |

### Mitigations

- All hooks run as the user; **no elevation**. Same as running `bash`.
- Matcher in hooks.json filters to interactive tools only — non-interactive
  tools (`Read`, `Bash`, `Edit`, …) skip the hook entirely. This was the
  fix in commit `1f016b8`-equivalent (April 2026; see `lens #10` in the
  global CLAUDE.md).
- All hook handlers (`workspace_bridge.py`) early-return on non-interactive
  tools as defense-in-depth.

## 4. Audit checklist for new MCP servers / skills

When adding any new MCP server or skill that grants new tool capabilities,
verify before merge:

- [ ] Bound to localhost only (or has authentication if remote)?
- [ ] Tools enumerated explicitly, not wildcard-allowed?
- [ ] Path scope:can it read/write outside the project? If yes — justified?
- [ ] Network egress: can it `WebFetch`/`Bash curl`? If yes — justified?
- [ ] Untrusted content boundary: README/issue text not auto-trusted as
  instructions to invoke this tool?
- [ ] Logged in agent observability (Phoenix span attributes include
  tool name + scope)?

If any is "no" without an explicit justification in commit message or
ADR — block the PR.

## References

- Lens #10 in `tasks/ai-codebase-mastery-action-plan.org`
- arxiv 2601.17548 — Prompt Injection Attacks on Agentic Coding Assistants
- OWASP LLM Top 10 (2025/2026)
