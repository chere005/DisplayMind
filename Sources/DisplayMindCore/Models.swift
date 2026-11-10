import Foundation

public struct DisplayMode: Codable, Hashable, Identifiable {
    public var width: Int
    public var height: Int
    public var hertz: Int
    public var depth: Int
    public var scaled: Bool
    public var id: String { "\(width)x\(height)-\(hertz)-\(depth)-\(scaled)" }
    public var label: String { "\(width) × \(height)" + (scaled ? " · HiDPI" : "") + (hertz > 0 ? " · \(hertz) Hz" : "") }
    public init(width: Int, height: Int, hertz: Int = 0, depth: Int = 8, scaled: Bool = false) {
        self.width = width; self.height = height; self.hertz = hertz; self.depth = depth; self.scaled = scaled
    }
}

public struct DisplaySetting: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var mode: DisplayMode
    public var rotation: Int
    public var x: Int
    public var y: Int
    public var mirrorOf: String?
    public var enabled: Bool
    public init(id: String, name: String, mode: DisplayMode, rotation: Int = 0, x: Int = 0, y: Int = 0, mirrorOf: String? = nil, enabled: Bool = true) {
        self.id = id; self.name = name; self.mode = mode; self.rotation = rotation
        self.x = x; self.y = y; self.mirrorOf = mirrorOf; self.enabled = enabled
    }
    /// Equal in everything macOS applies; the display's name is a label only.
    public func sameLayout(as other: DisplaySetting) -> Bool {
        var a = self; a.name = other.name
        return a == other
    }
}

public struct ConnectedDisplay: Identifiable, Equatable {
    public var setting: DisplaySetting
    public var modes: [DisplayMode]
    public var contextualID: UInt32
    public var builtIn: Bool
    public var id: String { setting.id }
    public init(setting: DisplaySetting, modes: [DisplayMode], contextualID: UInt32 = 0, builtIn: Bool = false) {
        self.setting = setting; self.modes = modes; self.contextualID = contextualID; self.builtIn = builtIn
    }
}

public struct Preset: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var displays: [DisplaySetting]
    public var confirmed: Bool
    public var airPlay: AirPlayDestination?
    public init(id: UUID = UUID(), name: String, displays: [DisplaySetting], confirmed: Bool = false, airPlay: AirPlayDestination? = nil) {
        self.id = id; self.name = name; self.displays = displays; self.confirmed = confirmed
        self.airPlay = airPlay
    }
}

public struct Device: Codable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Codable { case display, usb }
    public var id: String
    public var name: String
    public var kind: Kind
    public init(id: String, name: String, kind: Kind) { self.id = id; self.name = name; self.kind = kind }
}

public struct ConnectionRule: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var presetID: UUID
    public var requiredDevices: [Device]
    public var absentDevices: [Device]
    public var exactDisplays: Bool
    public var enabled: Bool
    public init(id: UUID = UUID(), name: String, presetID: UUID, requiredDevices: [Device], absentDevices: [Device] = [], exactDisplays: Bool = true, enabled: Bool = true) {
        self.id = id; self.name = name; self.presetID = presetID; self.requiredDevices = requiredDevices
        self.absentDevices = absentDevices; self.exactDisplays = exactDisplays; self.enabled = enabled
    }
}

public struct AppSettings: Codable, Equatable {
    public var schemaVersion = 1
    public var presets: [Preset] = []
    public var rules: [ConnectionRule] = []
    public var automationEnabled = true
    public init() {}
}

public struct DisplayMindError: LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Configuration {
    public static func validate(_ displays: [DisplaySetting]) throws {
        guard !displays.isEmpty, displays.count <= 32 else { throw DisplayMindError("A preset needs at least one display (up to 32).") }
        guard Set(displays.map(\.id)).count == displays.count else { throw DisplayMindError("A display appears more than once.") }
        for d in displays {
            guard UUID(uuidString: d.id) != nil else { throw DisplayMindError("A display identifier is invalid. Capture the layout again.") }
            guard [0, 90, 180, 270].contains(d.rotation), (-100_000...100_000).contains(d.x), (-100_000...100_000).contains(d.y) else {
                throw DisplayMindError("Use a quarter-turn rotation and positions between −100,000 and 100,000.")
            }
            guard (1...32768).contains(d.mode.width), (1...32768).contains(d.mode.height), (0...1000).contains(d.mode.hertz), (1...128).contains(d.mode.depth) else {
                throw DisplayMindError("A display resolution or refresh rate is invalid.")
            }
            if let parent = d.mirrorOf {
                guard let source = displays.first(where: { $0.id == parent }), source.id != d.id, source.mirrorOf == nil, source.enabled, d.enabled else {
                    throw DisplayMindError("A mirror must use an enabled, extended display as its source.")
                }
            }
        }
        let roots = displays.filter { $0.enabled && $0.mirrorOf == nil }
        guard roots.filter({ $0.x == 0 && $0.y == 0 }).count == 1 else {
            throw DisplayMindError("Choose exactly one main display at position (0, 0).")
        }
    }

    public static func arguments(for displays: [DisplaySetting]) throws -> [String] {
        try validate(displays)
        return displays.filter { $0.mirrorOf == nil }.map { d in
            if !d.enabled { return "id:\(d.id) enabled:false" }
            let ids = ([d.id] + displays.filter { $0.mirrorOf == d.id }.map(\.id)).joined(separator: "+")
            let m = d.mode
            return "id:\(ids) res:\(m.width)x\(m.height) hz:\(m.hertz) color_depth:\(m.depth) enabled:true scaling:\(m.scaled ? "on" : "off") origin:(\(d.x),\(d.y)) degree:\(d.rotation)"
        }
    }

    public static func validate(_ preset: Preset) throws {
        try validate(preset.displays)
        if let target = preset.airPlay {
            guard !target.receiverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  target.receiverName.count <= 256,
                  !target.receiverName.contains(where: { $0.isNewline }),
                  preset.displays.contains(where: { $0.id == target.displayID && $0.enabled }) else {
                throw DisplayMindError("Choose an AirPlay receiver and its enabled display in this preset.")
            }
        }
    }

    public static func sameLayout(_ a: [DisplaySetting], _ b: [DisplaySetting]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.sameLayout(as: $1) }
    }

    public static func availability(_ preset: Preset, connected: Set<String>, allowAirPlayConnection: Bool = true) -> String? {
        let wirelessID = allowAirPlayConnection ? preset.airPlay?.displayID : nil
        let missing = preset.displays.filter { !connected.contains($0.id) && $0.id != wirelessID }
        return missing.isEmpty ? nil : "Connect " + missing.map(\.name).joined(separator: ", ")
    }

    public static func makeMain(_ id: String, displays: inout [DisplaySetting]) {
        guard let target = displays.first(where: { $0.id == id && $0.mirrorOf == nil && $0.enabled }) else { return }
        for i in displays.indices { displays[i].x -= target.x; displays[i].y -= target.y }
    }

    /// Relative positions, mirroring, rotation and requested mode must all match.
    public static func matches(_ expected: [DisplaySetting], actual: [DisplaySetting]) -> Bool {
        expected.allSatisfy { wanted in
            guard let got = actual.first(where: { $0.id == wanted.id }), wanted.enabled == got.enabled else { return false }
            if !wanted.enabled { return true }
            guard wanted.mirrorOf == got.mirrorOf else { return false }
            if wanted.mirrorOf != nil { return true } // mirror modes are controlled by the source
            return wanted.rotation == got.rotation && wanted.x == got.x && wanted.y == got.y &&
                wanted.mode.width == got.mode.width && wanted.mode.height == got.mode.height &&
                wanted.mode.scaled == got.mode.scaled && (wanted.mode.hertz == 0 || abs(wanted.mode.hertz - got.mode.hertz) <= 1)
        }
    }
}

public enum RuleEngine {
    /// Ordered rules: the first eligible match wins. Never auto-apply an unconfirmed layout.
    public static func match(settings: AppSettings, devices: [Device]) -> ConnectionRule? {
        guard settings.automationEnabled else { return nil }
        let ids = Set(devices.map(\.id))
        let displayIDs = Set(devices.filter { $0.kind == .display }.map { String($0.id.dropFirst("display:".count)) })
        return settings.rules.first { rule in
            guard rule.enabled, !rule.requiredDevices.isEmpty || !rule.absentDevices.isEmpty,
                  let preset = settings.presets.first(where: { $0.id == rule.presetID }), preset.confirmed,
                  Configuration.availability(preset, connected: displayIDs) == nil,
                  rule.requiredDevices.allSatisfy({ ids.contains($0.id) }),
                  rule.absentDevices.allSatisfy({ !ids.contains($0.id) }) else { return false }
            let wireless = Set([preset.airPlay?.displayID].compactMap { $0 })
            return !rule.exactDisplays || displayIDs.subtracting(wireless) == Set(preset.displays.map(\.id)).subtracting(wireless)
        }
    }
}

public struct ConnectionGate {
    private var candidate: Set<String>?
    private var since = Date.distantPast
    private var consumed: Set<String>?
    public init() {}
    public mutating func reset() { candidate = nil; consumed = nil }
    /// A preset can itself add/remove an AirPlay display; do not treat that as a new external trigger.
    public mutating func consume(_ devices: [Device], now: Date) {
        let ids = Set(devices.map(\.id)); candidate = ids; consumed = ids; since = now
    }
    public mutating func shouldEvaluate(_ devices: [Device], now: Date, settle: TimeInterval = 3) -> Bool {
        let ids = Set(devices.map(\.id))
        if candidate != ids { candidate = ids; since = now }
        guard now.timeIntervalSince(since) >= settle, consumed != ids else { return false }
        consumed = ids
        return true
    }
}

extension DisplayMode {
    /// Picker order: width, height, refresh rate descending, then HiDPI first, depth descending, id as the final tie-break.
    public static func pickerOrder(_ a: DisplayMode, _ b: DisplayMode) -> Bool {
        if a.width != b.width { return a.width > b.width }
        if a.height != b.height { return a.height > b.height }
        if a.hertz != b.hertz { return a.hertz > b.hertz }
        if a.scaled != b.scaled { return a.scaled }
        if a.depth != b.depth { return a.depth > b.depth }
        return a.id < b.id
    }
}

extension Configuration {
    private struct Box { var id: String; var x: Int; var y: Int; var w: Int; var h: Int }
    private static func boxes(_ displays: [DisplaySetting]) -> [Box] {
        displays.filter { $0.enabled && $0.mirrorOf == nil }.map { Box(id: $0.id, x: $0.x, y: $0.y, w: $0.mode.width, h: $0.mode.height) }
    }
    private static func overlaps(_ a: Box, _ b: Box) -> Bool { a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h }
    private static func touches(_ a: Box, _ b: Box) -> Bool { a.x <= b.x + b.w && b.x <= a.x + a.w && a.y <= b.y + b.h && b.y <= a.y + a.h }

    /// Editor-only check: macOS renormalises extended layouts with overlaps or gaps, which makes exact-position verification fail.
    public static func arrangementIssue(_ displays: [DisplaySetting]) -> String? {
        let b = boxes(displays)
        guard b.count > 1 else { return nil }
        let names = Dictionary(displays.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for i in b.indices { for j in b.indices where j > i && overlaps(b[i], b[j]) {
            return "\(names[b[i].id] ?? "A display") and \(names[b[j].id] ?? "another display") overlap. macOS would move them, so the preset would not stay as saved. Drag them apart or use Place beside…."
        } }
        var seen: Set<Int> = [0]; var queue = [0]
        while let i = queue.popLast() { for j in b.indices where !seen.contains(j) && touches(b[i], b[j]) { seen.insert(j); queue.append(j) } }
        guard seen.count < b.count else { return nil }
        let lost = b.indices.filter { !seen.contains($0) }.map { names[b[$0].id] ?? "A display" }
        return lost.joined(separator: ", ") + (lost.count == 1 ? " is" : " are") + " not touching the other displays. macOS closes gaps, so the preset would not stay as saved. Drag it against another display or use Place beside…."
    }

    /// Nearest position at which `id` shares an edge (or a corner) with another extended display without overlapping any.
    /// The perpendicular coordinate stays as proposed, clamped so the edges still meet. Returns the proposal unchanged when the
    /// display is not an enabled extended one or has no neighbour, and nil when no overlap-free touching position exists.
    public static func snappedPosition(_ displays: [DisplaySetting], moving id: String, to proposed: (x: Int, y: Int)) -> (x: Int, y: Int)? {
        let all = boxes(displays)
        guard let me = all.first(where: { $0.id == id }) else { return proposed }
        let others = all.filter { $0.id != id }
        guard !others.isEmpty else { return proposed }
        var best: (x: Int, y: Int)?; var bestD = Int.max
        for o in others {
            let cy = min(max(proposed.y, o.y - me.h), o.y + o.h), cx = min(max(proposed.x, o.x - me.w), o.x + o.w)
            for c in [(o.x + o.w, cy), (o.x - me.w, cy), (cx, o.y - me.h), (cx, o.y + o.h)] {
                let moved = Box(id: id, x: c.0, y: c.1, w: me.w, h: me.h)
                if others.contains(where: { overlaps(moved, $0) }) { continue }
                let d = (c.0 - proposed.x) * (c.0 - proposed.x) + (c.1 - proposed.y) * (c.1 - proposed.y)
                if d < bestD { bestD = d; best = (c.0, c.1) }
            }
        }
        return best
    }
}
