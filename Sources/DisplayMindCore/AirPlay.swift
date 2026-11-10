import Foundation

public struct AirPlayDestination: Codable, Equatable {
    public var receiverName: String
    public var displayID: String
    public var controlIdentifier: String?
    public init(receiverName: String, displayID: String, controlIdentifier: String? = nil) {
        self.receiverName = receiverName; self.displayID = displayID; self.controlIdentifier = controlIdentifier
    }
}

public struct AirPlayReceiver: Equatable, Identifiable {
    public var id: String
    public var name: String
    public var selected: Bool?
    public init(id: String, name: String, selected: Bool?) { self.id = id; self.name = name; self.selected = selected }
}

public enum AirPlaySelection {
    public static func receiver(for target: AirPlayDestination, in receivers: [AirPlayReceiver]) throws -> AirPlayReceiver? {
        // Match an exact observed identifier, or an exact name. Never select the first available receiver.
        if let identifier = target.controlIdentifier, let match = receivers.first(where: { $0.id == identifier }) { return match }
        let matches = receivers.filter { $0.name == target.receiverName }
        guard matches.count <= 1 else { throw DisplayMindError("More than one AirPlay receiver is named \(target.receiverName). Choose the receiver with Find receivers.") }
        return matches.first
    }
    public static func shouldPress(_ receiver: AirPlayReceiver, connecting: Bool) throws -> Bool {
        guard let selected = receiver.selected else {
            throw DisplayMindError("macOS did not report whether \(receiver.name) is connected. No AirPlay control was pressed.")
        }
        return selected != connecting
    }
}

public enum AirPlayConnection {
    /// Wait for the saved display UUID, not an unrelated display or a successful UI click.
    public static func ensure(_ target: AirPlayDestination, online: () -> Set<String>, start: () throws -> Void,
                              now: () -> Date = Date.init, wait: (TimeInterval) -> Void = Thread.sleep,
                              timeout: TimeInterval = 30) throws {
        if online().contains(target.displayID) { return }
        try start()
        let deadline = now().addingTimeInterval(timeout)
        while !online().contains(target.displayID) {
            guard now() < deadline else {
                throw DisplayMindError("\(target.receiverName) did not provide the saved display. Complete any AirPlay pairing prompt, or capture the preset again if its display identity changed.")
            }
            wait(0.25)
        }
    }
}
