import AppKit
import DisplayMindCore
import UserNotifications

/// Injection seams for `Store`. The defaults are the real services; tests substitute fakes.
struct HardwareProvider {
    var devices: @Sendable () -> [Device]
    var connectedDisplayIDs: @Sendable () -> Set<String>
    var nameDisplays: @MainActor ([ConnectedDisplay]) -> [ConnectedDisplay]
    static let live = HardwareProvider(devices: { Hardware.devices() }, connectedDisplayIDs: { Hardware.connectedDisplayIDs() }, nameDisplays: { Hardware.nameDisplays($0) })
}

struct AirPlayActions {
    var authorized: () -> Bool
    var requireAccess: () throws -> Void
    var requestAccess: @MainActor () -> Void
    var receivers: @Sendable () throws -> [AirPlayReceiver]
    /// Connect or disconnect; `beforeConnect` persists ownership before a stream is started.
    var setConnected: @Sendable (AirPlayDestination, Bool, () throws -> Void) throws -> Void
    static let live = AirPlayActions(authorized: { AirPlayController.authorized }, requireAccess: { try AirPlayController.requireAccess() },
                                     requestAccess: { AirPlayController.requestAccess() }, receivers: { try AirPlayController().receivers() },
                                     setConnected: { try AirPlayController().setConnected($0, $1, beforeConnect: $2) })
}

/// User notifications, authorized lazily on first use. Never active outside the installed app bundle.
struct Notifier {
    var post: (_ title: String, _ body: String) -> Void
    static let none = Notifier(post: { _, _ in })
    static let live = Notifier { title, body in
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Whether DisplayMind's main window is on screen (the menu-bar popover is a panel and does not count).
@MainActor func mainWindowVisible() -> Bool {
    NSApplication.shared.windows.contains { $0.isVisible && $0.title == "DisplayMind" && !($0 is NSPanel) }
}
