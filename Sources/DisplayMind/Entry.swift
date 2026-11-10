import AppKit
import SwiftUI
import DisplayMindCore

@main
enum Entry {
    @MainActor static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--watchdog" {
            RecoveryController(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)).watch(backend: DisplayBackend())
            exit(0)
        }
        if CommandLine.arguments.contains("--diagnostics") {
            do {
                let backend = DisplayBackend()
                let displays = Hardware.nameDisplays(try backend.read())
                let devices = Hardware.devices()
                _ = try Configuration.arguments(for: displays.map(\.setting))
                // Applying the layout the displays already have must leave every mirror and rotation alone.
                let plan = try backend.plan(displays.map(\.setting))
                guard plan.allSatisfy({ $0 == "unchanged" || $0.hasPrefix("keep ") }) else {
                    fputs("The display helper would change the current layout when re-applying it: \(plan.joined(separator: "; "))\n", stderr); exit(1)
                }
                let sound = SystemAudio.current()
                print("DisplayMind: read-only diagnostics passed; \(displays.count) displays (\(displays.map(\.setting.name).joined(separator: ", "))); \(plan.filter { $0.hasPrefix("keep ") }.count) mirrors kept on re-apply; \(devices.filter { $0.kind == .usb }.count) USB devices; \(SystemAudio.devices(input: false).count) sound outputs (\(sound.output?.name ?? "none")); \(SystemAudio.devices(input: true).count) sound inputs (\(sound.input?.name ?? "none")); \(SystemAudio.bluetoothUIDs().count) Bluetooth sound devices; capture validated.")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--airplay-probe"), CommandLine.arguments.count > index + 1 {
            // Launch through LaunchServices (`open -n -g DisplayMind.app --args --airplay-probe file [--open]`) so macOS applies the app's own Accessibility grant.
            let report = AirPlayController().probe(open: CommandLine.arguments.contains("--open"))
            try? report.write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(where: { $0 == "--airplay-connect" || $0 == "--airplay-disconnect" }), CommandLine.arguments.count > index + 3 {
            // Developer check of the real connect/disconnect path: <receiver name> <display UUID> <report file>. Launch through LaunchServices as above.
            let connecting = CommandLine.arguments[index] == "--airplay-connect"
            let target = AirPlayDestination(receiverName: CommandLine.arguments[index + 1], displayID: CommandLine.arguments[index + 2])
            let started = Date()
            var report: String
            do {
                if connecting { try AirPlayConnection.ensure(target, online: Hardware.connectedDisplayIDs, start: { try AirPlayController().setConnected(target, true) }) }
                else { try AirPlayController().setConnected(target, false) }
                report = "ok"
            } catch { report = "FAILED: \(error.localizedDescription)" }
            report += String(format: " after %.1f s; display online: \(Hardware.connectedDisplayIDs().contains(target.displayID)); AirPlay displays: \(Hardware.airPlayDisplays())", Date().timeIntervalSince(started))
            try? report.write(toFile: CommandLine.arguments[index + 3], atomically: true, encoding: .utf8)
            exit(0)
        }
        if CommandLine.arguments.contains("--airplay-access-status") {
            print(AirPlayController.authorized ? "AirPlay Accessibility access: allowed" : "AirPlay Accessibility access: not allowed")
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            Preview.run(CommandLine.arguments, output: CommandLine.arguments[index + 1])
        }
        DisplayMindApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .openDisplayMind, object: nil)
        return true
    }
}
extension Notification.Name { static let openDisplayMind = Notification.Name("OpenDisplayMind") }

struct DisplayMindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()
    var body: some Scene {
        Window("DisplayMind", id: "main") {
            WindowContent(store: store)
        }.defaultSize(width: 1080, height: 760).windowResizability(.contentMinSize)
        MenuBarExtra { MenuContent(store: store) } label: { Image(nsImage: Branding.menuIcon).accessibilityLabel("DisplayMind") }
    }
}

struct WindowContent: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        MainView(store: store)
            .onAppear {
                store.openWindow = { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) }
                store.refreshAuthorization()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refreshAuthorization() }
            .onReceive(NotificationCenter.default.publisher(for: .openDisplayMind)) { _ in store.openWindow?() }
    }
}
struct MenuContent: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(store.status)
        if let message = store.menuError {
            Text("⚠︎ " + message)
            Button("Dismiss error", action: store.dismissMenuError)
        }
        Divider()
        if store.pending != nil {
            Button("Revert (\(store.secondsRemaining)s left)", action: store.revert)
            Button("Keep now", action: store.keep)
            Divider()
        }
        ForEach(store.settings.presets) { preset in
            Button { Task { await store.apply(preset) } } label: {
                if store.isActive(preset) { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
            }.disabled(store.busy || store.pending != nil || store.unavailable(preset) != nil)
        }
        if store.settings.presets.isEmpty { Text("No presets yet") }
        Divider()
        Toggle("Automatic switching", isOn: Binding(get: { store.settings.automationEnabled }, set: store.toggleAutomation))
        Button("Open DisplayMind…") { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) }
        Button("Capture current layout…") {
            openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true)
            Task { await store.capture() }
        }.disabled(store.busy || store.pending != nil)
        Divider()
        Button("Quit DisplayMind") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
