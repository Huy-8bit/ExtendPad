import Foundation
import CryptoKit

/// ExtendPad wire protocol v1 — see shared/protocol/PROTOCOL.md.
public enum WireProtocol {
    public static let version = 1
    public static let magic = "EXTENDPAD"
    public static let defaultPort: UInt16 = 27183
    public static let maxControlFrame = 65_536
    public static let maxVideoFrame = 8 * 1024 * 1024
    public static let headerSize = 5
}

public enum MessageType: UInt8 {
    case hello = 0x01, challenge = 0x02, auth = 0x03, accept = 0x04, reject = 0x05
    case streamConfig = 0x10, stats = 0x11, keyframeRequest = 0x12, ping = 0x13, pong = 0x14
    case frameAck = 0x15, settingsRequest = 0x16, error = 0x17, bye = 0x18
    case streamPause = 0x19, streamResume = 0x1A
    case inputPointer = 0x20
    case cursorImage = 0x21, cursorPos = 0x22
    case videoConfig = 0x30, videoFrame = 0x31
}

public struct Frame: Equatable {
    public var type: UInt8
    public var payload: Data
    public init(type: UInt8, payload: Data = Data()) { self.type = type; self.payload = payload }
    public init(_ type: MessageType, payload: Data = Data()) { self.type = type.rawValue; self.payload = payload }
    public var messageType: MessageType? { MessageType(rawValue: type) }

    public func encoded() -> Data {
        var d = Data(capacity: WireProtocol.headerSize + payload.count)
        d.appendBE(UInt32(1 + payload.count))
        d.append(type)
        d.append(payload)
        return d
    }

    public static func json(_ type: MessageType, _ object: [String: Any]) -> Frame {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Frame(type, payload: data)
    }

    public func jsonObject() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }
}

public enum FrameError: Error, Equatable, CustomStringConvertible {
    case zeroLength
    case tooLarge(Int)
    public var description: String {
        switch self {
        case .zeroLength: return "frame length 0"
        case .tooLarge(let n): return "frame length \(n) exceeds limit"
        }
    }
}

/// Incremental frame parser that tolerates arbitrary chunk boundaries (partial reads).
public struct FrameDecoder {
    public let maxFrame: Int
    private var buffer = Data()
    public init(maxFrame: Int) { self.maxFrame = maxFrame }

    public mutating func append(_ chunk: Data) { buffer.append(chunk) }

    /// Returns the next complete frame, nil if more bytes are needed, or throws on a protocol violation.
    public mutating func next() throws -> Frame? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let len = Int(buffer.readBE32(at: start))
        if len == 0 { throw FrameError.zeroLength }
        if len > maxFrame { throw FrameError.tooLarge(len) }
        guard buffer.count >= 4 + len else { return nil }
        let type = buffer[start + 4]
        let payload = Data(buffer[(start + 5)..<(start + 4 + len)])
        buffer.removeSubrange(start..<(start + 4 + len))
        if buffer.isEmpty { buffer = Data() } // reset indices
        return Frame(type: type, payload: payload)
    }

    public var bufferedBytes: Int { buffer.count }
}

// MARK: - Binary payloads

public struct PingPayload: Equatable {
    public var id: UInt64; public var senderMicros: UInt64
    public init(id: UInt64, senderMicros: UInt64) { self.id = id; self.senderMicros = senderMicros }
    public func encoded() -> Data { var d = Data(); d.appendBE(id); d.appendBE(senderMicros); return d }
    public init?(_ d: Data) {
        guard d.count >= 16 else { return nil }
        id = d.readBE64(at: d.startIndex); senderMicros = d.readBE64(at: d.startIndex + 8)
    }
}

public struct PongPayload: Equatable {
    public var id: UInt64; public var echoedMicros: UInt64; public var responderMicros: UInt64
    public init(id: UInt64, echoedMicros: UInt64, responderMicros: UInt64) {
        self.id = id; self.echoedMicros = echoedMicros; self.responderMicros = responderMicros
    }
    public func encoded() -> Data { var d = Data(); d.appendBE(id); d.appendBE(echoedMicros); d.appendBE(responderMicros); return d }
    public init?(_ d: Data) {
        guard d.count >= 24 else { return nil }
        let s = d.startIndex
        id = d.readBE64(at: s); echoedMicros = d.readBE64(at: s + 8); responderMicros = d.readBE64(at: s + 16)
    }
}

public struct FrameAckPayload: Equatable {
    public var frameId: UInt32; public var receiveToRenderMicros: UInt32
    public init?(_ d: Data) {
        guard d.count >= 8 else { return nil }
        frameId = d.readBE32(at: d.startIndex); receiveToRenderMicros = d.readBE32(at: d.startIndex + 4)
    }
}

public struct PointerEvent: Equatable {
    public enum Action: UInt8 { case move = 0, down = 1, up = 2, scroll = 3, cancel = 4 }
    public enum Button: UInt8 { case left = 0, right = 1 }
    public var action: Action
    public var button: Button
    public var x: UInt16
    public var y: UInt16
    public var scrollX: Int16
    public var scrollY: Int16

    public init(action: Action, button: Button, x: UInt16, y: UInt16, scrollX: Int16 = 0, scrollY: Int16 = 0) {
        self.action = action; self.button = button; self.x = x; self.y = y; self.scrollX = scrollX; self.scrollY = scrollY
    }

    /// Strict validation: unknown action/button values are rejected, not coerced.
    public init?(_ d: Data) {
        guard d.count >= 12 else { return nil }
        let s = d.startIndex
        guard let a = Action(rawValue: d[s]), let b = Button(rawValue: d[s + 1]) else { return nil }
        action = a; button = b
        x = d.readBE16(at: s + 2); y = d.readBE16(at: s + 4)
        scrollX = Int16(bitPattern: d.readBE16(at: s + 6)); scrollY = Int16(bitPattern: d.readBE16(at: s + 8))
    }

    public func encoded() -> Data {
        var d = Data(); d.append(action.rawValue); d.append(button.rawValue)
        d.appendBE(x); d.appendBE(y); d.appendBE(UInt16(bitPattern: scrollX)); d.appendBE(UInt16(bitPattern: scrollY)); d.appendBE(UInt16(0))
        return d
    }

    public var normalizedX: Double { Double(x) / 65535.0 }
    public var normalizedY: Double { Double(y) / 65535.0 }
}

public enum VideoPayload {
    public static func config(width: Int, height: Int, profileIdc: UInt8, levelIdc: UInt8, annexB: Data) -> Data {
        var d = Data(); d.appendBE(UInt16(width)); d.appendBE(UInt16(height)); d.append(profileIdc); d.append(levelIdc)
        d.appendBE(UInt16(0)); d.append(annexB); return d
    }
    public static func frame(frameId: UInt32, keyframe: Bool, idleRefresh: Bool, ptsMicros: UInt64,
                             captureMicros: UInt64, annexB: Data) -> Data {
        var d = Data(capacity: 21 + annexB.count)
        d.appendBE(frameId)
        d.append((keyframe ? 1 : 0) | (idleRefresh ? 2 : 0))
        d.appendBE(ptsMicros); d.appendBE(captureMicros); d.append(annexB)
        return d
    }
}

/// Mac-side cursor, rendered locally on the tablet so it moves independently of the video.
public enum CursorPayload {
    /// u16 x, u16 y (0..65535 across the display), u8 visible.
    public static func position(x: UInt16, y: UInt16, visible: Bool) -> Data {
        var d = Data(); d.appendBE(x); d.appendBE(y); d.append(visible ? 1 : 0); return d
    }
    /// u16 widthPt, u16 heightPt, u16 hotX, u16 hotY (macOS points), then PNG bytes.
    public static func image(widthPt: Int, heightPt: Int, hotX: Int, hotY: Int, png: Data) -> Data {
        var d = Data()
        for v in [widthPt, heightPt, hotX, hotY] { d.appendBE(UInt16(clamping: max(0, v))) }
        d.append(png); return d
    }
}

// MARK: - Authentication

public enum Auth {
    public static func randomHex(bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return b.map { String(format: "%02x", $0) }.joined()
    }

    public static func hexDecode(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let byte = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(byte); idx = next
        }
        return out
    }

    public static func hmacHex(tokenHex: String, role: String, channel: String, clientNonce: String, serverNonce: String) -> String? {
        guard let key = hexDecode(tokenHex), key.count == 32 else { return nil }
        let msg = "EXTENDPAD-v1|\(role)|\(channel)|\(clientNonce.lowercased())|\(serverNonce.lowercased())"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key))
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison of two hex strings.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    public static func isValidNonce(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0.isHexDigit }
    }
}

// MARK: - Data helpers

extension Data {
    mutating func appendBE(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xff)) }
    mutating func appendBE(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func appendBE(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { append(UInt8((v >> UInt64(s)) & 0xff)) } }
    func readBE16(at i: Index) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    func readBE32(at i: Index) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
    func readBE64(at i: Index) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = v << 8 | UInt64(self[i + k]) }
        return v
    }
}
