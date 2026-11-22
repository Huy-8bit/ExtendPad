// Compares what the Mac renders on the ExtendPad display with what the tablet shows.
//   swift compare-images.swift <mac.png> <tablet.png> [out-diff.png]
// Both images are scaled to a 192×120 grid (letterbox-free 16:10). Prints the share of cells whose
// colour differs strongly — compression noise stays far below the threshold, corruption does not.
import AppKit
func load(_ p: String) -> CGImage {
    guard let i = NSImage(contentsOfFile: p), let c = i.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("cannot read \(p)") }
    return c
}
let W = 192, H = 120
func pixels(_ img: CGImage) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: W * H * 4)
    let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .medium
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
    return buf
}
let a = pixels(load(CommandLine.arguments[1])), b = pixels(load(CommandLine.arguments[2]))
var bad = 0, worst = 0, sum = 0
var diff = [UInt8](repeating: 0, count: W * H * 4)
for i in 0..<(W * H) {
    let d = (0..<3).map { abs(Int(a[i * 4 + $0]) - Int(b[i * 4 + $0])) }
    let m = d.max()!
    sum += m; worst = max(worst, m)
    if m > 48 { bad += 1 }
    diff[i * 4] = UInt8(min(255, m * 3)); diff[i * 4 + 3] = 255
}
print(String(format: "cells=%d bad=%d (%.2f%%) meanDiff=%.1f worst=%d", W * H, bad, Double(bad) * 100 / Double(W * H), Double(sum) / Double(W * H), worst))
if CommandLine.arguments.count > 3 {
    let ctx = CGContext(data: &diff, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
}
