import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics

public enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)
    case failed(String)
    public var description: String {
        switch self {
        case .permissionDenied: return "Screen Recording permission is not granted"
        case .displayNotFound(let id): return "ScreenCaptureKit cannot see display \(id)"
        case .failed(let s): return s
        }
    }
}

public struct CaptureConfig: Equatable {
    public var displayID: CGDirectDisplayID
    public var width: Int
    public var height: Int
    public var fps: Int
    public var showsCursor: Bool
    public init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, showsCursor: Bool = true) {
        self.displayID = displayID; self.width = width; self.height = height; self.fps = fps; self.showsCursor = showsCursor
    }
}

/// Captures exactly one display (by CGDirectDisplayID) with ScreenCaptureKit.
/// Frames arrive as IOSurface-backed NV12 pixel buffers that go straight into VideoToolbox
/// without any CPU copy. ScreenCaptureKit only delivers frames when the content changed,
/// so a static screen costs (almost) nothing.
public final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public private(set) var config: CaptureConfig?
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "extendpad.capture", qos: .userInteractive)

    /// Called on the capture queue for every *new* frame.
    public var onFrame: ((CVPixelBuffer, _ captureMicros: UInt64) -> Void)?
    /// Called when ScreenCaptureKit stops the stream (permission revoked, display removed, …).
    public var onStopped: ((String) -> Void)?

    public static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public func start(_ cfg: CaptureConfig) async throws {
        await stop()
        guard ScreenCaptureEngine.hasPermission() else { throw CaptureError.permissionDenied }

        // A freshly created virtual display can take a moment to show up in SCShareableContent.
        var scDisplay: SCDisplay?
        for attempt in 0..<20 {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                scDisplay = content.displays.first { $0.displayID == cfg.displayID }
            } catch {
                let ns = error as NSError
                if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue {
                    throw CaptureError.permissionDenied
                }
                if attempt == 19 { throw CaptureError.failed("SCShareableContent: \(error.localizedDescription)") }
            }
            if scDisplay != nil { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard let scDisplay else { throw CaptureError.displayNotFound(cfg.displayID) }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let sc = SCStreamConfiguration()
        apply(cfg, to: sc)
        let s = SCStream(filter: filter, configuration: sc, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        do {
            try await s.startCapture()
        } catch {
            let ns = error as NSError
            if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue { throw CaptureError.permissionDenied }
            throw CaptureError.failed("startCapture: \(error.localizedDescription)")
        }
        stream = s
        config = cfg
        logInfo("capture", "capturing display \(cfg.displayID) at \(cfg.width)x\(cfg.height) ≤\(cfg.fps) fps")
    }

    private func apply(_ cfg: CaptureConfig, to sc: SCStreamConfiguration) {
        sc.width = cfg.width
        sc.height = cfg.height
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, cfg.fps)))
        sc.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        sc.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        sc.queueDepth = 6           // bounded: capture can never run more than 6 surfaces ahead
        sc.showsCursor = cfg.showsCursor
        sc.capturesAudio = false
        sc.scalesToFit = true
        if #available(macOS 14.0, *) { sc.preservesAspectRatio = true }
    }

    public func update(_ cfg: CaptureConfig) async throws {
        guard let stream, let current = config, current.displayID == cfg.displayID else {
            try await start(cfg); return
        }
        let sc = SCStreamConfiguration()
        apply(cfg, to: sc)
        try await stream.updateConfiguration(sc)
        config = cfg
        logInfo("capture", "updated capture to \(cfg.width)x\(cfg.height) ≤\(cfg.fps) fps")
    }

    public func stop() async {
        guard let s = stream else { return }
        stream = nil
        config = nil
        try? s.removeStreamOutput(self, type: .screen)
        try? await s.stopCapture()
        logInfo("capture", "capture stopped")
    }

    public var isRunning: Bool { stream != nil }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus), status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sb) else { return }
        // Capture timestamp: SCK reports mach absolute time of the frame.
        var captureMicros = MonoClock.nowMicros()
        if let displayTime = info[.displayTime] as? UInt64, displayTime > 0 {
            // displayTime is mach_absolute_time; convert into the same (continuous) clock domain.
            let nowAbs = mach_absolute_time()
            let ageMicros = nowAbs > displayTime ? MonoClock.micros(fromHostTime: nowAbs - displayTime) : 0
            captureMicros = captureMicros &- min(ageMicros, 1_000_000)
            if ProcessInfo.processInfo.environment["EXTENDPAD_TRACE_CAPTURE"] == "1" { logDebug("capture", "frame age at delivery \(ageMicros) us") }
        }
        onFrame?(pixelBuffer, captureMicros)
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        logWarn("capture", "stream stopped: \(error.localizedDescription)")
        if self.stream === stream { self.stream = nil; config = nil }
        onStopped?(error.localizedDescription)
    }
}
