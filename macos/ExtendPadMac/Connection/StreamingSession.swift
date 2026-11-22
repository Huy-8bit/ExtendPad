import Foundation
import CoreVideo
import IOSurface

/// A captured frame we hold on to. ScreenCaptureKit recycles its IOSurfaces based on the IOSurface
/// *use count*, not on CVPixelBuffer retain counts — without this, WindowServer can draw the next
/// screen image into a surface while VideoToolbox is still encoding it, producing torn frames with
/// wrong colours that then stick on static parts of the screen.
final class HeldFrame {
    let pixelBuffer: CVPixelBuffer
    let captureMicros: UInt64
    private let surface: IOSurfaceRef?
    init(_ pb: CVPixelBuffer, captureMicros: UInt64) {
        pixelBuffer = pb
        self.captureMicros = captureMicros
        surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue()
        if let surface { IOSurfaceIncrementUseCount(surface) }
    }
    deinit { if let surface { IOSurfaceDecrementUseCount(surface) } }
}

public struct SessionStats: Equatable {
    public var captureFps: Double = 0
    public var encodedFps: Double = 0
    public var renderedFps: Double = 0
    public var bitrateKbps: Double = 0
    public var targetBitrateKbps: Int = 0
    public var droppedFrames: Int = 0
    public var encodeMs: Double = 0
    public var latencyMs: Double = 0
    public var rttMs: Double = 0
    public var tabletDecodeMs: Double = 0
    public var tabletDecoderDrops: Int = 0
    public var keyframes: Int = 0
    /// Stage timings (median, ms): capture→encoder output, encoder output→tablet ack.
    public var captureToEncodedMs: Double = 0
    public var sendToAckMs: Double = 0
    public var encoderDrops: Int = 0
    public var videoConnected = false
    public var paused = false
    public init() {}
}

/// One authenticated tablet: control channel, optional video channel, and the encode pipeline.
/// All pipeline state lives on `pipelineQueue`.
public final class StreamingSession: @unchecked Sendable {
    public let id: String
    public let hello: ClientHello
    public let control: FramedConnection
    public let startedAt = Date()
    /// Set when the tablet ended the session itself (user tapped Disconnect, app left the foreground…).
    public private(set) var endedByTablet = false
    static let trace = ProcessInfo.processInfo.environment["EXTENDPAD_TRACE"] == "1"

    private let pipelineQueue = DispatchQueue(label: "extendpad.pipeline", qos: .userInteractive)
    /// VideoToolbox's low-latency encoder encodes synchronously inside EncodeFrame; keep that off
    /// the state queue so acks/heartbeats are never stuck behind an encode.
    private let encodeQueue = DispatchQueue(label: "extendpad.encode", qos: .userInteractive)

    // Single-slot hand-off from capture (guarded by slotLock). Capture never queues more than one
    // frame: a newer frame replaces an unencoded older one (newest-frame-wins).
    private let slotLock = NSLock()
    private var slot: HeldFrame?
    private var latestCaptured: HeldFrame?
    /// Frames inside VideoToolbox, kept (and marked in use) until their output arrives.
    private var inEncoder: [UInt32: HeldFrame] = [:]   // pipelineQueue
    private var encoderDrops = 0
    private var lastResyncMarker: UInt64 = 0
    private var lastNewFrameMicros: UInt64 = 0
    private var drainScheduled = false
    private var capturedCounter = 0
    private var replacedCounter = 0
    private var outstandingEncodes = 0     // pipelineQueue
    private var video: FramedConnection?
    private var encoder: H264Encoder?
    private var flow = FlowController(targetBitrate: 8_000_000)
    private var sentParamSets: Data?
    private var forceKeyframe = true
    private var nextFrameId: UInt32 = 1
    private var idleRefreshDone = true
    private var idleRefreshMarker: UInt64 = 0
    private var paused = false
    private var timer: DispatchSourceTimer?
    private var pingId: UInt64 = 0
    private var ended = false

    // Stats (pipelineQueue)
    private var encodedThisSecond = 0
    private var renderedThisSecond = 0
    private var bytesThisSecond = 0
    private var encodeMicrosSum: UInt64 = 0
    private var latencySamples: [Double] = []
    private var c2eSamples: [Double] = []
    private var s2aSamples: [Double] = []
    private var rttMs: Double = 0
    private var totalDropped = 0
    private var keyframes = 0
    private var lastTabletStats: [String: Any] = [:]
    private var statsSnapshot = SessionStats()
    private var lastTick = MonoClock.nowMicros()

    /// Main-queue callbacks.
    public var onEnded: ((StreamingSession, String) -> Void)?
    public var onPointer: ((PointerEvent) -> Void)?
    public var onSettingsRequest: (([String: Any]) -> Void)?

    public init(id: String, hello: ClientHello, control: FramedConnection) {
        self.id = id
        self.hello = hello
        self.control = control
    }

    public func start() {
        control.adopt(onFrame: { [weak self] f in self?.handleControl(f) },
                      onClose: { [weak self] reason in self?.end(reason: reason ?? "control channel closed") })
        let t = DispatchSource.makeTimerSource(queue: pipelineQueue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(10))
        var ticks = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            ticks += 1
            self.housekeeping()
            if ticks % 10 == 0 { self.secondTick() }
        }
        timer = t
        t.resume()
    }

    // MARK: - Configuration

    /// (Re)configures the encoder. Recreates it only when size/profile changed.
    public func configureEncoder(_ cfg: EncoderConfig, completion: ((String?) -> Void)? = nil) {
        pipelineQueue.async {
            self.flow.retarget(cfg.bitrate)
            if let e = self.encoder, e.config.width == cfg.width, e.config.height == cfg.height,
               e.config.highProfile == cfg.highProfile, e.config.fps == cfg.fps,
               e.config.prioritizeSpeed == cfg.prioritizeSpeed, e.config.maxFrameQP == cfg.maxFrameQP {
                e.setBitrate(self.flow.currentBitrate)
                DispatchQueue.main.async { completion?(nil) }
                return
            }
            self.encoder?.invalidate()
            self.encoder = nil
            do {
                var c = cfg
                c.bitrate = self.flow.currentBitrate
                let e = try H264Encoder(config: c)
                e.onComplete = { [weak self] tag, f in
                    if Self.trace, let f { logDebug("trace", "f\(tag) cap→vtOut \(MonoClock.nowMicros() &- f.captureMicros)us enc \(f.encodeMicros)us") }
                    guard let self else { return }
                    self.pipelineQueue.async {
                        self.outstandingEncodes = max(0, self.outstandingEncodes - 1)
                        self.inEncoder.removeValue(forKey: tag)
                        if let f {
                            self.didEncode(f)
                        } else {
                            // The encoder dropped this frame: make sure the newest screen still gets out.
                            self.encoderDrops += 1
                            self.requeueLatest()
                        }
                        self.drain()
                    }
                }
                e.onError = { msg in logWarn("encoder", msg) }
                self.encoder = e
                self.forceKeyframe = true
                self.sentParamSets = nil
                self.slotLock.lock(); self.slot = nil; self.latestCaptured = nil; self.slotLock.unlock() // old-size buffers are useless now
                self.outstandingEncodes = 0
                self.inEncoder.removeAll()
                self.flow.resetWindow()
                DispatchQueue.main.async { completion?(nil) }
            } catch {
                logError("encoder", "\(error)")
                DispatchQueue.main.async { completion?("\(error)") }
            }
        }
    }

    public var encoderIsHardware: Bool { pipelineQueue.sync { encoder?.isHardware ?? false } }

    public func sendStreamConfig(_ json: [String: Any]) { control.send(Frame.json(.streamConfig, json)) }

    public func sendError(code: String, message: String) {
        control.send(Frame.json(.error, ["code": code, "message": message]))
    }

    public func attachVideo(_ conn: FramedConnection) {
        conn.adopt(onFrame: { _ in /* tablet sends nothing on video */ },
                   onClose: { [weak self, weak conn] reason in
            guard let self, let conn else { return }
            self.pipelineQueue.async {
                if self.video === conn {
                    logInfo("session", "video channel closed: \(reason ?? "-")")
                    self.video = nil
                }
            }
        })
        pipelineQueue.async {
            self.video?.close(reason: "replaced by new video channel")
            self.video = conn
            self.sentParamSets = nil
            self.forceKeyframe = true
            self.flow.resetWindow()
            logInfo("session", "video channel attached")
            // A static screen produces no new captures: re-send what we have right away.
            self.requeueLatest()
            self.drain()
        }
    }

    // MARK: - Frames from capture (any queue)

    public func submit(_ pb: CVPixelBuffer, captureMicros: UInt64) {
        let held = HeldFrame(pb, captureMicros: captureMicros)
        slotLock.lock()
        if slot != nil { replacedCounter += 1 }
        slot = held
        latestCaptured = held
        lastNewFrameMicros = MonoClock.nowMicros()
        capturedCounter += 1
        let schedule = !drainScheduled
        drainScheduled = true
        slotLock.unlock()
        // At most one drain block is ever queued, however fast capture runs.
        if schedule {
            pipelineQueue.async {
                self.slotLock.lock(); self.drainScheduled = false; self.slotLock.unlock()
                self.drain()
            }
        }
    }

    /// Puts the newest captured frame back into the slot (static screen after reconnect/keyframe request).
    private func requeueLatest() {
        slotLock.lock()
        if slot == nil, let l = latestCaptured { slot = l }
        slotLock.unlock()
    }

    private func canEncodeNow() -> Bool {
        guard encoder != nil, let video, !paused, !ended, !video.isClosed else { return false }
        return flow.canEncode(now: MonoClock.nowMicros(), encoderInFlight: outstandingEncodes, queuedSendBytes: video.pendingSendBytes)
    }

    private func drain() {
        guard canEncodeNow() else { return }
        slotLock.lock()
        let pending = slot
        slot = nil
        slotLock.unlock()
        guard let pending else { return }
        encode(pending, captureMicros: pending.captureMicros, idle: false)
    }

    private func encode(_ frame: HeldFrame, captureMicros: UInt64, idle: Bool) {
        guard let encoder else { return }
        let pb = frame.pixelBuffer
        // Frames captured at an old size during reconfiguration are discarded.
        guard CVPixelBufferGetWidth(pb) == encoder.config.width, CVPixelBufferGetHeight(pb) == encoder.config.height else { return }
        let id = nextFrameId
        nextFrameId &+= 1
        if nextFrameId == 0 { nextFrameId = 1 }
        let key = forceKeyframe
        forceKeyframe = false
        outstandingEncodes += 1
        inEncoder[id] = frame
        encodeQueue.async { [weak self] in
            let t2 = MonoClock.nowMicros()
            let ok = encoder.encode(pb, tag: id, ptsMicros: t2, captureMicros: captureMicros, forceKeyframe: key, idleRefresh: idle)
            if Self.trace { logDebug("trace", "f\(id) cap→encCall \(t2 &- captureMicros)us encCall \(MonoClock.nowMicros() &- t2)us") }
            if !ok {
                self?.pipelineQueue.async {
                    self?.outstandingEncodes = max(0, (self?.outstandingEncodes ?? 1) - 1)
                    self?.inEncoder.removeValue(forKey: id)
                    self?.forceKeyframe = true
                }
            }
        }
    }

    private func didEncode(_ f: EncodedFrame) {
        guard let video, !video.isClosed else { forceKeyframe = true; return }
        if f.parameterSets != sentParamSets {
            guard f.isKeyframe else { forceKeyframe = true; return } // decoder can't start on a P-frame
            guard let enc = encoder else { return }
            let payload = VideoPayload.config(width: enc.config.width, height: enc.config.height,
                                              profileIdc: f.profileIdc, levelIdc: f.levelIdc, annexB: f.parameterSets)
            video.send(Frame(.videoConfig, payload: payload))
            sentParamSets = f.parameterSets
        } else if sentParamSets == nil {
            forceKeyframe = true; return
        }
        let payload = VideoPayload.frame(frameId: f.tag, keyframe: f.isKeyframe, idleRefresh: f.idleRefresh,
                                         ptsMicros: f.ptsMicros, captureMicros: f.captureMicros, annexB: f.annexB)
        let now = MonoClock.nowMicros()
        video.send(Frame(.videoFrame, payload: payload)) { [weak self] _ in
            self?.pipelineQueue.async { self?.drain() }
        }
        flow.didSend(frameId: f.tag, now: now, captureMicros: f.captureMicros)
        if !f.idleRefresh { c2eSamples.append(Double(now &- f.captureMicros) / 1000) }
        encodedThisSecond += 1
        bytesThisSecond += payload.count + WireProtocol.headerSize
        encodeMicrosSum += f.encodeMicros
        if f.isKeyframe { keyframes += 1 }
    }

    // MARK: - Control channel (connection queue)

    private func handleControl(_ f: Frame) {
        switch f.messageType {
        case .ping:
            if let p = PingPayload(f.payload) {
                control.send(Frame(.pong, payload: PongPayload(id: p.id, echoedMicros: p.senderMicros,
                                                               responderMicros: MonoClock.nowMicros()).encoded()))
            }
        case .pong:
            if let p = PongPayload(f.payload) {
                let rtt = Double(MonoClock.nowMicros() &- p.echoedMicros) / 1000
                pipelineQueue.async { self.rttMs = self.rttMs == 0 ? rtt : self.rttMs * 0.8 + rtt * 0.2 }
            }
        case .frameAck:
            guard let a = FrameAckPayload(f.payload) else { return }
            pipelineQueue.async {
                self.renderedThisSecond += 1
                if let hit = self.flow.ack(frameId: a.frameId) {
                    // capture → rendered-on-tablet, minus the ack's return trip (≈ RTT/2).
                    let ms = Double(MonoClock.nowMicros() &- hit.captureMicros) / 1000 - self.rttMs / 2
                    if ms > 0 && ms < 5000 { self.latencySamples.append(ms) }
                    self.s2aSamples.append(Double(MonoClock.nowMicros() &- hit.sentMicros) / 1000)
                }
                self.drain()
            }
        case .keyframeRequest:
            pipelineQueue.async {
                logInfo("session", "tablet requested a keyframe")
                self.forceKeyframe = true
                self.flow.resetWindow()
                self.requeueLatest()
                self.drain()
            }
        case .streamPause:
            pipelineQueue.async { logInfo("session", "tablet paused stream"); self.paused = true; self.flow.resetWindow() }
        case .streamResume:
            pipelineQueue.async {
                logInfo("session", "tablet resumed stream")
                self.paused = false
                self.forceKeyframe = true
                self.flow.resetWindow()
                self.requeueLatest()
                self.drain()
            }
        case .stats:
            if let j = f.jsonObject() { pipelineQueue.async { self.lastTabletStats = j } }
        case .inputPointer:
            guard let e = PointerEvent(f.payload) else { return }
            DispatchQueue.main.async { self.onPointer?(e) }
        case .settingsRequest:
            if let j = f.jsonObject() { DispatchQueue.main.async { self.onSettingsRequest?(j) } }
        case .error:
            logWarn("session", "tablet error: \(f.jsonObject() ?? [:])")
        case .bye:
            endedByTablet = true
            end(reason: "tablet disconnected (\((f.jsonObject()?["reason"] as? String) ?? "bye"))")
        default:
            break // unknown types are ignored for forward compatibility
        }
    }

    // MARK: - Timers (pipelineQueue)

    private func housekeeping() {
        let now = MonoClock.nowMicros()
        if flow.checkStall(now: now) {
            logWarn("session", "no frame acks for 1.5 s — resetting window and forcing a keyframe")
            forceKeyframe = true
            requeueLatest()
        }
        // Idle refresh: once the screen has been still for 300 ms, re-encode the last frame once so
        // the encoder can refine it (sharper text) — then stay silent until something changes.
        slotLock.lock()
        let latest = latestCaptured, lastNew = lastNewFrameMicros, slotEmpty = slot == nil
        slotLock.unlock()
        if lastNew != idleRefreshMarker { idleRefreshDone = false }
        if !idleRefreshDone, slotEmpty, let latest, now &- lastNew > 300_000, canEncodeNow() {
            idleRefreshDone = true
            idleRefreshMarker = lastNew
            encode(latest, captureMicros: now, idle: true)
        }
        // Self-healing: once the screen has been still for 1 s after changes, send the current
        // screen once more as a full keyframe. Whatever went wrong before (a dropped frame, a decoder
        // glitch) is then repaired on static content instead of staying visible.
        if idleRefreshDone, lastResyncMarker != lastNew, slotEmpty, let latest, now &- lastNew > 1_000_000, canEncodeNow() {
            lastResyncMarker = lastNew
            forceKeyframe = true
            encode(latest, captureMicros: now, idle: true)
        }
        drain()
    }

    private func secondTick() {
        let now = MonoClock.nowMicros()
        let dt = max(Double(now &- lastTick) / 1_000_000, 0.001)
        lastTick = now
        // Liveness: the tablet pings every second.
        if now &- control.lastReceiveMicros > 5_000_000 {
            end(reason: "tablet stopped responding (heartbeat timeout)")
            return
        }
        pingId += 1
        control.send(Frame(.ping, payload: PingPayload(id: pingId, senderMicros: now).encoded()))

        slotLock.lock()
        let captured = capturedCounter, replaced = replacedCounter
        capturedCounter = 0; replacedCounter = 0
        slotLock.unlock()
        for _ in 0..<replaced { flow.recordDrop() }
        totalDropped += replaced
        // Network share of the ack time = send→ack minus the tablet's own receive→render time.
        let tabletMs = (lastTabletStats["decodeMs"] as? Double) ?? 0
        let s2a = s2aSamples.isEmpty ? 0 : s2aSamples.sorted()[s2aSamples.count / 2]
        let frameMs = 1000.0 / Double(max(encoder?.config.fps ?? 60, 1))
        let networkMs = max(0, s2a - tabletMs)
        let congested = networkMs > max(30, 2 * frameMs) || (video?.pendingSendBytes ?? 0) > 512 * 1024
        if let newRate = flow.tick(framesWanted: captured, congested: congested) {
            encoder?.setBitrate(newRate)
            logDebug("session", "adaptive bitrate → \(newRate / 1000) kbps")
        }
        var s = SessionStats()
        s.captureFps = Double(captured) / dt
        s.encodedFps = Double(encodedThisSecond) / dt
        s.renderedFps = Double(renderedThisSecond) / dt
        s.bitrateKbps = Double(bytesThisSecond * 8) / dt / 1000
        s.targetBitrateKbps = flow.currentBitrate / 1000
        s.droppedFrames = totalDropped
        s.encodeMs = encodedThisSecond > 0 ? Double(encodeMicrosSum) / Double(encodedThisSecond) / 1000 : 0
        if !latencySamples.isEmpty {
            let sorted = latencySamples.sorted()
            s.latencyMs = sorted[sorted.count / 2]
        } else { s.latencyMs = statsSnapshot.latencyMs }
        s.rttMs = rttMs
        func median(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
        s.captureToEncodedMs = median(c2eSamples)
        s.sendToAckMs = median(s2aSamples)
        s.tabletDecodeMs = (lastTabletStats["decodeMs"] as? Double) ?? 0
        s.tabletDecoderDrops = (lastTabletStats["droppedFrames"] as? Int) ?? 0
        s.keyframes = keyframes
        s.encoderDrops = encoderDrops
        s.videoConnected = video != nil
        s.paused = paused
        statsSnapshot = s
        encodedThisSecond = 0; renderedThisSecond = 0; bytesThisSecond = 0
        encodeMicrosSum = 0; latencySamples.removeAll(keepingCapacity: true)
        c2eSamples.removeAll(keepingCapacity: true); s2aSamples.removeAll(keepingCapacity: true)
    }

    public var stats: SessionStats { pipelineQueue.sync { statsSnapshot } }

    // MARK: - Teardown

    public func end(reason: String, sendBye: Bool = false) {
        pipelineQueue.async {
            guard !self.ended else { return }
            self.ended = true
            logInfo("session", "session \(self.id.prefix(6)) ended: \(reason)")
            self.timer?.cancel(); self.timer = nil
            if sendBye {
                self.control.send(Frame.json(.bye, ["reason": reason])) { _ in self.control.close(reason: "bye") }
            } else {
                self.control.close(reason: reason)
            }
            self.video?.close(reason: reason)
            self.video = nil
            self.encoder?.invalidate()
            self.encoder = nil
            self.slotLock.lock(); self.slot = nil; self.latestCaptured = nil; self.slotLock.unlock()
            self.inEncoder.removeAll()
            DispatchQueue.main.async { self.onEnded?(self, reason) }
        }
    }
}
