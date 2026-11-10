# DisplayMind

The baseline for all of Sean's repos lives in ~/GIT/AgentSuite/AGENTS.md and is imported here; this file holds only what is true of THIS repo.
@../AgentSuite/AGENTS.md

- Native SwiftUI macOS app; keep runtime local and state in `~/Library/Application Support/DisplayMind` (`DataFolder.resolve` moves a 0.4-era `~/DisplayMind` once).
- Run `tools/preflight.sh` after implementation; it serializes builds with `tools/heavy-lock.sh`.
- Never change the live display configuration during automated tests; use fixture backends and offscreen rendering.
- Preserve the independent rollback watchdog and keep automatic rules limited to confirmed presets.
- Vendor changes must retain licensing and record the upstream revision and local changes in `Vendor/displayplacer/ORIGIN.md`.
- Release with `tools/tdtp.sh` (full preflight) or `tools/dtp.sh` (build, `--diagnostics`, watchdog check): bump minor, tag `vX.Y.0`, atomic push, install; `--dry-run` prints the mutating commands.
- `tools/build.sh` signs with the only Developer ID Application identity (hardened runtime) when `DISPLAYMIND_SIGNING_IDENTITY` is unset, so the Accessibility grant survives rebuilds; `-` forces ad hoc.
- `tools/install.sh` updates an installed copy in place (quits and relaunches a running app, keeps the old bundle until `--diagnostics` passes) and refuses while the data folder holds `pending-change.json` or a `restoring-*.json` under 3 minutes old.
- Look at every screen you touch before releasing: `--render-preview` in `--dark` and light with the state flags in `Preview.swift`, and `--show` for live controls; never ship a view nobody has seen.
- A SwiftUI menu-style `Picker` is as wide as its longest item and ignores `frame`; use `PopUp`/`Segments` in `Controls.swift` wherever controls must line up or a name can be long.
- Standard controls keep the system accent; brand colour is `Branding.fill` (fills, with white text) and `Branding.text` (labels), never a root `.tint`.
- AirPlay control is Accessibility scripting of Control Center and its controls change between macOS releases: check them with `--airplay-probe` before changing `AirPlayController`, and test connect/disconnect with `--airplay-connect`/`--airplay-disconnect`, each launched through `open -n -g dist/DisplayMind.app --args …` so the app's own grant applies (a shell-launched binary is not trusted).

