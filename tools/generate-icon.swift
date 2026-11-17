import AppKit

// DisplayMind's silver DM follows the MindSuite 96-unit, 9-unit rounded-stroke mark.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("assets", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
let silver = NSColor(srgbRed: 192.0/255, green: 192.0/255, blue: 192.0/255, alpha: 1)
let pathData = "M 14 26 L 14 70 L 24 70 C 50 70 50 26 24 26 L 14 26 M 54 70 L 54 26 L 68 52 L 82 26 L 82 70"
for square in [false, true] {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">
      <!-- DisplayMind: silver DM in the MindSuite rounded monogram style. -->
      <rect width="96" height="96"\(square ? "" : " rx=\"20\"") fill="#111111"/>
      <path d="\(pathData)" fill="none" stroke="#c0c0c0" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>
    """ + "\n"
    try svg.write(to: assets.appendingPathComponent(square ? "logo-square.svg" : "logo.svg"), atomically: true, encoding: .utf8)
}
func drawMark(color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 14, y: 26)); path.line(to: NSPoint(x: 14, y: 70)); path.line(to: NSPoint(x: 24, y: 70))
    path.curve(to: NSPoint(x: 24, y: 26), controlPoint1: NSPoint(x: 50, y: 70), controlPoint2: NSPoint(x: 50, y: 26))
    path.line(to: NSPoint(x: 14, y: 26))
    path.move(to: NSPoint(x: 54, y: 70)); path.line(to: NSPoint(x: 54, y: 26)); path.line(to: NSPoint(x: 68, y: 52))
    path.line(to: NSPoint(x: 82, y: 26)); path.line(to: NSPoint(x: 82, y: 70))
    path.lineWidth = 9; path.lineCapStyle = .round; path.lineJoinStyle = .round
    color.setStroke(); path.stroke()
}
func bitmap(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 96); transform.translateX(by: 0, yBy: 96); transform.scaleX(by: 1, yBy: -1); transform.concat()
    NSColor(srgbRed: 17.0/255, green: 17.0/255, blue: 17.0/255, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 96, height: 96), xRadius: 20, yRadius: 20).fill()
    drawMark(color: silver)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        try bitmap(pixels: size * scale).write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
try bitmap(pixels: 1024).write(to: assets.appendingPathComponent("logo.png"))
try bitmap(pixels: 256).write(to: assets.appendingPathComponent("logo-preview.png"))
let pdf = NSMutableData()
var mediaBox = CGRect(x: 0, y: 0, width: 96, height: 96)
let context = CGContext(consumer: CGDataConsumer(data: pdf)!, mediaBox: &mediaBox, nil)!
context.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
context.translateBy(x: 0, y: 96); context.scaleBy(x: 1, y: -1)
drawMark(color: .black)
NSGraphicsContext.restoreGraphicsState()
context.endPDFPage(); context.closePDF()
try (pdf as Data).write(to: root.appendingPathComponent("Resources/MenuBarIcon.pdf"))
