#!/bin/sh
# Register an `org-protocol://' URL handler on macOS so a path clicked in a
# terminal opens in the running Emacs instead of the terminal's own editor.
#
# Why this exists: Orca (and most terminals) route plain paths and file://
# hyperlinks to their built-in editor with no setting to redirect them.  A URL
# scheme is the one thing they hand to the operating system, so the way back to
# Emacs is a scheme macOS resolves to an app that talks to the Emacs server.
#
# macOS only delivers URL events to an application bundle, which is why this
# compiles a two-line AppleScript rather than dropping a shell script somewhere:
# a bare executable never receives the `GURL' Apple Event.
#
# The Emacs side lives in lp/org/code-agent-org.org § Opening a file from
# outside Emacs — it registers the `open-file' sub-protocol this handler feeds.
#
# Usage:
#   scripts/install-org-protocol-handler.sh [--app-dir DIR] [--emacsclient PATH]
#
# Re-running replaces the app in place; it is safe to run after an Emacs or
# Orca upgrade.

set -eu

APP_DIR="$HOME/Applications"
EMACSCLIENT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --emacsclient) EMACSCLIENT="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This installer is macOS-only — other platforms register URL schemes" >&2
  echo "through their desktop environment (e.g. a .desktop file on Linux)." >&2
  exit 1
fi

if [ -z "$EMACSCLIENT" ]; then
  EMACSCLIENT="$(command -v emacsclient || true)"
fi
if [ -z "$EMACSCLIENT" ]; then
  echo "emacsclient not found on PATH — pass --emacsclient /path/to/emacsclient" >&2
  exit 1
fi

APP="$APP_DIR/OrgProtocol.app"
PLIST="$APP/Contents/Info.plist"
SRC="$(mktemp -t org-protocol-handler.XXXXXX)"
trap 'rm -f "$SRC"' EXIT

# `quoted form of' keeps the URL's & and ? out of the shell's hands.  The
# handler hands the whole URL to emacsclient; org-protocol parses it.
cat > "$SRC" <<EOF
on open location this_URL
	do shell script "$EMACSCLIENT -n " & quoted form of this_URL
end open location
EOF

mkdir -p "$APP_DIR"
rm -rf "$APP"
osacompile -o "$APP" "$SRC"

# osacompile writes no URL types, so the scheme is declared afterwards.  Every
# key is added fresh because the bundle was just recreated.
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string 'org-protocol handler'" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string org-protocol" "$PLIST" >/dev/null

# Ad-hoc signature: editing Info.plist invalidates the one osacompile made, and
# an app with a broken signature is refused by LaunchServices.
codesign --force --deep -s - "$APP" >/dev/null 2>&1

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$APP"

echo "installed: $APP"
echo "  handler: $EMACSCLIENT -n <url>"
echo
echo "Emacs side — add to your init (already shipped in code-agent-org.org):"
echo "  (require 'org-protocol)"
echo
echo "Verify with a file you have open:"
echo "  open 'org-protocol://open-file?file=\$PWD/README.org&line=1'"
