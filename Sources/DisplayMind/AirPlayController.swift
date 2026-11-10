import AppKit
import ApplicationServices
import DisplayMindCore

/// Drives only Control Center's Screen Mirroring controls through the public Accessibility API.
/// No shell interpolation, coordinate clicks, or first-device fallbacks.
struct AirPlayController {
    static var authorized: Bool { AXIsProcessTrusted() }
    @MainActor static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !authorized { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    }
    static func requireAccess() throws {
        guard authorized else {
            throw DisplayMindError("Allow DisplayMind in System Settings → Privacy & Security → Accessibility so it can start and stop AirPlay. Use Allow AirPlay control in the preset editor.")
        }
    }

    func receivers() throws -> [AirPlayReceiver] {
        let panel = try openPanel()
        defer { panel.dismiss() }
        let deadline = Date().addingTimeInterval(5)
        var found: [AirPlayReceiver] = []
        repeat {
            found = receiverRows(panel.app).map(\.receiver)
            if !found.isEmpty { return found }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return found
    }

    func setConnected(_ target: AirPlayDestination, _ connecting: Bool, beforeConnect: () throws -> Void = {}) throws {
        let panel = try openPanel()
        defer { panel.dismiss() }
        let deadline = Date().addingTimeInterval(8)
        repeat {
            let rows = receiverRows(panel.app)
            if let receiver = try AirPlaySelection.receiver(for: target, in: rows.map(\.receiver)),
               let row = rows.first(where: { $0.receiver.id == receiver.id }) {
                if try AirPlaySelection.shouldPress(receiver, connecting: connecting) {
                    if connecting { try beforeConnect() } // persist ownership BEFORE starting the stream
                    try press(connecting ? row.control : row.stop ?? row.control)
                    Thread.sleep(forTimeInterval: 0.3)
                }
                if !connecting {
                    let removalDeadline = Date().addingTimeInterval(8)
                    while Hardware.connectedDisplayIDs().contains(target.displayID) {
                        guard Date() < removalDeadline else { throw DisplayMindError("macOS did not disconnect \(target.receiverName).") }
                        Thread.sleep(forTimeInterval: 0.25)
                    }
                }
                return
            }
            if !connecting && !Hardware.connectedDisplayIDs().contains(target.displayID) { return }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        throw DisplayMindError("AirPlay receiver \(target.receiverName) was not found in Screen Mirroring. Make sure it is awake and available on this network.")
    }

    /// What Control Center exposes to Accessibility on this Mac, for diagnosing a macOS that moved its controls.
    /// With `open` it opens the Screen Mirroring list, reads it and closes it again. It never presses a receiver.
    func probe(open: Bool) -> String {
        var lines = ["accessibility access: \(Self.authorized ? "allowed" : "NOT allowed")"]
        guard Self.authorized else { return lines.joined(separator: "\n") }
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else {
            return (lines + ["Control Center is not running"]).joined(separator: "\n")
        }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        func describe(_ element: AXUIElement, depth: Int, limit: Int) {
            guard depth < limit, lines.count < 600 else { return }
            var names: CFArray?
            AXUIElementCopyActionNames(element, &names)
            let value = Self.attribute(element, kAXValueAttribute).map { String("\($0)".prefix(40)) } ?? ""
            lines.append(String(repeating: "  ", count: depth) + "\(string(element, kAXRoleAttribute)) id=\(string(element, kAXIdentifierAttribute)) title=\(string(element, kAXTitleAttribute)) desc=\(string(element, kAXDescriptionAttribute)) value=\(value) actions=\((names as? [String] ?? []).map { String($0.prefix(60)).replacingOccurrences(of: "\n", with: " ") }.joined(separator: "|"))")
            for child in Self.elements(element, kAXChildrenAttribute) { describe(child, depth: depth + 1, limit: limit) }
        }
        lines.append("menu bar:")
        for bar in Self.elements(app, kAXExtrasMenuBarAttribute) + Self.elements(app, kAXMenuBarAttribute) { describe(bar, depth: 1, limit: 3) }
        guard open else { return lines.joined(separator: "\n") }
        do {
            let panel = try openPanel()
            defer { panel.dismiss() }
            Thread.sleep(forTimeInterval: 1)
            lines.append("opened Screen Mirroring \(panel.opener == nil ? "(already open)" : "with a menu-bar control"); windows:")
            for window in Self.elements(app, kAXWindowsAttribute) { describe(window, depth: 1, limit: 12) }
            lines.append("receivers read: " + receiverRows(app).map { "\($0.receiver.name) [\($0.receiver.id)] selected=\($0.receiver.selected.map(String.init) ?? "unknown") stop=\($0.stop != nil)" }.joined(separator: "; "))
        } catch { lines.append("could not open Screen Mirroring: \(error.localizedDescription)"); lines.append("windows:"); for window in Self.elements(app, kAXWindowsAttribute) { describe(window, depth: 1, limit: 12) } }
        return lines.joined(separator: "\n")
    }

    private struct Panel {
        var app: AXUIElement
        var opener: AXUIElement?
        func dismiss() {
            // Only close a panel we opened, without sending Escape to the user's active app.
            if let opener, !AirPlayController.elements(app, kAXWindowsAttribute).isEmpty {
                _ = AXUIElementPerformAction(opener, kAXPressAction as CFString)
            }
        }
    }
    private func openPanel() throws -> Panel {
        try Self.requireAccess()
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else {
            throw DisplayMindError("macOS Control Center is unavailable.")
        }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        if !receiverRows(app).isEmpty { return Panel(app: app, opener: nil) }
        let menuItems = tree(app).filter { string($0, kAXRoleAttribute) == kAXMenuBarItemRole }
        let direct = menuItems.first {
            ["com.apple.menuextra.airplay", "com.apple.menuextra.screenmirroring"].contains(string($0, kAXIdentifierAttribute)) ||
                string($0, kAXDescriptionAttribute) == "Screen Mirroring"
        }
        let center = menuItems.first {
            string($0, kAXIdentifierAttribute) == "com.apple.menuextra.controlcenter" ||
                ["Control Center", "Control Centre"].contains(string($0, kAXDescriptionAttribute))
        }
        var opener: AXUIElement?
        do {
            if let direct { try press(direct); opener = direct }
            else {
                if Self.elements(app, kAXWindowsAttribute).isEmpty {
                    guard let center else { throw DisplayMindError("Could not locate Control Center's menu-bar control.") }
                    try press(center); opener = center
                }
                guard let module = waitFor(app, timeout: 3, predicate: { string($0, kAXIdentifierAttribute) == "controlcenter-screen-mirroring" }) else {
                    throw DisplayMindError("Could not locate Screen Mirroring in Control Center.")
                }
                var actions: CFArray?
                AXUIElementCopyActionNames(module, &actions)
                let details = (actions as? [String])?.first { $0.lowercased().contains("show details") }
                let result = AXUIElementPerformAction(module, (details ?? kAXPressAction) as CFString)
                guard result == .success else { throw DisplayMindError("macOS could not open Screen Mirroring (\(result.rawValue)).") }
            }
            Thread.sleep(forTimeInterval: 0.4)
            return Panel(app: app, opener: opener)
        } catch {
            Panel(app: app, opener: opener).dismiss()
            throw error
        }
    }

    /// One receiver in the Screen Mirroring list: the control that connects it and, while it is connected on macOS 26, the button that stops it.
    private struct Row {
        var receiver: AirPlayReceiver
        var control: AXUIElement
        var stop: AXUIElement?
    }
    private func receiverRows(_ app: AXUIElement) -> [Row] {
        let prefix = "screen-mirroring-device-"
        var order: [String] = [], groups: [String: [AXUIElement]] = [:]
        for node in Self.elements(app, kAXWindowsAttribute).flatMap(tree) {
            let identifier = string(node, kAXIdentifierAttribute)
            guard identifier.hasPrefix(prefix), !identifier.hasPrefix(prefix + "Sidecar"), identifier != prefix + "list" else { continue }
            if groups[identifier] == nil { order.append(identifier) }
            groups[identifier, default: []].append(node)
        }
        return order.compactMap { identifier in
            let group = groups[identifier] ?? []
            func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) }
            func label(_ element: AXUIElement) -> String {
                ([string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute)] +
                    Self.elements(element, kAXChildrenAttribute).filter { role($0) == kAXStaticTextRole }.map { string($0, kAXValueAttribute) }).first { !$0.isEmpty } ?? ""
            }
            // macOS 13–15 list each receiver as a checkbox that toggles it. macOS 26 shows a connected receiver as a disclosure
            // triangle with "Change" and "Stop Mirroring"/"Stop Extending" buttons beside it; every one carries the receiver's identifier.
            let toggles = group.filter { [kAXCheckBoxRole, kAXDisclosureTriangleRole, kAXRadioButtonRole].contains(role($0)) }
            let buttons = group.filter { role($0) == kAXButtonRole }
            let stop = buttons.first { label($0).hasPrefix("Stop") } ?? (toggles.isEmpty ? nil : buttons.count > 1 ? buttons.last : nil)
            guard let control = toggles.first ?? buttons.first(where: { !label($0).isEmpty }) else { return nil }
            let value = Self.attribute(control, kAXValueAttribute)
            var selected: Bool?
            if let number = value as? NSNumber, [0, 1].contains(number.intValue) { selected = number.boolValue }
            else if let text = value as? String, ["0", "1"].contains(text) { selected = text == "1" }
            if stop != nil { selected = true }
            let name = label(control)
            return Row(receiver: AirPlayReceiver(id: identifier, name: name.isEmpty ? String(identifier.dropFirst(prefix.count)) : name, selected: selected), control: control, stop: stop)
        }
    }
    private func waitFor(_ root: AXUIElement, timeout: TimeInterval, predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let match = tree(root).first(where: predicate) { return match }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return nil
    }
    private func tree(_ root: AXUIElement) -> [AXUIElement] {
        var queue = [root]; var result: [AXUIElement] = []; var seen = Set<CFHashCode>()
        let deadline = Date().addingTimeInterval(2)
        while !queue.isEmpty && result.count < 400 && Date() < deadline {
            let element = queue.removeFirst()
            guard seen.insert(CFHash(element)).inserted else { continue }
            result.append(element)
            queue += Self.elements(element, kAXChildrenAttribute)
            if CFEqual(element, root) {
                queue += Self.elements(element, kAXWindowsAttribute)
                queue += Self.elements(element, kAXMenuBarAttribute)
                queue += Self.elements(element, kAXExtrasMenuBarAttribute)
            }
        }
        return result
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name) else { return [] }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return [unsafeBitCast(value, to: AXUIElement.self)] }
        return value as? [AXUIElement] ?? []
    }
    private func string(_ element: AXUIElement, _ name: String) -> String { Self.attribute(element, name) as? String ?? "" }
    private func press(_ element: AXUIElement) throws {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw DisplayMindError("macOS did not accept the AirPlay control (\(result.rawValue)).") }
    }
}
