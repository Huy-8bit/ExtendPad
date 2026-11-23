import Foundation
import AppKit
import CoreGraphics

/// Streams the Mac cursor (position + shape) to the tablet over the control channel so the tablet
/// can draw it itself. The cursor then moves at the tablet's refresh rate with only the USB round
/// trip as latency, instead of waiting for the next encoded video frame. The video is captured
/// without the cursor while this is active.
public final class CursorTracker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "extendpad.cursor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var displayID: CGDirectDisplayID = 0
    private var send: ((Frame) -> Void)?
    private var lastPos: (UInt16, UInt16, Bool)?
    private var lastImage = Data()
    private var lastImageCheck: UInt64 = 0
    private var bounds = CGRect.zero
    private var boundsCheckedAt: UInt64 = 0
    private var posSent = 0, imagesSent = 0, lastReport: UInt64 = 0

    public init() {}

    public func start(displayID: CGDirectDisplayID, send: @escaping (Frame) -> Void) {
        queue.async {
            self.lock.lock(); self.displayID = displayID; self.send = send; self.lock.unlock()
            self.lastPos = nil
            self.lastImage = Data()
            self.boundsCheckedAt = 0
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .microseconds(8_333), leeway: .microseconds(500)) // 120 Hz
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.lock.lock(); self.send = nil; self.lock.unlock()
        }
    }

    private func tick() {
        lock.lock(); let id = displayID; let send = self.send; lock.unlock()
        guard let send, id != 0 else { return }
        let now = MonoClock.nowMicros()
        if now &- boundsCheckedAt > 500_000 { bounds = CGDisplayBounds(id); boundsCheckedAt = now } // arrangement may change
        guard bounds.width > 1, bounds.height > 1, let loc = CGEvent(source: nil)?.location else { return }
        let inside = bounds.contains(loc)
        let x = UInt16(clamping: Int(((loc.x - bounds.minX) / bounds.width * 65535).rounded()))
        let y = UInt16(clamping: Int(((loc.y - bounds.minY) / bounds.height * 65535).rounded()))
        if let p = lastPos, p.2 == inside, !inside || (p.0 == x && p.1 == y) {
            // unchanged
        } else {
            lastPos = (x, y, inside)
            send(Frame(.cursorPos, payload: CursorPayload.position(x: x, y: y, visible: inside)))
            posSent += 1
        }
        if now &- lastReport > 5_000_000 {
            lastReport = now
            if posSent > 0 || imagesSent > 0 { logDebug("cursor", "sent \(posSent) positions, \(imagesSent) images (inside=\(inside))") }
            posSent = 0; imagesSent = 0
        }
        // Cursor shape (arrow, I-beam, resize…): check ~8×/s while the cursor is on this display.
        if inside && now &- lastImageCheck > 120_000 {
            lastImageCheck = now
            DispatchQueue.main.async { [weak self] in self?.checkImage() }
        }
    }

    /// Main thread (AppKit).
    private func checkImage() {
        guard let cursor = NSCursor.currentSystem else { return }
        let img = cursor.image
        let size = img.size
        guard size.width >= 1, size.height >= 1, size.width <= 256, size.height <= 256 else { return }
        // Render at 2× so it stays sharp on the tablet's dense panel.
        let pw = Int(size.width * 2), ph = Int(size.height * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let payload = CursorPayload.image(widthPt: Int(size.width.rounded()), heightPt: Int(size.height.rounded()),
                                          hotX: Int(cursor.hotSpot.x.rounded()), hotY: Int(cursor.hotSpot.y.rounded()), png: png)
        queue.async {
            guard payload != self.lastImage, payload.count < WireProtocol.maxControlFrame - 16 else { return }
            self.lastImage = payload
            self.lock.lock(); let send = self.send; self.lock.unlock()
            send?(Frame(.cursorImage, payload: payload))
            self.imagesSent += 1
        }
    }
}
