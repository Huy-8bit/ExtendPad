import XCTest
@testable import ExtendPadCore

/// Loads shared/protocol/test-vectors.json — the same file the Android tests use.
private func vectors() throws -> [String: Any] {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { url.deleteLastPathComponent() }   // → repo root
    let file = url.appendingPathComponent("shared/protocol/test-vectors.json")
    let data = try Data(contentsOf: file)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

final class AuthTests: XCTestCase {
    func testSharedHMACVectors() throws {
        let v = try vectors()
        let token = try XCTUnwrap(v["token"] as? String)
        let cases = try XCTUnwrap(v["auth"] as? [[String: String]])
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            XCTAssertEqual(Auth.hmacHex(tokenHex: token, role: "client", channel: c["channel"]!, clientNonce: c["clientNonce"]!, serverNonce: c["serverNonce"]!), c["clientMac"])
            XCTAssertEqual(Auth.hmacHex(tokenHex: token, role: "server", channel: c["channel"]!, clientNonce: c["clientNonce"]!, serverNonce: c["serverNonce"]!), c["serverProof"])
        }
    }

    func testRejectsBadTokens() {
        XCTAssertNil(Auth.hmacHex(tokenHex: "abcd", role: "client", channel: "control", clientNonce: "00", serverNonce: "00"))
        XCTAssertNil(Auth.hmacHex(tokenHex: String(repeating: "zz", count: 32), role: "client", channel: "control", clientNonce: "00", serverNonce: "00"))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(Auth.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(Auth.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(Auth.constantTimeEquals("abc", "abcd"))
    }

    func testNonceValidation() {
        XCTAssertTrue(Auth.isValidNonce(String(repeating: "a", count: 32)))
        XCTAssertFalse(Auth.isValidNonce(String(repeating: "a", count: 31)))
        XCTAssertFalse(Auth.isValidNonce(String(repeating: "g", count: 32)))
    }

    func testRandomHex() {
        let a = Auth.randomHex(bytes: 32), b = Auth.randomHex(bytes: 32)
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b)
    }
}

final class FramingTests: XCTestCase {
    func testSharedFrameVectors() throws {
        let v = try vectors()
        let frames = try XCTUnwrap(v["frames"] as? [String: String])
        let ping = Frame(.ping, payload: PingPayload(id: 1, senderMicros: 2).encoded())
        XCTAssertEqual(hex(ping.encoded()), frames["ping_id1_t2"])
        let input = Frame(.inputPointer, payload: PointerEvent(action: .down, button: .left, x: 32768, y: 65535, scrollX: -5, scrollY: 120).encoded())
        XCTAssertEqual(hex(input.encoded()), frames["input_down_left_32768_65535_m5_120"])
        XCTAssertEqual(hex(Frame(.cursorPos, payload: CursorPayload.position(x: 1000, y: 65535, visible: true)).encoded()),
                       frames["cursor_pos_x1000_y65535_visible"])
        XCTAssertEqual(hex(Frame(.cursorImage, payload: CursorPayload.image(widthPt: 17, heightPt: 23, hotX: 4, hotY: 5,
                                                                            png: Data([0x89, 0x50, 0x4e, 0x47]))).encoded()),
                       frames["cursor_image_17x23_hot4x5_png_89504e47"])
    }

    func testPartialReadsByteByByte() throws {
        let frames = [Frame(.hello, payload: Data("{\"a\":1}".utf8)), Frame(.keyframeRequest), Frame(.videoFrame, payload: Data(repeating: 7, count: 70_000))]
        var stream = Data(); frames.forEach { stream.append($0.encoded()) }
        var dec = FrameDecoder(maxFrame: WireProtocol.maxVideoFrame)
        var out: [Frame] = []
        for b in stream {
            dec.append(Data([b]))
            while let f = try dec.next() { out.append(f) }
        }
        XCTAssertEqual(out, frames)
        XCTAssertEqual(dec.bufferedBytes, 0)
    }

    func testRandomChunking() throws {
        var frames: [Frame] = []
        for i in 0..<200 { frames.append(Frame(type: UInt8(i % 40 + 1), payload: Data((0..<(i * 37 % 3000)).map { UInt8($0 & 0xff) }))) }
        var stream = Data(); frames.forEach { stream.append($0.encoded()) }
        var dec = FrameDecoder(maxFrame: 65_536)
        var out: [Frame] = []
        var i = 0
        var rng = SystemRandomNumberGenerator()
        while i < stream.count {
            let n = min(Int.random(in: 1...4096, using: &rng), stream.count - i)
            dec.append(stream.subdata(in: i..<(i + n))); i += n
            while let f = try dec.next() { out.append(f) }
        }
        XCTAssertEqual(out, frames)
    }

    func testRejectsOversizedAndZeroLength() {
        var dec = FrameDecoder(maxFrame: 1024)
        var d = Data(); d.appendBE(UInt32(1025)); d.append(1)
        dec.append(d)
        XCTAssertThrowsError(try dec.next()) { XCTAssertEqual($0 as? FrameError, .tooLarge(1025)) }
        var dec2 = FrameDecoder(maxFrame: 1024)
        dec2.append(Data([0, 0, 0, 0, 1]))
        XCTAssertThrowsError(try dec2.next()) { XCTAssertEqual($0 as? FrameError, .zeroLength) }
    }

    func testPointerValidation() {
        XCTAssertNil(PointerEvent(Data([9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])), "unknown action must be rejected")
        XCTAssertNil(PointerEvent(Data([0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])), "unknown button must be rejected")
        XCTAssertNil(PointerEvent(Data([0, 0, 0])), "short payload must be rejected")
        let e = PointerEvent(action: .scroll, button: .left, x: 1, y: 2, scrollX: -300, scrollY: 300)
        XCTAssertEqual(PointerEvent(e.encoded()), e)
    }

    func testPingPongRoundTrip() {
        let p = PongPayload(id: 9, echoedMicros: 123_456_789, responderMicros: 42)
        XCTAssertEqual(PongPayload(p.encoded()), p)
        XCTAssertNil(PongPayload(Data([1, 2, 3])))
    }

    func testVideoFrameLayout() {
        let d = VideoPayload.frame(frameId: 0x01020304, keyframe: true, idleRefresh: true, ptsMicros: 5, captureMicros: 6, annexB: Data([0, 0, 0, 1, 0x65]))
        XCTAssertEqual(d.count, 21 + 5)
        XCTAssertEqual(Array(d.prefix(5)), [1, 2, 3, 4, 3])
    }

    func testClientHelloValidation() {
        let good: [String: Any] = ["magic": "EXTENDPAD", "protocol": 1, "channel": "control", "clientNonce": String(repeating: "ab", count: 16),
                                   "display": ["widthPx": 99999, "heightPx": 1200], "device": ["model": "AGS5\u{0007}-W09"]]
        let h = ClientHello(json: good)
        XCTAssertNotNil(h)
        XCTAssertEqual(h?.displayWidthPx, 8192, "untrusted sizes are clamped")
        XCTAssertEqual(h?.deviceModel, "AGS5-W09", "control characters are stripped")
        var bad = good; bad["magic"] = "NOPE"
        XCTAssertNil(ClientHello(json: bad))
        bad = good; bad["channel"] = "admin"
        XCTAssertNil(ClientHello(json: bad))
        bad = good; bad["clientNonce"] = "short"
        XCTAssertNil(ClientHello(json: bad))
    }
}

final class AnnexBTests: XCTestCase {
    func testAvccToAnnexB() {
        let avcc: [UInt8] = [0, 0, 0, 2, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0, 0, 0, 3, 0x65, 0x88, 0x99]
        let out = avcc.withUnsafeBufferPointer { H264Encoder.avccToAnnexB($0, lengthSize: 4) }
        XCTAssertEqual(out.map { Array($0) }, [0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65, 0x88, 0x99])
        XCTAssertEqual(SelfTest.nalTypes(out!), [7, 8, 5])
    }

    func testMalformedAvccRejected() {
        let bad: [UInt8] = [0, 0, 0, 9, 0x65, 0x88]
        XCTAssertNil(bad.withUnsafeBufferPointer { H264Encoder.avccToAnnexB($0, lengthSize: 4) })
        XCTAssertNil([UInt8]([0, 0, 0, 0]).withUnsafeBufferPointer { H264Encoder.avccToAnnexB($0, lengthSize: 4) })
    }
}

final class ADBParsingTests: XCTestCase {
    func testParseDevices() {
        let text = """
        List of devices attached
        * daemon started successfully
        AGS5ABCDEF123\tdevice usb:1-1 product:AGS5-W09 model:AGS5_W09 device:HWAGS5 transport_id:3
        XYZ999\tunauthorized usb:2-1 transport_id:4
        192.168.1.7:5555\tdevice product:x model:Pixel transport_id:5
        emulator-5554\tdevice product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 transport_id:1
        BADDEV\tno permissions (user in plugdev group); see [http://developer.android.com/tools/device.html] usb:3-1
        rm -rf\tdevice
        """
        let d = ADB.parseDevices(text)
        XCTAssertEqual(d.count, 5, "invalid serials are dropped")
        XCTAssertEqual(d[0].serial, "AGS5ABCDEF123"); XCTAssertEqual(d[0].state, .device); XCTAssertTrue(d[0].isUSB); XCTAssertEqual(d[0].model, "AGS5 W09")
        XCTAssertEqual(d[1].state, .unauthorized)
        XCTAssertTrue(d[2].isNetwork); XCTAssertFalse(d[2].isUSB)
        XCTAssertTrue(d[3].isEmulator); XCTAssertFalse(d[3].isUSB)
        XCTAssertEqual(d[4].state, .noPermissions)
    }

    func testSerialValidation() {
        XCTAssertTrue(ADB.isValidSerial("AGS5ABCDEF123"))
        XCTAssertTrue(ADB.isValidSerial("adb-R5CT.local:5555"))
        XCTAssertFalse(ADB.isValidSerial("a;b"))
        XCTAssertFalse(ADB.isValidSerial("$(x)"))
        XCTAssertFalse(ADB.isValidSerial(""))
    }
}

final class InputMappingTests: XCTestCase {
    func testMapsIntoDisplayBounds() {
        let b = CGRect(x: 1512, y: 100, width: 1332, height: 800)
        let tl = InputInjector.map(PointerEvent(action: .move, button: .left, x: 0, y: 0), into: b)
        let br = InputInjector.map(PointerEvent(action: .move, button: .left, x: 65535, y: 65535), into: b)
        let mid = InputInjector.map(PointerEvent(action: .move, button: .left, x: 32768, y: 32768), into: b)
        XCTAssertEqual(tl, CGPoint(x: 1512, y: 100))
        XCTAssertEqual(br, CGPoint(x: 1512 + 1331, y: 100 + 799), "never lands on a neighbouring display")
        XCTAssertEqual(mid.x, 1512 + 665, accuracy: 1)
        XCTAssertEqual(InputInjector.map(PointerEvent(action: .move, button: .left, x: 1, y: 1), into: .zero), .zero)
    }

    func testNegativeOriginDisplays() {
        let b = CGRect(x: -1332, y: 0, width: 1332, height: 800)
        let p = InputInjector.map(PointerEvent(action: .move, button: .left, x: 65535, y: 0), into: b)
        XCTAssertEqual(p.x, -1, accuracy: 0.5)
    }
}
