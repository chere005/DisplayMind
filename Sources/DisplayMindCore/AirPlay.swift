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
    /// The receiver's own name from the name macOS gives its display: "plex’s Mac mini (AirPlay)" is the receiver "plex’s Mac mini".
    public static func receiverName(fromDisplay name: String) -> String {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasSuffix(" (AirPlay)") ? String(text.dropLast(" (AirPlay)".count)) : text
    }
    /// Names compare without the display suffix, case, or the kind of apostrophe.
    public static func normalized(_ name: String) -> String {
        receiverName(fromDisplay: name).replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'").lowercased()
    }
    public static func receiver(for target: AirPlayDestination, in receivers: [AirPlayReceiver]) throws -> AirPlayReceiver? {
        // An identifier seen before, then the exact name, then the same name written another way. Never the first available receiver.
        if let identifier = target.controlIdentifier, let match = receivers.first(where: { $0.id == identifier }) { return match }
        for matches in [receivers.filter { $0.name == target.receiverName }, receivers.filter { normalized($0.name) == normalized(target.receiverName) }] where !matches.isEmpty {
            guard matches.count == 1 else { throw DisplayMindError("More than one AirPlay receiver is named \(target.receiverName). Choose the receiver with Find receivers.") }
            return matches[0]
        }
        return nil
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
