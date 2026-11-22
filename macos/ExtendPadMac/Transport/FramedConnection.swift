import Foundation
import Network

/// A length-prefixed message connection on top of an `NWConnection`.
/// Handles partial reads (via `FrameDecoder`), tracks queued send bytes for back-pressure,
/// and records the time of the last received byte for liveness checks.
public final class FramedConnection: @unchecked Sendable {
    public let id = UUID()
    public let maxFrame: Int
    public let queue: DispatchQueue
    private let connection: NWConnection
    private var decoder: FrameDecoder
    private let lock = NSLock()
    private var _pendingSendBytes = 0
    private var _closed = false
    private var _lastReceiveMicros: UInt64 = MonoClock.nowMicros()

    public var onFrame: ((Frame) -> Void)?
    public var onClose: ((String?) -> Void)?
    public var label: String

    public init(connection: NWConnection, maxFrame: Int, label: String) {
        self.connection = connection
        self.maxFrame = maxFrame
        self.decoder = FrameDecoder(maxFrame: maxFrame)
        self.label = label
        self.queue = DispatchQueue(label: "extendpad.conn.\(label)", qos: .userInteractive)
    }

    public var pendingSendBytes: Int { lock.lock(); defer { lock.unlock() }; return _pendingSendBytes }
    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    public var lastReceiveMicros: UInt64 { lock.lock(); defer { lock.unlock() }; return _lastReceiveMicros }

    public var remoteDescription: String { "\(connection.endpoint)" }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receiveLoop()
            case .failed(let err): self.close(reason: "failed: \(err)")
            case .cancelled: self.close(reason: nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// Re-targets callbacks after a handshake handed this connection to a new owner.
    /// Frames that arrive while `onFrame` is nil (between handshake and adoption) are held and flushed here.
    public func adopt(onFrame: @escaping (Frame) -> Void, onClose: @escaping (String?) -> Void) {
        queue.async {
            self.onFrame = onFrame
            self.onClose = onClose
            let held = self.heldFrames
            self.heldFrames.removeAll()
            held.forEach(onFrame)
            if self.isClosed { onClose(self.closeReason) }
        }
    }

    /// Detach callbacks (must be called on `queue`); subsequent frames are held until `adopt`.
    public func detach() { onFrame = nil; onClose = nil }
    private var heldFrames: [Frame] = []
    private var closeReason: String?

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock(); self._lastReceiveMicros = MonoClock.nowMicros(); self.lock.unlock()
                self.decoder.append(data)
                do {
                    while let frame = try self.decoder.next() {
                        if self.isClosed { return }
                        if let cb = self.onFrame { cb(frame) }
                        else if self.heldFrames.count < 256 { self.heldFrames.append(frame) }
                    }
                } catch {
                    self.close(reason: "protocol error: \(error)")
                    return
                }
            }
            if let error { self.close(reason: "receive error: \(error)"); return }
            if isComplete { self.close(reason: "peer closed"); return }
            if !self.isClosed { self.receiveLoop() }
        }
    }

    /// Queues a frame. `completion` runs when the bytes were handed to the kernel.
    public func send(_ frame: Frame, completion: ((Bool) -> Void)? = nil) {
        let data = frame.encoded()
        lock.lock()
        if _closed { lock.unlock(); completion?(false); return }
        _pendingSendBytes += data.count
        lock.unlock()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock(); self._pendingSendBytes -= data.count; self.lock.unlock()
            if let error {
                completion?(false)
                self.close(reason: "send error: \(error)")
            } else {
                completion?(true)
            }
        })
    }

    public func close(reason: String?) {
        lock.lock()
        if _closed { lock.unlock(); return }
        _closed = true
        lock.unlock()
        connection.cancel()
        queue.async { self.closeReason = reason; self.onClose?(reason) }
    }
}
