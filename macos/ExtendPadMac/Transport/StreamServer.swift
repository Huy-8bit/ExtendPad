import Foundation
import Network

/// Information the tablet reported in its control-channel HELLO.
public struct ClientHello {
    public var channel: String
    public var clientNonce: String
    public var sessionId: String?
    public var appVersion: String
    public var deviceModel: String
    public var deviceManufacturer: String
    public var sdk: Int
    public var release: String
    public var harmony: String
    public var displayWidthPx: Int
    public var displayHeightPx: Int
    public var densityDpi: Int
    public var xdpi: Double
    public var refreshHz: Double
    public var decoderName: String
    public var decoderHardware: Bool
    public var decoderLowLatency: Bool
    public var decoderMaxWidth: Int
    public var decoderMaxHeight: Int
    public var decoderHighProfile: Bool
    public var decoderMaxFpsNative: Int
    public var raw: [String: Any]

    public init?(json: [String: Any]) {
        guard json["magic"] as? String == WireProtocol.magic,
              (json["protocol"] as? Int) == WireProtocol.version,
              let channel = json["channel"] as? String, channel == "control" || channel == "video",
              let nonce = json["clientNonce"] as? String, Auth.isValidNonce(nonce) else { return nil }
        self.channel = channel
        self.clientNonce = nonce.lowercased()
        self.sessionId = json["sessionId"] as? String
        self.appVersion = (json["appVersion"] as? String) ?? "?"
        let device = json["device"] as? [String: Any] ?? [:]
        let display = json["display"] as? [String: Any] ?? [:]
        let decoder = json["decoder"] as? [String: Any] ?? [:]
        deviceModel = Self.clean(device["model"] as? String ?? "Android tablet")
        deviceManufacturer = Self.clean(device["manufacturer"] as? String ?? "")
        sdk = device["sdk"] as? Int ?? 0
        release = Self.clean(device["release"] as? String ?? "")
        harmony = Self.clean(device["harmony"] as? String ?? "")
        displayWidthPx = Self.clamp(display["widthPx"] as? Int ?? 0, 0, 8192)
        displayHeightPx = Self.clamp(display["heightPx"] as? Int ?? 0, 0, 8192)
        densityDpi = Self.clamp(display["densityDpi"] as? Int ?? 160, 72, 1000)
        xdpi = (display["xdpi"] as? Double) ?? Double(densityDpi)
        refreshHz = min(max((display["refreshHz"] as? Double) ?? 60, 24), 240)
        decoderName = Self.clean(decoder["name"] as? String ?? "unknown")
        decoderHardware = decoder["hardware"] as? Bool ?? false
        decoderLowLatency = decoder["lowLatency"] as? Bool ?? false
        decoderMaxWidth = Self.clamp(decoder["maxWidth"] as? Int ?? 1920, 320, 8192)
        decoderMaxHeight = Self.clamp(decoder["maxHeight"] as? Int ?? 1088, 240, 8192)
        decoderHighProfile = decoder["highProfile"] as? Bool ?? false
        decoderMaxFpsNative = Self.clamp(decoder["maxFpsNative"] as? Int ?? 60, 1, 240)
        raw = json
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
    /// Untrusted strings are only ever displayed; still strip control characters and cap length.
    private static func clean(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80).map(Character.init))
    }

    public var displayName: String {
        let m = deviceManufacturer.isEmpty ? "" : deviceManufacturer.capitalized + " "
        return m + deviceModel
    }
}

public protocol StreamServerDelegate: AnyObject {
    /// Called on the main queue once a control channel authenticated.
    func server(_ server: StreamServer, didAcceptControl connection: FramedConnection, hello: ClientHello, sessionId: String)
    /// Called on the main queue once a video channel authenticated for `sessionId`.
    func server(_ server: StreamServer, didAcceptVideo connection: FramedConnection, sessionId: String)
    /// Called on the main queue to check whether a video channel's session id is live.
    func server(_ server: StreamServer, isLiveSession sessionId: String) -> Bool
    func serverListenerFailed(_ server: StreamServer, error: String)
}

/// Loopback-only TCP listener that performs the HMAC handshake before handing connections off.
public final class StreamServer: @unchecked Sendable {
    public let port: UInt16
    public weak var delegate: StreamServerDelegate?
    private var listener: NWListener?
    private let tokenProvider: () -> String
    private let serverName: String
    private let appVersion: String
    private var handshakes: [UUID: FramedConnection] = [:]
    private let lock = NSLock()

    public init(port: UInt16, serverName: String, appVersion: String, tokenProvider: @escaping () -> String) {
        self.port = port
        self.serverName = serverName
        self.appVersion = appVersion
        self.tokenProvider = tokenProvider
    }

    public var isListening: Bool { listener != nil }

    public func start() throws {
        guard listener == nil else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        // Bind strictly to the IPv4 loopback address; never a public interface.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: logInfo("server", "listening on 127.0.0.1:\(self.port)")
            case .failed(let err):
                logError("server", "listener failed: \(err)")
                DispatchQueue.main.async {
                    self.listener = nil
                    self.delegate?.serverListenerFailed(self, error: "\(err)")
                }
            default: break
            }
        }
        l.start(queue: DispatchQueue(label: "extendpad.listener"))
        listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.lock(); let pending = handshakes.values; handshakes.removeAll(); lock.unlock()
        pending.forEach { $0.close(reason: "server stopped") }
    }

    private func handle(_ nw: NWConnection) {
        // Defence in depth: only accept loopback peers even though we bind to loopback.
        if case let .hostPort(host, _) = nw.endpoint {
            let h = "\(host)"
            if !(h == "127.0.0.1" || h == "::1" || h.hasPrefix("::ffff:127.0.0.1")) {
                logWarn("server", "rejecting non-loopback peer \(h)")
                nw.cancel(); return
            }
        }
        logDebug("server", "accepted connection from \(nw.endpoint)")
        let conn = FramedConnection(connection: nw, maxFrame: WireProtocol.maxControlFrame, label: "handshake")
        lock.lock(); handshakes[conn.id] = conn; lock.unlock()

        var hello: ClientHello?
        var serverNonce = ""
        var finished = false

        let timeout = DispatchWorkItem { [weak self, weak conn] in
            guard let conn, !finished else { return }
            logWarn("server", "handshake timeout")
            conn.close(reason: "handshake timeout")
            self?.forget(conn)
        }
        conn.queue.asyncAfter(deadline: .now() + 5, execute: timeout)

        let reject: (String, String) -> Void = { [weak self] code, message in
            logWarn("server", "reject \(code): \(message)")
            conn.send(Frame.json(.reject, ["code": code, "message": message])) { _ in conn.close(reason: "rejected") }
            finished = true
            timeout.cancel()
            self?.forget(conn)
        }

        conn.onClose = { [weak self] _ in timeout.cancel(); self?.forget(conn) }
        conn.onFrame = { [weak self] frame in
            logDebug("server", "handshake frame 0x\(String(frame.type, radix: 16)) (\(frame.payload.count) bytes)")
            guard let self, !finished else { return }
            switch frame.messageType {
            case .hello where hello == nil:
                guard let json = frame.jsonObject() else { return reject("bad_hello", "invalid JSON") }
                if (json["protocol"] as? Int) != WireProtocol.version {
                    return reject("version", "unsupported protocol version \(json["protocol"] ?? "nil"); Mac speaks \(WireProtocol.version)")
                }
                guard let h = ClientHello(json: json) else { return reject("bad_hello", "malformed HELLO") }
                hello = h
                serverNonce = Auth.randomHex(bytes: 16)
                conn.send(Frame.json(.challenge, ["protocol": WireProtocol.version, "serverNonce": serverNonce,
                                                  "serverName": self.serverName, "appVersion": self.appVersion]))
            case .auth where hello != nil:
                guard let h = hello, let json = frame.jsonObject(), let mac = json["mac"] as? String else {
                    return reject("auth", "malformed AUTH")
                }
                let token = self.tokenProvider()
                guard let expected = Auth.hmacHex(tokenHex: token, role: "client", channel: h.channel,
                                                  clientNonce: h.clientNonce, serverNonce: serverNonce),
                      Auth.constantTimeEquals(expected, mac.lowercased()),
                      let proof = Auth.hmacHex(tokenHex: token, role: "server", channel: h.channel,
                                               clientNonce: h.clientNonce, serverNonce: serverNonce) else {
                    return reject("auth", "pairing token mismatch — reconnect the tablet over USB so the Mac can re-pair it")
                }
                finished = true
                timeout.cancel()
                self.forget(conn)
                conn.detach()   // hold any further frames until the session adopts the connection
                DispatchQueue.main.async {
                    if h.channel == "control" {
                        let sid = Auth.randomHex(bytes: 12)
                        conn.label = "control"
                        conn.send(Frame.json(.accept, ["sessionId": sid, "serverProof": proof]))
                        self.delegate?.server(self, didAcceptControl: conn, hello: h, sessionId: sid)
                    } else {
                        guard let sid = h.sessionId, self.delegate?.server(self, isLiveSession: sid) == true else {
                            conn.send(Frame.json(.reject, ["code": "session", "message": "unknown session"])) { _ in
                                conn.close(reason: "unknown session")
                            }
                            return
                        }
                        conn.label = "video"
                        conn.send(Frame.json(.accept, ["sessionId": sid, "serverProof": proof]))
                        self.delegate?.server(self, didAcceptVideo: conn, sessionId: sid)
                    }
                }
            default:
                reject("sequence", "unexpected message 0x\(String(frame.type, radix: 16)) during handshake")
            }
        }
        conn.start()
    }

    private func forget(_ conn: FramedConnection) {
        lock.lock(); handshakes.removeValue(forKey: conn.id); lock.unlock()
    }
}
