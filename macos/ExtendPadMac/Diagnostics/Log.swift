import Foundation
import os

/// Local-only logging: unified log + a rotating file in ~/Library/Logs/ExtendPad.
/// Nothing is ever sent off the machine.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let osLog = Logger(subsystem: "com.extendpad.mac", category: "app")
    private let queue = DispatchQueue(label: "extendpad.log")
    private var handle: FileHandle?
    private var recent: [String] = []
    private let recentLimit = 400
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ExtendPad", isDirectory: true)
    }
    public static var logFile: URL { logDirectory.appendingPathComponent("extendpad.log") }

    private init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Log.logDirectory, withIntermediateDirectories: true)
        let file = Log.logFile
        if let attrs = try? fm.attributesOfItem(atPath: file.path),
           let size = attrs[.size] as? NSNumber, size.intValue > 5_000_000 {
            let old = Log.logDirectory.appendingPathComponent("extendpad.1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: file, to: old)
        }
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
    }

    public enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    public func write(_ level: Level, _ category: String, _ message: String) {
        let ts = Date()
        queue.async {
            let line = "\(self.formatter.string(from: ts)) [\(level.rawValue)] [\(category)] \(message)"
            self.recent.append(line)
            if self.recent.count > self.recentLimit { self.recent.removeFirst(self.recent.count - self.recentLimit) }
            if let data = (line + "\n").data(using: .utf8) { try? self.handle?.write(contentsOf: data) }
            if ProcessInfo.processInfo.environment["EXTENDPAD_LOG_STDERR"] == "1" {
                FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
            }
        }
        switch level {
        case .debug: osLog.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .info: osLog.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .warn: osLog.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error: osLog.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
    }

    public func recentLines() -> [String] { queue.sync { recent } }
}

public func logInfo(_ cat: String, _ msg: String) { Log.shared.write(.info, cat, msg) }
public func logWarn(_ cat: String, _ msg: String) { Log.shared.write(.warn, cat, msg) }
public func logError(_ cat: String, _ msg: String) { Log.shared.write(.error, cat, msg) }
public func logDebug(_ cat: String, _ msg: String) { Log.shared.write(.debug, cat, msg) }

/// Monotonic clock in microseconds (mach continuous time, unaffected by wall-clock changes).
public enum MonoClock {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return tb
    }()
    public static func nowMicros() -> UInt64 {
        let t = mach_continuous_time()
        return t * UInt64(timebase.numer) / UInt64(timebase.denom) / 1000
    }
    public static func micros(fromHostTime t: UInt64) -> UInt64 {
        t * UInt64(timebase.numer) / UInt64(timebase.denom) / 1000
    }
}
