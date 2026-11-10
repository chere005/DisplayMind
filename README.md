# DisplayMind

A small native macOS app for display presets and connection-based defaults.

![DisplayMind](docs/displaymind.png)

- Capture the current arrangement, then edit rotation, resolution, refresh rate, main display, extended positions, and mirroring.
- Switch presets from the window or menu bar.
- Apply a default when selected displays or USB docks/devices are connected or absent.
- Arrange rule priority; require an exact display set or allow extra displays.
- Preview changes with a 20-second Keep/Revert countdown and a separate rollback process.
- Optionally launch at login. Closing the window leaves the menu-bar app running.

## Use

Open DisplayMind and choose **Capture current**. Give the preset a name, adjust the layout, and save it. **Apply preset** offers a timed confirmation. Capturing an unchanged current layout also marks it ready for automatic rules.

In **Connection rules**, choose a preset and mark each relevant display or USB device **Connected** or **Absent**. All conditions must match. The first eligible rule wins after connections settle for three seconds. Rules also run on launch and wake. A manually selected preset remains active until the next connection change, wake, or rule change. Automatic switching can be paused in the sidebar or menu bar.

[Layout editor](docs/preset-editor.png) · [Connection rules](docs/connection-rules.png) · [Rule editor](docs/rule-editor.png)

An edited preset must be applied and kept once before it can run automatically. Automatic applications verify the resulting configuration and revert on failure. Newly connected USB devices appear automatically. Previously selected devices remain available in the rule editor after disconnecting.

## Build

Requires macOS 13 or later and Xcode Command Line Tools with Swift 5.9 or later. The app and helper build for the current Mac's architecture. No downloaded packages, Homebrew, or network access are needed after cloning.

```sh
tools/preflight.sh
tools/install.sh
open /Applications/DisplayMind.app
```

The output is `dist/DisplayMind.app`, signed locally with an ad-hoc signature. This repository does not provide a notarized distribution. `tools/install.sh` refuses to overwrite an existing installation. A debug build is available with `tools/build.sh debug`.

## Storage and privacy

Settings live in the visible `~/DisplayMind/settings.json` folder. The app has no network client, analytics, or account. Display UUIDs and USB identities stay in local settings. **Open data folder** reveals them. Invalid or newer settings files are preserved and reported instead of silently reset.

During a pending change, `pending-change.json` holds the previous configuration. A separate watchdog restores it when the deadline expires, even if the UI exits. A failed rollback retains a `restoring-*.json` snapshot and records the failure. Reopening the app resumes recovery for an interrupted pending change.

## Compatibility

Display control uses a bundled build of [displayplacer 1.4.0](https://github.com/jakehilborn/displayplacer/tree/v1.4.0), under its MIT license. Rotation relies on Apple's private MonitorPanel framework. Available modes, rotation, and mirroring depend on macOS and the display/driver; rejected settings trigger recovery. The editor shows modes reported for the current orientation and transposes dimensions when rotated. macOS can reject a particular rotated mode.

Mirrored displays share their source's rotation, resolution, and position. Presets address already connected displays; the app does not initiate AirPlay or Sidecar connections. Display UUIDs normally persist but can change with some docks, adapters, or macOS updates; capture the layout again if macOS assigns a new identity. USB devices without serial numbers are identified by vendor, product, and port, so moving one to another port requires updating its rule. Display disabling is not offered in the editor; an already disabled display is preserved when captured.

## Development

`DisplayMindCore` contains configuration validation, displayplacer parsing, rule matching, connection settling, and JSON storage. `DisplayMind` contains SwiftUI, the USB registry reader, process execution, and rollback watchdog. Vendor provenance and modifications are recorded in `Vendor/displayplacer/ORIGIN.md`.

Preflight builds the app, runs the full fixture-based suite, verifies the bundle and version, and performs read-only diagnostics against connected hardware. Tests never change live display settings. To render the interface offscreen with synthetic data:

```sh
dist/DisplayMind.app/Contents/MacOS/DisplayMind --render-preview /tmp/displaymind.png
```

Add `--rules`, `--editor`, or `--rule-editor` for the other views. No desktop window is shown during rendering.
