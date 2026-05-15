# cmux Dev Build Management

## Layout

| App | Path | Bundle ID | Socket |
|-----|------|-----------|--------|
| Production / Release | `/Applications/cmux.app` | `com.cmuxterm.app` | auto-detect |
| Dev (daily) | `/Applications/cmux DEV.app` | `com.cmuxterm.app.debug.emacs.test` | `/tmp/cmux-dev.sock` |
| Dev (test build) | `~/Library/Developer/Xcode/DerivedData/cmux-emacs-test/...` | same | `/tmp/cmux-debug-emacs-test.sock` |
| Release (test build) | `~/Library/Developer/Xcode/DerivedData/cmux-release-test/...` | same as production | none (uses default) |

## Source repo

- Origin: `git@github.com:jingtaozf/cmux.git`
- Upstream: `https://github.com/manaflow-ai/cmux.git`
- Dev branch: `jt`
- Feature branches: `feat/<name>` (for PRs to upstream)

## Sync an upstream tag into the local jt branch

Upstream releases ship as tags `vX.Y.Z`. To bring `jt` to a new release:

```bash
cd reference/cmux
git fetch upstream --tags
# verify the tag arrived and is not yet an ancestor of HEAD
git merge-base --is-ancestor vX.Y.Z HEAD; echo $?  # 1 = not merged yet
# fast-forward-friendly merge with the same message style as prior merges
git merge vX.Y.Z -m "Merge tag 'vX.Y.Z' into jt"
```

If `git fetch` rejects the `nightly` tag with `would clobber existing tag`,
that's harmless — the version tags still come through.

## Three build pitfalls (apply to BOTH dev and release)

These three reliably bite a fresh build on this machine; bake them into
every xcodebuild invocation.

### 1. Zig version mismatch — Ghostty requires v0.15.2

`/opt/homebrew/bin/zig` is whatever the latest brew ships (currently
0.16.0). Ghostty's `build.zig` rejects anything that isn't 0.15.2:

```
error: Your Zig version v0.16.0 does not meet the required build version of v0.15.2
```

`zig@0.15` is keg-only on this machine — installed but not on PATH.
Override via `CMUX_ZIG`, which `scripts/build-ghostty-cli-helper.sh`
honours (and which propagates into the xcodebuild Run Script phase):

```bash
export CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig
# verify: $CMUX_ZIG version  →  0.15.2
```

If `zig@0.15` isn't installed, run `brew install zig@0.15` first.

### 2. Architecture — build arm64-only on Apple Silicon

Release config defaults to a universal (arm64 + x86_64) build, but some
upstream dependencies aren't built for x86_64 on this machine, so the
x86_64 link fails with `Undefined symbols for architecture x86_64`.
For local use on Apple Silicon, force arm64-only:

```
ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
```

(Debug config / `reload.sh` already does the right thing here — the
issue only bites Release config invoked directly.)

### 3. Code signing — disable for local builds

Release config has `Sign To Run Locally` plus entitlements that demand
a development signing certificate:

```
error: "GhosttyTabs" has entitlements that require signing with a
       development certificate.
```

For local-only builds, suppress signing entirely:

```
CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS=""
```

The resulting `cmux.app` is unsigned — Gatekeeper will warn on first
launch via `open`, right-click → Open to override. (Debug config also
needs this if you invoke xcodebuild directly; `reload.sh` handles it.)

## Build dev app (safe — does not affect running dev app)

```bash
cd reference/cmux
git config --global url."git@github.com:".insteadOf "https://github.com/"
CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
  ./scripts/reload.sh --tag emacs-test
git config --global --unset url."git@github.com:".insteadOf
```

Output goes to `~/Library/Developer/Xcode/DerivedData/cmux-emacs-test/Build/Products/Debug/cmux DEV emacs-test.app`.
Build time on M-series: ~17 s incremental, ~2 min cold.

## Build release app (safe — does not affect running release app)

`scripts/reload.sh` is hard-coded to Debug config. The full release
pipeline (`scripts/build-sign-upload.sh`) does sign + notarize + DMG +
GitHub upload — too heavyweight for a local install. For a *local*
release-config build, drive xcodebuild directly:

```bash
cd reference/cmux
git config --global url."git@github.com:".insteadOf "https://github.com/"
CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/cmux-release-test \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  build
git config --global --unset url."git@github.com:".insteadOf
```

Output: `~/Library/Developer/Xcode/DerivedData/cmux-release-test/Build/Products/Release/cmux.app`
(~84 MB, arm64-only, unsigned). Build time on M-series: ~3-5 min cold.

## Copy + Relaunch — dev app (DANGEROUS — kills running dev sessions)

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

## Copy + Relaunch — release app (DANGEROUS — kills running release sessions)

**NEVER do this automatically.** Only when the user explicitly asks.
Replacing `/Applications/cmux.app` while it's running will terminate
every Claude Code session it hosts (including, potentially, the agent's
own session).

```bash
# Confirm nothing critical is running first:
ps -ef | grep -i "/Applications/cmux.app" | grep -v grep

rm -rf /Applications/cmux.app
cp -R ~/Library/Developer/Xcode/DerivedData/cmux-release-test/Build/Products/Release/cmux.app /Applications/cmux.app
open /Applications/cmux.app
```

The first launch of an unsigned build triggers Gatekeeper. If `open`
silently refuses, right-click the app in Finder → *Open* once to
register an exception.

## Emacs connection

Set per-file: `#+PROPERTY: CMUX_VERSION dev`
Or global: `(setq code-agent-org-cmux-socket-path "/tmp/cmux-debug-emacs-test.sock")`
