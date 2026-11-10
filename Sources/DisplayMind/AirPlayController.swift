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
            throw DisplayMindError("Allow DisplayMind in System Settings → Privacy & Security → Accessibility to connect AirPlay. Use Allow AirPlay control in the preset editor.")
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
                    try press(row.element)
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

    private func receiverRows(_ app: AXUIElement) -> [(receiver: AirPlayReceiver, element: AXUIElement)] {
        let nodes = Self.elements(app, kAXWindowsAttribute).flatMap(tree)
        return nodes.compactMap { node in
            let identifier = string(node, kAXIdentifierAttribute)
            guard string(node, kAXRoleAttribute) == kAXCheckBoxRole,
                  identifier.hasPrefix("screen-mirroring-device-"),
                  !identifier.hasPrefix("screen-mirroring-device-Sidecar") else { return nil }
            let labels = [string(node, kAXTitleAttribute), string(node, kAXDescriptionAttribute)] +
                Self.elements(node, kAXChildrenAttribute).filter { string($0, kAXRoleAttribute) == kAXStaticTextRole }.map { string($0, kAXValueAttribute) }
            let name = labels.first { !$0.isEmpty } ?? String(identifier.dropFirst("screen-mirroring-device-".count))
            let value = Self.attribute(node, kAXValueAttribute)
            let selected: Bool?
            if let number = value as? NSNumber, [0,1].contains(number.intValue) { selected = number.boolValue }
            else if let text = value as? String, ["0", "1"].contains(text) { selected = text == "1" }
            else { selected = nil }
            return (AirPlayReceiver(id: identifier, name: name, selected: selected), node)
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
