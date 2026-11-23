import XCTest
@testable import ExtendPadCore

private func tablet(_ w: Int = 2000, _ h: Int = 1200, maxW: Int = 4096, maxH: Int = 2176, fps: Int = 120, hz: Double = 60) -> TabletInfo {
    TabletInfo(widthPx: w, heightPx: h, xdpi: 224, refreshHz: hz, decoderMaxWidth: maxW, decoderMaxHeight: maxH,
               decoderHighProfile: true, decoderMaxFpsNative: fps)
}

final class DisplayPlannerTests: XCTestCase {
    func testNativePreset() {
        let p = DisplayPlanner.plan(tablet: tablet(), request: PlanRequest(preset: .native, quality: .balanced))
        XCTAssertEqual([p.logicalWidth, p.logicalHeight, p.pixelWidth, p.pixelHeight, p.streamWidth, p.streamHeight], [2000, 1200, 2000, 1200, 2000, 1200])
        XCTAssertFalse(p.hiDPI)
        XCTAssertEqual(p.fps, 60)
        XCTAssertTrue(p.modes.contains(ModeSpec(width: 2000, height: 1200)))
    }

    func testComfortableIsRetinaScaledToNative() {
        let p = DisplayPlanner.plan(tablet: tablet(), request: PlanRequest(preset: .comfortable, quality: .balanced))
        XCTAssertTrue(p.hiDPI)
        XCTAssertEqual(p.logicalWidth, 1332); XCTAssertEqual(p.logicalHeight, 800)
        XCTAssertEqual(p.pixelWidth, 2664); XCTAssertEqual(p.pixelHeight, 1600)
        XCTAssertEqual(p.streamWidth, 2000); XCTAssertEqual(p.streamHeight, 1200)
        XCTAssertEqual(p.modes.first, ModeSpec(width: 2664, height: 1600))
        XCTAssertGreaterThanOrEqual(p.maxPixelsWide, 2664)
    }

    func testPortraitReportedPanelIsLandscaped() {
        let p = DisplayPlanner.plan(tablet: tablet(1200, 2000), request: PlanRequest(preset: .native, quality: .balanced))
        XCTAssertEqual(p.streamWidth, 2000); XCTAssertEqual(p.streamHeight, 1200)
    }

    func testDecoderLimitsDownscale() {
        let p = DisplayPlanner.plan(tablet: tablet(maxW: 1920, maxH: 1088), request: PlanRequest(preset: .native, quality: .balanced))
        XCTAssertLessThanOrEqual(p.streamWidth, 1920); XCTAssertLessThanOrEqual(p.streamHeight, 1088)
        XCTAssertEqual(Double(p.streamWidth) / Double(p.streamHeight), 2000.0 / 1200.0, accuracy: 0.02, "aspect preserved")
        XCTAssertEqual(p.streamWidth % 2, 0); XCTAssertEqual(p.streamHeight % 2, 0)
    }

    func testPerformancePreset() {
        let p = DisplayPlanner.plan(tablet: tablet(), request: PlanRequest(preset: .performance, quality: .performance))
        XCTAssertEqual(p.streamWidth, 1280); XCTAssertEqual(p.streamHeight, 768)
        XCTAssertEqual(p.fps, 30)
    }

    func testFpsCappedByPanelDecoderAndUser() {
        XCTAssertEqual(DisplayPlanner.plan(tablet: tablet(hz: 50), request: PlanRequest(preset: .native, quality: .balanced)).fps, 50)
        XCTAssertEqual(DisplayPlanner.plan(tablet: tablet(fps: 40), request: PlanRequest(preset: .native, quality: .balanced)).fps, 40)
        XCTAssertEqual(DisplayPlanner.plan(tablet: tablet(), request: PlanRequest(preset: .native, quality: .balanced, fpsLimit: 45)).fps, 45)
    }

    func testBitrateBoundsAndCustom() {
        let q = DisplayPlanner.plan(tablet: tablet(), request: PlanRequest(preset: .native, quality: .quality))
        let b = DisplayPlanner.plan(tablet: tablet(), request: PlanRequest(preset: .native, quality: .balanced))
        XCTAssertGreaterThan(q.bitrate, b.bitrate)
        XCTAssertLessThanOrEqual(q.bitrate, 50_000_000)
        XCTAssertEqual(q.maxFrameQP, 0, "no QP cap: it makes VideoToolbox drop frames")
        let c = DisplayPlanner.plan(tablet: tablet(), request: PlanRequest(preset: .native, quality: .balanced, customBitrateKbps: 12_000))
        XCTAssertEqual(c.bitrate, 12_000_000)
    }

    func testCustomResolutionStreamNeverExceedsPanel() {
        let p = DisplayPlanner.plan(tablet: tablet(), request: PlanRequest(preset: .custom, quality: .balanced, customWidth: 1920, customHeight: 1200))
        XCTAssertEqual(p.logicalWidth, 1920); XCTAssertEqual(p.logicalHeight, 1200)
        XCTAssertLessThanOrEqual(p.streamWidth, 2000); XCTAssertLessThanOrEqual(p.streamHeight, 1200)
    }

    func testBogusPanelFallsBack() {
        let p = DisplayPlanner.plan(tablet: tablet(0, 0), request: PlanRequest(preset: .native, quality: .balanced))
        XCTAssertEqual(p.streamWidth, 1920); XCTAssertEqual(p.streamHeight, 1200)
    }

    func testSupportedResolutionsFiltered() {
        let list = DisplayPlanner.supportedResolutions(for: tablet(maxW: 1600, maxH: 1600))
        XCTAssertFalse(list.contains(ModeSpec(width: 1920, height: 1200)))
        XCTAssertTrue(list.contains(ModeSpec(width: 1280, height: 800)))
    }

    func testMirrorSize() {
        let s = DisplayPlanner.mirrorStreamSize(sourceWidth: 3024, sourceHeight: 1964, tablet: tablet(), quality: .balanced)
        XCTAssertLessThanOrEqual(s.width, 2000); XCTAssertLessThanOrEqual(s.height, 1200)
        XCTAssertEqual(Double(s.width) / Double(s.height), 3024.0 / 1964.0, accuracy: 0.01)
    }
}

final class FlowControllerTests: XCTestCase {
    func testWindowLimitsAndCumulativeAcks() {
        var f = FlowController(targetBitrate: 10_000_000)
        for i in 1...6 { XCTAssertTrue(f.canEncode(now: 1000, encoderInFlight: 0, queuedSendBytes: 0)); f.didSend(frameId: UInt32(i), now: 1000, captureMicros: 900) }
        XCTAssertFalse(f.canEncode(now: 1000, encoderInFlight: 0, queuedSendBytes: 0), "window full")
        let hit = f.ack(frameId: 4)
        XCTAssertEqual(hit?.captureMicros, 900)
        XCTAssertEqual(f.unacked.map(\.frameId), [5, 6], "ack retires older frames too")
        XCTAssertTrue(f.canEncode(now: 1000, encoderInFlight: 0, queuedSendBytes: 0))
    }

    func testEncoderAndSocketBackpressure() {
        let f = FlowController(targetBitrate: 10_000_000)
        XCTAssertFalse(f.canEncode(now: 0, encoderInFlight: f.maxEncoderInFlight, queuedSendBytes: 0))
        XCTAssertFalse(f.canEncode(now: 0, encoderInFlight: 0, queuedSendBytes: f.maxQueuedSendBytes + 1))
    }

    func testAgeLimitAndStallReset() {
        var f = FlowController(targetBitrate: 10_000_000)
        f.didSend(frameId: 1, now: 0, captureMicros: 0)
        XCTAssertTrue(f.canEncode(now: 100_000, encoderInFlight: 0, queuedSendBytes: 0))
        XCTAssertFalse(f.canEncode(now: 300_000, encoderInFlight: 0, queuedSendBytes: 0), "oldest unacked too old")
        XCTAssertFalse(f.checkStall(now: 1_000_000))
        XCTAssertTrue(f.checkStall(now: 2_000_000))
        XCTAssertTrue(f.unacked.isEmpty)
    }

    func testAckWithWrappedIds() {
        var f = FlowController(targetBitrate: 1)
        f.didSend(frameId: UInt32.max - 1, now: 0, captureMicros: 0)
        f.didSend(frameId: UInt32.max, now: 0, captureMicros: 0)
        f.didSend(frameId: 1, now: 0, captureMicros: 0)
        _ = f.ack(frameId: 0)   // unknown id after wrap: retires frames before it
        XCTAssertEqual(f.unacked.map(\.frameId), [1])
    }

    func testAdaptiveBitrate() {
        var f = FlowController(targetBitrate: 10_000_000, minBitrate: 2_000_000)
        for _ in 0..<20 { f.recordDrop() }
        XCTAssertEqual(f.tick(framesWanted: 60), 8_500_000)
        for _ in 0..<20 { f.recordDrop() }
        XCTAssertEqual(f.tick(framesWanted: 60), 7_225_000)
        XCTAssertNil(f.tick(framesWanted: 60)); XCTAssertNil(f.tick(framesWanted: 60))
        let up = f.tick(framesWanted: 60)
        XCTAssertNotNil(up); XCTAssertGreaterThan(up!, 7_225_000)
        for _ in 0..<200 { _ = f.tick(framesWanted: 60) }
        XCTAssertEqual(f.currentBitrate, 10_000_000, "never exceeds the target")
        for _ in 0..<100 { for _ in 0..<30 { f.recordDrop() }; _ = f.tick(framesWanted: 60) }
        XCTAssertEqual(f.currentBitrate, 2_000_000, "never below the floor")
    }

    func testFewDropsDoNotReduce() {
        var f = FlowController(targetBitrate: 10_000_000)
        f.recordDrop(); f.recordDrop()
        XCTAssertNil(f.tick(framesWanted: 60))
    }
}

final class SettingsCodingTests: XCTestCase {
    func testPartialSettingsKeepDefaults() throws {
        let s = try JSONDecoder().decode(EngineSettings.self, from: Data(#"{"quality":"quality","allowEmulator":true,"unknownKey":5}"#.utf8))
        XCTAssertEqual(s.quality, .quality)
        XCTAssertTrue(s.allowEmulator)
        XCTAssertEqual(s.preset, .comfortable)
        XCTAssertEqual(s.displayGraceSeconds, 20)
    }

    func testRoundTrip() throws {
        var s = EngineSettings(); s.mode = .mirror; s.customBitrateKbps = 9000
        XCTAssertEqual(try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(s)), s)
    }
}

final class AdaptiveBitrateCongestionTests: XCTestCase {
    func testDecoderBoundDropsHoldBitrate() {
        var f = FlowController(targetBitrate: 10_000_000)
        for _ in 0..<5 {
            for _ in 0..<30 { f.recordDrop() }
            XCTAssertNil(f.tick(framesWanted: 60, congested: false), "slow decoder must not reduce bitrate")
        }
        XCTAssertEqual(f.currentBitrate, 10_000_000)
        for _ in 0..<30 { f.recordDrop() }
        XCTAssertEqual(f.tick(framesWanted: 60, congested: true), 8_500_000)
    }
}

final class RetargetTests: XCTestCase {
    func testRetargetStartsAtNewTarget() {
        var f = FlowController(targetBitrate: 8_000_000)
        f.retarget(20_000_000)
        XCTAssertEqual(f.currentBitrate, 20_000_000)
        f.retarget(5_000_000)
        XCTAssertEqual(f.currentBitrate, 5_000_000)
    }
}
