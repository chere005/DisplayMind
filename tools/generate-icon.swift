import AppKit

// DisplayMind's shiny silver DM follows the MindSuite 96-unit, 9-unit rounded-stroke mark; its short M is NoteMind's and PlanMind's.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("assets", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
// Shiny silver (Sean, 2026-11-21): a soft vertical sheen over the whole mark, lit from the top with a gentle
// shade just below the middle. 0.21.0's hard chrome band was "too aggressive"; keep the contrast this low.
// Offsets run from y 22 to y 74, the stroked mark's extent.
let chrome: [(offset: CGFloat, hex: String)] = [(0, "eef0f2"), (0.45, "d0d3d7"), (0.58, "b8bcc1"), (0.72, "c9ccd0"), (1, "dadde0")]
let pathData = "M 14 26 L 14 70 L 24 70 C 50 70 50 26 24 26 L 14 26 M 58 70 L 58 40 L 68 54 L 78 40 L 78 70"
let svgStops = chrome.map { "<stop offset=\"\($0.offset)\" stop-color=\"#\($0.hex)\"/>" }.joined()
for square in [false, true] {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">
      <!-- DisplayMind: softly shining silver DM in the MindSuite rounded monogram style. -->
      <defs><linearGradient id="chrome" gradientUnits="userSpaceOnUse" x1="0" y1="22" x2="0" y2="74">\(svgStops)</linearGradient></defs>
      <rect width="96" height="96"\(square ? "" : " rx=\"20\"") fill="#111111"/>
      <path d="\(pathData)" fill="none" stroke="url(#chrome)" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>
    """ + "\n"
    try svg.write(to: assets.appendingPathComponent(square ? "logo-square.svg" : "logo.svg"), atomically: true, encoding: .utf8)
}
func markPath() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 14, y: 26)); path.line(to: NSPoint(x: 14, y: 70)); path.line(to: NSPoint(x: 24, y: 70))
    path.curve(to: NSPoint(x: 24, y: 26), controlPoint1: NSPoint(x: 50, y: 70), controlPoint2: NSPoint(x: 50, y: 26))
    path.line(to: NSPoint(x: 14, y: 26))
    path.move(to: NSPoint(x: 58, y: 70)); path.line(to: NSPoint(x: 58, y: 40)); path.line(to: NSPoint(x: 68, y: 54))
    path.line(to: NSPoint(x: 78, y: 40)); path.line(to: NSPoint(x: 78, y: 70))
    path.lineWidth = 9; path.lineCapStyle = .round; path.lineJoinStyle = .round
    return path
}
func drawMark(color: NSColor) {
    color.setStroke(); markPath().stroke()
}
// Called inside the flipped 96-unit space, so y 22 is the top of the mark, as in the SVG.
func drawChromeMark() {
    let context = NSGraphicsContext.current!.cgContext
    let colors = chrome.map { stop -> CGColor in
        let value = Int(stop.hex, radix: 16)!
        return CGColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: chrome.map(\.offset))!
    context.saveGState()
    context.addPath(markPath().cgPath)
    context.setLineWidth(9); context.setLineCap(.round); context.setLineJoin(.round)
    context.replacePathWithStrokedPath(); context.clip()
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 22), end: CGPoint(x: 0, y: 74), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}
func bitmap(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 96); transform.translateX(by: 0, yBy: 96); transform.scaleX(by: 1, yBy: -1); transform.concat()
    NSColor(srgbRed: 17.0/255, green: 17.0/255, blue: 17.0/255, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 96, height: 96), xRadius: 20, yRadius: 20).fill()
    drawChromeMark()
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
