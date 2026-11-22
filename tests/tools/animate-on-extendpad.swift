// Load generator for manual/automated tests: opens a window on "ExtendPad Display" that
// scrolls code-like text and animates a moving block, so the stream has real changes.
//   swift tests/tools/animate-on-extendpad.swift [seconds] [mode: scroll|static|video]
import AppKit

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "scroll"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let screen = NSScreen.screens.first(where: { $0.localizedName.contains("ExtendPad") }) else {
    print("ExtendPad Display not found (is a session active?)"); exit(2)
}
print("found \(screen.localizedName) frame=\(screen.frame) scale=\(screen.backingScaleFactor)")
let rect = screen.visibleFrame.insetBy(dx: 30, dy: 30)
let win = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
win.title = "ExtendPad load test — \(mode)"
win.setFrame(rect, display: true)
let view = NSView(frame: NSRect(origin: .zero, size: rect.size)); view.wantsLayer = true
view.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
win.contentView = view
let text = NSTextField(labelWithString: "")
text.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
text.textColor = NSColor(calibratedRed: 0.8, green: 0.9, blue: 0.8, alpha: 1)
text.frame = NSRect(x: 20, y: 20, width: rect.width - 40, height: rect.height - 70)
text.maximumNumberOfLines = 0
view.addSubview(text)
let block = NSView(frame: NSRect(x: 0, y: 40, width: 120, height: 120)); block.wantsLayer = true
block.layer?.backgroundColor = NSColor.systemBlue.cgColor
if mode != "static" { view.addSubview(block) }
win.orderFrontRegardless()
let lines = (0..<400).map { String(format: "%04d  func render(frame: Int) -> String { return \"line \\(frame) — the quick brown fox jumps over the lazy dog\" }", $0) }
var n = 0
Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
    n += 1
    if mode == "static" && n > 1 { return }
    let start = (n / 2) % 300
    text.stringValue = lines[start..<(start + 60)].joined(separator: "\n")
    block.frame.origin.x = CGFloat((n * 9) % Int(rect.width))
    if mode == "video" { view.layer?.backgroundColor = NSColor(hue: CGFloat(n % 240) / 240, saturation: 0.6, brightness: 0.5, alpha: 1).cgColor }
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
