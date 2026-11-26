# DisplayMind for Windows

The repository baseline and root AGENTS.md apply. These instructions scope the native Windows implementation.

- Native C++20 and Win32. Keep the application independent of Swift, Electron, WebView, .NET and downloaded runtime packages. Use tabs for code indentation.
- Build with `tools/build.ps1`; the build lock serializes heavy desktop builds. `-Tests` also builds the native test executable.
- Windows preflight is `tools/preflight.ps1`. The root shell preflight is for the unchanged macOS implementation and cannot validate Windows code.
- Automated tests must use FixtureBackend. Never change live display settings, default audio endpoints, Cast connections or login registration during tests. Read-only diagnostics may use QueryDisplayConfig, SetupAPI, CoreAudio enumeration and SetDisplayConfig with SDC_VALIDATE only.
- A verified layout stays after ten seconds or after the application exits. Only explicit Revert or an incomplete apply triggers rollback. Preserve the independent watchdog and atomic recovery journal.
- Only confirmed presets may run automatically. Consume connection events caused by the app's own wireless changes, and respect manual selections until the next external connection change, wake or rule edit.
- Preserve corrupt/newer settings and failed rollback snapshots. Do not silently reset settings or discard a failed recovery.
- Inspect rendered light and dark previews for every changed screen. Use `--preview` for interactive fixture controls and `--ui-self-test <report.json>` for native control checks.
- A passing fixture suite does not establish that live GPU reconfiguration or physical wireless projection was exercised. Report those verification limits accurately.
- No commits, pushes or releases without Sean's authorization.
