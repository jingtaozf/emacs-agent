# Lessons Learned — code-agent

每条 lesson:date / mistake / context / rule。新条目放最上面(逆序)。
≥3 次同类后 promote 到 `CLAUDE.md`,本文件保留 backfill 历史。

参考:[`docs/research/2026-AI-codebase-mastery-lens-11`](../docs/) 的"双层结构 lessons → CLAUDE.md"。

## Pattern format

```
- date: YYYY-MM-DD
  mistake: <what went wrong>
  context: <where / when / which command>
  rule: <one-sentence preventive rule>
```

---

## Unknowns(agent 跑时不知道为什么的瞬间,等人 backfill)

- (空) — agent 在 task 中遇到 "我不知道为什么 X 这么做" 时,把问题贴到这里,后续选高频项写 design-doc。

---

## Backlog of lessons to promote(累计 ≥3 同类的)

- (空)

---

## Recent lessons(逆序)

### 2026-04-30 — `AGENTS.md` 被错误 commit

- mistake: `AGENTS.md` 是 `opencode_workspace.py` 的 ephemeral session inject(头有 `auto-removed on exit`),但 `atexit` cleanup 把"被污染的 original"写回去,导致 self-perpetuating 污染 + 被 git commit。文件长到 736 行(30K),严重 context rot。
- context: 在 lens #5 (Documentation as agent context) action plan 里发现;writer 在 `python/claude_agent/opencode_workspace.py:84-97`。
- rule: ephemeral 文件**必须**写到非 git tracked 路径(`.cache/` 或 tmp);若必须落项目根,则 .gitignore + cleanup 必须可证明幂等。
- fix shipped (2026-05-01): 治标 commit `bba334b` 把 AGENTS.md 截到 60 行;治本 commit (此次) 把 cleanup 改成 *content-driven idempotent* — 加 `strip_emacs_agent_inject_blocks` + `cleanup_emacs_agent_inject` helpers 到 `workspace_launcher.py`,opencode_workspace + copilot_workspace 都改用 helper。两个 regression test 在 `test_opencode_workspace.py::test_polluted_original_does_not_self_perpetuate` 和 `test_cleanup_is_idempotent_and_strips_inject_block`。

### 2026-04-30 — `code-agent-org-workspace-archive-workflow` 删 CLAUDE_CLI_SESSION

- mistake: Archive workflow 在归档完毕后调 `(org-delete-property code-agent-org-cli-session-property)`,导致下次 Open terminal 不能 resume(Claude CLI session 丢失,起新对话)。
- context: `code-agent-org.org:3526-3530`(已修)。
- rule: 归档(folding 旧 transcript)≠ session reset;不要在归档动作里清 session id。
- fix shipped: commit `90843db` (2026-04-30)。

### 2026-04-30 — `difftool.symlinks=false` 不是 valid git config

- mistake: 把 `[difftool] symlinks = false` 写到 `~/.gitconfig` 想全局禁止 git difftool --dir-diff 建 symlink;实测 git 完全忽略这个 key(官方 doc 没列)。
- context: Beyond Compare 5 在 macOS 看到 link 而非内容差异。
- rule: 仅信任 `git config --help` 列出的 config keys;实测验证后再依赖。
- fix: 改在 BC5 GUI 里勾 *Session → Session Settings → Handling → Follow Symbolic Links*(per-session-default)— 不动 git config。

### 2026-04-30 — cmux daemon 重启后 Emacs.app 调不通 socket

- mistake: cmux 默认 access mode 是 `cmuxOnly`,通过 `isDescendant(pid)` 检查 caller 进程的 ppid 链是否能走到 daemon pid。从 Dock/Finder 启动的 Emacs.app parent 链是 `Emacs ← launchd`,过不了。Daemon 重启后即使老 Emacs 进程仍在,但 daemon pid 变了 → 所有 RPC broken-pipe。
- context: 全部 cmux CLI 调用从 Emacs 进程返回 `Error: Failed to write to socket (Broken pipe, errno 32)`;直接 shell 调正常。
- rule: cmux daemon 重启后 *Settings → Socket Control → Automation* 而非 cmuxOnly,跳过 ancestry 检查;或者从 cmux pane 内 launch Emacs(`open -na Emacs` 在 cmux terminal)让 ppid 链连上。
- followup: 把这条加到 `.claude/rules/cmux-dev-build.md`。

### 2026-04-30 — `cmux send` 跟 Claude Code TUI 的 slash-command palette 冲突

- mistake: `code-agent-org-cmux-restart` 调 `cmux send "/exit"`,但 `surface.send_text` 在 daemon 端走 `sendKeyEvent`(ghostty 的键盘事件路径),Claude Code TUI 的 React 输入处理把 `/` 当 slash-palette 触发,后续 `exit` 字符进 palette query input。结果用户看到屏幕上是 `t`(palette query 残留),Claude 没真正退出。
- context: code-agent-org-cmux.org:1709 `(code-agent-org-cmux--call "send" "--surface" surface-id "/exit")`。
- rule: 当目标 TUI 有 slash-palette 时,不能用 keyboard-event 路径发 `/cmd`。改用 `send-key ctrl+c` × 2(取消然后退出)绕开 palette;或者写专用 paste 路径(bracketed paste,绕 keyboard event)。
- followup: 把 restart 函数 line 1705-1711 改成 `(send-key ctrl+c) × 2 + sleep`;加 regression test。

### 2026-04-30 — literate-elisp 不读 `lexical-binding: t` 文件头

- mistake: `.org` 文件头部加 `;; -*- lexical-binding: t -*-` 不会被 literate-elisp 识别(它从 #+begin_src elisp 块里加载,绕过文件级 cookie)。timer / sentinel / lambda 闭包必须用 `lexical-let`(cl-lib)显式捕获变量,否则运行时 void-variable error。
- context: 多次踩坑;`docs/ELISP_IDIOMS.org` 已记录,但仍在新代码里偶尔再犯。
- rule: literate-elisp 写的 .org 里所有 timer / process filter / sentinel 闭包用 `lexical-let`,不用普通 `let`。
- promote-candidate: 已是 CLAUDE.md 的一条;再有同类违例就锁进 test-structural.el。

---

## Glossary(unknowns 投票后凝练成 design rationale 的内容)

- (空 — 等 unknowns 累积到一定量再写到 docs/design-docs/)

## 2026-05-27 — literate-elisp EOF when file ends with prose

**Mistake**: Added `* See also` heading + Verified-by prose at the end of LP `.org` files. literate-elisp's reader signalled `(end-of-file nil)` and aborted load.

**Context**: The reader treats every char after the last `#+END_SRC` and decides whether to read it as Lisp. A `*` heading + `:PROPERTIES:` drawer + `**Verified by:**` block hits the fallthrough "enter Emacs read" branch, which then EOFs mid-sexp.

**Rule**: Any `.org` file loaded via literate-elisp must end with a `#+BEGIN_SRC ... #+END_SRC` block. When trailing prose is needed, append a no-tangle sentinel src block:

```org
#+begin_src elisp :tangle no
;; literate-elisp reader sentinel — keeps file's final non-empty content a code block
#+end_src
```
