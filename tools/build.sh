#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. tools/heavy-lock.sh
heavy_lock "DisplayMind macOS build"
MODE="${1:-release}"
case "$MODE" in release|debug) ;; *) echo 'usage: build.sh [release|debug]' >&2; exit 2 ;; esac
mkdir -p dist
# A release is universal (Apple silicon and Intel) so the same bundle is what ships in the dmg; that needs Xcode.
# DISPLAYMIND_NATIVE=1, or a debug build, builds for this Mac only and works with the Command Line Tools.
CLANG_ARCHS=""
SWIFT_ARCHS=""
if [ "$MODE" = release ] && [ "${DISPLAYMIND_NATIVE:-0}" != 1 ]; then
  CLANG_ARCHS="-arch arm64 -arch x86_64"
  SWIFT_ARCHS="--arch arm64 --arch x86_64"
fi
# The deployment target matches Package.swift; without it the helper would only run on this macOS or newer.
# shellcheck disable=SC2086
xcrun clang -O2 $CLANG_ARCHS -mmacosx-version-min=13.0 -Wno-deprecated-declarations -Wno-gnu-folding-constant -I Vendor/displayplacer/src \
  Vendor/displayplacer/src/DisplayPlacer.c Vendor/displayplacer/src/Legacy/v130.c \
  -x objective-c Vendor/displayplacer/src/MonitorPanel.m \
  -F Vendor/displayplacer/src/Headers -F /System/Library/PrivateFrameworks \
  -framework IOKit -framework ApplicationServices -framework DisplayServices \
  -framework CoreDisplay -framework OSD -framework MonitorPanel -framework SkyLight \
  -o dist/displayplacer
# shellcheck disable=SC2086
swift build -c "$MODE" $SWIFT_ARCHS --jobs 4
# shellcheck disable=SC2086
BIN=$(swift build -c "$MODE" $SWIFT_ARCHS --show-bin-path)
APP=dist/DisplayMind.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DisplayMind" "$APP/Contents/MacOS/DisplayMind"
cp dist/displayplacer "$APP/Contents/MacOS/displayplacer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Vendor/displayplacer/LICENSE "$APP/Contents/Resources/displayplacer-LICENSE.txt"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
cp Resources/MenuBarIcon.pdf "$APP/Contents/Resources/MenuBarIcon.pdf"
cp assets/logo.png "$APP/Contents/Resources/Logo.png"
if [ -n "$SWIFT_ARCHS" ]; then
  for BINARY in "$APP/Contents/MacOS/DisplayMind" "$APP/Contents/MacOS/displayplacer"; do
    case "$(lipo -archs "$BINARY")" in
      *arm64*x86_64*|*x86_64*arm64*) ;;
      *) echo "$BINARY is not universal" >&2; exit 1 ;;
    esac
  done
fi
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
