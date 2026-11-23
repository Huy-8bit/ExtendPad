import Foundation
import Security

/// One-click install of Google's official Android SDK Platform-Tools (which contain `adb`) into
/// ExtendPad's own folder, so users don't need Homebrew, Android Studio or the Terminal.
///
/// - The only network request ExtendPad ever makes, and only when the user clicks "Install adb".
/// - Downloaded from Google over HTTPS; the extracted `adb` must carry a valid code signature from
///   Google's Developer ID (team EQHXZ8M8AV) or it is rejected and nothing is installed.
/// - Installed into ~/Library/Application Support/ExtendPad/platform-tools (no admin rights, nothing
///   system-wide); replaced atomically, so a failed update never breaks a working copy.
public final class ADBInstaller: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
    /// Google's page with the Platform-Tools release notes and license terms.
    public static let termsURL = URL(string: "https://developer.android.com/tools/releases/platform-tools")!
    public static let googleTeamID = "EQHXZ8M8AV"
    static let maxArchiveBytes: Int64 = 200 * 1024 * 1024

    public enum InstallError: Error, LocalizedError {
        case download(String), tooLarge, unzip(String), missingADB, badSignature(String), notRunnable(String), install(String)
        public var errorDescription: String? {
            switch self {
            case .download(let s): return "Download failed: \(s)"
            case .tooLarge: return "The download was unexpectedly large and was discarded."
            case .unzip(let s): return "Could not unpack the download: \(s)"
            case .missingADB: return "The download did not contain adb."
            case .badSignature(let s): return "adb is not signed by Google (\(s)); it was not installed."
            case .notRunnable(let s): return "The downloaded adb does not run on this Mac: \(s)"
            case .install(let s): return "Could not install adb: \(s)"
            }
        }
    }

    private var session: URLSession?
    private var progress: ((Double) -> Void)?
    private var completion: ((Result<String, Error>) -> Void)?
    private let destination: URL

    public init(destination: URL = ADB.managedDirectory) {
        self.destination = destination
    }

    /// Downloads, verifies and installs adb. Callbacks run on the main queue. Returns the adb version line.
    public func install(progress: @escaping (Double) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        self.progress = progress
        self.completion = completion
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 15 * 60
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        logInfo("adb-install", "downloading \(Self.downloadURL.absoluteString)")
        s.downloadTask(with: Self.downloadURL).resume()
    }

    public func cancel() { session?.invalidateAndCancel(); session = nil }

    private func finish(_ r: Result<String, Error>) {
        session?.finishTasksAndInvalidate()
        session = nil
        if case .failure(let e) = r { logWarn("adb-install", e.localizedDescription) }
        let c = completion
        completion = nil
        DispatchQueue.main.async { c?(r) }
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.maxArchiveBytes { downloadTask.cancel(); finish(.failure(InstallError.tooLarge)); return }
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let cb = progress
        DispatchQueue.main.async { cb?(min(p, 1)) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(InstallError.download("HTTP \(http.statusCode)"))); return
        }
        // The temporary file is deleted when this method returns: move it first.
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("extendpad-platform-tools-\(UUID().uuidString).zip")
        do { try FileManager.default.moveItem(at: location, to: zip) } catch {
            finish(.failure(InstallError.download(error.localizedDescription))); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(at: zip) }
            self.finish(Result { try self.installArchive(zip) })
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, completion != nil { finish(.failure(InstallError.download(error.localizedDescription))) }
    }

    // MARK: Install

    /// Unpacks `zip`, verifies the adb inside and atomically installs it. Also used by tests.
    func installArchive(_ zip: URL) throws -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: zip.path)
        if let size = attrs?[.size] as? NSNumber, size.int64Value > Self.maxArchiveBytes { throw InstallError.tooLarge }

        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".platform-tools-staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let unzip = Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path], timeout: 120)
        guard unzip.status == 0 else { throw InstallError.unzip(unzip.output) }
        let tools = staging.appendingPathComponent("platform-tools", isDirectory: true)
        let adb = tools.appendingPathComponent("adb")
        guard fm.isExecutableFile(atPath: adb.path) else { throw InstallError.missingADB }

        try Self.verifyGoogleSignature(adb.path)
        let v = Self.run(adb.path, ["version"], timeout: 15)
        guard v.status == 0, let version = v.output.split(separator: "\n").first.map(String.init) else {
            throw InstallError.notRunnable(v.output)
        }

        // Atomic swap: never leave a half-installed copy behind.
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = destination.deletingLastPathComponent().appendingPathComponent(".platform-tools-old-\(UUID().uuidString)")
        do {
            if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: old) }
            try fm.moveItem(at: tools, to: destination)
            try? fm.removeItem(at: old)
        } catch {
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: destination.path) { try? fm.moveItem(at: old, to: destination) }
            throw InstallError.install(error.localizedDescription)
        }
        logInfo("adb-install", "installed \(version) at \(destination.path)")
        return version
    }

    /// Requires a valid, Apple-anchored Developer ID signature from Google's team.
    public static func verifyGoogleSignature(_ path: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            throw InstallError.badSignature("unreadable")
        }
        var req: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(googleTeamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else {
            throw InstallError.badSignature("requirement")
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), req)
        guard status == errSecSuccess else { throw InstallError.badSignature("OSStatus \(status)") }
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        var data = Data()
        let reader = DispatchWorkItem { data = pipe.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(execute: reader)
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        _ = reader.wait(timeout: .now() + 2)
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
