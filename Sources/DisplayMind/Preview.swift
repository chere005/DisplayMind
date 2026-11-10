import AppKit
import SwiftUI
import DisplayMindCore

/// Offscreen renders of every screen and state, for looking at the interface without opening a window.
/// Uses synthetic data (or a copied settings file) and fake services: never reads or changes live displays or sound.
///
///     DisplayMind --render-preview out.png [--dark] [--size 1080x760] [--scale 2] [--show [--light]]
///         [--rules | --editor | --rule-editor] [--settings copy.json] [--select N] [--display N]
///         [--airplay] [--airplay-allowed] [--receivers] [--pending] [--empty] [--busy] [--unavailable] [--unconfirmed]
///         [--paused] [--long] [--many] [--no-sound] [--no-rules] [--invalid] [--renaming]
@MainActor enum Preview {
    static func run(_ args: [String], output: String) -> Never {
        func has(_ flag: String) -> Bool { args.contains(flag) }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // On screen the window follows the system unless told; a render defaults to the light appearance.
        let appearance: NSAppearance? = has("--dark") ? NSAppearance(named: .darkAqua) : has("--light") || !has("--show") ? NSAppearance(named: .aqua) : nil
        app.appearance = appearance
        let hardware = HardwareProvider(devices: { [] }, connectedDisplayIDs: { [] }, nameDisplays: { $0 })
        let allowed = has("--airplay-allowed")
        let airPlay = AirPlayActions(authorized: { allowed }, requireAccess: {}, requestAccess: {}, receivers: { [] }, setConnected: { _, _, _ in })
        // The helper is a command that only fails, so nothing a preview does can reach the real displays.
        let store = Store(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DisplayMind-preview"), demo: true,
                          backend: DisplayBackend(helper: URL(fileURLWithPath: "/usr/bin/false")), hardware: hardware, airPlay: airPlay, notifier: .none, launchWatchdog: { _ in }, windowVisible: { true }, background: false)
        if let path = value("--settings") {
            do {
                store.settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                let connected = store.settings.presets.first?.displays ?? []
                store.displays = connected.map { ConnectedDisplay(setting: $0, modes: [$0.mode], builtIn: $0.name.lowercased().contains("built-in")) }
                store.devices = connected.map { Device(id: "display:\($0.id)", name: $0.name, kind: .display) } + [Device(id: "usb:demo", name: "Desk dock", kind: .usb)]
                store.status = "\(connected.count) displays connected"
            } catch { fputs("Could not read \(path): \(error)\n", stderr); exit(1) }
        }
        if has("--long") {
            for i in store.settings.presets.indices { store.settings.presets[i].name = "A deliberately long preset name that should truncate, number \(i + 1)" }
            for i in store.settings.presets.indices { for j in store.settings.presets[i].displays.indices { store.settings.presets[i].displays[j].name = "LG UltraFine 5K Thunderbolt Display with a long name \(j + 1)" } }
            for i in store.settings.rules.indices { store.settings.rules[i].name = "When the very long-named Thunderbolt dock and its many peripherals are connected at the office desk" }
            store.displays = store.displays.enumerated().map { i, d in var c = d; c.setting.name = "LG UltraFine 5K Thunderbolt Display with a long name \(i + 1)"; return c }
            store.devices = store.devices.map { Device(id: $0.id, name: $0.name + " with a very long product description string", kind: $0.kind) }
            store.status = "Automatically applied A deliberately long preset name that should truncate. Sound output Studio Display Speakers is not connected."
        }
        if has("--many"), let first = store.settings.presets.first {
            store.settings.presets += (1...14).map { Preset(name: "Preset \($0 + 3)", displays: first.displays, confirmed: true) }
            store.settings.rules += (1...5).map { ConnectionRule(name: "Rule \($0 + 1)", presetID: first.id, requiredDevices: [store.devices.last!], absentDevices: $0 % 2 == 0 ? [store.devices[0]] : [], enabled: $0 != 3) }
            store.devices += (1...9).map { Device(id: "usb:extra\($0)", name: ["Keyboard", "Trackpad", "Webcam", "USB3.1 Hub", "Audio Interface", "Card Reader", "Ethernet Adapter", "Stream Deck", "Wacom One 12"][$0 - 1], kind: .usb) }
        }
        if has("--no-rules") { store.settings.rules = [] }
        if has("--no-sound") { for i in store.settings.presets.indices { store.settings.presets[i].audio = nil } }
        if has("--empty") { store.settings.presets = []; store.settings.rules = [] }
        let selected = min(max(0, Int(value("--select") ?? "") ?? 0), max(0, store.settings.presets.count - 1))
        store.selectedPresetID = store.settings.presets.indices.contains(selected) ? store.settings.presets[selected].id : nil
        if has("--airplay"), store.settings.presets.indices.contains(selected), store.settings.presets[selected].displays.count > 1 {
            store.settings.presets[selected].airPlay = AirPlayDestination(receiverName: "Living Room TV", displayID: store.settings.presets[selected].displays[1].id)
        }
        if has("--receivers") {
            store.airPlayReceivers = [AirPlayReceiver(id: "screen-mirroring-device-1", name: "Living Room TV", selected: false), AirPlayReceiver(id: "screen-mirroring-device-2", name: "Office Apple TV", selected: true)]
        }
        if has("--unconfirmed") { for i in store.settings.presets.indices { store.settings.presets[i].confirmed = false } }
        if has("--paused") { store.settings.automationEnabled = false }
        if has("--unavailable") { store.displays = Array(store.displays.prefix(1)); store.devices = store.devices.filter { $0.kind == .usb }; store.status = "1 display connected" }
        if has("--rules") { store.showRules = true }
        if has("--busy") { store.busy = true; store.status = "Applying \(store.selectedPreset?.name ?? "preset")…" }
        if has("--pending"), let preset = store.selectedPreset {
            store.pending = Store.PendingChange(journal: RecoveryJournal(deadline: Date().addingTimeInterval(17), previous: preset.displays), preset: preset)
            store.secondsRemaining = 17; store.status = "Keep this display layout?"
        }
        var size = NSSize(width: 1080, height: 760)
        if let text = value("--size")?.split(separator: "x").compactMap({ Double($0) }), text.count == 2 { size = NSSize(width: text[0], height: text[1]) }
        let content: AnyView
        if has("--editor"), let preset = store.selectedPreset ?? store.settings.presets.first {
            let display = min(max(0, Int(value("--display") ?? "") ?? 0), preset.displays.count - 1)
            var draft = preset
            if has("--invalid"), draft.displays.count > 1 { draft.displays[1].x += 400 }
            content = AnyView(PresetEditor(store: store, original: draft, selected: draft.displays[display].id, validate: has("--invalid")))
        } else if has("--rule-editor"), let rule = store.settings.rules.first ?? store.settings.presets.first.map({ ConnectionRule(name: "Use \($0.name)", presetID: $0.id, requiredDevices: []) }) {
            content = AnyView(RuleEditor(store: store, original: rule))
        } else { content = AnyView(MainView(store: store, renaming: has("--renaming") ? store.selectedPresetID : nil)) }
        if has("--show") {
            // A real key window with the same synthetic store, for looking at live controls, menus and sheets.
            app.setActivationPolicy(.regular)
            let shown = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            shown.title = "DisplayMind Preview"
            shown.appearance = appearance
            shown.contentView = NSHostingView(rootView: MainView(store: store, renaming: has("--renaming") ? store.selectedPresetID : nil))
            shown.center()
            shown.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            if has("--editor"), let preset = store.selectedPreset { store.editorPreset = preset }
            if has("--rule-editor"), let rule = store.settings.rules.first { store.editorRule = rule }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: shown, queue: .main) { _ in exit(0) }
            app.run()
            exit(0)
        }
        app.finishLaunching()
        let view = NSHostingView(rootView: content)
        if has("--editor") || has("--rule-editor") { size = view.fittingSize }
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        view.displayIfNeeded()
        let scale = max(1, min(3, Int(value("--scale") ?? "") ?? 2))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: output)); exit(0) }
        catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
