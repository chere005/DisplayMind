#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh tools/build.sh release
. tools/heavy-lock.sh
heavy_lock "DisplayMind tests"
swift test --jobs 4
heavy_unlock
plutil -lint Resources/Info.plist
! /usr/libexec/PlistBuddy -c 'Print LSUIElement' Resources/Info.plist >/dev/null 2>&1 || { echo 'Info.plist must not set LSUIElement: DisplayMind is a normal Dock app.' >&2; exit 1; }
test "$(cat VERSION)" = "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
dist/DisplayMind.app/Contents/MacOS/DisplayMind --diagnostics
python3 tools/check-watchdog.py
python3 tools/check-install-processes.py
git diff --check
git diff --cached --check
if git rev-parse --verify HEAD >/dev/null 2>&1; then git show --format= --check HEAD; fi
printf 'DisplayMind preflight passed.\n'
