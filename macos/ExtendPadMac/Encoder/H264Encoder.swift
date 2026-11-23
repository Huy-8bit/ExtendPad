import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

public struct EncodedFrame {
    public var tag: UInt32
    public var annexB: Data
    public var isKeyframe: Bool
    /// Annex-B SPS+PPS of the format this frame belongs to.
    public var parameterSets: Data
    public var profileIdc: UInt8
    public var levelIdc: UInt8
    public var ptsMicros: UInt64
    public var captureMicros: UInt64
    public var encodeMicros: UInt64
    public var idleRefresh: Bool
}

public struct EncoderConfig: Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrate: Int
    public var highProfile: Bool
    public var prioritizeSpeed: Bool
    /// Upper bound for frame QP (0 = encoder default). Lower = never blockier than this.
    public var maxFrameQP: Int
    public init(width: Int, height: Int, fps: Int, bitrate: Int, highProfile: Bool, prioritizeSpeed: Bool, maxFrameQP: Int = 0) {
        self.width = width; self.height = height; self.fps = fps; self.bitrate = bitrate
        self.highProfile = highProfile; self.prioritizeSpeed = prioritizeSpeed; self.maxFrameQP = maxFrameQP
    }
}

public enum EncoderError: Error, CustomStringConvertible {
    case createFailed(OSStatus)
    public var description: String {
        switch self { case .createFailed(let s): return "VTCompressionSessionCreate failed (\(s))" }
    }
}

/// Real-time, low-latency H.264 encoder on VideoToolbox.
/// - Hardware encoder with low-latency rate control when available; software fallback otherwise.
/// - No B-frames (AllowFrameReordering = false), so decode order == display order.
/// - Long GOP; IDR frames are produced on demand (keyframe requests) and every ~10 s.
public final class H264Encoder: @unchecked Sendable {
    public private(set) var config: EncoderConfig
    public private(set) var isHardware = false
    public private(set) var lowLatencyRateControl = false
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var _inFlight = 0

    /// Called exactly once per submitted frame: with the frame, or nil if it was dropped/failed.
    public var onComplete: ((UInt32, EncodedFrame?) -> Void)?
    public var onError: ((String) -> Void)?

    public init(config: EncoderConfig) throws {
        self.config = config
        try createSession()
    }

    deinit { invalidate() }

    public var inFlight: Int { lock.lock(); defer { lock.unlock() }; return _inFlight }

    private func createSession() throws {
        // Standard (non-low-latency) rate control first. The low-latency mode keeps every frame
        // about the same size — fine for video calls, but on a desktop a full-screen change then gets
        // starved and chroma residuals are zeroed: the old colours stay on static areas ("ghost"
        // colour from a closed window). Over USB occasional large frames are cheap, and measured
        // encode latency is the same (~8 ms, ~18 ms once the media engine clocks down).
        var attempts: [(spec: [CFString: Any], lowLatency: Bool, requiresHW: Bool)] = []
        attempts.append(([kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true], false, true))
        attempts.append(([kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
                          kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true], true, true))
        attempts.append(([kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true], false, false))
        var requiredHW = false

        var lastStatus: OSStatus = 0
        let sourceAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: config.width,
            kCVPixelBufferHeightKey: config.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        for attempt in attempts {
            var s: VTCompressionSession?
            let status = VTCompressionSessionCreate(allocator: nil, width: Int32(config.width), height: Int32(config.height),
                                                    codecType: kCMVideoCodecType_H264,
                                                    encoderSpecification: attempt.spec as CFDictionary,
                                                    imageBufferAttributes: sourceAttrs as CFDictionary,
                                                    compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                    compressionSessionOut: &s)
            lastStatus = status
            if status == noErr, let s {
                session = s
                lowLatencyRateControl = attempt.lowLatency
                requiredHW = attempt.requiresHW
                break
            }
        }
        guard let session else { throw EncoderError.createFailed(lastStatus) }

        var hw: CFBoolean?
        if VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                 allocator: nil, valueOut: &hw) == noErr {
            isHardware = (hw == kCFBooleanTrue)
        }
        // Creation with RequireHardwareAcceleratedVideoEncoder only succeeds on the hardware encoder.
        if requiredHW { isHardware = true }
        if !isHardware { logWarn("encoder", "hardware H.264 encoder unavailable — using software encoding") }

        func set(_ key: CFString, _ value: CFTypeRef) {
            let st = VTSessionSetProperty(session, key: key, value: value)
            if st != noErr { logDebug("encoder", "property \(key) not applied (\(st))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        let profile: CFString
        if #available(macOS 12.0, *) {
            profile = config.highProfile ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel : kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        } else {
            profile = config.highProfile ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_H264_Baseline_AutoLevel
        }
        set(kVTCompressionPropertyKey_ProfileLevel, profile)
        set(kVTCompressionPropertyKey_AverageBitRate, config.bitrate as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits, Self.dataRateLimits(config.bitrate) as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, config.fps as CFNumber)
        // Cap the worst-case quantiser so fast motion / keyframes don't turn into visible blocks.
        // (Supported by the low-latency H.264 encoder; the encoder may skip a frame instead.)
        if config.maxFrameQP > 0 { set(kVTCompressionPropertyKey_MaxAllowedFrameQP, config.maxFrameQP as CFNumber) }
        // Long GOP: IDRs are requested on demand (decoder start, errors, resume); a periodic IDR
        // every 30 s is only a safety net and costs little on static screens.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (config.fps * 30) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 30 as CFNumber)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
        if #available(macOS 13.0, *) {
            set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, config.prioritizeSpeed ? kCFBooleanTrue : kCFBooleanFalse)
        }
        set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
        logInfo("encoder", "H.264 \(config.width)x\(config.height)@\(config.fps) \(config.bitrate / 1000) kbps hw=\(isHardware) lowLatencyRC=\(lowLatencyRateControl) profile=\(config.highProfile ? "ConstrainedHigh" : "ConstrainedBaseline")")
    }

    public func setBitrate(_ bitrate: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let session, bitrate != config.bitrate else { return }
        config.bitrate = bitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: Self.dataRateLimits(bitrate) as CFArray)
    }

    /// Encodes one frame asynchronously. Returns false if the session is gone.
    @discardableResult
    public func encode(_ pixelBuffer: CVPixelBuffer, tag: UInt32, ptsMicros: UInt64, captureMicros: UInt64,
                       forceKeyframe: Bool, idleRefresh: Bool) -> Bool {
        lock.lock()
        guard let session else { lock.unlock(); return false }
        _inFlight += 1
        lock.unlock()

        let pts = CMTime(value: CMTimeValue(ptsMicros), timescale: 1_000_000)
        let props: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let start = MonoClock.nowMicros()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                     duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
            [weak self] status, _, sampleBuffer in
            guard let self else { return }
            self.lock.lock(); self._inFlight -= 1; self.lock.unlock()
            guard status == noErr, let sampleBuffer else {
                if status != noErr { self.onError?("encode callback status \(status)") }
                self.onComplete?(tag, nil)
                return
            }
            let frame = H264Encoder.package(sampleBuffer, tag: tag, ptsMicros: ptsMicros, captureMicros: captureMicros,
                                            encodeMicros: MonoClock.nowMicros() - start, idleRefresh: idleRefresh)
            self.onComplete?(tag, frame)
        }
        if status != noErr {
            lock.lock(); _inFlight -= 1; lock.unlock()
            onError?("VTCompressionSessionEncodeFrame failed (\(status))")
            return false
        }
        return true
    }

    public func invalidate() {
        lock.lock()
        let s = session
        session = nil
        lock.unlock()
        if let s {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
    }

    /// Allow bursts (a full-screen change may need many times the average frame size) while still
    /// bounding sustained throughput: ≤ 2× average over any 1 s window.
    static func dataRateLimits(_ bitrate: Int) -> [NSNumber] {
        [NSNumber(value: bitrate / 8 * 2), NSNumber(value: 1.0)]
    }

    // MARK: - AVCC → Annex-B

    static let startCode = Data([0, 0, 0, 1])

    static func package(_ sb: CMSampleBuffer, tag: UInt32, ptsMicros: UInt64, captureMicros: UInt64, encodeMicros: UInt64, idleRefresh: Bool) -> EncodedFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sb), let fmt = CMSampleBufferGetFormatDescription(sb) else { return nil }
        var isKey = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }

        var paramSets = Data()
        var count = 0
        var nalHeaderLen: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                           nalUnitHeaderLengthOut: &nalHeaderLen)
        var profile: UInt8 = 0, level: UInt8 = 0
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                  parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                  nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                paramSets.append(startCode)
                paramSets.append(ptr, count: size)
                if i == 0 && size >= 4 { profile = ptr[1]; level = ptr[3] }
            }
        }

        var totalLength = 0
        var dataPtr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPtr) == noErr, let dataPtr else { return nil }
        let raw = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: UInt8.self)
        guard let annexB = avccToAnnexB(UnsafeBufferPointer(start: raw, count: totalLength), lengthSize: Int(nalHeaderLen)) else { return nil }
        return EncodedFrame(tag: tag, annexB: annexB, isKeyframe: isKey, parameterSets: paramSets, profileIdc: profile, levelIdc: level,
                            ptsMicros: ptsMicros, captureMicros: captureMicros, encodeMicros: encodeMicros, idleRefresh: idleRefresh)
    }

    /// Converts length-prefixed NAL units to start-code-prefixed ones. Returns nil on malformed input.
    public static func avccToAnnexB(_ buf: UnsafeBufferPointer<UInt8>, lengthSize: Int) -> Data? {
        guard (1...4).contains(lengthSize) else { return nil }
        var out = Data(capacity: buf.count + 16)
        var offset = 0
        while offset + lengthSize <= buf.count {
            var len = 0
            for k in 0..<lengthSize { len = (len << 8) | Int(buf[offset + k]) }
            offset += lengthSize
            guard len > 0, offset + len <= buf.count else { return nil }
            out.append(startCode)
            out.append(UnsafeBufferPointer(rebasing: buf[offset..<(offset + len)]))
            offset += len
        }
        return offset == buf.count ? out : nil
    }
}
