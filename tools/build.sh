#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. tools/heavy-lock.sh
heavy_lock "DisplayMind macOS build"
MODE="${1:-release}"
case "$MODE" in release|debug) ;; *) echo 'usage: build.sh [release|debug]' >&2; exit 2 ;; esac
mkdir -p dist
# DisplayMind supports Apple silicon; explicitly target arm64 for both binaries.
xcrun clang -O2 -arch arm64 -mmacosx-version-min=13.0 -Wno-deprecated-declarations -Wno-gnu-folding-constant -I Vendor/displayplacer/src \
  Vendor/displayplacer/src/DisplayPlacer.c Vendor/displayplacer/src/Legacy/v130.c \
  -x objective-c Vendor/displayplacer/src/MonitorPanel.m \
  -F Vendor/displayplacer/src/Headers -F /System/Library/PrivateFrameworks \
  -framework IOKit -framework ApplicationServices -framework DisplayServices \
  -framework CoreDisplay -framework OSD -framework MonitorPanel -framework SkyLight \
  -o dist/displayplacer
swift build -c "$MODE" --arch arm64 --jobs 4
BIN=$(swift build -c "$MODE" --arch arm64 --show-bin-path)
APP=dist/DisplayMind.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DisplayMind" "$APP/Contents/MacOS/DisplayMind"
cp dist/displayplacer "$APP/Contents/MacOS/displayplacer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Vendor/displayplacer/LICENSE "$APP/Contents/Resources/displayplacer-LICENSE.txt"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
cp Resources/MenuBarIcon.pdf "$APP/Contents/Resources/MenuBarIcon.pdf"
cp assets/logo.png "$APP/Contents/Resources/Logo.png"
for BINARY in "$APP/Contents/MacOS/DisplayMind" "$APP/Contents/MacOS/displayplacer"; do
  [ "$(lipo -archs "$BINARY")" = arm64 ] || { echo "$BINARY must contain only arm64" >&2; exit 1; }
done
. tools/signing.sh
if [ "$SIGN_KIND" = "ad hoc" ]; then
  set -- --force --sign -
else
  # Hardened runtime needs no entitlements here: checked with --diagnostics and
  # the helper's `list` on a Developer ID + runtime copy of the bundle.
  set -- --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp
fi
codesign "$@" "$APP/Contents/MacOS/displayplacer"
codesign "$@" "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s (%s; signed: %s)\n' "$APP" "$(lipo -archs "$APP/Contents/MacOS/DisplayMind")" "$SIGN_KIND"
