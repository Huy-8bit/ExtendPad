import Foundation

public struct DeviceSnapshot: Equatable {
    public enum Phase: Equatable {
        case adbMissing
        case adbError(String)
        case noDevice
        case networkOnly          // only ADB-over-Wi‑Fi devices present; ExtendPad requires USB
        case unauthorized(String) // serial
        case offline(String)
        case noPermissions(String)
        case tunnelFailed(String)
        case appMissing(String)
        case ready(String)
    }
    public var phase: Phase = .noDevice
    public var adbPath: String?
    public var adbVersion: String?
    public var serial: String?
    public var model: String = ""
    public var usbPort: String?
    public var reverseActive = false
    public var appInstalled = false
    public var properties: [String: String] = [:]
    public var allDevices: [ADBDevice] = []
    public init() {}
}

/// Polls `adb` every 2 s on a background queue: picks the USB tablet, keeps the `adb reverse`
/// tunnel alive (it is lost on every replug or adbd restart), and opens the tablet app with the
/// pairing token when no session is active. Recovers automatically when the adb server restarts.
public final class DeviceMonitor: @unchecked Sendable {
    public static let androidPackage = "com.extendpad.android"
    public static let androidComponent = "com.extendpad.android/.ui.MainActivity"
    public static let connectAction = "com.extendpad.action.CONNECT"

    private let queue = DispatchQueue(label: "extendpad.adb", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var adb: ADB?
    private var adbVersion: String?
    private var lastLaunch: [String: Date] = [:]
    /// How many more times the tablet app may be opened automatically, per device. A newly plugged
    /// device gets a small budget; a disconnect chosen on the tablet sets it to 0 so ExtendPad never
    /// drags the app back into the foreground. Replugging or "Connect" on the Mac grants it again.
    private var launchBudget: [String: Int] = [:]
    public static let defaultLaunchBudget = 3
    private var propsCache: [String: [String: String]] = [:]
    private var installedCache: [String: (Bool, Date)] = [:]
    private var reversedSerials: Set<String> = []
    private var consecutiveFailures = 0
    private var snapshot = DeviceSnapshot()

    public let port: UInt16
    public var userADBPath: String?
    public var allowEmulator = false
    public var autoLaunchApp = true
    /// Asked on the adb queue; return true when no tablet session is active.
    public var wantsTabletConnection: () -> Bool = { true }
    public var tokenProvider: () -> String = { "" }
    /// Called on the main queue.
    public var onUpdate: ((DeviceSnapshot) -> Void)?

    public init(port: UInt16) { self.port = port }

    public func start() {
        queue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.poll() }
            self.timer = t
            t.resume()
        }
    }

    /// Stops polling and removes the reverse tunnels we created.
    public func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            if let adb = self.adb {
                for s in self.reversedSerials { adb.removeReverse(serial: s, port: self.port) }
            }
            self.reversedSerials.removeAll()
            self.lastLaunch.removeAll()
            DispatchQueue.main.async { completion?() }
        }
    }

    public func pollNow() { queue.async { self.poll() } }

    /// Allow the tablet app to be opened again right away (user pressed Connect, transport recovered…).
    public func grantLaunches(_ n: Int = DeviceMonitor.defaultLaunchBudget) {
        queue.async {
            self.lastLaunch.removeAll()
            for k in Set(self.launchBudget.keys).union(self.snapshot.serial.map { [$0] } ?? []) { self.launchBudget[k] = n }
        }
    }

    /// The tablet's user ended the session: never re-open the app automatically until replug/Connect.
    public func suppressLaunches() {
        queue.async { for k in self.launchBudget.keys { self.launchBudget[k] = 0 } }
    }

    public func install(apkPath: String, completion: @escaping (Bool, String) -> Void) {
        queue.async {
            guard let adb = self.adb, let serial = self.snapshot.serial else {
                DispatchQueue.main.async { completion(false, "No authorised USB tablet") }; return
            }
            logInfo("adb", "installing \(apkPath) on \(serial)")
            let r = adb.install(serial: serial, apkPath: apkPath)
            self.installedCache.removeValue(forKey: serial)
            let msg = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { completion(r.ok && msg.contains("Success"), msg) }
            self.poll()
        }
    }

    public func launchNow() {
        queue.async {
            guard let adb = self.adb, let serial = self.snapshot.serial else { return }
            self.lastLaunch[serial] = Date()
            self.launch(adb: adb, serial: serial)
        }
    }

    private func publish(_ s: DeviceSnapshot) {
        let changed = s != snapshot
        snapshot = s
        if changed { DispatchQueue.main.async { self.onUpdate?(s) } }
    }

    private func poll() {
        var s = DeviceSnapshot()
        if adb == nil || !(FileManager.default.isExecutableFile(atPath: adb!.path)) {
            guard let path = ADB.locate(userPath: userADBPath) else {
                s.phase = .adbMissing
                publish(s); return
            }
            adb = ADB(path: path)
            adbVersion = adb?.version()
            logInfo("adb", "using \(path) (\(adbVersion ?? "unknown version"))")
        }
        guard let adb else { return }
        s.adbPath = adb.path
        s.adbVersion = adbVersion

        guard let devices = adb.devices() else {
            consecutiveFailures += 1
            s.phase = .adbError("adb did not respond")
            publish(s)
            // The adb server may have been killed or is restarting: start it again.
            if consecutiveFailures >= 2 { _ = adb.startServer(); reversedSerials.removeAll() }
            return
        }
        consecutiveFailures = 0
        s.allDevices = devices

        // Forget per-device state for devices that went away so a replug re-runs setup immediately.
        let present = Set(devices.map(\.serial))
        for k in lastLaunch.keys where !present.contains(k) { lastLaunch.removeValue(forKey: k) }
        for k in launchBudget.keys where !present.contains(k) { launchBudget.removeValue(forKey: k) }
        reversedSerials = reversedSerials.intersection(present)

        let eligible = devices.filter { $0.isUSB || (allowEmulator && $0.isEmulator) }
        guard let dev = eligible.first(where: { $0.state == .device }) ?? eligible.first else {
            s.phase = devices.contains(where: { $0.isNetwork }) ? .networkOnly : .noDevice
            publish(s); return
        }
        s.serial = dev.serial
        s.model = dev.model
        s.usbPort = dev.usb
        switch dev.state {
        case .unauthorized: s.phase = .unauthorized(dev.serial); publish(s); return
        case .offline: s.phase = .offline(dev.serial); publish(s); return
        case .noPermissions: s.phase = .noPermissions(dev.serial); publish(s); return
        case .unknown: s.phase = .offline(dev.serial); publish(s); return
        case .device: break
        }

        if propsCache[dev.serial] == nil {
            let p = adb.deviceProperties(serial: dev.serial)
            propsCache[dev.serial] = p
            logInfo("adb", "device \(dev.serial): " + p.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }
        s.properties = propsCache[dev.serial] ?? [:]

        // Keep the USB tunnel alive.
        if adb.hasReverse(serial: dev.serial, port: port) {
            s.reverseActive = true
            reversedSerials.insert(dev.serial)
        } else {
            let r = adb.setupReverse(serial: dev.serial, port: port)
            if r.ok {
                logInfo("adb", "adb reverse tcp:\(port) established on \(dev.serial)")
                s.reverseActive = true
                reversedSerials.insert(dev.serial)
            } else {
                s.phase = .tunnelFailed((r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
                publish(s); return
            }
        }

        let installed: Bool
        if let c = installedCache[dev.serial], Date().timeIntervalSince(c.1) < (c.0 ? 60 : 6) {
            installed = c.0
        } else {
            installed = adb.isPackageInstalled(serial: dev.serial, package: Self.androidPackage)
            installedCache[dev.serial] = (installed, Date())
        }
        s.appInstalled = installed
        if !installed { s.phase = .appMissing(dev.serial); publish(s); return }

        s.phase = .ready(dev.serial)
        publish(s)

        if launchBudget[dev.serial] == nil { launchBudget[dev.serial] = Self.defaultLaunchBudget } // newly plugged in
        if autoLaunchApp && wantsTabletConnection(), let budget = launchBudget[dev.serial], budget > 0 {
            let last = lastLaunch[dev.serial] ?? .distantPast
            if Date().timeIntervalSince(last) > 20 {
                launchBudget[dev.serial] = budget - 1
                launch(adb: adb, serial: dev.serial)
            }
        }
    }

    private func launch(adb: ADB, serial: String) {
        lastLaunch[serial] = Date()
        let token = tokenProvider()
        guard !token.isEmpty else { return }
        let r = adb.launchApp(serial: serial, component: Self.androidComponent, action: Self.connectAction, token: token, port: port)
        if r.ok && !r.stdout.contains("Error") { logInfo("adb", "opened ExtendPad on \(serial)") }
        else { logWarn("adb", "could not open tablet app: \(r.stderr) \(r.stdout)") }
    }
}

/// The 32-byte pairing secret, stored in Application Support with 0600 permissions.
public final class TokenStore {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ExtendPad", isDirectory: true)
    }
    private static var file: URL { directory.appendingPathComponent("pairing-token") }

    public static func loadOrCreate() -> String {
        if let s = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           s.count == 64, s.allSatisfy(\.isHexDigit) {
            return s.lowercased()
        }
        return regenerate()
    }

    @discardableResult
    public static func regenerate() -> String {
        let token = Auth.randomHex(bytes: 32)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }
}
