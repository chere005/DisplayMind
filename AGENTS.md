# DisplayMind

The baseline for all of Sean's repos lives in ~/GIT/AgentSuite/AGENTS.md and is imported here; this file holds only what is true of THIS repo.
@../AgentSuite/AGENTS.md

- Native SwiftUI macOS app; keep runtime local and settings in `~/DisplayMind`.
- Run `tools/preflight.sh` after implementation; it serializes builds with `tools/heavy-lock.sh`.
- Never change the live display configuration during automated tests; use fixture backends and offscreen rendering.
- Preserve the independent rollback watchdog and keep automatic rules limited to confirmed presets.
- Vendor changes must retain licensing and record the upstream revision and local changes in `Vendor/displayplacer/ORIGIN.md`.
- Release with `tools/tdtp.sh` (full preflight) or `tools/dtp.sh` (build, `--diagnostics`, watchdog check): bump minor, tag `vX.Y.0`, atomic push, install; `--dry-run` prints the mutating commands.
- `tools/build.sh` signs with the only Developer ID Application identity (hardened runtime) when `DISPLAYMIND_SIGNING_IDENTITY` is unset, so the Accessibility grant survives rebuilds; `-` forces ad hoc.
- `tools/install.sh` updates an installed copy in place (quits and relaunches a running app, keeps the old bundle until `--diagnostics` passes) and refuses while `~/DisplayMind/pending-change.json` exists.
