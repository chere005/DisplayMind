import AppKit

// Vector artwork rendered at every standard macOS icon size.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func drawIcon() {
    let background = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.43, blue: 0.54, alpha: 1), ending: NSColor(calibratedRed: 0.06, green: 0.20, blue: 0.32, alpha: 1))!.draw(in: background, angle: -70)
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: 170, y: 330, width: 490, height: 365), xRadius: 35, yRadius: 35).fill()
    NSColor(calibratedRed: 0.2, green: 0.68, blue: 0.72, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 192, y: 365, width: 446, height: 308), xRadius: 19, yRadius: 19).fill()
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: 374, y: 270, width: 80, height: 72), xRadius: 9, yRadius: 9).fill()
    NSBezierPath(roundedRect: NSRect(x: 310, y: 252, width: 210, height: 24), xRadius: 12, yRadius: 12).fill()
    NSColor(calibratedRed: 0.07, green: 0.25, blue: 0.36, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 615, y: 280, width: 250, height: 475), xRadius: 36, yRadius: 36).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 630, y: 296, width: 220, height: 444), xRadius: 25, yRadius: 25).fill()
    NSColor(calibratedRed: 0.42, green: 0.79, blue: 0.77, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 648, y: 330, width: 184, height: 392), xRadius: 12, yRadius: 12).fill()
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
