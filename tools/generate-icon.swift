import AppKit

// One geometry source for MindSuite's mint, joined DM in every vector and native asset.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("assets", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
let mint = NSColor(srgbRed: 52.0/255, green: 211.0/255, blue: 153.0/255, alpha: 1)
enum Stroke {
    case move(Int, Int), line(Int, Int), curve(Int, Int, Int, Int, Int, Int)
    var svg: String {
        switch self {
        case let .move(x, y): return "M \(x) \(y)"
        case let .line(x, y): return "L \(x) \(y)"
        case let .curve(x, y, a, b, c, d): return "C \(a) \(b) \(c) \(d) \(x) \(y)"
        }
    }
    func append(to path: NSBezierPath) {
        func point(_ x: Int, _ y: Int) -> NSPoint { NSPoint(x: CGFloat(x), y: CGFloat(y)) }
        switch self {
        case let .move(x, y): path.move(to: point(x, y))
        case let .line(x, y): path.line(to: point(x, y))
        case let .curve(x, y, a, b, c, d): path.curve(to: point(x, y), controlPoint1: point(a, b), controlPoint2: point(c, d))
        }
    }
}
let strokes: [Stroke] = [
    .move(27, 71), .curve(27, 25, 53, 71, 53, 25),
    .line(16, 25), .line(16, 71), .line(27, 71), .line(58, 71),
    .line(58, 45), .line(69, 58), .line(80, 45), .line(80, 71)
]
let pathData = strokes.map(\.svg).joined(separator: " ")
for square in [false, true] {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">
      <!-- DisplayMind: one joined mint DM in the MindSuite rounded monogram style. -->
      <rect width="96" height="96"\(square ? "" : " rx=\"20\"") fill="#111111"/>
      <path d="\(pathData)" fill="none" stroke="#34d399" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>
    """ + "\n"
    try svg.write(to: assets.appendingPathComponent(square ? "logo-square.svg" : "logo.svg"), atomically: true, encoding: .utf8)
}
func drawMark(color: NSColor) {
    let path = NSBezierPath()
    for stroke in strokes { stroke.append(to: path) }
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
    drawMark(color: mint)
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
