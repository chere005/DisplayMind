#!/bin/sh
# Package dist/DisplayMind.app as a disk image another Mac opens without warnings:
# Developer ID signed, notarized by Apple and stapled, for Apple silicon.
#
#   tools/dmg.sh                 build dist/DisplayMind-<version>.dmg (notarized)
#   tools/dmg.sh --publish       ...and attach it to the GitHub release for the tag v<version>
#   tools/dmg.sh --publish-only  attach the dmg already built and checked
#   tools/dmg.sh --unnotarized   build dist/DisplayMind-<version>-unnotarized.dmg, for looking at the image only
#   --dry-run prints what notarizing and publishing would run.
#
# Notarization needs a notarytool keychain profile, which holds an Apple ID's app-specific password and so
# can only be created by its owner:  xcrun notarytool store-credentials DisplayMind --apple-id <id> --team-id <team>
# The profile name is $DISPLAYMIND_NOTARY_PROFILE, else $APPLE_KEYCHAIN_PROFILE, else "DisplayMind".
set -eu
cd "$(dirname "$0")/.."
APP=dist/DisplayMind.app
PROFILE="${DISPLAYMIND_NOTARY_PROFILE:-${APPLE_KEYCHAIN_PROFILE:-DisplayMind}}"
NOTARIZE=1
PUBLISH=0
BUILD=1
DRY=0
for A in "$@"; do
  case "$A" in
    --publish) PUBLISH=1 ;;
    --publish-only) PUBLISH=1; BUILD=0 ;;
    --unnotarized) NOTARIZE=0 ;;
    --dry-run) DRY=1 ;;
    --ready) xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; exit $? ;;
    *) echo 'usage: tools/dmg.sh [--publish | --publish-only | --unnotarized] [--dry-run] | --ready' >&2; exit 2 ;;
  esac
done
die() { echo "dmg: $*" >&2; exit 1; }
run() { if [ "$DRY" = 1 ]; then printf '+ %s\n' "$*"; else "$@"; fi; }

test -d "$APP" || die 'build the app with tools/build.sh first'
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
TAG="v$VERSION"
if [ "$NOTARIZE" = 1 ]; then DMG="dist/DisplayMind-$VERSION.dmg"; else DMG="dist/DisplayMind-$VERSION-unnotarized.dmg"; fi
[ "$NOTARIZE" = 1 ] || [ "$PUBLISH" = 0 ] || die 'an image that is not notarized is never published'

# Submit one file and wait. A rejection prints Apple's log, which names the file and the reason.
notarize() {
  if [ "$DRY" = 1 ]; then printf '+ xcrun notarytool submit %s --keychain-profile %s --wait\n' "$1" "$PROFILE"; return 0; fi
  OUT=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1) || { echo "$OUT" >&2; die "Apple did not accept $1 for notarization"; }
  echo "$OUT" | grep -q 'status: Accepted' || {
    ID=$(echo "$OUT" | sed -n 's/^ *id: *//p' | head -1)
    echo "$OUT" >&2
    [ -z "$ID" ] || xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
    die "notarization of $1 was not accepted"
  }
}

if [ "$BUILD" = 1 ]; then
  # What ships must target Apple silicon only and carry a real signature.
  for BINARY in "$APP/Contents/MacOS/DisplayMind" "$APP/Contents/MacOS/displayplacer"; do
    [ "$(lipo -archs "$BINARY")" = arm64 ] || die "$BINARY must contain only arm64; build with tools/build.sh release"
  done
  codesign --verify --deep --strict "$APP"
  case "$(codesign -dv "$APP" 2>&1)" in *Signature=adhoc*) die 'the app is ad hoc signed; a Developer ID Application identity is needed' ;; esac
  . tools/signing.sh
  [ "$SIGN_KIND" != "ad hoc" ] || die 'no Developer ID Application identity to sign the image with'

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/DisplayMind-dmg.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
  if [ "$NOTARIZE" = 1 ]; then
    [ "$DRY" = 1 ] || xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 ||
      die "no notarytool keychain profile named \"$PROFILE\". Its owner creates it once with:
  xcrun notarytool store-credentials $PROFILE --apple-id <Apple ID> --team-id <team id>"
    # The app first, so the copy inside the image carries its own ticket and opens offline.
    run ditto -c -k --keepParent "$APP" "$WORK/DisplayMind.zip"
    notarize "$WORK/DisplayMind.zip"
    run xcrun stapler staple "$APP"
  fi
  mkdir "$WORK/image"
  ditto "$APP" "$WORK/image/DisplayMind.app"
  ln -s /Applications "$WORK/image/Applications"
  rm -f "$DMG"
  hdiutil create -quiet -volname "DisplayMind $VERSION" -srcfolder "$WORK/image" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
  if [ "$NOTARIZE" = 1 ]; then
    notarize "$DMG"
    run xcrun stapler staple "$DMG"
  fi
fi

test -f "$DMG" || die "$DMG does not exist; run tools/dmg.sh first"
hdiutil verify -quiet "$DMG"
codesign --verify --strict "$DMG"
if [ "$NOTARIZE" = 1 ] && [ "$DRY" = 0 ]; then
  # Gatekeeper's own verdict, as another Mac would reach it.
  xcrun stapler validate -q "$DMG" || die "$DMG has no notarization ticket stapled"
  spctl --assess --type open --context context:primary-signature "$DMG" || die "Gatekeeper does not accept $DMG"
  spctl --assess --type execute "$APP" || die "Gatekeeper does not accept $APP"
fi
SUM=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
printf '%s  %s\n' "$SUM" "$(basename "$DMG")" > "$DMG.sha256"
printf 'dmg: %s (%s, sha256 %s)\n' "$DMG" "$(du -h "$DMG" | cut -f1 | tr -d ' ')" "$SUM"

if [ "$PUBLISH" = 1 ]; then
  [ "$DRY" = 1 ] || git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG does not exist; release with tools/tdtp.sh"
  [ "$DRY" = 1 ] || [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || die "HEAD is not $TAG; the image would not be that release"
  PREVIOUS=$(git tag -l 'v[0-9]*' --sort=-v:refname | grep -v -x "$TAG" | head -1)
  NOTES=$(mktemp "${TMPDIR:-/tmp}/DisplayMind-notes.XXXXXX")
  {
    printf 'Open the disk image and drag DisplayMind to Applications. macOS 13 or later, Apple silicon.\n\n'
    if [ -n "$PREVIOUS" ]; then git log --format='- %s' "$PREVIOUS..$TAG" | grep -v -E '^- DisplayMind [0-9]+\.[0-9]+\.[0-9]+$' || true; fi
    printf '\nSHA-256 `%s`\n' "$SUM"
  } > "$NOTES"
  if [ "$DRY" = 0 ] && gh release view "$TAG" >/dev/null 2>&1; then
    run gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
  else
    run gh release create "$TAG" "$DMG" "$DMG.sha256" --verify-tag --title "DisplayMind $VERSION" --notes-file "$NOTES"
  fi
  rm -f "$NOTES"
  [ "$DRY" = 1 ] || printf 'dmg: published with release %s\n' "$TAG"
fi
