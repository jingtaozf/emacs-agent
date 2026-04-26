# cmux Dev Build Management

## Layout

| App | Path | Bundle ID | Socket |
|-----|------|-----------|--------|
| Production | `/Applications/cmux.app` | `com.cmuxterm.app` | auto-detect |
| Dev (daily) | `/Applications/cmux DEV.app` | `com.cmuxterm.app.debug.emacs.test` | `/tmp/cmux-dev.sock` |
| Dev (test build) | `~/Library/Developer/Xcode/DerivedData/cmux-emacs-test/...` | same | `/tmp/cmux-debug-emacs-test.sock` |

## Build (safe — does not affect running dev app)

```bash
cd reference/cmux
git config --global url."git@github.com:".insteadOf "https://github.com/"
./scripts/reload.sh --tag emacs-test
git config --global --unset url."git@github.com:".insteadOf
```

## Copy + Relaunch (DANGEROUS — kills running sessions)

**NEVER do this automatically.** Only when the user explicitly asks.
Running Claude Code sessions in the dev app will be terminated.

```bash
pkill -9 -f "/Applications/cmux DEV" 2>/dev/null; sleep 2
cp -R ~/Library/Developer/Xcode/DerivedData/cmux-emacs-test/Build/Products/Debug/cmux\ DEV\ emacs-test.app /Applications/cmux\ DEV.app
CMUX_SOCKET_MODE=allowAll \
CMUX_SOCKET_PATH=/tmp/cmux-dev.sock \
CMUX_DEBUG_LOG=/tmp/cmux-dev.log \
nohup "/Applications/cmux DEV.app/Contents/MacOS/cmux DEV" > /dev/null 2>&1 &
```

## Emacs connection

Set per-file: `#+PROPERTY: CMUX_VERSION dev`
Or global: `(setq code-agent-org-cmux-socket-path "/tmp/cmux-debug-emacs-test.sock")`

## Source repo

- Origin: `git@github.com:jingtaozf/cmux.git`
- Upstream: `https://github.com/manaflow-ai/cmux.git`
- Dev branch: `jt`
- Feature branches: `feat/<name>` (for PRs to upstream)
