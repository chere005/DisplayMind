# Sourced by tools/build.sh and tools/dmg.sh: sets SIGNING_IDENTITY and SIGN_KIND.
# DISPLAYMIND_SIGNING_IDENTITY wins ("-" forces ad hoc). Unset: use the login
# keychain's only Developer ID Application identity so the code identity, and
# with it the Accessibility grant, survives rebuilds; else ad hoc.
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
  SIGN_KIND="ad hoc"
fi
