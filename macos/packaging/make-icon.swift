// Renders the ExtendPad app icon into an .iconset directory (no external assets needed).
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let bg = NSBezierPath(roundedRect: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88), xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.16, alpha: 1),
               ending: NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.08, alpha: 1))!.draw(in: bg, angle: -90)
    let lw = s * 0.035
    // Mac screen
    let mac = NSBezierPath(roundedRect: NSRect(x: s * 0.17, y: s * 0.42, width: s * 0.42, height: s * 0.28), xRadius: s * 0.03, yRadius: s * 0.03)
    mac.lineWidth = lw; NSColor(calibratedWhite: 0.78, alpha: 1).setStroke(); mac.stroke()
    NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: s * 0.31, y: s * 0.35, width: s * 0.14, height: s * 0.035)).fill()
    // Tablet
    let tab = NSBezierPath(roundedRect: NSRect(x: s * 0.50, y: s * 0.24, width: s * 0.34, height: s * 0.30), xRadius: s * 0.035, yRadius: s * 0.035)
    NSColor(calibratedRed: 0.30, green: 0.55, blue: 1.0, alpha: 0.25).setFill(); tab.fill()
    tab.lineWidth = lw; NSColor(calibratedRed: 0.30, green: 0.55, blue: 1.0, alpha: 1).setStroke(); tab.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
