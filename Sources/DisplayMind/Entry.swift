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
                let displays = try DisplayBackend().read()
                let devices = Hardware.devices()
                _ = try Configuration.arguments(for: displays.map(\.setting))
                let sound = SystemAudio.current()
                print("DisplayMind: read-only diagnostics passed; \(displays.count) displays; \(devices.filter { $0.kind == .usb }.count) USB devices; \(SystemAudio.devices(input: false).count) sound outputs (\(sound.output?.name ?? "none")); \(SystemAudio.devices(input: true).count) sound inputs (\(sound.input?.name ?? "none")); capture validated.")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
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
            Button("Keep changes (\(store.secondsRemaining)s)", action: store.keep)
            Button("Revert", action: store.revert)
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
