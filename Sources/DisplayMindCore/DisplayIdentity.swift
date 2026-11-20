import Foundation

/// The display's reported hardware identity, independent of its port-dependent macOS UUID.
public struct DisplayIdentity: Codable, Equatable, Hashable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    /// A serial is best, but some displays (including pen displays) report zero. In that case
    /// vendor + model can still identify a display when it is the only one of that model.
    public var isUsable: Bool { vendor != 0 && model != 0 }
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

    /// Exact UUIDs take precedence. A missing UUID is replaced by a unique hardware identity;
    /// identities without a serial are matched only when that vendor/model is unique on both sides.
    /// A display whose model number changed (a Wacom One 12 reports two) is still the same when its vendor,
    /// serial number and real name all agree and it is the only such display saved and connected.
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
        let storedByModel = Dictionary(grouping: usableStored, by: { DisplayModel(vendor: $0.1.vendor, model: $0.1.model) })
        let connectedByModel = Dictionary(grouping: unique.filter { $0.setting.identity?.isUsable == true }) {
            DisplayModel(vendor: $0.setting.identity!.vendor, model: $0.setting.identity!.model)
        }
        let connectedByPhysical = Dictionary(grouping: unique.filter { $0.setting.identity?.isUsable == true && $0.setting.identity?.serial != 0 }) {
            PhysicalDisplay($0.setting.identity!)
        }
        let savedNames = Dictionary(grouping: settings.presets.flatMap(\.displays), by: \.id).mapValues { Set($0.map { normalized($0.name) }) }
        var result: [String: String] = [:]
        for (oldID, identity) in usableStored {
            guard !online.contains(oldID) else { continue }
            let candidate: ConnectedDisplay?
            var sameDisplay: (DisplayIdentity) -> Bool = { $0 == identity }
            if identity.serial != 0 {
                if let exact = byIdentity[identity] {
                    guard sources[identity]?.count == 1, exact.count == 1 else { continue }
                    candidate = exact.first
                } else {
                    // The same physical display reporting another model number.
                    let physical = PhysicalDisplay(identity)
                    let missing = usableStored.filter { !online.contains($0.0) && PhysicalDisplay($0.1) == physical }
                    guard missing.count == 1,
                          let candidates = connectedByPhysical[physical], candidates.count == 1,
                          let live = candidates.first, !DisplayParser.isPlaceholder(live.setting.name),
                          savedNames[oldID]?.contains(normalized(live.setting.name)) == true else { continue }
                    sameDisplay = { PhysicalDisplay($0) == physical }
                    candidate = live
                }
            } else {
                let model = DisplayModel(vendor: identity.vendor, model: identity.model)
                guard storedByModel[model]?.count == 1,
                      let candidates = connectedByModel[model], candidates.count == 1 else { continue }
                candidate = candidates.first
            }
            guard let candidate,
                  (stored[candidate.id] ?? []).allSatisfy(sameDisplay) else { continue }
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
        let savedNames = Dictionary(grouping: result.presets.flatMap(\.displays), by: \.id).mapValues { Set($0.map { normalized($0.name) }) }
        for p in result.presets.indices {
            for d in result.presets[p].displays.indices {
                let saved = result.presets[p].displays[d]
                guard !excluded.contains(saved.id),
                      let matches = current[saved.id], matches.count == 1,
                      let identity = matches.first?.setting.identity, identity.isUsable else { continue }
                if saved.identity == nil {
                    guard (stored[saved.id] ?? []).allSatisfy({ $0 == identity }) else { continue }
                    result.presets[p].displays[d].identity = identity
                } else if let old = saved.identity, old != identity, identity.serial != 0, PhysicalDisplay(old) == PhysicalDisplay(identity),
                          !DisplayParser.isPlaceholder(matches[0].setting.name), savedNames[saved.id]?.contains(normalized(matches[0].setting.name)) == true {
                    // The model number changed under the same serial: keep the newest so a later UUID change still matches.
                    result.presets[p].displays[d].identity = identity
                }
            }
        }
        return result
    }
}

private struct DisplayModel: Hashable {
    let vendor: UInt32
    let model: UInt32
}

/// What stays the same when a display reports another model number: its vendor and serial number.
private struct PhysicalDisplay: Hashable {
    let vendor: UInt32
    let serial: UInt32
    init(_ identity: DisplayIdentity) { vendor = identity.vendor; serial = identity.serial }
}

private func normalized(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
