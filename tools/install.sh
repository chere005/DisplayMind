#!/bin/sh
# Install dist/DisplayMind.app, updating an existing copy in place.
#   tools/install.sh [destination-dir]    (default /Applications)
# With an explicit destination other than /Applications (tests), the real app is
# never quit or launched.
set -eu
cd "$(dirname "$0")/.."
BUNDLE_ID=com.seancheren.DisplayMind
REAL=0
if [ $# -eq 0 ] || [ "$1" = /Applications ]; then REAL=1; fi
DEST="${1:-/Applications}"

die() { echo "$*" >&2; exit 1; }

test -d dist/DisplayMind.app || die 'Build the app with tools/preflight.sh first.'
# Refuse while a change or a restore is in flight in a state folder.
check_state() {
  [ ! -e "$1/pending-change.json" ] || die "A display change is pending ($1/pending-change.json); keep or revert it first."
  # A snapshot touched in the last 3 minutes is a restore in flight; an older one is a kept record of a failed restore.
  RECENT=$(find "$1" -maxdepth 1 -name 'restoring-*.json' -mmin -3 2>/dev/null | head -1)
  [ -z "$RECENT" ] || die "A display recovery is in progress ($RECENT); let it finish first."
}
if [ -n "${DISPLAYMIND_STATE_DIR:-}" ]; then
  check_state "$DISPLAYMIND_STATE_DIR"
else
  check_state "$HOME/Library/Application Support/DisplayMind"
  check_state "$HOME/DisplayMind"   # 0.4 and earlier, until the app has moved it
fi
codesign --verify --deep --strict dist/DisplayMind.app
mkdir -p "$DEST"
TARGET="$DEST/DisplayMind.app"
STAGE="$DEST/.DisplayMind.app.new.$$"
PREV="$DEST/.DisplayMind.app.prev.$$"
WAS_RUNNING=0
trap 'rm -rf "$STAGE"' EXIT

# Exchange two directories atomically (renamex_np RENAME_SWAP); 0 on success.
swap() {
  python3 -I - "$1" "$2" <<'PY'
import ctypes, sys
libc = ctypes.CDLL(None, use_errno=True)
sys.exit(0 if libc.renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), 2) == 0 else 1)
PY
}

relaunch() { if [ "$WAS_RUNNING" = 1 ]; then open "$TARGET" || true; fi; }

rm -rf "$STAGE"
ditto dist/DisplayMind.app "$STAGE"
codesign --verify --deep --strict "$STAGE"

# Real install only: the Apple event may be refused (no Automation consent), so pgrep also counts.
is_running() {
  [ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null || echo false)" = true ] || pgrep -x DisplayMind >/dev/null 2>&1
}

if [ "$REAL" = 1 ] && [ -e "$TARGET" ]; then
  if is_running; then
    WAS_RUNNING=1
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || pkill -TERM -x DisplayMind || true
    N=0
    while is_running; do
      N=$((N + 1))
      [ "$N" -le 20 ] || die 'DisplayMind did not quit within 10 seconds; leaving the installed copy untouched.'
      [ "$N" -ne 6 ] || pkill -TERM -x DisplayMind || true   # the Apple event did not take effect within 3 s
      sleep 0.5
    done
  fi
fi

if [ -e "$TARGET" ]; then
  # Swap so TARGET is never absent; the old bundle then sits at STAGE.
  if swap "$STAGE" "$TARGET"; then
    mv "$STAGE" "$PREV"
  else
    mv "$TARGET" "$PREV"
    mv "$STAGE" "$TARGET"
  fi
else
  mv "$STAGE" "$TARGET"
fi

if ! "$TARGET/Contents/MacOS/DisplayMind" --diagnostics; then
  echo 'New build failed --diagnostics; restoring the previous bundle.' >&2
  if [ -e "$PREV" ]; then
    if swap "$PREV" "$TARGET"; then rm -rf "$PREV"; else rm -rf "$TARGET"; mv "$PREV" "$TARGET"; fi
  else
    rm -rf "$TARGET"
  fi
  relaunch
  exit 1
fi
rm -rf "$PREV"
relaunch
printf 'Installed %s\n' "$TARGET"
