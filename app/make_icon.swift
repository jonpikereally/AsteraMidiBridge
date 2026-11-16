// Renders the app icon (two-peak mark on a dark rounded square) into an .iconset folder.
// Usage: make_icon <output.iconset>   then: iconutil -c icns <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                          xRadius: s * 0.19, yRadius: s * 0.19)
    NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
    bg.fill()

    let k = (s * 0.60) / 18
    let ox = s * 0.20, oy = s * 0.20
    func shape(_ pts: [(CGFloat, CGFloat)], _ color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: ox + pts[0].0 * k, y: oy + pts[0].1 * k))
        for p in pts.dropFirst() { path.line(to: NSPoint(x: ox + p.0 * k, y: oy + p.1 * k)) }
        path.close()
        path.lineJoinStyle = .round
        path.lineWidth = 1.6 * k
        color.setFill(); color.setStroke()
        path.fill(); path.stroke()
    }
    shape([(2, 3), (8.2, 15), (10.8, 15), (9.6, 9.5), (6.6, 3)], NSColor(srgbRed: 0.44, green: 0.22, blue: 0.72, alpha: 1))
    shape([(7.2, 3), (16, 3), (11.6, 10.4)], NSColor(srgbRed: 0.96, green: 0.62, blue: 0.13, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try! render(px).write(to: out.appendingPathComponent(name + ".png"))
}
