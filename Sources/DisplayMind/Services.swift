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

enum HardwareChange { case displays, usb, wake }

/// Change notifications that replace idle polling. `start` registers and returns a token; releasing the token unregisters.
struct HardwareMonitor {
    var start: @MainActor (_ onChange: @escaping @MainActor (HardwareChange) -> Void) -> AnyObject?
    static let none = HardwareMonitor { _ in nil }
    static let live = HardwareMonitor { LiveHardwareMonitor(onChange: $0) }
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

/// Default sound devices. `set` applies the non-nil sides and returns the names of saved devices that are not connected.
struct AudioActions {
    var outputs: @Sendable () -> [AudioDevice]
    var inputs: @Sendable () -> [AudioDevice]
    var current: @Sendable () -> AudioSelection
    var set: @Sendable (AudioSelection) throws -> [String]
    static let live = AudioActions(outputs: { SystemAudio.devices(input: false) }, inputs: { SystemAudio.devices(input: true) },
                                   current: { SystemAudio.current() }, set: { try SystemAudio.set($0) })
    /// Preview mode: fixed device lists, never touches the system.
    static let demo = AudioActions(outputs: { [AudioDevice(uid: "demo-speakers", name: "MacBook Pro Speakers"), AudioDevice(uid: "demo-display", name: "Studio Display Speakers")] },
                                   inputs: { [AudioDevice(uid: "demo-mic", name: "MacBook Pro Microphone")] },
                                   current: { AudioSelection(output: AudioDevice(uid: "demo-speakers", name: "MacBook Pro Speakers"), input: AudioDevice(uid: "demo-mic", name: "MacBook Pro Microphone")) },
                                   set: { _ in [] })
}

/// Owns the notification center delegate (banners while the app is frontmost) and asks for authorization only once.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationPresenter()
    private let lock = NSLock()
    private var requested = false, granted: Bool?
    private var waiting: [(Bool) -> Void] = []
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
    func whenAuthorized(_ center: UNUserNotificationCenter, _ body: @escaping (Bool) -> Void) {
        lock.lock()
        if let granted { lock.unlock(); body(granted); return }
        waiting.append(body)
        let first = !requested
        requested = true
        lock.unlock()
        guard first else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { ok, _ in
            self.lock.lock(); self.granted = ok; let pending = self.waiting; self.waiting = []; self.lock.unlock()
            pending.forEach { $0(ok) }
        }
    }
}

/// User notifications, authorized lazily on first use. Never active outside the installed app bundle.
struct Notifier {
    var post: (_ title: String, _ body: String) -> Void
    static let none = Notifier(post: { _, _ in })
    static let live = Notifier { title, body in
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        NotificationPresenter.shared.whenAuthorized(center) { granted in
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
