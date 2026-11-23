import Foundation

public enum StreamQuality: String, CaseIterable, Codable {
    case performance, balanced, quality
}

/// How the virtual display is laid out relative to the tablet's physical pixels.
public enum DisplayPreset: String, CaseIterable, Codable {
    /// 1 macOS point = 1 tablet pixel. Sharpest, but UI is small on a 10–11" screen.
    case native
    /// Retina (HiDPI): logical size = native / 1.5, rendered at 2× and scaled to native. Larger, crisp text.
    case comfortable
    /// Retina (HiDPI): logical size = native / 2 (exact 2× Retina). Largest text, least space.
    case large
    /// Lower resolution (≈1280 wide) at 1×, for weak decoders or minimal latency.
    case performance
    /// Fixed resolution chosen by the user (`customWidth` × `customHeight`).
    case custom
}

public enum DisplayMode: String, Codable { case extend, mirror }

public struct TabletInfo: Equatable {
    public var widthPx: Int
    public var heightPx: Int
    public var xdpi: Double
    public var refreshHz: Double
    public var decoderMaxWidth: Int
    public var decoderMaxHeight: Int
    public var decoderHighProfile: Bool
    public var decoderMaxFpsNative: Int
    public init(widthPx: Int, heightPx: Int, xdpi: Double, refreshHz: Double, decoderMaxWidth: Int,
                decoderMaxHeight: Int, decoderHighProfile: Bool, decoderMaxFpsNative: Int) {
        self.widthPx = widthPx; self.heightPx = heightPx; self.xdpi = xdpi; self.refreshHz = refreshHz
        self.decoderMaxWidth = decoderMaxWidth; self.decoderMaxHeight = decoderMaxHeight
        self.decoderHighProfile = decoderHighProfile; self.decoderMaxFpsNative = decoderMaxFpsNative
    }
}

public struct PlanRequest: Equatable {
    public var preset: DisplayPreset
    public var quality: StreamQuality
    public var customWidth: Int
    public var customHeight: Int
    public var fpsLimit: Int          // user cap (0 = automatic)
    public var customBitrateKbps: Int // 0 = automatic
    public init(preset: DisplayPreset, quality: StreamQuality, customWidth: Int = 1920, customHeight: Int = 1200,
                fpsLimit: Int = 0, customBitrateKbps: Int = 0) {
        self.preset = preset; self.quality = quality; self.customWidth = customWidth; self.customHeight = customHeight
        self.fpsLimit = fpsLimit; self.customBitrateKbps = customBitrateKbps
    }
}

public struct ModeSpec: Equatable, Hashable { public var width: Int; public var height: Int }

public struct DisplayPlan: Equatable {
    /// Encoded stream size (≤ tablet pixels, ≤ decoder limits).
    public var streamWidth: Int
    public var streamHeight: Int
    /// macOS point size of the virtual display.
    public var logicalWidth: Int
    public var logicalHeight: Int
    /// Backing pixel size of the virtual display (2× logical when HiDPI).
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hiDPI: Bool
    /// Modes handed to CGVirtualDisplaySettings (pixel sizes).
    public var modes: [ModeSpec]
    public var maxPixelsWide: Int
    public var maxPixelsHigh: Int
    public var fps: Int
    public var bitrate: Int
    /// Worst allowed frame QP (lower = never blockier than this).
    public var maxFrameQP: Int
    public var highProfile: Bool
    public var sizeInMillimeters: CGSize

    /// Display-shape part of the plan; when unchanged the existing virtual display is reused.
    public var displayKey: String { "\(logicalWidth)x\(logicalHeight)@\(hiDPI ? 2 : 1)" }
}

public enum DisplayPlanner {
    static let even: (Double) -> Int = { v in max(2, Int(v.rounded()) & ~1) }

    /// Standard selectable resolutions (filtered by the decoder's limits).
    public static let standardResolutions: [ModeSpec] = [
        ModeSpec(width: 1280, height: 800), ModeSpec(width: 1600, height: 1000), ModeSpec(width: 1920, height: 1200),
    ]

    public static func supportedResolutions(for t: TabletInfo) -> [ModeSpec] {
        var list = standardResolutions
        let native = nativeSize(t)
        if !list.contains(native) { list.append(native) }
        return list.filter { fits($0.width, $0.height, t) }.sorted { $0.width < $1.width }
    }

    static func fits(_ w: Int, _ h: Int, _ t: TabletInfo) -> Bool {
        // Decoders report max width/height for either orientation; check both.
        let a = w <= t.decoderMaxWidth && h <= t.decoderMaxHeight
        let b = w <= t.decoderMaxHeight && h <= t.decoderMaxWidth
        return a || b
    }

    /// Tablet pixels in landscape, scaled down (keeping aspect) if the decoder cannot handle them.
    static func nativeSize(_ t: TabletInfo) -> ModeSpec {
        var w = max(t.widthPx, t.heightPx), h = min(t.widthPx, t.heightPx)
        if w < 640 || h < 400 { w = 1920; h = 1200 }  // unknown/bogus → sensible default
        if !fits(w, h, t) {
            let scale = min(Double(t.decoderMaxWidth) / Double(w), Double(t.decoderMaxHeight) / Double(h), 1.0)
            w = even(Double(w) * scale); h = even(Double(h) * scale)
        }
        return ModeSpec(width: even(Double(w)), height: even(Double(h)))
    }

    public static func plan(tablet t: TabletInfo, request r: PlanRequest) -> DisplayPlan {
        let native = nativeSize(t)
        let aspect = Double(native.width) / Double(native.height)
        var stream = native
        var logical = native
        var hiDPI = false

        switch r.preset {
        case .native:
            break
        case .comfortable:
            logical = ModeSpec(width: even(Double(native.width) / 1.5), height: even(Double(native.height) / 1.5))
            hiDPI = true
        case .large:
            logical = ModeSpec(width: even(Double(native.width) / 2), height: even(Double(native.height) / 2))
            hiDPI = true
        case .performance:
            let w = min(1280, native.width)
            logical = ModeSpec(width: even(Double(w)), height: even(Double(w) / aspect))
            stream = logical
        case .custom:
            var cw = max(640, min(r.customWidth, 4096)), ch = max(400, min(r.customHeight, 2560))
            if !fits(cw, ch, t) { cw = native.width; ch = native.height }
            logical = ModeSpec(width: even(Double(cw)), height: even(Double(ch)))
            // Stream never exceeds the tablet panel; downscale preserving the custom aspect.
            let s = min(Double(native.width) / Double(cw), Double(native.height) / Double(ch), 1.0)
            stream = ModeSpec(width: even(Double(cw) * s), height: even(Double(ch) * s))
        }

        let pixel = hiDPI ? ModeSpec(width: logical.width * 2, height: logical.height * 2) : logical
        // Mode list: the chosen pixel size first, plus a few useful alternatives with the same aspect,
        // so the user can also pick other sizes in System Settings → Displays.
        // With hiDPI, macOS offers every mode W×H both at 1× and as a Retina "looks like W/2×H/2" mode.
        var candidates: [ModeSpec] = [pixel, native]
        if hiDPI {
            candidates.append(ModeSpec(width: even(Double(native.width) / 1.5) * 2, height: even(Double(native.height) / 1.5) * 2))
        } else {
            let w = min(1280, native.width)
            candidates.append(ModeSpec(width: even(Double(w)), height: even(Double(w) / aspect)))
        }
        var modes: [ModeSpec] = []
        for m in candidates where !modes.contains(m) { modes.append(m) }
        let maxW = max(modes.map(\.width).max() ?? pixel.width, pixel.width)
        let maxH = max(modes.map(\.height).max() ?? pixel.height, pixel.height)

        // Frame-rate: quality target, capped by panel refresh, decoder capability and user limit.
        var fps: Int
        switch r.quality {
        case .performance: fps = 30
        case .balanced, .quality: fps = 60
        }
        fps = min(fps, Int(t.refreshHz.rounded()), max(15, t.decoderMaxFpsNative))
        if r.fpsLimit > 0 { fps = min(fps, r.fpsLimit) }
        fps = max(15, fps)

        // Bitrate: bits-per-pixel heuristic for screen content, clamped to what USB 2 ADB handles comfortably.
        // These are ceilings for the rate control: static screen content uses a small fraction of
        // them, but fast motion gets enough bits not to break up into blocks. USB 2 ADB carries
        // well over 100 Mbit/s, so ≤ 50 Mbit/s leaves ample headroom.
        let bpp: Double
        let maxQP: Int
        switch r.quality {
        case .performance: bpp = 0.10; maxQP = 0
        case .balanced: bpp = 0.16; maxQP = 0
        case .quality: bpp = 0.25; maxQP = 0
        }
        // maxQP stays 0 (encoder default): with a QP cap VideoToolbox may *drop* a frame it cannot
        // fit, and a dropped final frame leaves stale content on a static screen.
        var bitrate = Int(Double(stream.width * stream.height * fps) * bpp)
        bitrate = min(max(bitrate, 2_000_000), 50_000_000)
        if r.customBitrateKbps > 0 { bitrate = min(max(r.customBitrateKbps * 1000, 500_000), 80_000_000) }

        // Physical size from the tablet's real pixel density so macOS reports a sensible DPI.
        let dpi = (t.xdpi >= 100 && t.xdpi <= 600) ? t.xdpi : 220
        let mm = CGSize(width: Double(native.width) / dpi * 25.4, height: Double(native.height) / dpi * 25.4)

        return DisplayPlan(streamWidth: stream.width, streamHeight: stream.height,
                           logicalWidth: logical.width, logicalHeight: logical.height,
                           pixelWidth: pixel.width, pixelHeight: pixel.height, hiDPI: hiDPI,
                           modes: modes, maxPixelsWide: maxW, maxPixelsHigh: maxH, fps: fps, bitrate: bitrate,
                           maxFrameQP: maxQP, highProfile: t.decoderHighProfile, sizeInMillimeters: mm)
    }

    /// Plan for Mirror mode: stream the chosen Mac display scaled to fit the tablet.
    public static func mirrorStreamSize(sourceWidth: Int, sourceHeight: Int, tablet t: TabletInfo, quality: StreamQuality) -> ModeSpec {
        let native = nativeSize(t)
        var maxW = native.width, maxH = native.height
        if quality == .performance { maxW = min(maxW, 1280); maxH = min(maxH, 800) }
        let s = min(Double(maxW) / Double(sourceWidth), Double(maxH) / Double(sourceHeight), 1.0)
        return ModeSpec(width: even(Double(sourceWidth) * s), height: even(Double(sourceHeight) * s))
    }
}
