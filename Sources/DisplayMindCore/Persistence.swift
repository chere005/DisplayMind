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
    public var startedAirPlay: AirPlayDestination?
    public init(id: UUID = UUID(), deadline: Date, previous: [DisplaySetting]) {
        self.id = id; self.deadline = deadline; self.previous = previous
    }
}

public struct RecoveryResult: Codable {
    public var id: UUID
    public var error: String?
    public init(id: UUID, error: String?) { self.id = id; self.error = error }
}
