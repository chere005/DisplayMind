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
                print("DisplayMind: read-only diagnostics passed; \(displays.count) displays; \(devices.filter { $0.kind == .usb }.count) USB devices; capture validated.")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let store = Store(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DisplayMind-preview"), demo: true)
            if CommandLine.arguments.contains("--rules") { store.showRules = true }
            let content: AnyView
            if CommandLine.arguments.contains("--editor") { content = AnyView(PresetEditor(store: store, original: store.settings.presets[0])) }
            else if CommandLine.arguments.contains("--rule-editor") { content = AnyView(RuleEditor(store: store, original: store.settings.rules[0])) }
            else { content = AnyView(MainView(store: store)) }
            app.finishLaunching()
            let view = NSHostingView(rootView: content.environment(\.colorScheme, .light).tint(Color(red: 0.12, green: 0.48, blue: 0.58)))
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1080, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 1080, height: 760)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            view.displayIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
                    catch { fputs("\(error)\n", stderr); exit(1) }
                }
            }
            exit(1)
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
            WindowContent(store: store).tint(Color(red: 0.12, green: 0.48, blue: 0.58))
        }.defaultSize(width: 1080, height: 760).windowResizability(.contentMinSize)
        MenuBarExtra("DisplayMind", systemImage: "display.2") { MenuContent(store: store) }
    }
}

struct WindowContent: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        MainView(store: store)
            .onAppear { store.openWindow = { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) } }
            .onReceive(NotificationCenter.default.publisher(for: .openDisplayMind)) { _ in store.openWindow?() }
    }
}
struct MenuContent: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(store.status)
        Divider()
        if store.pending != nil {
            Button("Keep changes (\(store.secondsRemaining)s)", action: store.keep)
            Button("Revert", action: store.revert)
            Divider()
        }
        ForEach(store.settings.presets) { preset in
            Button(preset.name) { Task { await store.apply(preset) } }
                .disabled(store.busy || store.pending != nil || store.unavailable(preset) != nil)
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
