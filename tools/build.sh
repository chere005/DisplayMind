#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. tools/heavy-lock.sh
heavy_lock "DisplayMind macOS build"
MODE="${1:-release}"
case "$MODE" in release|debug) ;; *) echo 'usage: build.sh [release|debug]' >&2; exit 2 ;; esac
mkdir -p dist
xcrun clang -O2 -Wno-deprecated-declarations -I Vendor/displayplacer/src \
  Vendor/displayplacer/src/DisplayPlacer.c Vendor/displayplacer/src/Legacy/v130.c \
  -x objective-c Vendor/displayplacer/src/MonitorPanel.m \
  -F Vendor/displayplacer/src/Headers -F /System/Library/PrivateFrameworks \
  -framework IOKit -framework ApplicationServices -framework DisplayServices \
  -framework CoreDisplay -framework OSD -framework MonitorPanel -framework SkyLight \
  -o dist/displayplacer
swift build -c "$MODE" --jobs 4
BIN=$(swift build -c "$MODE" --show-bin-path)
APP=dist/DisplayMind.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DisplayMind" "$APP/Contents/MacOS/DisplayMind"
cp dist/displayplacer "$APP/Contents/MacOS/displayplacer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Vendor/displayplacer/LICENSE "$APP/Contents/Resources/displayplacer-LICENSE.txt"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
cp Resources/MenuBarIcon.pdf "$APP/Contents/Resources/MenuBarIcon.pdf"
cp assets/logo.png "$APP/Contents/Resources/Logo.png"
# Signing: DISPLAYMIND_SIGNING_IDENTITY wins ("-" forces ad hoc). Unset: use the
# login keychain's only Developer ID Application identity so the code identity,
# and with it the Accessibility grant, survives rebuilds; else ad hoc.
SIGNING_IDENTITY="${DISPLAYMIND_SIGNING_IDENTITY:-}"
SIGN_KIND=""
if [ -z "$SIGNING_IDENTITY" ]; then
  FOUND=$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application:' || true)
  if [ -n "$FOUND" ] && [ "$(printf '%s\n' "$FOUND" | wc -l | tr -d ' ')" = 1 ]; then
    SIGNING_IDENTITY=$(printf '%s\n' "$FOUND" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) .*/\1/p')
    SIGN_KIND="Developer ID Application"
  fi
elif [ "$SIGNING_IDENTITY" != - ]; then
  SIGN_KIND="DISPLAYMIND_SIGNING_IDENTITY"
fi
if [ -z "$SIGN_KIND" ]; then
  SIGNING_IDENTITY=-
  set -- --force --sign -
  SIGN_KIND="ad hoc"
else
  # Hardened runtime needs no entitlements here: checked with --diagnostics and
  # the helper's `list` on a Developer ID + runtime copy of the bundle.
  set -- --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp
fi
codesign "$@" "$APP/Contents/MacOS/displayplacer"
codesign "$@" "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s (signed: %s)\n' "$APP" "$SIGN_KIND"
