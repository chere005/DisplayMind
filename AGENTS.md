# DisplayMind

- Native SwiftUI macOS app; keep runtime local and settings in `~/DisplayMind`.
- Run `tools/preflight.sh` after implementation; it serializes builds with `tools/heavy-lock.sh`.
- Never change the live display configuration during automated tests; use fixture backends and offscreen rendering.
- Preserve the independent rollback watchdog and keep automatic rules limited to confirmed presets.
- Vendor changes must retain licensing and record the upstream revision and local changes in `Vendor/displayplacer/ORIGIN.md`.
