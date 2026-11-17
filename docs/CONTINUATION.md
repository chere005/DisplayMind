# Signing handoff

## Current state

- DisplayMind's release lane uses the `DisplayMind` notarytool Keychain profile to notarize and staple its Apple-silicon-only app and DMG, publish the image and checksum, and install the update.
- The Keychain profile `DisplayMind` validated successfully and can notarize local builds. Never record or print the app-specific password.
- Signed, notarized DMGs and `SHA256SUMS.txt` are in `~/Downloads/Notarized Mac Builds/`:
  - AgentTeam 0.8.0, arm64 and x64.
  - CalMind 1.58.0, arm64.
  - ChefMind 1.39.0 and AcctMind 0.62.0, arm64.
  - NoteMind 0.15.0, arm64.
- These six images passed stapler validation and Gatekeeper assessment. The four published-source applications were copied from release DMGs and checked against their published checksums; NoteMind was built locally. CalMind 1.58.0 came from the MindSuite release, newer than the original CalMind repository's 1.57.0 release. The other suite versions came from their original repositories.
- The six signed images are local copies: they were not installed or published, and existing release assets and checksums were not overwritten. They do not set up signing for future CI releases. NoteMind's build regenerated line endings in `THIRD-PARTY-NOTICES.txt`; that build-only change was restored, and its checkout was clean.

## Remaining work

- AgentTeam TaskMind #46 remains open: the local macOS artifacts are signed, but the release workflow still needs signing credentials and the ticket also covers the Windows installer. Its `SIGNING.md` describes the existing workflow secret requirements; do not overwrite an existing release's assets.
- Proposed TaskMind tickets for CalMind, ChefMind and AcctMind request signing and notarization in their release workflows. They await approval. Their local DMGs do not change those workflows.
- MindSuite's main checkout was on `feat/shared-login-library` with other worktrees in use; inspect its current state and use an isolated worktree for any release-workflow changes. Do not alter or deploy unrelated suite work.
- Apple initially rejected AgentTeam and NoteMind because `codesign --deep` alone left native binaries inside Electron resources unsigned. The successful local copies explicitly signed every embedded Mach-O with a Developer ID identity, hardened runtime and timestamp before signing the containing app, then notarized and stapled both app and DMG. AgentTeam used its existing Electron JIT entitlements. A transient stapler validation failure on the AgentTeam arm64 app succeeded on retry.
- Temporary scripts and logs under `/tmp/mind-notarize*` are diagnostic scratch files, not a maintained release lane; do not rely on them for future builds. No Windows signing was performed.

## Preflight

The display identity and preset organization update passed all 147 Swift tests, read-only diagnostics, and the independent fake-backend watchdog smoke check on 2026-11-16. The former watchdog timeout is resolved. Builds used a task-local `SDKROOT` from `xcrun --no-cache --sdk macosx --show-sdk-path` because xcrun's cached SDK did not match the selected Xcode; no global Xcode settings changed.
