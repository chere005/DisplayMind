# DisplayMind for Windows

A native C++20/Win32 implementation of DisplayMind's display presets and connection-based layouts. The Mac source remains alongside it as the behavioral reference. Windows has its own OS adapters and settings; it does not run the Mac code.

## Run

Extract the portable ZIP and open **DisplayMind.exe**. The x64 executable uses Windows system libraries and includes the C++ runtime; it needs no Electron, browser engine, .NET runtime or administrator installation. Windows 10 and Windows 11 are the intended platforms. This development build is unsigned.

Choose **Capture current layout**, name the preset, and save. In **Edit preset**, select a display in the diagram or the native display picker. Drag an extended display to move it, enter exact coordinates, use **Place beside**, or **Make main**. Choose its rotation, driver-reported resolution/refresh rate, or mirror source. Mirrored displays follow their source. Displays captured as disabled stay disabled; the editor does not offer disabling all screens.

Releasing a dragged display snaps it to the nearest available edge. The editor explains overlapping or separated arrangements before saving, because Windows would otherwise move them. Unsaved preset names, sound selections, positions, and rule conditions survive a dock change while their monitor paths follow the reconnected hardware.

**Apply preset** verifies the result, retries up to three times, then offers **Keep** and **Revert** for ten seconds. Verified layouts stay when the countdown ends. Closing the window leaves the tray app running. The tray menu switches presets, pauses automatic switching, shows errors and quits. Opening DisplayMind again restores its existing window.

Choose **Includes displays** to filter by one or more monitors. Select **All selected** or **Any selected** to change how those checks combine. Each preset shows a thumbnail of its saved arrangement. Use **New folder** and the preset menu's **Move to folder** to organize your layouts. Click a folder to collapse it, or right-click it to rename or remove it. Removing a folder moves its presets to **Ungrouped**. Double-click a preset or press F2 to rename it in place.

## Connection rules

Rules are ordered. Mark each relevant display or USB device **Connected**, **Absent** or **Ignore**. Every marked condition must match. The first eligible rule wins after connections settle for three seconds. **Only when no other display is connected** requires the preset's exact display set; turn it off to permit extra screens, which remain usable.

An unchanged capture is immediately eligible. An edited layout must be applied and kept once before automation can use it. A verified automatic apply keeps its layout immediately. Renaming a preset or changing only its audio selection preserves its confirmation and rule identity. Known USB devices remain selectable after disconnecting. Duplicate device names show identity hints. USB identity is Windows' device-instance identity, which can depend on the port for devices without a serial number.

DisplayMind updates saved preset, mirror, filter and rule references when a port or dock changes the Windows display path. An EDID serial identifies the monitor when available; a monitor without a serial can use its vendor/model only when that model is unique among both saved and connected monitors. Conflicting identities, duplicate models and changes that would merge two rule conditions are left untouched. Older presets learn hardware identity while their original display path is connected.

Display/USB notifications, audio endpoint notifications and wake events trigger refreshes. Bursts are coalesced. A one-minute fallback covers missed notifications. A manual layout stays until connections change, the computer wakes, or rules change. Timers are otherwise limited to a settle/recovery/revert window.

## Sound

The Sound page saves output and input endpoints separately; **Don't change** leaves a side alone. Selection follows display verification. Bluetooth defaults in use are preserved, and the matching active preset takes over after those headphones disconnect. A user-selected replacement while the headphones remain connected is respected. Missing audio devices are skipped and reported; an audio failure does not revert a successful layout.

Windows distinguishes console, multimedia and communications defaults. Applying a selection handles those roles while protecting Bluetooth endpoints. Revert restores the separate previous defaults and works for audio-only changes. Endpoint enumeration and notifications use public CoreAudio interfaces. Setting Windows' default endpoint uses the OS PolicyConfig COM interface. DisplayMind reports an error if this interface fails.

## Wireless displays

The Windows equivalent uses **Miracast**, with Windows providing the sender and pairing UI. A connected Miracast display is recognized from the OS connector type. Capture it while connected, then use the Wireless page to verify the exact receiver name and its display. **Connect manually** disables automatic receiver connection for that preset. **Open Windows Cast (Win+K)** opens Windows' connection interface.

Automatic connection targets the English Windows **Cast/Connect** shell interface through UI Automation. Selection is restricted to the exact saved receiver, an actionable control inside that interface, and the Windows shell host. Duplicate names require a manual connection. Connect through Windows when the automatic control is unavailable. Connection and disconnection each wait up to thirty seconds for Windows to report the saved display. A stream with no saved receiver stays connected. Managed stream changes are journaled for recovery.

AirPlay-only receivers are not implemented by this Windows build: Windows' Miracast sender does not provide Apple's AirPlay protocol. Sidecar and audio-only casting are outside the original screen-streaming feature too. No third-party sender or driver is bundled.

## Recovery and local data

Data lives in `%LOCALAPPDATA%\DisplayMind`. **Open data folder** reveals the settings and recovery files. Presets, USB identities, display paths, receiver names and audio endpoint IDs stay local. There are no accounts, telemetry or network services.

Settings are strict, versioned JSON and are written through an atomic replacement. Corrupt, duplicate or newer settings are preserved and editing is blocked instead of silently resetting the file. Mac display UUIDs and audio UIDs cannot be applied on Windows, so Mac settings are deliberately rejected.

Before any layout mutation the app records the previous configuration and starts an independent process. It waits for that process to acknowledge readiness. An interrupted/incomplete application is restored even if the GUI exits or hangs. A verified application stays if the GUI exits. Explicit Revert restores the previous display/audio configuration and known wireless sessions. A failed rollback keeps its `restoring-*.json` snapshot; **Retry recovery** in the preset/tray menu retries it and retains the failure history.

**Open at login** registers this executable in the current user's Windows Run key. Keep the executable at a stable location when enabling it. Moving the app requires re-enabling that option from its new location.

## Build and checks

Install Visual Studio 2022 Build Tools with the **Desktop development with C++** workload and a Windows 10/11 SDK. Use PowerShell 7 for the scripts. No NuGet packages or downloads are needed to compile.

```powershell
.\tools\build.ps1 -Tests
.\tools\preflight.ps1
.\tools\package.ps1
```

To update an existing installation after preflight, run `tools/install.ps1 -InstallDirectory C:\path\to\DisplayMind -Launch`. It preserves previous app files, verifies the installed executable, and leaves the data folder intact. An active apply or recovery blocks the update. `tools/test-install.ps1` verifies preservation and recovery guards in temporary folders. The existing shortcut remains valid when updating in place.

The Windows release lane is `tools/dtp.ps1 -InstallDirectory C:\path\to\DisplayMind`. It runs preflight, installer checks and packaging, commits only Windows changes, creates a `windows-vX.Y.0` tag and atomically pushes through an SSH origin before installing. `-DryRun` prints the planned actions. Windows tags and versions are independent of macOS tags.

The build produces `dist\DisplayMind.exe`. Preflight writes reports and light and dark previews under `artifacts`. Packaging verifies the tested executable's hash and creates `dist\DisplayMind-Windows-0.3.0-x64.zip`, with the runnable app and its Windows source. The checked-in ICO contains the original Mac icon's PNG representations. `node tools/make-icon.cjs` regenerates it without image dependencies when run in the full repository.

Fixture-based coverage includes configuration validation, strict JSON and atomic persistence, display-source assignment/mirroring, connection priority/settling, Bluetooth policy, retries and failed verification, exact wireless identities, independent-process recovery, and native UI controls through Apply/Keep/Revert. Preview and UI-test modes cannot reach the live backend.

Hardware diagnostics read connected display modes, USB identities and audio endpoints and submit the current plan with **SDC_VALIDATE only**. Windows can deny that validation to an agent, sandbox or remote session even when enumeration works; the report records that restriction. Automated checks do not exercise live GPU reconfiguration, audio default changes, physical Miracast projection or login registration. Those operations therefore are not claimed as hardware-verified by the fixture suite.

Useful commands:

```powershell
.\dist\DisplayMind.exe --preview --dark
.\dist\DisplayMind.exe --render-preview C:\temp\displaymind.png --editor --light
.\dist\DisplayMind.exe --ui-self-test C:\temp\ui-tests.json
.\dist\DisplayMind.exe --diagnostics C:\temp\hardware.json
```

Additional preview states: `--rules`, `--rule-editor`, `--editor --sound`, `--editor --wireless`, `--empty`, `--pending`, `--unavailable`, `--long`, and `--many`. Previews use synthetic data in a separate temporary directory. `--data-dir <folder>` selects a data folder explicitly.

## Implementation and source

| Concern | Native Windows mechanism |
|---|---|
| Identity, positions, rotation, cloning and refresh | QueryDisplayConfig / DisplayConfigGetDeviceInfo / SetDisplayConfig and monitor EDID via SetupAPI |
| Driver-reported mode choices | EnumDisplaySettingsEx |
| USB/dock identity | SetupAPI device-instance IDs |
| Connection and wake events | WM_DEVICECHANGE, device-interface registration, WM_DISPLAYCHANGE, WM_POWERBROADCAST |
| Audio endpoints and events | IMMDeviceEnumerator and IMMNotificationClient |
| Default audio endpoints | Isolated PolicyConfig COM adapter |
| Wireless transport | Windows Miracast sender and scoped UI Automation of Cast/Connect |
| Native interface | Win32 controls, GDI+, per-monitor DPI awareness and Shell_NotifyIcon |
| Recovery and storage | Separate native process, named mutexes, flushed atomic JSON files |

The original Windows port used the macOS 0.11.0 source archive. The 0.3.0 Windows build also follows the macOS 1.0.0 preset organization and monitor recognition behavior. `SOURCE.json` records provenance. Both versions retain the repository's MIT license.

Microsoft references: [SetDisplayConfig](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setdisplayconfig), [QueryDisplayConfig](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-querydisplayconfig), [CoreAudio endpoint notifications](https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient), and [Miracast support](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/wireless-displays--miracast-).
