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

### 2026-06-10 — restart 在非聚焦 cmux workspace 上不重启(send-key/输入/检测三连 + 测试 count 耦合)

- mistake: 以为修好命令内容(#1/#2)+ build-launch E2E 就够了,误报 "verified end-to-end";实际在**非聚焦** workspace 上 restart 根本没退出 Claude——干净命令被打进运行中的 agent。用户纠正 "it doesn't restart"。
- context: edo dev2(非 GUI 聚焦)。三个叠加 bug:(a) restart 的 send-key 不带 `--workspace` → 非聚焦 workspace 上 `Surface is not a terminal`,`/exit` 的 Return 没提交(send 文本可省、send-key 不可);(b) 输入行残留字符使 `/exit` 拼成 `t/exit` 不被识别(需 `ctrl+u` 清行);(c) 退出检测被 stale TUI 帧骗(Claude 退出不清屏,`bypass permissions` 残留 scrollback;`❯` 既是 shell 也是 Claude 输入框)。另:`Escape` 在 ctrl+u 前会污染 Claude 输入。
- rule: 驱动 cmux 终端 TUI——send-key 必带 `--workspace`;清输入用 `ctrl+u` 不是 Escape;判"退到 shell"用"Claude TUI 连续 N 次从**底部**消失"(小窗 capture 避开残帧),别正向匹配 prompt(starship `❯` 会被截、退出语多变);检测失败时 **abort 而非盲发**命令。
- test trap: e2e mock 用精确 `capture-count` 编排,会被轮询次数变化打破 → 改**内容/状态驱动**(按是否已发 launch 命令决定屏幕)。
- fix shipped (2026-06-10): `--surface-call`(注入 --workspace)、`ctrl+u`、去 Escape、`--wait-for-shell` 改 2-连续-clear-poll、`--shell-ready-p`+exit-banner、capture 8→4、abort-if-not-shell。回归测试 3 个 + 修 2 个 count-coupled 测试。live E2E(edo dev2):旧 Claude 退出 → 全新 Claude 启动 → /ide 连上 Emacs。

### 2026-06-09 — restart 启动命令被两个 bug 污染(propertized system-prompt + EXTRA_ARGS 裸切)

- mistake: 报 bug 后倾向直接写 batch unit test + 修;但其中一个 bug(系统提示带文本属性,序列化成 `#("..." props)`)**只在 fontify 过的 live org buffer 里发作**,批处理 ert 复现不出来。用户纠正:先基于 `tests/e2e/org` 在 live Emacs E2E 复现再修。
- context: edo dev3 `R Restart`;`code-agent-org--collect-system-prompts` 用 `match-string`(在 fontified buffer 里带 face/org-indent 属性),经 MCP evalElisp 序列化进 `--system-prompt`;并 `code-agent-org-cmux.org` 五处 `(split-string prop-args)` 把 `--settings '{"ultracode": true}'` 按空格切断 → Claude "Settings file not found" 退出。
- rule: 依赖 buffer 渲染状态(fontify/org-indent)的 bug,先用 `tests/e2e/org` + evalElisp 在 live Emacs E2E 复现;批处理 ert 用 `put-text-property` 模拟 fontify 才能锁回归。凡从 org buffer 取出、要外传(MCP/shell)的文本,一律 `*-no-properties` / `substring-no-properties`。
- fix shipped (2026-06-09): `match-string`→`match-string-no-properties` + `--build-system-prompt` 末尾 `substring-no-properties`;`(split-string prop-args)`→`(split-string-shell-command prop-args)`(×5)。回归测试 3 个 + fixture `tests/e2e/org/restart-extra-args-test.org`。

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

## 2026-07-20 — partial-refactor dangling calls (defun deleted, call site left)

**Mistake**: `git log -S` showed two refactor commits left dangling call sites behind:
- `26df975` (pivot to org-as-control-plane) deleted `code-agent-org-cmux--wait-for-ready` but kept the call in `--launch-workspace` → void-function at runtime.
- `7980a53` (drop response sync, verbose buffer) deleted `code-agent-org-cancel-all` + `code-agent-org--notify` but kept the calls in `--on-buffer-kill` and `--permission-needed`.

**Context**: `*Messages*` surfaced the `wait-for-ready` one because `launch-workspace` runs every session start; the other two stayed silent (only fire on buffer-kill / permission event). Existing `test-structural-no-dead-public-functions` (F35) missed all three — its `directory-files` is non-recursive, so it scans only repo-root `.org` files, never `lp/org/` where the actual sources live.

**Rule**: After any refactor that deletes a `defun`, grep `(defun NAME\b` AND `NAME\b` separately — call sites and definitions can diverge. Treat any call to a project-prefixed symbol with no `defun` as a bug, not dead code. When the deleted feature is intentional, delete the call site too (don't leave the dead reference).

**Structural test added**: `test-structural-no-dangling-calls` (F35b) in `tests/test-structural.el` — recursively scans every source `.org` (including `lp/org/`), builds a defined-set from `defun`/`cl-defun`/`defmacro`/`defsubst`/`cl-defgeneric`/`cl-defmethod`/`cl-defstruct` (with `:constructor`/`:predicate` options) / `define-minor-mode` / `defalias`, walks every call site (skipping `quote`, def-form metadata, `setq`/`let`/`lambda` data positions), and fails on any project-prefixed call that has no definition. Caught both `7980a53` leaks on first run.

## 2026-07-25 — tangled .py edited directly; the .org went stale

**Mistake**: `670f37e` ("恢复 CLI session persistence") added `_handle_session_start` and `_cli_session_property` to `python/code_agent/workspace_bridge.py` **and** the `SessionStart` entry to `hooks/hooks.json` by hand. Both files are tangle output of `lp/sdk/code-agent-python.org`, which never received either change. The drift stayed invisible for four days because nothing re-tangles on its own.

**Context**: Surfaced only when an unrelated change to `workspace_launcher.py` required `make tangle-python` — the tangle silently *reverted* both files, deleting a whole handler plus the hook that invokes it. `git diff` after tangling was the only signal; the 117 python tests still passed against the stale-but-present `.py` right up to that moment, and would have started failing the moment the tangle was committed. The second file was nearly missed: `git status` was scanned for `python/` and `hooks/hooks.json` sat two lines above it.

**Rule**: Before tangling, `git diff --stat <tangle-output-dir>` must be empty. A non-empty diff *before* your own change means someone hand-edited the output — port it back into the `.org` first, then tangle, then confirm the only remaining diff is yours. Never resolve the conflict by discarding the tangle: the `.org` is the source of truth, so the fix direction is always `.py` → `.org`, never `.org` ← re-run.

**Not yet a structural test**: the check wants a CI step that tangles into a scratch tree and diffs against the committed output (`make check-tangle-drift` shape, per `literate-agent`'s `lp-resync-metadata.md` invariant 2). Filed here rather than implemented because it needs a tangle-to-tempdir mode the Makefile does not have yet.

## 2026-07-25 — "ok: true" is not "alive" (Orca closed-tab handle)

**Mistake**: `code-agent-mux-ensure-session` for the Orca backend treated any non-error envelope from `orca terminal show` as proof the terminal was live. Closing a tab does *not* invalidate the handle — `terminal show` keeps answering `ok: true`, with `connected: false`, and the terminal disappears from `terminal list`.

**Context**: Every unit test passed; the bug appeared only in live E2E, where relaunching after closing the tab reported "Orca terminal focused" and then sent prompts into a pane that no longer existed. The envelope's `ok` field answers "was the request well-formed", never "is the resource usable".

**Rule**: When a CLI wraps replies in an `ok`/`error` envelope, `ok: true` means the *call* succeeded. Liveness, writability, and existence are separate fields inside `result` — read them. Any `ensure-*` / `-alive-p` predicate built on the envelope alone is checking the wrong thing.

## 2026-07-26 — deferred lambda closed over `let` state; literate-elisp is dynamically bound

**Mistake**: `code-agent-orca--call-async` handed `set-process-sentinel` an inline lambda referencing `buf` and `callback` from the enclosing `let*`, and the same shape repeated twice more (`code-agent-orca-wait-for-ready` over `callback`, `code-agent-org-backend-launch` over `handle`). literate-elisp loads `.org` sources under dynamic binding — the `lexical-binding: t` cookie is not honoured — so none of the three lambdas captured anything.

**Context**: Every launch through `code-agent-menu` printed `if: Symbol's value as variable is void: buf` in `*Messages*` and silently dropped the readiness report. The reported variable was the *cleanup* one: the body's `void-variable callback` was overwritten by the `unwind-protect` cleanup's own `void-variable buf`, which is why the message named a buffer and not the callback. Nothing failed loudly — `terminal create` had already succeeded, so the terminal appeared and only the post-launch callback chain was dead.

**Rule**: A lambda that outlives the form that created it must not reference enclosing `let` bindings. Three fixes, in preference order: read the value back off the object that survives (`process-buffer`, `process-get`), pass it through `apply-partially` to a named handler, or `lexical-let` it. Inline `lambda` remains fine for synchronous callers (`cl-some`, `mapcar`) that run inside the dynamic extent.

**Structural test added**: `test-structural-no-deferred-closure-over-let` (F48) in `tests/test-structural.el` — walks every source `.org`, tracks `let`/arglist bindings, and flags any inline lambda passed to `set-process-sentinel` / `set-process-filter` / `run-at-time` / `run-with-timer` / `run-with-idle-timer` or a project function whose name ends in `-async` / `wait-for-ready` that references an outer binding. Verified against the pre-fix file: 3 violations found, 0 after the fix.
