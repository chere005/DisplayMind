#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh tools/build.sh release
. tools/heavy-lock.sh
heavy_lock "DisplayMind tests"
swift test --jobs 4
heavy_unlock
plutil -lint Resources/Info.plist
test "$(cat VERSION)" = "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
dist/DisplayMind.app/Contents/MacOS/DisplayMind --diagnostics
python3 tools/check-watchdog.py
git diff --check
git diff --cached --check
if git rev-parse --verify HEAD >/dev/null 2>&1; then git show --format= --check HEAD; fi
printf 'DisplayMind preflight passed.\n'
