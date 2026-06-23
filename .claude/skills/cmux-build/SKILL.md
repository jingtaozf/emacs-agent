---
name: cmux-build
description: Build cmux dev or release app from source. Handles zig, Metal, signing, and architecture pitfalls.
---
# cmux Build

Build the cmux app from the local source at `reference/cmux/`.

## Prerequisites

1. **Zig 0.15.2** (not 0.16.0 — Ghostty rejects it):
   ```bash
   brew install zig@0.15  # if not installed
   export PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"
   export CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig
   ```

2. **Metal Toolchain** (v0.64.12+):
   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```

## Build dev app (safe — does not affect running dev app)

```bash
cd reference/cmux
git config --global url."git@github.com:".insteadOf "https://github.com/"
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
  ./scripts/reload.sh --tag emacs-test
git config --global --unset url."git@github.com:".insteadOf
```

Output: `~/Library/Developer/Xcode/DerivedData/cmux-emacs-test/Build/Products/Debug/cmux DEV emacs-test.app`

## Build release app (safe — does not affect running release app)

```bash
cd reference/cmux
git config --global url."git@github.com:".insteadOf "https://github.com/"
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
CMUX_ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
xcodebuild \
  -project cmux.xcodeproj \
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

## Copy + Relaunch (DANGEROUS — kills running sessions)

Only when user explicitly asks. **Never do automatically.**

### Dev app
```bash
pkill -9 -f "/Applications/cmux DEV" 2>/dev/null; sleep 2
cp -R ~/Library/Developer/Xcode/DerivedData/cmux-emacs-test/Build/Products/Debug/cmux\ DEV\ emacs-test.app /Applications/cmux\ DEV.app
CMUX_SOCKET_MODE=allowAll CMUX_SOCKET_PATH=/tmp/cmux-dev.sock \
nohup "/Applications/cmux DEV.app/Contents/MacOS/cmux DEV" > /dev/null 2>&1 &
```

### Release app
```bash
rm -rf /Applications/cmux.app
cp -R ~/Library/Developer/Xcode/DerivedData/cmux-release-test/Build/Products/Release/cmux.app /Applications/cmux.app
open /Applications/cmux.app
```

## Emacs connection

Set per-file: `#+PROPERTY: CMUX_VERSION dev`
Or global: `(setq code-agent-org-cmux-socket-path "/tmp/cmux-debug-emacs-test.sock")`

## Disk hygiene — clean build caches

```bash
rm -rf ~/projects/emacs-agent/reference/cmux/ghostty/.zig-cache  # ~9 GB, regenerates
rm -rf ~/.cache/cmux
```
