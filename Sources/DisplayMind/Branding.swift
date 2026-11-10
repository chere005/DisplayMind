import AppKit

enum Branding {
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
