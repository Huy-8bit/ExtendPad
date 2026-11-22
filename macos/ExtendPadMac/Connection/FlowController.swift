import Foundation

/// Pure flow-control + adaptive-bitrate state machine (no I/O, unit tested).
///
/// Policy: frames are dropped *before* encoding when the pipeline is congested, never after,
/// so the H.264 reference chain stays intact. The newest skipped frame is retained by the caller
/// and encoded as soon as `canEncode` turns true again.
public struct FlowController {
    public struct Unacked { public var frameId: UInt32; public var sentMicros: UInt64; public var captureMicros: UInt64 }

    public var maxUnackedFrames = 6
    public var maxUnackedAgeMicros: UInt64 = 250_000
    public var stallResetMicros: UInt64 = 1_500_000
    public var maxEncoderInFlight = 2   // standard-mode encoder pipelines 2 frames → full 60 fps
    public var maxQueuedSendBytes = 3 * 1024 * 1024

    public private(set) var unacked: [Unacked] = []
    public private(set) var droppedSinceTick = 0
    public private(set) var cleanTicks = 0

    public var targetBitrate: Int
    public private(set) var currentBitrate: Int
    public let minBitrate: Int

    public init(targetBitrate: Int, minBitrate: Int = 1_500_000) {
        self.targetBitrate = targetBitrate
        self.currentBitrate = targetBitrate
        self.minBitrate = minBitrate
    }

    /// New quality target: start right at it (USB has headroom); congestion backs off from there.
    public mutating func retarget(_ bitrate: Int) {
        targetBitrate = bitrate
        currentBitrate = max(min(bitrate, targetBitrate), min(bitrate, minBitrate))
        cleanTicks = 0
    }

    public func canEncode(now: UInt64, encoderInFlight: Int, queuedSendBytes: Int) -> Bool {
        if encoderInFlight >= maxEncoderInFlight { return false }
        if queuedSendBytes > maxQueuedSendBytes { return false }
        if unacked.count >= maxUnackedFrames { return false }
        if let oldest = unacked.first, now &- oldest.sentMicros > maxUnackedAgeMicros { return false }
        return true
    }

    public mutating func recordDrop() { droppedSinceTick += 1 }

    public mutating func didSend(frameId: UInt32, now: UInt64, captureMicros: UInt64) {
        unacked.append(Unacked(frameId: frameId, sentMicros: now, captureMicros: captureMicros))
    }

    /// Acks are cumulative: acking N also retires anything older than N.
    /// Returns the acknowledged frame's capture time (for latency) if it was outstanding.
    public mutating func ack(frameId: UInt32) -> Unacked? {
        guard let idx = unacked.firstIndex(where: { $0.frameId == frameId }) else {
            // Unknown/older id: retire anything that precedes it in sequence space.
            unacked.removeAll { Int32(bitPattern: $0.frameId &- frameId) <= 0 }
            return nil
        }
        let hit = unacked[idx]
        unacked.removeFirst(idx + 1)
        return hit
    }

    /// Returns true when the oldest frame is so old the tablet is presumed stuck (decoder reset,
    /// surface lost…). The window is cleared and the caller must force a keyframe.
    public mutating func checkStall(now: UInt64) -> Bool {
        guard let oldest = unacked.first, now &- oldest.sentMicros > stallResetMicros else { return false }
        unacked.removeAll()
        return true
    }

    public mutating func resetWindow() { unacked.removeAll() }

    /// Called once per second. Returns the new bitrate if it changed.
    /// `framesWanted`: frames the capture produced this second (drops matter only with real demand).
    /// `congested`: evidence that the *network* (not the encoder/decoder) is the bottleneck. Skipped
    /// frames caused by a slow decoder are not helped by a lower bitrate, so they only hold the rate.
    public mutating func tick(framesWanted: Int, congested: Bool = true) -> Int? {
        defer { droppedSinceTick = 0 }
        let old = currentBitrate
        let heavyDrops = droppedSinceTick >= max(3, framesWanted / 5)
        if heavyDrops && !congested { cleanTicks = 0; return nil }
        if heavyDrops {
            cleanTicks = 0
            currentBitrate = max(minBitrate, Int(Double(currentBitrate) * 0.85))
        } else if droppedSinceTick == 0 {
            cleanTicks += 1
            if cleanTicks >= 3 && currentBitrate < targetBitrate {
                currentBitrate = min(targetBitrate, Int(Double(currentBitrate) * 1.05) + 1)
            }
        }
        return currentBitrate != old ? currentBitrate : nil
    }
}
