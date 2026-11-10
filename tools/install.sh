#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test -d dist/DisplayMind.app || { echo 'Build the app with tools/preflight.sh first.' >&2; exit 1; }
codesign --verify --deep --strict dist/DisplayMind.app
DEST="${1:-/Applications}"
mkdir -p "$DEST"
if [ -e "$DEST/DisplayMind.app" ]; then
  echo 'An installed DisplayMind already exists; quit it and move it aside before installing.' >&2
  exit 1
fi
ditto dist/DisplayMind.app "$DEST/DisplayMind.app"
codesign --verify --deep --strict "$DEST/DisplayMind.app"
"$DEST/DisplayMind.app/Contents/MacOS/DisplayMind" --diagnostics
printf 'Installed %s/DisplayMind.app\n' "$DEST"
