#!/usr/bin/env bash
# Build a distributable DMG for Terminal Fly.
#
# Usage:
#   ./scripts/make-dmg.sh              # build + package (unsigned/ad-hoc)
#   ./scripts/make-dmg.sh --notarize   # also submit to Apple + staple
#
# Notarization needs a Developer ID cert and credentials. Set either:
#   NOTARY_PROFILE   a keychain profile from `xcrun notarytool store-credentials`
# or:
#   APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD
#
# This script does NOT create a cert for you, and it will not pretend to
# notarize: with no credentials it packages the DMG and says plainly that the
# bundle is unsigned, rather than emitting a "done" that macOS will reject.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NOTARIZE=0
[ "${1:-}" = "--notarize" ] && NOTARIZE=1

APP="build/TerminalFly.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/TerminalFly-${VERSION}.dmg"
STAGE="build/dmg-stage"

echo "==> release build"
./scripts/build.sh release

if [ ! -x "$APP/Contents/MacOS/TerminalFly" ]; then
  echo "FATAL: $APP/Contents/MacOS/TerminalFly missing — build did not produce a binary" >&2
  exit 1
fi

# --- Signing. Ad-hoc when no identity is available; Developer ID otherwise.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ]; then
  echo "==> codesigning with $IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" "$APP"
else
  echo "==> no CODESIGN_IDENTITY set — ad-hoc signing (not distributable)"
  codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true
fi

echo "==> verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

if [ -n "$IDENTITY" ]; then
  echo "==> gatekeeper assessment"
  spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/    /' || \
    echo "    (spctl failed — expected until the app is notarized and stapled)"
fi

# --- Stage the DMG contents: the app plus a symlink to /Applications so the
#     window reads as "drag me here".
echo "==> staging DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Terminal Fly" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

echo "==> built $DMG ($(du -h "$DMG" | cut -f1))"

# --- Notarization.
if [ "$NOTARIZE" = "1" ]; then
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> submitting with keychain profile '$NOTARY_PROFILE'"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    echo "==> submitting as $APPLE_ID (team $APPLE_TEAM_ID)"
    xcrun notarytool submit "$DMG" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" \
      --wait
  else
    echo "FATAL: --notarize needs NOTARY_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD" >&2
    echo "       Nothing was submitted. $DMG exists but is UNNOTARIZED." >&2
    exit 1
  fi
  echo "==> stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "==> notarized and stapled: $DMG"
else
  cat <<EOF

$DMG is ready but UNSIGNED WITH A DEVELOPER ID and UNNOTARIZED.
On another Mac, Gatekeeper will block it until the user allows it in
System Settings → Privacy & Security. To ship properly:

    export CODESIGN_IDENTITY="Developer ID Application: NAME (TEAMID)"
    export NOTARY_PROFILE="terminalfly"
    ./scripts/make-dmg.sh --notarize
EOF
fi
