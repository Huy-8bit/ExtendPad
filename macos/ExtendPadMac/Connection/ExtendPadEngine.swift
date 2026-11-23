import Foundation
import CoreGraphics
import AppKit

public struct EngineSettings: Codable, Equatable {
    public var mode: DisplayMode = .extend
    public var preset: DisplayPreset = .comfortable
    public var quality: StreamQuality = .balanced
    public var customWidth = 1920
    public var customHeight = 1200
    public var fpsLimit = 0                  // 0 = automatic
    public var customBitrateKbps = 0         // 0 = automatic
    public var arrangement: Arrangement = .automatic
    public var autoConnectOnLaunch = true
    public var autoLaunchTabletApp = true
    public var autoReconnect = true
    public var allowTouchInput = false       // explicit opt-in
    public var displayGraceSeconds = 20      // keep the display this long after a disconnect
    public var adbPath = ""
    public var allowEmulator = false         // developer/testing only
    public var showCursor = true
    /// Draw the cursor on the tablet from a 120 Hz position stream instead of inside the video.
    public var localCursor = true
    public init() {}

    /// Tolerant decoding: keys missing from older saved settings keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil ?? def }
        mode = v(.mode, d.mode); preset = v(.preset, d.preset); quality = v(.quality, d.quality)
        customWidth = v(.customWidth, d.customWidth); customHeight = v(.customHeight, d.customHeight)
        fpsLimit = v(.fpsLimit, d.fpsLimit); customBitrateKbps = v(.customBitrateKbps, d.customBitrateKbps)
        arrangement = v(.arrangement, d.arrangement); autoConnectOnLaunch = v(.autoConnectOnLaunch, d.autoConnectOnLaunch)
        autoLaunchTabletApp = v(.autoLaunchTabletApp, d.autoLaunchTabletApp); autoReconnect = v(.autoReconnect, d.autoReconnect)
        allowTouchInput = v(.allowTouchInput, d.allowTouchInput); displayGraceSeconds = v(.displayGraceSeconds, d.displayGraceSeconds)
        adbPath = v(.adbPath, d.adbPath); allowEmulator = v(.allowEmulator, d.allowEmulator); showCursor = v(.showCursor, d.showCursor)
        localCursor = v(.localCursor, d.localCursor)
    }

    public var planRequest: PlanRequest {
        PlanRequest(preset: preset, quality: quality, customWidth: customWidth, customHeight: customHeight,
                    fpsLimit: fpsLimit, customBitrateKbps: customBitrateKbps)
    }
}

public enum ConnectionPhase: Equatable {
    case stopped
    case adbMissing
    case waitingForDevice
    case networkOnly
    case unauthorized
    case deviceOffline
    case tunnelFailed(String)
    case appMissing
    case waitingForTabletApp
    case starting
    case streaming
    case error(String)
}

public struct EngineStatus: Equatable {
    public var phase: ConnectionPhase = .stopped
    public var device = DeviceSnapshot()
    public var tabletName: String?
    public var tabletDecoder: String?
    public var tabletPanel: String?
    public var displayActive = false
    public var displayID: CGDirectDisplayID = 0
    public var plan: DisplayPlan?
    public var streamWidth = 0
    public var streamHeight = 0
    public var targetFps = 0
    public var encoderHardware = false
    public var stats = SessionStats()
    public var sessionStartedAt: Date?
    public var lastError: String?
    public var screenRecordingGranted = false
    public var accessibilityGranted = false
    public var virtualDisplaySupported = VirtualDisplayManager.isSupported
    public var displayRemovalPending = false
    public init() {}
}

/// Main-thread orchestrator for the whole Mac side.
public final class ExtendPadEngine: StreamServerDelegate {
    public static let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

    public private(set) var status = EngineStatus() { didSet { if status != oldValue { onStatus?(status) } } }
    public var onStatus: ((EngineStatus) -> Void)?
    public private(set) var settings: EngineSettings

    private let port: UInt16
    private let token: String
    private let server: StreamServer
    private let monitor: DeviceMonitor
    private let display = VirtualDisplayManager()
    private let capture = ScreenCaptureEngine()
    private let injector = InputInjector()
    private let cursor = CursorTracker()
    private var session: StreamingSession?
    private let sinkLock = NSLock()
    private var sink: StreamingSession?
    private var removeDisplayWork: DispatchWorkItem?
    private var statsTimer: Timer?
    private var running = false
    private var captureRestartAttempts = 0
    private var observers: [NSObjectProtocol] = []
    /// Prevents App Nap / timer coalescing while streaming. Without it macOS throttles this
    /// background menu-bar process after ~5 s and latency jumps from ~10 ms to 150+ ms.
    private var streamingActivity: NSObjectProtocol?

    public init(settings: EngineSettings, port: UInt16 = WireProtocol.defaultPort) {
        self.settings = settings
        self.port = port
        self.token = TokenStore.loadOrCreate()
        let tok = token
        self.server = StreamServer(port: port, serverName: Host.current().localizedName ?? "Mac",
                                   appVersion: Self.appVersion, tokenProvider: { tok })
        self.monitor = DeviceMonitor(port: port)
        server.delegate = self
        monitor.tokenProvider = { tok }
        monitor.onUpdate = { [weak self] snap in self?.deviceChanged(snap) }
        monitor.wantsTabletConnection = { [weak self] in
            guard let self else { return false }
            self.sinkLock.lock(); defer { self.sinkLock.unlock() }
            return self.sink == nil
        }
        applyMonitorSettings()
        capture.onFrame = { [weak self] pb, t in
            guard let self else { return }
            self.sinkLock.lock(); let s = self.sink; self.sinkLock.unlock()
            s?.submit(pb, captureMicros: t)
        }
        capture.onStopped = { [weak self] err in DispatchQueue.main.async { self?.captureStopped(err) } }
        display.onTerminated = { [weak self] in
            DispatchQueue.main.async {
                self?.session?.end(reason: "virtual display terminated by macOS", sendBye: true)
                self?.refreshDisplayStatus()
            }
        }
        refreshPermissions()
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.willSleep()
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.didWake()
        })
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pollStats() }
    }

    deinit { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    public var isRunning: Bool { running }
    public var pairingToken: String { token }

    // MARK: - Public controls

    public func start() {
        guard !running else { return }
        running = true
        status.lastError = nil
        do { try server.start() } catch {
            status.phase = .error("Cannot listen on 127.0.0.1:\(port): \(error)")
            running = false
            return
        }
        monitor.grantLaunches()
        monitor.start()
        status.phase = .waitingForDevice
        logInfo("engine", "service started")
    }

    /// Ends the session, removes tunnels and the virtual display.
    public func stop() {
        guard running else { return }
        running = false
        session?.end(reason: "disconnected on Mac", sendBye: true)
        server.stop()
        monitor.stop()
        cursor.stop()
        Task { await capture.stop() }
        cancelDisplayRemoval()
        display.destroy(reason: "user disconnected")
        refreshDisplayStatus()
        status.phase = .stopped
        status.sessionStartedAt = nil
        logInfo("engine", "service stopped")
    }

    public func update(settings new: EngineSettings) {
        let old = settings
        settings = new
        applyMonitorSettings()
        if old.arrangement != new.arrangement { display.applyArrangement(new.arrangement) }
        if old.allowTouchInput != new.allowTouchInput && new.allowTouchInput {
            status.accessibilityGranted = InputInjector.isTrusted(prompt: true)
        }
        let streamAffecting = old.mode != new.mode || old.preset != new.preset || old.quality != new.quality ||
            old.customWidth != new.customWidth || old.customHeight != new.customHeight || old.fpsLimit != new.fpsLimit ||
            old.customBitrateKbps != new.customBitrateKbps || old.showCursor != new.showCursor ||
            old.localCursor != new.localCursor ||
            old.allowTouchInput != new.allowTouchInput
        if streamAffecting, let s = session { configureStream(for: s) }
    }

    public func reconnectTablet() {
        monitor.grantLaunches()
        if let s = session { s.end(reason: "reconnect requested", sendBye: true) }
        monitor.launchNow()
        monitor.pollNow()
    }

    public func installTabletApp(completion: @escaping (Bool, String) -> Void) {
        guard let apk = Bundle.main.path(forResource: "ExtendPad", ofType: "apk") else {
            completion(false, "ExtendPad.apk is not bundled in this build"); return
        }
        monitor.install(apkPath: apk, completion: completion)
    }

    public var hasBundledAPK: Bool { Bundle.main.path(forResource: "ExtendPad", ofType: "apk") != nil }

    public func refreshPermissions() {
        status.screenRecordingGranted = ScreenCaptureEngine.hasPermission()
        status.accessibilityGranted = InputInjector.isTrusted(prompt: false)
    }

    public func requestScreenRecording() {
        ScreenCaptureEngine.requestPermission()
        refreshPermissions()
    }

    public func requestAccessibility() { status.accessibilityGranted = InputInjector.isTrusted(prompt: true) }

    /// Window recovery: removing the virtual display makes macOS move its windows to the built-in screen.
    public func gatherWindows() {
        cancelDisplayRemoval()
        session?.end(reason: "windows gathered to the Mac screen", sendBye: true)
        display.destroy(reason: "gather windows")
        refreshDisplayStatus()
    }

    // MARK: - StreamServerDelegate

    public func server(_ server: StreamServer, didAcceptControl connection: FramedConnection, hello: ClientHello, sessionId: String) {
        guard running else { connection.close(reason: "service stopped"); return }
        logInfo("engine", "tablet authenticated: \(hello.displayName) Android \(hello.release) (SDK \(hello.sdk)) panel \(hello.displayWidthPx)x\(hello.displayHeightPx)@\(Int(hello.refreshHz))Hz decoder \(hello.decoderName) hw=\(hello.decoderHardware) lowLatency=\(hello.decoderLowLatency) app \(hello.appVersion)")
        if let old = session { old.end(reason: "replaced by a new connection") }
        let s = StreamingSession(id: sessionId, hello: hello, control: connection)
        s.onEnded = { [weak self] sess, reason in self?.sessionEnded(sess, reason: reason) }
        s.onPointer = { [weak self] e in self?.handlePointer(e) }
        s.onSettingsRequest = { [weak self] j in self?.handleSettingsRequest(j) }
        session = s
        sinkLock.lock(); sink = s; sinkLock.unlock()
        if streamingActivity == nil {
            streamingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                reason: "Streaming the ExtendPad display to the tablet")
        }
        s.start()
        status.tabletName = hello.displayName
        status.tabletDecoder = "\(hello.decoderName)\(hello.decoderHardware ? " (HW)" : " (SW)")\(hello.decoderLowLatency ? ", low-latency" : "")"
        status.tabletPanel = "\(hello.displayWidthPx)×\(hello.displayHeightPx) @ \(Int(hello.refreshHz)) Hz, \(hello.densityDpi) dpi"
        status.sessionStartedAt = Date()
        status.phase = .starting
        status.lastError = nil
        captureRestartAttempts = 0
        configureStream(for: s)
    }

    public func server(_ server: StreamServer, didAcceptVideo connection: FramedConnection, sessionId: String) {
        guard let s = session, s.id == sessionId else { connection.close(reason: "stale session"); return }
        s.attachVideo(connection)
    }

    public func server(_ server: StreamServer, isLiveSession sessionId: String) -> Bool { session?.id == sessionId }

    public func serverListenerFailed(_ server: StreamServer, error: String) {
        status.phase = .error("Listener failed: \(error)")
        if running {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.running else { return }
                try? self.server.start()
            }
        }
    }

    // MARK: - Stream setup

    private func tabletInfo(_ h: ClientHello) -> TabletInfo {
        TabletInfo(widthPx: h.displayWidthPx, heightPx: h.displayHeightPx, xdpi: h.xdpi, refreshHz: h.refreshHz,
                   decoderMaxWidth: h.decoderMaxWidth, decoderMaxHeight: h.decoderMaxHeight,
                   decoderHighProfile: h.decoderHighProfile, decoderMaxFpsNative: h.decoderMaxFpsNative)
    }

    private func configureStream(for s: StreamingSession) {
        refreshPermissions()
        guard status.screenRecordingGranted else {
            fail(s, code: "permission", message: "Screen Recording permission is required. Open ExtendPad on the Mac → Settings → Permissions.")
            ScreenCaptureEngine.requestPermission()
            return
        }
        let t = tabletInfo(s.hello)
        var plan = DisplayPlanner.plan(tablet: t, request: settings.planRequest)
        let targetDisplay: CGDirectDisplayID

        switch settings.mode {
        case .extend:
            cancelDisplayRemoval()
            do {
                targetDisplay = try display.ensure(plan, arrangement: settings.arrangement)
            } catch {
                // Never silently fall back to mirroring: report the failure clearly.
                fail(s, code: "virtual_display", message: "\(error)")
                return
            }
        case .mirror:
            targetDisplay = CGMainDisplayID()
            let b = CGDisplayBounds(targetDisplay)
            let mode = CGDisplayCopyDisplayMode(targetDisplay)
            let srcW = mode?.pixelWidth ?? Int(b.width), srcH = mode?.pixelHeight ?? Int(b.height)
            let size = DisplayPlanner.mirrorStreamSize(sourceWidth: srcW, sourceHeight: srcH, tablet: t, quality: settings.quality)
            plan.streamWidth = size.width
            plan.streamHeight = size.height
            plan.logicalWidth = Int(b.width); plan.logicalHeight = Int(b.height)
            plan.pixelWidth = srcW; plan.pixelHeight = srcH
            plan.hiDPI = srcW > Int(b.width)
            plan.bitrate = settings.customBitrateKbps > 0 ? settings.customBitrateKbps * 1000 :
                min(max(Int(Double(size.width * size.height * plan.fps) * (settings.quality == .quality ? 0.17 : 0.10)), 2_000_000), 40_000_000)
            // Mirror does not need a virtual display.
            scheduleDisplayRemoval(after: 0)
        }
        status.plan = plan
        status.streamWidth = plan.streamWidth
        status.streamHeight = plan.streamHeight
        status.targetFps = plan.fps
        refreshDisplayStatus()

        let enc = EncoderConfig(width: plan.streamWidth, height: plan.streamHeight, fps: plan.fps, bitrate: plan.bitrate,
                                highProfile: plan.highProfile, prioritizeSpeed: settings.quality != .quality,
                                maxFrameQP: plan.maxFrameQP)
        let localCursor = settings.showCursor && settings.localCursor
        let captureCfg = CaptureConfig(displayID: targetDisplay, width: plan.streamWidth, height: plan.streamHeight,
                                       fps: plan.fps, showsCursor: settings.showCursor && !localCursor)
        let streamJSON: [String: Any] = [
            "mode": settings.mode.rawValue, "displayName": VirtualDisplayManager.displayName,
            "width": plan.streamWidth, "height": plan.streamHeight,
            "logicalWidth": plan.logicalWidth, "logicalHeight": plan.logicalHeight, "hiDPI": plan.hiDPI,
            "fps": plan.fps, "bitrate": plan.bitrate, "quality": settings.quality.rawValue, "preset": settings.preset.rawValue,
            "inputEnabled": settings.allowTouchInput && status.accessibilityGranted,
            "localCursor": localCursor,
        ]
        s.configureEncoder(enc) { [weak self, weak s] err in
            guard let self, let s, self.session === s else { return }
            if let err { self.fail(s, code: "encoder", message: err); return }
            self.status.encoderHardware = s.encoderIsHardware
            s.sendStreamConfig(streamJSON)
            Task { @MainActor in
                do {
                    if self.capture.isRunning, self.capture.config?.displayID == captureCfg.displayID {
                        try await self.capture.update(captureCfg)
                    } else {
                        try await self.capture.start(captureCfg)
                    }
                    guard self.session === s else { return }
                    self.status.phase = .streaming
                    if localCursor {
                        self.cursor.start(displayID: targetDisplay) { [weak s] f in s?.control.send(f) }
                    } else {
                        self.cursor.stop()
                    }
                } catch {
                    guard self.session === s else { return }
                    if case CaptureError.permissionDenied = error { self.status.screenRecordingGranted = false }
                    self.fail(s, code: "capture", message: "\(error)")
                }
            }
        }
    }

    private func fail(_ s: StreamingSession, code: String, message: String) {
        logError("engine", "\(code): \(message)")
        status.lastError = message
        status.phase = .error(message)
        s.sendError(code: code, message: message)
        s.end(reason: message, sendBye: true)
    }

    private func captureStopped(_ err: String) {
        guard let s = session else { return }
        refreshPermissions()
        if !status.screenRecordingGranted {
            fail(s, code: "permission", message: "Screen Recording permission was revoked.")
            return
        }
        // Display reconfiguration or a transient WindowServer hiccup: try to resume a few times.
        captureRestartAttempts += 1
        if captureRestartAttempts <= 3 {
            logWarn("engine", "capture stopped (\(err)); restarting (attempt \(captureRestartAttempts))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let s = self.session else { return }
                self.configureStream(for: s)
            }
        } else {
            fail(s, code: "capture", message: "Screen capture keeps stopping: \(err)")
        }
    }

    private func sessionEnded(_ s: StreamingSession, reason: String) {
        guard session === s else { return }
        session = nil
        sinkLock.lock(); sink = nil; sinkLock.unlock()
        if let a = streamingActivity { ProcessInfo.processInfo.endActivity(a); streamingActivity = nil }
        injector.releaseAll()
        cursor.stop()
        Task { await capture.stop() }
        status.sessionStartedAt = nil
        status.stats = SessionStats()
        if case .error = status.phase {} else { status.phase = running ? .waitingForTabletApp : .stopped }
        if running {
            if s.endedByTablet {
                // Respect the tablet user's choice: don't reopen the app until replug or Connect on the Mac.
                monitor.suppressLaunches()
            } else if settings.autoReconnect {
                monitor.grantLaunches()
                monitor.pollNow()
            }
        }
        // Keep the display for a grace period so a cable wiggle doesn't reshuffle windows.
        if display.isActive { scheduleDisplayRemoval(after: running ? settings.displayGraceSeconds : 0) }
    }

    private func scheduleDisplayRemoval(after seconds: Int) {
        cancelDisplayRemoval()
        guard display.isActive else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session == nil || self.settings.mode == .mirror else { return }
            self.display.destroy(reason: seconds > 0 ? "tablet gone for \(seconds) s" : "not needed")
            self.status.displayRemovalPending = false
            self.refreshDisplayStatus()
        }
        removeDisplayWork = work
        status.displayRemovalPending = seconds > 0
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func cancelDisplayRemoval() {
        removeDisplayWork?.cancel()
        removeDisplayWork = nil
        status.displayRemovalPending = false
    }

    private func refreshDisplayStatus() {
        status.displayActive = display.isActive
        status.displayID = display.displayID
    }

    // MARK: - Input

    private func handlePointer(_ e: PointerEvent) {
        guard settings.allowTouchInput, session != nil else { return }
        guard status.accessibilityGranted || InputInjector.isTrusted(prompt: false) else { return }
        status.accessibilityGranted = true
        let bounds: CGRect = settings.mode == .extend ? display.bounds : CGDisplayBounds(CGMainDisplayID())
        injector.handle(e, displayBounds: bounds)
    }

    private func handleSettingsRequest(_ j: [String: Any]) {
        var s = settings
        if let q = j["quality"] as? String, let v = StreamQuality(rawValue: q) { s.quality = v }
        if let p = j["preset"] as? String, let v = DisplayPreset(rawValue: p), v != .custom { s.preset = v }
        if s != settings {
            logInfo("engine", "tablet changed settings: quality=\(s.quality.rawValue) preset=\(s.preset.rawValue)")
            update(settings: s)
            onSettingsChangedRemotely?(s)
        }
    }

    public var onSettingsChangedRemotely: ((EngineSettings) -> Void)?

    // MARK: - Devices, sleep/wake, stats

    private func applyMonitorSettings() {
        monitor.userADBPath = settings.adbPath.isEmpty ? nil : settings.adbPath
        monitor.allowEmulator = settings.allowEmulator
        monitor.autoLaunchApp = settings.autoLaunchTabletApp
    }

    private func deviceChanged(_ snap: DeviceSnapshot) {
        let previousSerial = status.device.serial
        status.device = snap
        guard running else { return }
        if session != nil, let prev = previousSerial, snap.adbPath != nil,
           !snap.allDevices.contains(where: { $0.serial == prev && $0.state == .device }),
           snap.phase == .noDevice || snap.phase == .networkOnly || snap.serial != prev {
            // Cable pulled: the adb tunnel is gone; the heartbeat would notice within 5 s, act now.
            session?.end(reason: "USB device disconnected")
        }
        guard session == nil else { return }
        if case .error = status.phase, snap.phase != .noDevice { return }
        switch snap.phase {
        case .adbMissing: status.phase = .adbMissing
        case .adbError(let e): status.phase = .tunnelFailed(e)
        case .noDevice: status.phase = .waitingForDevice
        case .networkOnly: status.phase = .networkOnly
        case .unauthorized: status.phase = .unauthorized
        case .offline, .noPermissions: status.phase = .deviceOffline
        case .tunnelFailed(let e): status.phase = .tunnelFailed(e)
        case .appMissing: status.phase = .appMissing
        case .ready: status.phase = .waitingForTabletApp
        }
    }

    public func clearError() {
        status.lastError = nil
        if case .error = status.phase { status.phase = running ? .waitingForDevice : .stopped }
        deviceChanged(status.device)
    }

    private func willSleep() {
        logInfo("engine", "Mac is going to sleep")
        session?.end(reason: "Mac went to sleep", sendBye: true)
        cancelDisplayRemoval()   // keep the display across sleep so windows stay put
    }

    private func didWake() {
        logInfo("engine", "Mac woke up")
        guard running else { return }
        refreshPermissions()
        monitor.grantLaunches()
        monitor.pollNow()
        if session == nil && display.isActive { scheduleDisplayRemoval(after: max(settings.displayGraceSeconds, 30)) }
    }

    private var statsLogCounter = 0
    private func pollStats() {
        guard let s = session else { return }
        let st = s.stats
        status.stats = st
        statsLogCounter += 1
        if statsLogCounter % 5 == 0 {
            logInfo("stats", String(format: "capture %.1f fps, encoded %.1f, shown on tablet %.1f, %.0f kbps (target %d), encode %.1f ms, capture→encoded %.1f ms, send→ack %.1f ms, est. latency %.1f ms, RTT %.1f ms, skipped %d, encoder drops %d, tablet decode %.1f ms, keyframes %d",
                                          st.captureFps, st.encodedFps, st.renderedFps, st.bitrateKbps, st.targetBitrateKbps, st.encodeMs,
                                          st.captureToEncodedMs, st.sendToAckMs, st.latencyMs, st.rttMs, st.droppedFrames, st.encoderDrops, st.tabletDecodeMs, st.keyframes))
        }
    }

    // MARK: - Diagnostics

    public func diagnosticsReport() -> String {
        var lines: [String] = []
        let pi = ProcessInfo.processInfo
        lines.append("ExtendPad \(Self.appVersion) diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("macOS \(pi.operatingSystemVersionString), arch \(Self.machineArch()), \(pi.activeProcessorCount) cores, \(pi.physicalMemory / 1_073_741_824) GB RAM")
        lines.append("Virtual display API: \(VirtualDisplayManager.isSupported ? "available" : VirtualDisplayManager.unsupportedReason)")
        lines.append("Screen Recording: \(status.screenRecordingGranted ? "granted" : "NOT granted"), Accessibility: \(status.accessibilityGranted ? "granted" : "not granted")")
        lines.append("ADB: \(status.device.adbPath ?? "not found") \(status.device.adbVersion ?? "")")
        lines.append("Phase: \(status.phase)")
        for d in status.device.allDevices {
            lines.append("  device \(d.serial) state=\(d.state.rawValue) model=\(d.model) usb=\(d.usb ?? "-")")
        }
        if !status.device.properties.isEmpty {
            lines.append("Tablet properties:")
            for (k, v) in status.device.properties.sorted(by: { $0.key < $1.key }) { lines.append("  \(k) = \(v)") }
        }
        lines.append("reverse tunnel: \(status.device.reverseActive), app installed: \(status.device.appInstalled)")
        if let n = status.tabletName { lines.append("Tablet: \(n), panel \(status.tabletPanel ?? "?"), decoder \(status.tabletDecoder ?? "?")") }
        lines.append("Display: active=\(status.displayActive) id=\(status.displayID) plan=\(status.plan.map { "\($0.logicalWidth)x\($0.logicalHeight) px \($0.pixelWidth)x\($0.pixelHeight) hiDPI=\($0.hiDPI) stream \($0.streamWidth)x\($0.streamHeight)@\($0.fps) \($0.bitrate / 1000)kbps" } ?? "-")")
        lines.append("Encoder hardware: \(status.encoderHardware)")
        let st = status.stats
        lines.append(String(format: "Stats: capture %.1f fps, encoded %.1f fps, rendered %.1f fps, %.0f kbps (target %d), encode %.1f ms, latency %.1f ms, rtt %.1f ms, drops %d, tablet decode %.1f ms",
                            st.captureFps, st.encodedFps, st.renderedFps, st.bitrateKbps, st.targetBitrateKbps, st.encodeMs, st.latencyMs, st.rttMs, st.droppedFrames, st.tabletDecodeMs))
        lines.append("Online displays:")
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        for id in ids.prefix(Int(n)) {
            let b = CGDisplayBounds(id)
            lines.append("  \(id): \(Int(b.width))x\(Int(b.height)) at (\(Int(b.minX)),\(Int(b.minY)))\(CGDisplayIsMain(id) != 0 ? " main" : "")\(id == display.displayID ? " ← ExtendPad" : "")")
        }
        lines.append("")
        lines.append("Recent log:")
        lines += Log.shared.recentLines().suffix(120)
        return lines.joined(separator: "\n")
    }

    static func machineArch() -> String {
        var sys = utsname(); uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
