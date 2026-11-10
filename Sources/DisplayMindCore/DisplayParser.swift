import Foundation

public enum DisplayParser {
    private static func captures(_ pattern: String, _ input: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = input as NSString
        return regex.matches(in: input, range: NSRange(location: 0, length: text.length)).map { match in
            (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : text.substring(with: match.range(at: $0)) }
        }
    }
    private static func first(_ pattern: String, _ input: String) -> String? { captures(pattern, input).first?.first }

    public static func parse(_ output: String) throws -> [ConnectedDisplay] {
        let blocks = output.components(separatedBy: "Persistent screen id: ").dropFirst()
        var displays: [ConnectedDisplay] = []
        for block in blocks {
            guard let id = block.components(separatedBy: .newlines).first, UUID(uuidString: id) != nil,
                  let res = captures("(?m)^Resolution: (\\d+)x(\\d+)", block).first,
                  let origin = captures("(?m)^Origin: \\((-?\\d+),(-?\\d+)\\)", block).first,
                  let rotation = first("(?m)^Rotation: (\\d+)", block).flatMap(Int.init),
                  let contextualID = first("(?m)^Contextual screen id: (\\d+)", block).flatMap(UInt32.init) else {
                throw DisplayMindError("Could not read the display configuration. No changes were made.")
            }
            let builtIn = block.contains("Type: MacBook built in screen")
            // macOS names only screens it draws to; a mirror keeps this name, so prefer the reported size to a bare ordinal.
            let inches = first("(?m)^Type: (\\d+) inch external screen", block)
            let name = builtIn ? "Built-in display" : inches.map { "\($0)-inch display" } ?? "External display \(displays.filter { !$0.builtIn }.count + 1)"
            let mode = DisplayMode(width: Int(res[0]) ?? 0, height: Int(res[1]) ?? 0,
                                   hertz: first("(?m)^Hertz: (\\d+)", block).flatMap(Int.init) ?? 0,
                                   depth: first("(?m)^Color Depth: (\\d+)", block).flatMap(Int.init) ?? 8,
                                   scaled: block.contains("\nScaling: on"))
            let modes = captures("(?m)^  mode \\d+: res:(\\d+)x(\\d+)(?: hz:(\\d+))? color_depth:(\\d+)( scaling:on)?", block).map { m in
                DisplayMode(width: Int(m[0]) ?? 0, height: Int(m[1]) ?? 0, hertz: Int(m[2]) ?? 0, depth: Int(m[3]) ?? 8, scaled: !m[4].isEmpty)
            }
            let setting = DisplaySetting(id: id, name: name, mode: mode, rotation: rotation,
                                         x: Int(origin[0]) ?? 0, y: Int(origin[1]) ?? 0, enabled: !block.contains("\nEnabled: false"))
            displays.append(ConnectedDisplay(setting: setting, modes: Array(Set(modes + [mode])).sorted {
                if $0.width != $1.width { return $0.width > $1.width }
                if $0.height != $1.height { return $0.height > $1.height }
                return $0.id < $1.id
            }, contextualID: contextualID, builtIn: builtIn))
        }
        guard !displays.isEmpty, let command = output.components(separatedBy: .newlines).last(where: { $0.hasPrefix("displayplacer ") }) else {
            throw DisplayMindError("No usable display configuration was returned.")
        }
        for group in captures("\"id:([A-Fa-f0-9+\\-]+) [^\"]*\"", command) {
            let ids = group[0].components(separatedBy: "+")
            for id in ids.dropFirst() {
                guard let i = displays.firstIndex(where: { $0.id == id }) else { throw DisplayMindError("A mirrored display could not be identified.") }
                displays[i].setting.mirrorOf = ids[0]
                displays[i].setting.enabled = true
            }
        }
        try Configuration.validate(displays.map(\.setting))
        return displays
    }
}
