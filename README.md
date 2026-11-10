# DisplayMind

A small native macOS app for display presets and connection-based defaults.

<img src="assets/logo-preview.png" width="128" alt="DisplayMind silver DM logo">

![DisplayMind](docs/displaymind.png)

- Capture the current arrangement, then edit rotation, resolution, refresh rate, main display, extended positions, and mirroring.
- Switch presets from the window or menu bar.
- Connect a saved AirPlay receiver before applying a preset, including from connection rules.
- Apply a default when selected displays or USB docks/devices are connected or absent.
- Arrange rule priority; require an exact display set or allow extra displays.
- An applied preset stays; for 10 seconds a countdown offers Revert. A separate process rolls back an apply that never finishes.
- Optionally launch at login. Closing the window leaves the menu-bar app running.

## Use

Open DisplayMind and choose **Capture current layout** in the sidebar. Give the preset a name, adjust it, and save it. **Apply preset** applies it and offers **Revert** for 10 seconds; do nothing and it stays; **Edit preset…** reopens the editor, where a click on a display selects it and a drag moves it. The sidebar and the menu-bar menu mark the preset whose layout the displays have now. Double-click a preset in the sidebar, or choose **Rename** from its ⋯ menu, to rename it in place; renaming never affects its rules. Capturing an unchanged current layout also marks it ready for automatic rules.

In **Connection rules**, choose a preset and mark each relevant display or USB device **Connected** or **Absent**. All conditions must match. The first eligible rule wins after connections settle for three seconds. DisplayMind does not poll: display, USB and wake notifications trigger a check (bursts are coalesced), a timer runs only during a revert countdown, recovery wait or settle window, and a 60-second fallback re-check covers a missed notification. Rules also run on launch and wake. A manually selected preset remains active until the next connection change, wake, or rule change. Automatic switching can be paused in the sidebar or menu bar.

[Layout editor](docs/preset-editor.png) · [Connection rules](docs/connection-rules.png) · [Rule editor](docs/rule-editor.png)

An edited preset must be applied and kept once before it can run automatically. Every application is verified against the preset and retried up to three times while macOS settles (a mirror can drop after a rotation); automatic applications revert on failure. Newly connected USB devices appear automatically. Previously selected devices remain available in the rule editor after disconnecting.

## AirPlay

A preset that contains an AirPlay display connects its receiver when it is applied, and a preset without that display stops the stream: the preset says which displays there are. Capture a layout while the receiver is connected through macOS Screen Mirroring and the preset is linked to it by itself; presets captured before 0.7.0 are linked the next time that display is connected. The editor's **AirPlay** section shows the receiver and its display, and **Connect a receiver when applying** turns the link off for a preset you would rather connect by hand.

[AirPlay preset editor](docs/airplay-editor.png)

**Allow AirPlay control** opens the macOS Accessibility permission settings. Enable DisplayMind there so it can use the Screen Mirroring controls. The permission is needed only to start or stop a stream. Receiver pairing codes and macOS approval prompts remain under your control.

Applying a preset stops any AirPlay stream it has no display for, connects its own receiver and waits up to 30 seconds for that display, then applies the arrangement and offers Revert. Reverting puts the streams back as they were: one the change started is stopped, one it stopped is reconnected, including if the app exits.

Connection rules can trigger while the preset’s AirPlay display is offline. Use a dock or another display as the connection condition; an explicit condition requiring the AirPlay display to be connected still means it must already be connected. An AirPlay connection made by DisplayMind does not immediately trigger another rule.

DisplayMind recognises an AirPlay display from what macOS reports about it, and finds the receiver in Control Center's Screen Mirroring list by a saved control identifier or by name; it never falls back to an arbitrary receiver. On macOS 26 a connected receiver is stopped with its **Stop Mirroring**/**Stop Extending** button; earlier systems toggle its checkbox. If macOS moves those controls, `DisplayMind --airplay-probe report.txt --open` (launched with `open -n -g DisplayMind.app --args …` so the app's own permission applies) writes what Control Center exposes. This feature controls screen streaming, not audio-only AirPlay or Sidecar.

## Sound

A preset saves the Mac's default sound output and input when captured; the editor's **Sound** section changes either, or leaves one on **Don't change**. Devices are matched by CoreAudio UID. Bluetooth headphones in use are never taken off: a side whose current device is Bluetooth is left alone when a preset is applied, and when that device disconnects the active preset's device takes over instead of whatever macOS falls back to. A device you choose yourself while the headphones stay connected is left alone. Applying the preset sets them after the displays verify (output also becomes the alert-sound device). A saved device that is not connected is skipped and named in the status or notification; the layout stays. A sound error is reported without reverting the layout. Reverting, expiry and the watchdog put back the previous devices after the layout, best effort. Changing only the sound devices keeps a preset eligible for automatic rules.

## Build

Requires macOS 13 or later and Xcode Command Line Tools with Swift 5.9 or later. The app and helper build for the current Mac's architecture. No downloaded packages, Homebrew, or network access are needed for building after cloning.

```sh
tools/preflight.sh
tools/install.sh
open /Applications/DisplayMind.app
```

The output is `dist/DisplayMind.app`. Signing: `DISPLAYMIND_SIGNING_IDENTITY` if set (`-` forces ad hoc); otherwise the login keychain's only `Developer ID Application` identity, with hardened runtime and a secure timestamp; otherwise ad hoc. A stable identity keeps the Accessibility grant across rebuilds (an ad-hoc signature changes each build). The build prints which kind was used. This repository does not provide a notarized distribution. A debug build is available with `tools/build.sh debug`.

`tools/install.sh [dir]` installs into `/Applications` or `dir`, updating an existing copy in place. It refuses while a display change is pending, quits a running app (and relaunches it), and keeps the previous bundle until the new one passes `--diagnostics`, restoring it otherwise.

Release: `tools/tdtp.sh` (full preflight) or `tools/dtp.sh` (build, `--diagnostics`, watchdog check) from a clean `main`. It bumps the minor version and build number (or reuses an untagged bump), commits, tags `vX.Y.0`, pushes atomically, installs, and reports to the status page. `--dry-run` prints the mutating commands.

## Storage and privacy

Settings and rollback journals live in `~/Library/Application Support/DisplayMind`; a `~/DisplayMind` folder from 0.4 and earlier is moved there on first launch. The app has no analytics or account. Display UUIDs, USB identities, AirPlay receiver selections, and sound device names and UIDs stay in local settings. macOS handles the network connection and screen streaming when AirPlay is selected. **Open data folder** reveals local settings. Invalid or newer settings files are preserved and reported instead of silently reset. Existing presets without an AirPlay or sound setting retain their behavior.

While a preset is being applied, and for the revert window after it, `pending-change.json` holds the previous configuration. A separate watchdog restores it if you revert, or if the apply never finishes because the app hangs or exits mid-change. Once the new layout has verified it stays, even if the app exits before the window closes. A failed rollback retains a `restoring-*.json` snapshot and records the failure. Reopening the app resumes recovery for an interrupted pending change. It also finishes a restore the watchdog claimed but never completed (a `restoring-*.json` with no result, under an hour old), and reports a failed recovery that happened while the app was closed, once.

Automatic switches post a notification ("Automatically applied …"). With the window closed, errors post a notification and stay in the menu-bar menu as a line with **Dismiss error**; with the window open they appear as an alert. Allow notifications for DisplayMind in System Settings if macOS prompts.

## Compatibility

Display control uses a bundled build of [displayplacer 1.4.0](https://github.com/jakehilborn/displayplacer/tree/v1.4.0), under its MIT license. Rotation relies on Apple's private MonitorPanel framework. Available modes, rotation, and mirroring depend on macOS and the display/driver; rejected settings trigger recovery. The editor shows modes reported for the current orientation and transposes dimensions when rotated. macOS can reject a particular rotated mode.

Mirrored displays share their source's rotation, resolution, and position. A preset that keeps a mirror leaves it connected while it is applied, so an AirPlay mirror does not drop because another display rotates. macOS names only the screens it draws to, so a mirror takes its product name from the display itself; a preset captured earlier with a placeholder such as “External display 2” picks up the real name the next time that display is connected. AirPlay presets can initiate their saved receiver connection; other displays must already be connected. Display UUIDs normally persist but can change with some docks, adapters, or macOS updates; capture the layout again if macOS assigns a new identity. USB devices without serial numbers are identified by vendor, product, and port, so moving one to another port requires updating its rule. Display disabling is not offered in the editor; an already disabled display is preserved when captured.

## Development

`DisplayMindCore` contains configuration validation, displayplacer parsing, rule matching, connection settling, and JSON storage. `DisplayMind` contains SwiftUI, the USB registry reader, process execution, and rollback watchdog. Vendor provenance and modifications are recorded in `Vendor/displayplacer/ORIGIN.md`.

Preflight builds the app, runs the full fixture-based suite, verifies the bundle and version, and performs read-only diagnostics against connected hardware. Tests never change live display settings. To render the interface offscreen with synthetic data:

```sh
dist/DisplayMind.app/Contents/MacOS/DisplayMind --render-preview /tmp/displaymind.png
```

Add `--dark`, `--rules`, `--editor`, `--rule-editor`, `--airplay`, and state flags such as `--pending`, `--empty`, `--unavailable`, `--long` or `--many` (listed at the top of `Sources/DisplayMind/Preview.swift`); `--settings copy.json` renders a copy of real presets, and `--show` opens the same synthetic window on screen. The preview store uses a display helper that only fails, so nothing it does can reach the real displays, and automated tests use fake connection controls and never start or stop a real AirPlay stream.

The silver DM mark uses MindSuite's charcoal tile, rounded 9-unit strokes, and 96-unit grid. Vector originals are in `assets/logo.svg` and `assets/logo-square.svg`; `tools/generate-icon.swift` generates the PNG, menu-bar PDF, and iconset used by the app.
