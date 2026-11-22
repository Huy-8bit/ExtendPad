import Foundation
import AppKit
import Network

/// `ExtendPad --selftest [seconds] [--preset native|comfortable|large|performance] [--quality ...] [--dump file.h264]`
///
/// Runs the *real* Mac pipeline end to end without a tablet:
///   virtual display → ScreenCaptureKit → VideoToolbox → protocol server (127.0.0.1)
/// with an in-process test client that performs the HMAC handshake on both channels,
/// receives VIDEO_CONFIG/VIDEO_FRAME, validates the Annex-B stream and acks frames like
/// the Android app does. An animated window is placed on the virtual display so there is
/// real content to capture. Prints a JSON report and exits non-zero on failure.
public enum SelfTest {
    public static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var seconds = 8.0
        var settings = EngineSettings()
        settings.autoLaunchTabletApp = false
        settings.autoConnectOnLaunch = false
        settings.displayGraceSeconds = 0
        var dumpPath: String?
        var args = arguments.dropFirst()
        while let a = args.popFirst() {
            switch a {
            case "--selftest": if let n = args.first, let v = Double(n) { seconds = v; args.removeFirst() }
            case "--preset": if let v = args.popFirst(), let p = DisplayPreset(rawValue: v) { settings.preset = p }
            case "--quality": if let v = args.popFirst(), let q = StreamQuality(rawValue: v) { settings.quality = q }
            case "--mirror": settings.mode = .mirror
            case "--dump": dumpPath = args.popFirst()
            default: break
            }
        }
        let runner = Runner(settings: settings, seconds: seconds, dumpPath: dumpPath)
        DispatchQueue.main.async { runner.begin() }
        app.run()
        exit(0)
    }

    final class Runner {
        let engine: ExtendPadEngine
        let seconds: Double
        let dumpPath: String?
        let port: UInt16 = 27_190
        var client: TestClient?
        var window: NSWindow?
        var animTimer: Timer?
        var report: [String: Any] = [:]
        var failures: [String] = []
        var timeline: [[String: Any]] = []

        init(settings: EngineSettings, seconds: Double, dumpPath: String?) {
            engine = ExtendPadEngine(settings: settings, port: 27_190)
            self.seconds = seconds
            self.dumpPath = dumpPath
        }

        func begin() {
            report["macos"] = ProcessInfo.processInfo.operatingSystemVersionString
            report["arch"] = ExtendPadEngine.machineArch()
            report["virtualDisplayAPI"] = VirtualDisplayManager.isSupported ? "available" : VirtualDisplayManager.unsupportedReason
            report["screenRecordingPermission"] = ScreenCaptureEngine.hasPermission()
            report["preset"] = engine.settings.preset.rawValue
            report["quality"] = engine.settings.quality.rawValue
            report["mode"] = engine.settings.mode.rawValue
            engine.start()
            let c = TestClient(port: port, token: engine.pairingToken, dumpPath: dumpPath)
            client = c
            c.onConfig = { [weak self] w, h in DispatchQueue.main.async { self?.placeAnimatedWindow() ; _ = (w, h) } }
            c.start()
            var tick = 0
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                tick += 1
                let s = self.engine.status.stats
                self.timeline.append(["t": tick, "fps": self.r1(s.encodedFps), "acked": self.r1(s.renderedFps), "encMs": self.r1(s.encodeMs),
                                      "c2eMs": self.r1(s.captureToEncodedMs), "s2aMs": self.r1(s.sendToAckMs),
                                      "latMs": self.r1(s.latencyMs), "kbps": Int(s.bitrateKbps)])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.finish() }
        }

        /// An animated window on the virtual display gives ScreenCaptureKit real changes to deliver.
        func placeAnimatedWindow() {
            guard window == nil, engine.status.displayActive else { return }
            let id = engine.status.displayID
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }) else { failures.append("NSScreen for virtual display not found"); return }
            report["virtualScreenFrame"] = "\(Int(screen.frame.width))x\(Int(screen.frame.height)) at (\(Int(screen.frame.minX)),\(Int(screen.frame.minY))) scale \(screen.backingScaleFactor)"
            let rect = screen.visibleFrame.insetBy(dx: 40, dy: 40)
            let w = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
            w.title = "ExtendPad self-test"
            w.setFrame(rect, display: true)
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedSystemFont(ofSize: 28, weight: .regular)
            label.frame = NSRect(x: 20, y: 20, width: rect.width - 40, height: rect.height - 80)
            label.maximumNumberOfLines = 0
            w.contentView?.addSubview(label)
            w.orderFrontRegardless()
            window = w
            var n = 0
            animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
                n += 1
                let hue = CGFloat(n % 360) / 360
                w.contentView?.wantsLayer = true
                w.contentView?.layer?.backgroundColor = NSColor(hue: hue, saturation: 0.25, brightness: 0.95, alpha: 1).cgColor
                label.stringValue = "ExtendPad self-test frame \(n)\nfunc hello() { print(\"text clarity check 0123456789\") }\n" +
                    String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 4)
            }
        }

        func finish() {
            animTimer?.invalidate()
            let st = engine.status
            report["phase"] = "\(st.phase)"
            report["displayCreated"] = st.displayActive || st.plan != nil
            report["displayID"] = st.displayID
            if let p = st.plan {
                report["plan"] = ["logical": "\(p.logicalWidth)x\(p.logicalHeight)", "pixels": "\(p.pixelWidth)x\(p.pixelHeight)",
                                  "hiDPI": p.hiDPI, "stream": "\(p.streamWidth)x\(p.streamHeight)", "fps": p.fps, "bitrateKbps": p.bitrate / 1000]
            }
            if st.displayActive {
                let b = CGDisplayBounds(st.displayID)
                report["displayBoundsPoints"] = "\(Int(b.width))x\(Int(b.height)) at (\(Int(b.minX)),\(Int(b.minY)))"
                if let m = CGDisplayCopyDisplayMode(st.displayID) {
                    report["activeMode"] = "\(m.width)x\(m.height) px \(m.pixelWidth)x\(m.pixelHeight)"
                }
            }
            report["encoderHardware"] = st.encoderHardware
            let s = st.stats
            report["engineStats"] = ["captureFps": r1(s.captureFps), "encodedFps": r1(s.encodedFps), "ackedFps": r1(s.renderedFps),
                                     "bitrateKbps": Int(s.bitrateKbps), "encodeMs": r1(s.encodeMs), "latencyMs": r1(s.latencyMs),
                                     "rttMs": r1(s.rttMs), "captureToEncodedMs": r1(s.captureToEncodedMs), "sendToAckMs": r1(s.sendToAckMs), "droppedBeforeEncode": s.droppedFrames, "keyframes": s.keyframes]
            if let c = client { report["client"] = c.summary(); failures += c.failures }
            if !st.displayActive && engine.settings.mode == .extend { failures.append("virtual display not active") }
            if (client?.framesReceived ?? 0) < 5 { failures.append("fewer than 5 frames received") }
            report["timeline"] = timeline
            report["result"] = failures.isEmpty ? "PASS" : "FAIL"
            report["failures"] = failures
            engine.stop()
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            exit(failures.isEmpty ? 0 : 1)
        }

        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    }

    /// Minimal protocol client mirroring the Android implementation.
    final class TestClient {
        let port: UInt16
        let token: String
        let dumpHandle: FileHandle?
        var control: FramedConnection?
        var video: FramedConnection?
        var sessionId: String?
        var failures: [String] = []
        private var live: [FramedConnection] = []   // keep connections alive during the handshake
        var onConfig: ((Int, Int) -> Void)?
        private let lock = NSLock()
        private(set) var framesReceived = 0
        private var keyframes = 0
        private var configs = 0
        private var bytes = 0
        private var firstFrameAt: Date?
        private var lastFrameAt: Date?
        private var width = 0, height = 0
        private var gotStreamConfig = false
        private var badNal = 0
        private var idleRefreshes = 0
        private var handshakeMs: Double = 0
        private let started = Date()

        init(port: UInt16, token: String, dumpPath: String?) {
            self.port = port; self.token = token
            if let p = dumpPath { FileManager.default.createFile(atPath: p, contents: nil); dumpHandle = FileHandle(forWritingAtPath: p) }
            else { dumpHandle = nil }
        }

        func start() { connect(channel: "control") }

        private func connect(channel: String) {
            let nw = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let conn = FramedConnection(connection: nw, maxFrame: channel == "video" ? WireProtocol.maxVideoFrame : WireProtocol.maxControlFrame,
                                        label: "test-\(channel)")
            let nonce = Auth.randomHex(bytes: 16)
            var hello: [String: Any] = ["magic": WireProtocol.magic, "protocol": WireProtocol.version, "channel": channel,
                                        "clientNonce": nonce, "appVersion": "selftest"]
            if channel == "control" {
                hello["device"] = ["manufacturer": "ExtendPad", "model": "SelfTest", "sdk": 31, "release": "12"]
                hello["display"] = ["widthPx": 2000, "heightPx": 1200, "densityDpi": 240, "xdpi": 224.0, "refreshHz": 60.0]
                hello["decoder"] = ["name": "selftest", "hardware": true, "lowLatency": true, "maxWidth": 4096, "maxHeight": 4096,
                                    "highProfile": true, "maxFpsNative": 60]
            } else {
                hello["sessionId"] = sessionId ?? ""
            }
            live.append(conn)
            var serverNonce = ""
            var accepted = false
            conn.onClose = { [weak self] reason in
                if !accepted { self?.failures.append("\(channel) closed during handshake: \(reason ?? "-")") }
            }
            conn.onFrame = { [weak self, weak conn] f in
                guard let self, let conn else { return }
                switch f.messageType {
                case .challenge:
                    serverNonce = (f.jsonObject()?["serverNonce"] as? String) ?? ""
                    let mac = Auth.hmacHex(tokenHex: self.token, role: "client", channel: channel, clientNonce: nonce, serverNonce: serverNonce) ?? ""
                    conn.send(Frame.json(.auth, ["mac": mac]))
                case .accept:
                    let j = f.jsonObject() ?? [:]
                    let expected = Auth.hmacHex(tokenHex: self.token, role: "server", channel: channel, clientNonce: nonce, serverNonce: serverNonce)
                    if (j["serverProof"] as? String) != expected { self.failures.append("server proof mismatch on \(channel)") }
                    accepted = true
                    if channel == "control" {
                        self.handshakeMs = Date().timeIntervalSince(self.started) * 1000
                        self.sessionId = j["sessionId"] as? String
                        self.control = conn
                        self.connect(channel: "video")
                    } else { self.video = conn }
                case .reject:
                    self.failures.append("\(channel) rejected: \(f.jsonObject() ?? [:])")
                case .streamConfig:
                    self.gotStreamConfig = true
                case .ping:
                    if let p = PingPayload(f.payload) {
                        conn.send(Frame(.pong, payload: PongPayload(id: p.id, echoedMicros: p.senderMicros, responderMicros: MonoClock.nowMicros()).encoded()))
                    }
                case .videoConfig:
                    self.handleConfig(f.payload)
                case .videoFrame:
                    self.handleFrame(f.payload)
                case .error:
                    self.failures.append("server error: \(f.jsonObject() ?? [:])")
                default: break
                }
            }
            conn.start()
            conn.send(Frame.json(.hello, hello))
            // Heartbeat like the tablet.
            if channel == "control" {
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak conn] t in
                    guard let conn, !conn.isClosed else { t.invalidate(); return }
                    conn.send(Frame(.ping, payload: PingPayload(id: 1, senderMicros: MonoClock.nowMicros()).encoded()))
                }
            }
        }

        private func handleConfig(_ p: Data) {
            guard p.count > 8 else { failures.append("short VIDEO_CONFIG"); return }
            let s = p.startIndex
            lock.lock()
            width = Int(p.readBE16(at: s)); height = Int(p.readBE16(at: s + 2)); configs += 1
            lock.unlock()
            let csd = p.subdata(in: (s + 8)..<p.endIndex)
            let types = SelfTest.nalTypes(csd)
            if !(types.contains(7) && types.contains(8)) { failures.append("VIDEO_CONFIG lacks SPS/PPS: \(types)") }
            try? dumpHandle?.write(contentsOf: csd)
            onConfig?(width, height)
        }

        private func handleFrame(_ p: Data) {
            guard p.count > 21 else { failures.append("short VIDEO_FRAME"); return }
            let s = p.startIndex
            let frameId = p.readBE32(at: s)
            let flags = p[s + 4]
            let au = p.subdata(in: (s + 21)..<p.endIndex)
            let types = SelfTest.nalTypes(au)
            lock.lock()
            framesReceived += 1
            bytes += p.count
            if flags & 1 != 0 { keyframes += 1; if !types.contains(5) { badNal += 1 } }
            if flags & 2 != 0 { idleRefreshes += 1 }
            if types.isEmpty { badNal += 1 }
            if firstFrameAt == nil { firstFrameAt = Date(); if configs == 0 { failures.append("frame before VIDEO_CONFIG") } }
            lastFrameAt = Date()
            lock.unlock()
            try? dumpHandle?.write(contentsOf: au)
            var ack = Data(); ack.appendBE(frameId); ack.appendBE(UInt32(1000))
            control?.send(Frame(.frameAck, payload: ack))
        }

        func summary() -> [String: Any] {
            lock.lock(); defer { lock.unlock() }
            let span = (firstFrameAt != nil && lastFrameAt != nil) ? lastFrameAt!.timeIntervalSince(firstFrameAt!) : 0
            if !gotStreamConfig { failures.append("no STREAM_CONFIG received") }
            if badNal > 0 { failures.append("\(badNal) access units with malformed NAL structure") }
            return ["framesReceived": framesReceived, "keyframes": keyframes, "videoConfigs": configs, "stream": "\(width)x\(height)",
                    "megabytes": Double(bytes) / 1_000_000, "avgFps": span > 0 ? Double(framesReceived - 1) / span : 0,
                    "idleRefreshFrames": idleRefreshes, "handshakeMs": handshakeMs,
                    "firstFrameAfterMs": firstFrameAt.map { $0.timeIntervalSince(started) * 1000 } ?? -1]
        }
    }

    /// NAL unit types in an Annex-B buffer.
    public static func nalTypes(_ d: Data) -> [UInt8] {
        var out: [UInt8] = []
        let b = [UInt8](d)
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0 && b[i + 1] == 0 && (b[i + 2] == 1 || (b[i + 2] == 0 && i + 3 < b.count && b[i + 3] == 1)) {
                let start = b[i + 2] == 1 ? i + 3 : i + 4
                if start < b.count { out.append(b[start] & 0x1f) }
                i = start
            } else { i += 1 }
        }
        return out
    }
}
