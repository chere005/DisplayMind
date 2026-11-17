import Foundation

/// Preset-list filtering and grouping; organizing a preset never changes its display layout.
public enum PresetOrganization {
    public enum MatchMode: String, CaseIterable, Codable {
        case all
        case any
    }

    public struct Monitor: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let title: String
        public let connected: Bool
    }

    public struct Group: Identifiable {
        public let id: String
        public let folder: PresetFolder?
        public let presets: [Preset]
        public let totalCount: Int
    }

    private static let locale = Locale(identifier: "en_US_POSIX")
    private static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }

    /// Saved displays stay available to the filter after disconnecting. A UUID remains the selection value even when names match.
    public static func monitors(presets: [Preset], connected: [ConnectedDisplay]) -> [Monitor] {
        var names: [String: String] = [:]
        for display in presets.flatMap(\.displays) {
            if names[display.id] == nil || (DisplayParser.isPlaceholder(names[display.id]!) && !DisplayParser.isPlaceholder(display.name)) {
                names[display.id] = display.name
            }
        }
        for display in connected {
            if names[display.id] == nil || !DisplayParser.isPlaceholder(display.setting.name) {
                names[display.id] = display.setting.name
            }
        }
        let online = Set(connected.map(\.id))
        let sorted = names.keys.sorted {
            let left = nameKey(names[$0]!), right = nameKey(names[$1]!)
            return left == right ? $0 < $1 : left < right
        }
        let counts = Dictionary(grouping: sorted, by: { nameKey(names[$0]!) }).mapValues(\.count)
        var ordinals: [String: Int] = [:]
        return sorted.map { id in
            let name = names[id]!, key = nameKey(name)
            ordinals[key, default: 0] += 1
            let number = counts[key, default: 0] > 1 ? " (\(ordinals[key]!))" : ""
            let connected = online.contains(id)
            return Monitor(id: id, name: name, title: name + number + (connected ? "" : " · Not connected"), connected: connected)
        }
    }

    public static func filtered(_ presets: [Preset], monitorID: String?) -> [Preset] {
        filtered(presets, monitorIDs: selection(monitorID))
    }

    /// An empty selection shows every preset. Saved disabled displays still count as included displays.
    public static func filtered(_ presets: [Preset], monitorIDs: Set<String>, matching mode: MatchMode = .all) -> [Preset] {
        guard !monitorIDs.isEmpty else { return presets }
        return presets.filter { preset in
            let included = Set(preset.displays.map(\.id))
            switch mode {
            case .all: return monitorIDs.isSubset(of: included)
            case .any: return !monitorIDs.isDisjoint(with: included)
            }
        }
    }

    /// Folder order and preset order are saved order. Unknown folder references remain accessible under Ungrouped.
    public static func groups(settings: AppSettings, monitorID: String? = nil) -> [Group] {
        groups(settings: settings, monitorIDs: selection(monitorID))
    }

    public static func groups(settings: AppSettings, monitorIDs: Set<String>, matching mode: MatchMode = .all) -> [Group] {
        var seen = Set<UUID>()
        let folders = (settings.presetFolders ?? []).filter { seen.insert($0.id).inserted }
        let folderIDs = Set(folders.map(\.id))
        let allUngrouped = settings.presets.filter { $0.folderID.map { !folderIDs.contains($0) } ?? true }
        let ungrouped = filtered(allUngrouped, monitorIDs: monitorIDs, matching: mode)
        var result: [Group] = []
        if !ungrouped.isEmpty {
            result.append(Group(id: "ungrouped", folder: nil, presets: ungrouped, totalCount: allUngrouped.count))
        }
        for folder in folders {
            let all = settings.presets.filter { $0.folderID == folder.id }
            let presets = filtered(all, monitorIDs: monitorIDs, matching: mode)
            if !presets.isEmpty || monitorIDs.isEmpty {
                result.append(Group(id: folder.id.uuidString, folder: folder, presets: presets, totalCount: all.count))
            }
        }
        return result
    }

    public static func visiblePresets(settings: AppSettings, monitorID: String? = nil) -> [Preset] {
        visiblePresets(settings: settings, monitorIDs: selection(monitorID))
    }

    public static func visiblePresets(settings: AppSettings, monitorIDs: Set<String>, matching mode: MatchMode = .all) -> [Preset] {
        groups(settings: settings, monitorIDs: monitorIDs, matching: mode).flatMap { $0.folder?.collapsed == true ? [] : $0.presets }
    }

    private static func selection(_ monitorID: String?) -> Set<String> {
        guard let monitorID, !monitorID.isEmpty else { return [] }
        return [monitorID]
    }
}
