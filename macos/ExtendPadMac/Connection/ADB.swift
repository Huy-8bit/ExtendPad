import Foundation

public struct ADBDevice: Equatable {
    public enum State: String { case device, unauthorized, offline, noPermissions = "no permissions", unknown }
    public var serial: String
    public var state: State
    public var model: String
    public var product: String
    public var usb: String?          // present for USB-attached devices
    public var transportId: String?

    public var isUSB: Bool { usb != nil }
    public var isEmulator: Bool { serial.hasPrefix("emulator-") }
    /// ADB over Wi‑Fi devices look like "192.168.1.5:5555" or mDNS "adb-XXXX._adb-tls-connect._tcp".
    public var isNetwork: Bool { serial.contains(":") || serial.contains("._adb-tls") }
}

/// Thin, argv-only wrapper around the `adb` binary. Never builds shell strings from untrusted data;
/// remote shell commands are fixed literals. Serials come from `adb devices` and are validated.
public final class ADB: @unchecked Sendable {
    public let path: String
    public init(path: String) { self.path = path }

    /// ExtendPad's own copy of Google's platform-tools, installed on request by `ADBInstaller`.
    /// `EXTENDPAD_ADB_DIR` overrides it (tests).
    public static var managedDirectory: URL {
        if let d = ProcessInfo.processInfo.environment["EXTENDPAD_ADB_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return TokenStore.directory.appendingPathComponent("platform-tools", isDirectory: true)
    }
    public static var managedPath: String { managedDirectory.appendingPathComponent("adb").path }

    /// Search order: explicit user setting → an adb already on the system (Android Studio SDK, Homebrew)
    /// → ExtendPad's own downloaded copy. System copies win so that ExtendPad never starts a second,
    /// different adb version that would keep killing Android Studio's adb server.
    /// `ignoreSystem` (EXTENDPAD_IGNORE_SYSTEM_ADB=1) exists to test the "no adb installed" path.
    public static func candidatePaths(userPath: String?, env: [String: String], home: String,
                                      bundled: String?, managed: String, ignoreSystem: Bool = false) -> [String] {
        var c: [String] = []
        if let p = userPath, !p.isEmpty { c.append((p as NSString).expandingTildeInPath) }
        if !ignoreSystem {
            for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] { if let v = env[key], !v.isEmpty { c.append(v + "/platform-tools/adb") } }
            c += [home + "/Library/Android/sdk/platform-tools/adb",
                  "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                  "/opt/homebrew/Caskroom/android-platform-tools/latest/platform-tools/adb"]
        }
        if let bundled { c.append(bundled) }
        c.append(managed)
        return c
    }

    public static func locate(userPath: String?) -> String? {
        let env = ProcessInfo.processInfo.environment
        let list = candidatePaths(userPath: userPath, env: env, home: FileManager.default.homeDirectoryForCurrentUser.path,
                                  bundled: Bundle.main.path(forResource: "adb", ofType: nil, inDirectory: "platform-tools"),
                                  managed: managedPath, ignoreSystem: env["EXTENDPAD_IGNORE_SYSTEM_ADB"] == "1")
        return list.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// True when `path` is ExtendPad's own downloaded copy.
    public static func isManaged(_ path: String?) -> Bool { path == managedPath }

    public struct Result { public var status: Int32; public var stdout: String; public var stderr: String; public var timedOut: Bool
        public var ok: Bool { status == 0 && !timedOut } }

    /// Runs adb synchronously with a timeout. Call from a background queue.
    public func run(_ args: [String], timeout: TimeInterval = 10) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        do { try p.run() } catch {
            return Result(status: -1, stdout: "", stderr: "failed to launch adb: \(error.localizedDescription)", timedOut: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        var timedOut = false
        if p.isRunning { timedOut = true; p.terminate(); usleep(200_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        p.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
    }

    public func version() -> String? {
        let r = run(["version"], timeout: 5)
        return r.ok ? r.stdout.split(separator: "\n").first.map(String.init) : nil
    }

    public func startServer() -> Bool { run(["start-server"], timeout: 15).ok }

    public func devices() -> [ADBDevice]? {
        let r = run(["devices", "-l"], timeout: 8)
        guard r.ok else { return nil }
        return ADB.parseDevices(r.stdout)
    }

    public static func parseDevices(_ text: String) -> [ADBDevice] {
        var list: [ADBDevice] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("List of devices") || s.hasPrefix("*") { continue }
            // Format: SERIAL <ws> STATE [key:value ...]; state may be "no permissions (...)".
            // adb separates the serial from the rest with a TAB; the serial itself never contains spaces.
            let serialPart: String
            let rest: String
            if let tab = s.firstIndex(of: "\t") {
                serialPart = String(s[..<tab]); rest = String(s[s.index(after: tab)...])
            } else {
                let sp = s.split(separator: " ", maxSplits: 1).map(String.init)
                guard sp.count == 2 else { continue }
                serialPart = sp[0]; rest = sp[1]
            }
            guard isValidSerial(serialPart) else { continue }
            let parts = [serialPart] + rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            var state: ADBDevice.State = ADBDevice.State(rawValue: parts[1]) ?? .unknown
            if parts[1] == "no" && parts.count > 2 && parts[2].hasPrefix("permissions") { state = .noPermissions }
            var dev = ADBDevice(serial: parts[0], state: state, model: "", product: "", usb: nil, transportId: nil)
            for kv in parts.dropFirst(2) {
                let pair = kv.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "model": dev.model = pair[1].replacingOccurrences(of: "_", with: " ")
                case "product": dev.product = pair[1]
                case "usb": dev.usb = pair[1]
                case "transport_id": dev.transportId = pair[1]
                default: break
                }
            }
            list.append(dev)
        }
        return list
    }

    /// Serials are passed as argv (no shell), but still restrict them to a conservative charset.
    public static func isValidSerial(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:@[]".unicodeScalars.contains($0)
        }
    }

    // MARK: Per-device operations

    public func hasReverse(serial: String, port: UInt16) -> Bool {
        let r = run(["-s", serial, "reverse", "--list"], timeout: 5)
        return r.ok && r.stdout.contains("tcp:\(port) tcp:\(port)")
    }

    public func setupReverse(serial: String, port: UInt16) -> Result {
        run(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"], timeout: 8)
    }

    public func removeReverse(serial: String, port: UInt16) {
        _ = run(["-s", serial, "reverse", "--remove", "tcp:\(port)"], timeout: 5)
    }

    public func isPackageInstalled(serial: String, package: String) -> Bool {
        let r = run(["-s", serial, "shell", "pm", "path", package], timeout: 8)
        return r.ok && r.stdout.contains("package:")
    }

    public func install(serial: String, apkPath: String) -> Result {
        run(["-s", serial, "install", "-r", apkPath], timeout: 120)
    }

    /// Opens the tablet app and hands it the pairing token. `token` is hex and `port` numeric, so the
    /// resulting remote command line contains no shell metacharacters.
    public func launchApp(serial: String, component: String, action: String, token: String, port: UInt16) -> Result {
        precondition(token.allSatisfy(\.isHexDigit))
        return run(["-s", serial, "shell", "am", "start", "-n", component, "-a", action,
                    "--es", "ep_token", token, "--ei", "ep_port", String(port)], timeout: 10)
    }

    public struct DeviceProps { public var values: [String: String] }

    /// Fixed, literal remote command: hardware inspection for diagnostics.
    public func deviceProperties(serial: String) -> [String: String] {
        let keys = ["ro.product.manufacturer", "ro.product.model", "ro.product.device", "ro.build.version.release",
                    "ro.build.version.sdk", "ro.product.cpu.abi", "ro.build.display.id", "hw_sc.build.platform.version",
                    "ro.huawei.build.display.id", "ro.board.platform", "ro.hardware"]
        var props: [String: String] = [:]
        let r = run(["-s", serial, "shell", "getprop"], timeout: 8)
        if r.ok {
            for line in r.stdout.split(whereSeparator: \.isNewline) {
                // [key]: [value]
                let s = String(line)
                guard let k1 = s.firstIndex(of: "["), let k2 = s.firstIndex(of: "]") , k1 < k2 else { continue }
                let key = String(s[s.index(after: k1)..<k2])
                guard keys.contains(key) else { continue }
                let rest = s[s.index(after: k2)...]
                if let v1 = rest.firstIndex(of: "["), let v2 = rest.lastIndex(of: "]"), v1 < v2 {
                    props[key] = String(rest[rest.index(after: v1)..<v2])
                }
            }
        }
        let wm = run(["-s", serial, "shell", "wm", "size"], timeout: 5)
        if wm.ok { props["wm.size"] = wm.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        let dens = run(["-s", serial, "shell", "wm", "density"], timeout: 5)
        if dens.ok { props["wm.density"] = dens.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        let mem = run(["-s", serial, "shell", "cat", "/proc/meminfo"], timeout: 5)
        if mem.ok, let first = mem.stdout.split(whereSeparator: \.isNewline).first { props["meminfo.total"] = String(first) }
        return props
    }
}
