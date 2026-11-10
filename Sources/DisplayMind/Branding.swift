import AppKit
import SwiftUI

enum Branding {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    /// Fills: the primary button, switches, the main display tile. White text stays legible on it in both appearances.
    static let fill = Color(red: 0.13, green: 0.52, blue: 0.63)
    /// Text and icons in the brand colour: darker on a light window, brighter on a dark one.
    static let text = dynamic(light: NSColor(srgbRed: 0.09, green: 0.42, blue: 0.52, alpha: 1), dark: NSColor(srgbRed: 0.42, green: 0.80, blue: 0.90, alpha: 1))
    /// Group background that stays visible in both appearances (controlBackgroundColor vanishes on a dark window).
    static let card = Color.primary.opacity(0.055)
    static let hairline = Color.primary.opacity(0.08)
    static let selection = dynamic(light: NSColor(srgbRed: 0.13, green: 0.52, blue: 0.63, alpha: 0.16), dark: NSColor(srgbRed: 0.30, green: 0.70, blue: 0.82, alpha: 0.24))
    static let logo: NSImage = {
        guard let url = Bundle.main.url(forResource: "Logo", withExtension: "png"), let image = NSImage(contentsOf: url) else {
            return NSImage(named: NSImage.applicationIconName)!
        }
        return image
    }()
    static let menuIcon: NSImage = {
        let image = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf").flatMap(NSImage.init(contentsOf:)) ?? NSImage(systemSymbolName: "display.2", accessibilityDescription: "DisplayMind")!
        image.isTemplate = true
        image.size = NSSize(width: 24, height: 24)
        return image
    }()
}
