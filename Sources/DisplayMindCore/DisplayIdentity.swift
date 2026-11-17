import Foundation

/// The display's reported hardware identity, independent of its port-dependent macOS UUID.
public struct DisplayIdentity: Codable, Equatable, Hashable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var isUsable: Bool { vendor != 0 && model != 0 && serial != 0 }
    public init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor; self.model = model; self.serial = serial
    }
}

/// Rebinds physical display references only when the reported hardware identifies one display.
public enum DisplayReconciliation {
    /// A cached alias can itself be rebound after another reconnect; a cycle is never followed.
    public static func resolvedID(_ id: String, using mapping: [String: String]) -> String {
        var result = id, visited: Set<String> = []
        while let next = mapping[result], next != result {
            guard visited.insert(result).inserted else { return id }
            result = next
        }
        return result
    }

    private static func excludedIDs(_ settings: AppSettings, _ excluded: Set<String>) -> Set<String> {
        excluded.union(settings.presets.compactMap { $0.airPlay?.displayID })
    }

    private static func storedIdentities(_ settings: AppSettings) -> [String: Set<DisplayIdentity>] {
        Dictionary(grouping: settings.presets.flatMap(\.displays), by: \.id).mapValues {
            Set($0.compactMap(\.identity))
        }
    }

    /// Exact UUIDs take precedence. A missing UUID is replaced only by a unique full hardware tuple.
    /// Repeated/contradictory identities and references that would merge two displays are left unchanged.
    public static func mapping(settings: AppSettings, connected: [ConnectedDisplay], excluded: Set<String> = []) -> [String: String] {
        let excluded = excludedIDs(settings, excluded)
        let online = Set(connected.map(\.id))
        let byID = Dictionary(grouping: connected.filter { !excluded.contains($0.id) }, by: \.id)
        let unique = byID.values.compactMap { $0.count == 1 ? $0.first : nil }
        let byIdentity = Dictionary(grouping: unique.filter { $0.setting.identity?.isUsable == true }) { $0.setting.identity! }
        let stored = storedIdentities(settings)
        let usableStored = stored.compactMap { id, identities -> (String, DisplayIdentity)? in
            guard !excluded.contains(id), identities.count == 1, let identity = identities.first, identity.isUsable else { return nil }
            return (id, identity)
        }
        let sources = Dictionary(grouping: usableStored, by: { $0.1 })
        var result: [String: String] = [:]
        for (oldID, identity) in usableStored {
            guard !online.contains(oldID), sources[identity]?.count == 1,
                  let candidates = byIdentity[identity], candidates.count == 1, let candidate = candidates.first,
                  (stored[candidate.id] ?? []).allSatisfy({ $0 == identity }) else { continue }
            result[oldID] = candidate.id
        }

        var scopes = settings.presets.map { $0.displays.map(\.id) }
        scopes += settings.rules.map { rule in
            (rule.requiredDevices + rule.absentDevices).compactMap { device in
                device.kind == .display && device.id.hasPrefix("display:") ? String(device.id.dropFirst("display:".count)) : nil
            }
        }
        var collisions: Set<String> = []
        for ids in scopes {
            let rebound = Dictionary(grouping: ids, by: { resolvedID($0, using: result) })
            for originals in rebound.values where Set(originals).count > 1 {
                collisions.formUnion(originals.filter { result[$0] != nil })
            }
        }
        for id in collisions { result.removeValue(forKey: id) }
        return result
    }

    /// Layout, confirmation, folders, audio and receiver settings are retained.
    public static func remap(preset: Preset, using mapping: [String: String]) -> Preset {
        var preset = preset
        let physical = mapping.filter { $0.key != preset.airPlay?.displayID && $0.value != preset.airPlay?.displayID }
        for d in preset.displays.indices {
            preset.displays[d].id = resolvedID(preset.displays[d].id, using: physical)
            preset.displays[d].mirrorOf = preset.displays[d].mirrorOf.map { resolvedID($0, using: physical) }
        }
        return preset
    }

    public static func remap(rule: ConnectionRule, using mapping: [String: String]) -> ConnectionRule {
        func remap(_ device: Device) -> Device {
            guard device.kind == .display, device.id.hasPrefix("display:") else { return device }
            var device = device
            device.id = "display:" + resolvedID(String(device.id.dropFirst("display:".count)), using: mapping)
            return device
        }
        var rule = rule
        rule.requiredDevices = rule.requiredDevices.map(remap)
        rule.absentDevices = rule.absentDevices.map(remap)
        return rule
    }

    /// Enriches exact matches now so a future reconnect can be matched without relying on names.
    public static func reconcile(settings: AppSettings, connected: [ConnectedDisplay], excluded: Set<String> = []) -> AppSettings {
        let excluded = excludedIDs(settings, excluded)
        let aliases = mapping(settings: settings, connected: connected, excluded: excluded)
        let current = Dictionary(grouping: connected.filter { !excluded.contains($0.id) }, by: \.id)
        var result = settings
        result.presets = result.presets.map { remap(preset: $0, using: aliases) }
        result.rules = result.rules.map { remap(rule: $0, using: aliases) }
        let stored = storedIdentities(result)
        for p in result.presets.indices {
            for d in result.presets[p].displays.indices {
                let saved = result.presets[p].displays[d]
                guard saved.identity == nil, !excluded.contains(saved.id),
                      let matches = current[saved.id], matches.count == 1,
                      let identity = matches.first?.setting.identity, identity.isUsable,
                      (stored[saved.id] ?? []).allSatisfy({ $0 == identity }) else { continue }
                result.presets[p].displays[d].identity = identity
            }
        }
        return result
    }
}
