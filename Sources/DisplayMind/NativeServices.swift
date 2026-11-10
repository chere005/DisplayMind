import AppKit
import CoreGraphics
import DisplayMindCore
import IOKit
import ServiceManagement

enum ProcessRunner {
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 30) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        timer.resume()
        defer { timer.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw DisplayMindError(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "The display helper stopped or timed out. The previous layout will be restored."
                : String(output.suffix(2000)))
        }
        return output
    }
}

struct DisplayBackend {
    let helper: URL
    init(helper: URL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("displayplacer")) { self.helper = helper }
    func read() throws -> [ConnectedDisplay] { try DisplayParser.parse(ProcessRunner.run(helper, arguments: ["list"])) }
    func apply(_ displays: [DisplaySetting]) throws { _ = try ProcessRunner.run(helper, arguments: Configuration.arguments(for: displays)) }
}

enum Hardware {
    static func connectedDisplayIDs() -> Set<String> {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &displays, &count) == .success else { return [] }
        return Set(displays.prefix(Int(count)).compactMap { display in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
            return CFUUIDCreateString(nil, uuid)! as String
        })
    }
    static func devices() -> [Device] {
        var result: [Device] = []
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(32, &displays, &count) == .success {
            for display in displays.prefix(Int(count)) {
                if let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() {
                    let id = CFUUIDCreateString(nil, uuid)! as String
                    result.append(Device(id: "display:\(id)", name: CGDisplayIsBuiltin(display) != 0 ? "Built-in display" : "External display", kind: .display))
                }
            }
        }
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let values = properties?.takeRetainedValue() as? [String: Any],
                      let vendor = values["idVendor"] as? NSNumber,
                      let product = values["idProduct"] as? NSNumber else { continue }
                let name = values["USB Product Name"] as? String ?? values["kUSBProductString"] as? String ?? "USB device"
                let serial = (values["USB Serial Number"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let identity = serial.flatMap { $0.isEmpty ? nil : "serial:\($0)" } ?? "port:\((values["locationID"] as? NSNumber)?.uint32Value ?? 0)"
                result.append(Device(id: "usb:\(vendor):\(product):\(identity)", name: name, kind: .usb))
            }
        }
        return Array(Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted {
            if $0.kind != $1.kind { return $0.kind == .display }
            return $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
        }
    }

    @MainActor static func nameDisplays(_ displays: [ConnectedDisplay]) -> [ConnectedDisplay] {
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (UInt32, String)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return (id, screen.localizedName)
        }, uniquingKeysWith: { a, _ in a })
        return displays.map { display in
            var copy = display
            if let name = names[display.contextualID] { copy.setting.name = name }
            return copy
        }
    }
}

/// Display reconfiguration, USB attach/detach and wake, delivered on the main actor. Everything is unregistered on deinit.
final class LiveHardwareMonitor {
    private final class Sink: @unchecked Sendable {
        var handler: (@MainActor (HardwareChange) -> Void)?
        func emit(_ change: HardwareChange) { Task { @MainActor in handler?(change) } }
    }
    private let sink = Sink()
    private let context: UnsafeMutableRawPointer
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var wake: NSObjectProtocol?
    private static let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard let context, !flags.contains(.beginConfigurationFlag) else { return }
        Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue().emit(.displays)
    }
    private static let usbCallback: IOServiceMatchingCallback = { context, iterator in
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }   // draining re-arms the notification
        if let context { Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue().emit(.usb) }
    }

    @MainActor init(onChange: @escaping @MainActor (HardwareChange) -> Void) {
        sink.handler = onChange
        context = Unmanaged.passRetained(sink).toOpaque()
        CGDisplayRegisterReconfigurationCallback(Self.displayCallback, context)
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOUSBHostDevice"), Self.usbCallback, context, &iterator) == KERN_SUCCESS else { continue }
            iterators.append(iterator)
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
        }
        let sink = self.sink
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in sink.emit(.wake) }
    }
    deinit {
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        CGDisplayRemoveReconfigurationCallback(Self.displayCallback, context)
        iterators.forEach { IOObjectRelease($0) }
        if let port { IONotificationPortDestroy(port) }
        sink.handler = nil
        // A callback already queued on the main queue still holds the context; release it behind that queue.
        let address = UInt(bitPattern: context)
        DispatchQueue.main.async { Unmanaged<Sink>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).release() }
    }
}

/// An independent process owns the deadline. Closing or crashing the UI cannot cancel rollback.
struct RecoveryController {
    let directory: URL
    var pendingURL: URL { directory.appendingPathComponent("pending-change.json") }
    var resultURL: URL { directory.appendingPathComponent("recovery-result.json") }
    func read() -> RecoveryJournal? { try? JSONDecoder().decode(RecoveryJournal.self, from: Data(contentsOf: pendingURL)) }
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("recovery.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw DisplayMindError("Could not open the display recovery lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw DisplayMindError("Could not lock display recovery.") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    /// Held by whoever applies a restore, for its whole duration (the watchdog, or the app resuming an orphan); separate from the short-lived `recovery.lock`.
    var restoringLockURL: URL { directory.appendingPathComponent("restoring.lock") }
    func withRestoreLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(restoringLockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw DisplayMindError("Could not open the display restore lock.") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 { guard errno == EINTR else { throw DisplayMindError("Could not lock the display restore.") } }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func write(_ journal: RecoveryJournal) throws {
        try JSONEncoder().encode(journal).write(to: pendingURL, options: .atomic)
    }
    func updateDeadline(id: UUID, deadline: Date) throws {
        try withLock {
            guard var journal = read(), journal.id == id, journal.deadline > Date() else {
                throw DisplayMindError("The display change has already started reverting.")
            }
            journal.deadline = deadline
            try write(journal)
        }
    }
    func markAirPlayStarted(id: UUID, target: AirPlayDestination) throws {
        try withLock {
            guard var journal = read(), journal.id == id, journal.deadline > Date() else {
                throw DisplayMindError("The display change has already started reverting.")
            }
            journal.startedAirPlay = target
            try write(journal)
        }
    }
    func arm(previous: [DisplaySetting], setupTimeout: TimeInterval = 65, launch: (URL) throws -> Void = RecoveryController.launchWatchdog) throws -> RecoveryJournal {
        try Configuration.validate(previous)
        let journal = RecoveryJournal(deadline: Date().addingTimeInterval(setupTimeout), previous: previous)
        try withLock {
            guard !FileManager.default.fileExists(atPath: pendingURL.path) else { throw DisplayMindError("A display change is already awaiting confirmation.") }
            try? FileManager.default.removeItem(at: resultURL)
            supersedeSnapshots()
            try write(journal)
        }
        do { try launch(directory) } catch { try? FileManager.default.removeItem(at: pendingURL); throw error }
        return journal
    }
    /// The independent rollback process: this executable in `--watchdog` mode.
    static func launchWatchdog(_ directory: URL) throws {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--watchdog", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    private func snapshots() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("restoring-") && $0.pathExtension == "json" }
    }
    /// A new change replaces any earlier snapshot; keep it for the user but never resume it automatically.
    private func supersedeSnapshots() {
        for url in snapshots() {
            try? FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("superseded-" + url.lastPathComponent.dropFirst("restoring-".count)))
        }
    }
    /// A `restoring-*.json` that no result accounts for: the watchdog died after claiming the journal.
    func orphanedRestore(maxAge: TimeInterval = 3600) -> RecoveryJournal? {
        let settled = result()?.id
        for url in snapshots() {
            guard let journal = try? JSONDecoder().decode(RecoveryJournal.self, from: Data(contentsOf: url)), journal.id != settled,
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  Date().timeIntervalSince(modified) < maxAge else { continue }
            return journal
        }
        return nil
    }
    /// A `restoring-*.json` past the resume limit that no result accounts for: nobody will restore it. Returned once; it is renamed `abandoned-*` so it is never reported again.
    func takeStaleUnsettledRestore(maxAge: TimeInterval = 3600) -> RecoveryJournal? {
        let settled = result()?.id
        for url in snapshots() {
            guard let journal = try? JSONDecoder().decode(RecoveryJournal.self, from: Data(contentsOf: url)), journal.id != settled,
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  Date().timeIntervalSince(modified) >= maxAge else { continue }
            try? FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("abandoned-" + url.lastPathComponent.dropFirst("restoring-".count)))
            return journal
        }
        return nil
    }
    /// Marks a failed result as shown. The `restoring-*.json` snapshot stays.
    func acknowledge() {
        guard var result = result(), result.error != nil, result.acknowledged != true else { return }
        result.acknowledged = true
        if let data = try? JSONEncoder().encode(result) { try? data.write(to: resultURL, options: .atomic) }
    }
    func keep(id: UUID) throws {
        try withLock {
            guard let journal = read(), journal.id == id, journal.deadline > Date() else { throw DisplayMindError("The confirmation period ended. Restoring the previous layout.") }
            try FileManager.default.removeItem(at: pendingURL)
        }
    }
    func requestRevert() throws {
        try withLock {
            guard var journal = read() else { return }
            journal.deadline = .distantPast
            try write(journal)
        }
    }
    func result() -> RecoveryResult? { try? JSONDecoder().decode(RecoveryResult.self, from: Data(contentsOf: resultURL)) }

    func watch(backend: DisplayBackend, disconnectAirPlay: (AirPlayDestination) throws -> Void = { try AirPlayController().setConnected($0, false) }) {
        while let journal = read() {
            if journal.deadline > Date() { Thread.sleep(forTimeInterval: 0.25); continue }
            let claimed = directory.appendingPathComponent("restoring-\(journal.id).json")
            var finished = false
            do {
                // The restore lock is taken before claiming, so an app resuming an orphan can never overlap this restore.
                try withRestoreLock {
                    do {
                        try withLock {
                            guard let current = read(), current.id == journal.id, current.deadline <= Date() else { throw DisplayMindError("Recovery was cancelled or extended.") }
                            try FileManager.default.moveItem(at: pendingURL, to: claimed)
                        }
                    } catch { return }
                    restore(journal, claimed: claimed, backend: backend, disconnectAirPlay: disconnectAirPlay)
                    finished = true
                }
            } catch {
                let failure = RecoveryResult(id: journal.id, error: error.localizedDescription)
                if let data = try? JSONEncoder().encode(failure) { try? data.write(to: resultURL, options: .atomic) }
                return
            }
            if finished { return }
            if read() != nil { continue }
            return
        }
    }
    /// Resumes a restore whose watchdog died after claiming the journal. Blocks until any live restore finishes, then re-checks before acting.
    func resume(_ journal: RecoveryJournal, backend: DisplayBackend, disconnectAirPlay: (AirPlayDestination) throws -> Void = { try AirPlayController().setConnected($0, false) }) {
        let claimed = directory.appendingPathComponent("restoring-\(journal.id).json")
        do {
            try withRestoreLock {
                guard result()?.id != journal.id, FileManager.default.fileExists(atPath: claimed.path) else { return }   // the watchdog finished meanwhile: its result stands
                restore(journal, claimed: claimed, backend: backend, disconnectAirPlay: disconnectAirPlay)
            }
        } catch {
            let failure = RecoveryResult(id: journal.id, error: error.localizedDescription)
            if let data = try? JSONEncoder().encode(failure) { try? data.write(to: resultURL, options: .atomic) }
        }
    }
    /// The caller holds the restore lock.
    private func restore(_ journal: RecoveryJournal, claimed: URL, backend: DisplayBackend, disconnectAirPlay: (AirPlayDestination) throws -> Void) {
        var failure: String?
        if let target = journal.startedAirPlay {
            do { try disconnectAirPlay(target) }
            catch { failure = "Could not stop the AirPlay connection started by this change: \(error.localizedDescription)" }
        }
        do {
            let actual = try backend.read()
            let connected = Set(actual.map(\.id))
            var previous = journal.previous.filter { connected.contains($0.id) }
            guard !previous.isEmpty else { throw DisplayMindError("The previous displays are disconnected. Use macOS Display Settings to choose the available layout.") }
            for i in previous.indices {
                if let parent = previous[i].mirrorOf, !connected.contains(parent) { previous[i].mirrorOf = nil }
            }
            if !previous.contains(where: { $0.enabled && $0.mirrorOf == nil && $0.x == 0 && $0.y == 0 }),
               let first = previous.first(where: { $0.enabled && $0.mirrorOf == nil }) {
                Configuration.makeMain(first.id, displays: &previous)
            }
            if !Configuration.matches(previous, actual: actual.map(\.setting)) { try backend.apply(previous) }
            let restored = try backend.read()
            guard Configuration.matches(previous, actual: restored.map(\.setting)) else { throw DisplayMindError("macOS did not restore every display setting. Open Display Settings to recover the layout.") }
        } catch { failure = [failure, error.localizedDescription].compactMap { $0 }.joined(separator: " ") }
        let result = RecoveryResult(id: journal.id, error: failure)
        if let data = try? JSONEncoder().encode(result) { try? data.write(to: resultURL, options: .atomic) }
        if failure == nil { try? FileManager.default.removeItem(at: claimed) }
    }
}
