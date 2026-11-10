# Shared release lane, sourced by tools/dtp.sh and tools/tdtp.sh (not run directly).
#   LANE=dtp|tdtp   dtp: build + --diagnostics + watchdog check
#                   tdtp: full tools/preflight.sh
# Options: --dry-run prints every mutating command instead of running it.
# Env (tests): DISPLAYMIND_INSTALL_DEST installs there instead of /Applications;
# DISPLAYMIND_REPORT_STATUS overrides the report-status.sh path; MIND_RUN_ID set
# means a parent run owns the status card and this lane reports nothing.

PLIST=Resources/Info.plist
DRY=0
BUMPED=0
REPORTED=""
RUN_ID=""

say() { printf '%s: %s\n' "$LANE" "$*"; }
fail() { say "$*" >&2; exit 1; }

# Run a mutating command, or print it under --dry-run.
run() {
  if [ "$DRY" = 1 ]; then printf '+ %s\n' "$*"; else "$@"; fi
}

report_script() {
  if [ -n "${DISPLAYMIND_REPORT_STATUS:-}" ]; then printf '%s' "$DISPLAYMIND_REPORT_STATUS"; return; fi
  for C in "$HOME/GIT/CoreMind/bin/report-status.sh" "$HOME/GIT/MindSuite/CoreMind/bin/report-status.sh"; do
    if [ -f "$C" ]; then printf '%s' "$C"; return; fi
  done
}

# Never fatal: every call ends in `|| true`.
report() {
  [ -z "${MIND_RUN_ID:-}" ] || return 0
  if [ "$DRY" = 1 ]; then printf '+ report-status %s\n' "$*"; return 0; fi
  R=$(report_script)
  [ -n "$R" ] || return 0
  case "$1" in
    start) RUN_ID=$(sh "$R" start "$LANE" DisplayMind 2>/dev/null || true) ;;
    finish) [ -z "$RUN_ID" ] || sh "$R" finish "$RUN_ID" "$2" "$3" "$4" >/dev/null 2>&1 || true ;;
  esac
  return 0
}

on_exit() {
  CODE=$?
  trap - EXIT
  if [ "$CODE" != 0 ]; then
    # A bump that never reached a commit is undone.
    if [ "$BUMPED" = 1 ] && [ "$DRY" = 0 ]; then
      git checkout HEAD -- VERSION "$PLIST" 2>/dev/null || true
      say 'restored VERSION and Info.plist' >&2
    fi
    if [ -z "$REPORTED" ]; then report finish failed 3 "Stopped before release completed."; fi
  fi
  exit "$CODE"
}

# major*1000000 + minor*1000 + patch, for comparing x.y.z.
vnum() { echo "$1" | awk -F. '{ printf "%d", $1 * 1000000 + $2 * 1000 + $3 }'; }

release_main() {
  for A in "$@"; do
    case "$A" in
      --dry-run) DRY=1 ;;
      *) echo "usage: tools/$LANE.sh [--dry-run]" >&2; exit 2 ;;
    esac
  done
  cd "$(dirname "$0")/.."

  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" = main ] || fail "not on main (on $BRANCH)"
  git remote get-url origin >/dev/null 2>&1 || fail 'no origin remote'

  VERSION=$(cat VERSION)
  PLIST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")
  [ "$VERSION" = "$PLIST_VERSION" ] || fail "VERSION ($VERSION) differs from the plist ($PLIST_VERSION)"
  case "$VERSION" in
    [0-9]*.[0-9]*.0) ;;
    *) fail "VERSION $VERSION is not x.y.0" ;;
  esac
  case "$VERSION" in *[!0-9.]*) fail "VERSION $VERSION is not x.y.0" ;; esac

  # Only the release's own files may be dirty.
  OTHER=$(git status --porcelain | grep -v -E '^.. (VERSION|Resources/Info\.plist)$' || true)
  [ -z "$OTHER" ] || fail "the tree has other changes: commit or stash them
$OTHER"

  LATEST=$(git tag -l 'v[0-9]*' | awk -F. '{ printf "%s %d\n", $0, substr($1,2) * 1000000 + $2 * 1000 + $3 }' | sort -k2 -n | tail -1 | cut -d' ' -f1)
  BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")
  if [ -n "$LATEST" ] && [ "$(vnum "$VERSION")" -le "$(vnum "${LATEST#v}")" ]; then
    git diff --quiet -- VERSION "$PLIST" || fail "VERSION/Info.plist are modified but not ahead of $LATEST"
    NEW=${VERSION%%.*}
    MINOR=${VERSION#*.}; MINOR=${MINOR%%.*}
    NEW="$NEW.$((MINOR + 1)).0"
    BUMP=1
    PREV_BUILD=$(git show "$LATEST:$PLIST" > "${TMPDIR:-/tmp}/dm-plist.$$" && /usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "${TMPDIR:-/tmp}/dm-plist.$$"; rm -f "${TMPDIR:-/tmp}/dm-plist.$$")
    [ "$PREV_BUILD" -ge "$BUILD" ] 2>/dev/null && BUILD=$PREV_BUILD
    NEW_BUILD=$((BUILD + 1))
  else
    NEW=$VERSION
    BUMP=0
    NEW_BUILD=$BUILD
    if [ -n "$LATEST" ]; then
      PREV_BUILD=$(git show "$LATEST:$PLIST" > "${TMPDIR:-/tmp}/dm-plist.$$" && /usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "${TMPDIR:-/tmp}/dm-plist.$$"; rm -f "${TMPDIR:-/tmp}/dm-plist.$$")
      if [ "$PREV_BUILD" -ge "$NEW_BUILD" ] 2>/dev/null; then
        # Reused bump that forgot the build number: bump it as part of this release.
        NEW_BUILD=$((PREV_BUILD + 1)); BUILD_FIX=1
      fi
    fi
  fi
  TAG="v$NEW"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
  if [ "$BUMP" = 1 ]; then say "bumping $VERSION -> $NEW (build $NEW_BUILD)"; else say "reusing untagged $NEW (build $NEW_BUILD)"; fi

  trap on_exit EXIT
  report start
  # --- bump
  if [ "$BUMP" = 1 ] || [ "${BUILD_FIX:-0}" = 1 ]; then
    [ "$BUMP" = 0 ] || BUMPED=1
    if [ "$DRY" = 1 ]; then
      printf '+ write VERSION %s; PlistBuddy Set CFBundleShortVersionString %s, CFBundleVersion %s\n' "$NEW" "$NEW" "$NEW_BUILD"
    else
      printf '%s\n' "$NEW" > VERSION
      /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $NEW" -c "Set CFBundleVersion $NEW_BUILD" "$PLIST"
    fi
  fi

  # --- check
  if [ "$LANE" = tdtp ]; then
    run sh tools/preflight.sh
  else
    run sh tools/build.sh release
    run dist/DisplayMind.app/Contents/MacOS/DisplayMind --diagnostics
    run python3 tools/check-watchdog.py
  fi

  # --- signature: an ad hoc build must not ship (zero or several Developer ID identities make build.sh fall back)
  if [ "$DRY" = 1 ]; then
    printf '+ verify dist/DisplayMind.app is not ad hoc signed\n'
  elif [ "${DISPLAYMIND_ALLOW_ADHOC_RELEASE:-0}" != 1 ]; then
    SIG=$(codesign -dv dist/DisplayMind.app 2>&1) || fail 'could not read the signature of dist/DisplayMind.app'
    case "$SIG" in
      *Signature=adhoc*) fail 'dist/DisplayMind.app is ad hoc signed (need exactly one Developer ID Application identity); set DISPLAYMIND_ALLOW_ADHOC_RELEASE=1 to override' ;;
    esac
  fi

  # --- distributable: a notarized disk image for other Macs, when this Mac can notarize (before anything is pushed)
  DMG_READY=0
  if [ "$DRY" = 1 ]; then
    printf '+ sh tools/dmg.sh   (when a notarytool keychain profile exists)\n'
  elif sh tools/dmg.sh --ready; then
    sh tools/dmg.sh
    DMG_READY=1
  else
    say 'no notarytool keychain profile: this release is a tag without a disk image (see tools/dmg.sh)' >&2
  fi

  # --- commit, tag, push
  run git add VERSION "$PLIST"
  if [ "$DRY" = 1 ] || ! git diff --cached --quiet; then
    run git commit -m "DisplayMind $NEW"
  fi
  BUMPED=0
  run git tag -a "$TAG" -m "DisplayMind $NEW"
  if [ "$DRY" = 0 ] && ! git push --atomic origin main "$TAG"; then
    git tag -d "$TAG" >/dev/null
    fail "push failed; removed local tag $TAG (the release commit is kept)"
  fi
  [ "$DRY" = 0 ] || printf '+ git push --atomic origin main %s\n' "$TAG"

  # --- publish the disk image with the GitHub release
  PUBLISH_FAILED=0
  if [ "$DRY" = 1 ]; then
    printf '+ sh tools/dmg.sh --publish-only   (when the image was built)\n'
  elif [ "$DMG_READY" = 1 ]; then
    sh tools/dmg.sh --publish-only || PUBLISH_FAILED=1
  fi

  # --- install
  INSTALL_FAILED=0
  if [ -n "${DISPLAYMIND_INSTALL_DEST:-}" ]; then
    run sh tools/install.sh "$DISPLAYMIND_INSTALL_DEST" || INSTALL_FAILED=1
  else
    run sh tools/install.sh || INSTALL_FAILED=1
  fi

  REPORTED=1
  if [ "$PUBLISH_FAILED" = 1 ]; then
    report finish ok 2 "Released $TAG; the disk image was not published."
    fail "released $TAG but the disk image was not published (retry with tools/dmg.sh --publish-only)"
  fi
  if [ "$INSTALL_FAILED" = 1 ]; then
    report finish ok 2 "Released $TAG; install on this Mac failed."
    fail "released $TAG but the install failed"
  fi
  report finish ok 0 "Released $TAG."
  if [ "$DMG_READY" = 1 ]; then say "released $TAG with its disk image and installed it"; else say "released $TAG and installed it"; fi
}
