import Foundation

public struct SettingsFile {
    public let directory: URL
    public var url: URL { directory.appendingPathComponent("settings.json") }
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppSettings() }
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
        guard settings.schemaVersion == 1 else { throw DisplayMindError("These settings were created by a newer DisplayMind. The file has been preserved.") }
        guard Set(settings.presets.map(\.id)).count == settings.presets.count,
              Set(settings.rules.map(\.id)).count == settings.rules.count else { throw DisplayMindError("Duplicate identifiers in settings. The file has been preserved.") }
        for preset in settings.presets { try Configuration.validate(preset) }
        return settings
    }
    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

public struct RecoveryJournal: Codable {
    public var id: UUID
    public var deadline: Date
    public var previous: [DisplaySetting]
    /// Set once the new layout has verified: the change stays when the deadline passes, and the deadline is only how long a revert is offered.
    /// Without it the deadline is a safety net: an apply that never finished is rolled back.
    public var keepWhenDue: Bool?
    public var startedAirPlay: AirPlayDestination?
    /// AirPlay streams this change stopped because the new preset has no place for their display; a revert reconnects them.
    public var stoppedAirPlay: [AirPlayDestination]?
    /// The default sound devices before the change (only the sides the change overwrote); absent in older journals.
    public var previousAudio: AudioSelection?
    public init(id: UUID = UUID(), deadline: Date, previous: [DisplaySetting], previousAudio: AudioSelection? = nil) {
        self.id = id; self.deadline = deadline; self.previous = previous; self.previousAudio = previousAudio
    }
}

public struct RecoveryResult: Codable {
    public var id: UUID
    public var error: String?
    /// Set once a failed result has been shown to the user, so it is not shown again at every launch.
    public var acknowledged: Bool?
    public init(id: UUID, error: String?, acknowledged: Bool? = nil) { self.id = id; self.error = error; self.acknowledged = acknowledged }
}

public enum DataFolder {
    /// `~/Library/Application Support/DisplayMind`, where an app's own state belongs.
    /// Versions through 0.4 kept it in `~/DisplayMind`; that folder is moved here once. It is left alone, and used for this run, while a change
    /// is still pending in it: the watchdog for that change was started with the old path and must find its journal there.
    public static func resolve(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                               fileManager: FileManager = .default) -> URL {
        let current = support.appendingPathComponent("DisplayMind", isDirectory: true)
        let legacy = home.appendingPathComponent("DisplayMind", isDirectory: true)
        // Only a folder this app wrote is moved; anything else called ~/DisplayMind is not ours to touch.
        guard !fileManager.fileExists(atPath: current.path),
              fileManager.fileExists(atPath: legacy.appendingPathComponent("settings.json").path) else { return current }
        if fileManager.fileExists(atPath: legacy.appendingPathComponent("pending-change.json").path) { return legacy }
        do {
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: current)
            return current
        } catch { return legacy }
    }
}
