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
codesign --force --sign - "$APP/Contents/MacOS/displayplacer"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
