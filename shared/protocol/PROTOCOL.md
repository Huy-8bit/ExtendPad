# ExtendPad Wire Protocol — version 1

ExtendPad uses **two TCP connections** between the Android tablet (client) and the
Mac (server). Both run through the USB ADB transport via `adb reverse`:

```
Android 127.0.0.1:27183  ──adbd──USB──adb server──▶  Mac 127.0.0.1:27183
```

The Mac listens **only on 127.0.0.1**. No public interface is ever bound.

| Channel  | Direction of bulk data | Purpose |
|----------|------------------------|---------|
| control  | both                   | handshake, stream config, heartbeats, acks, stats, input, settings |
| video    | Mac → Android          | H.264 parameter sets and access units |

Keeping video on its own socket means heartbeats, frame acks and touch input are never
stuck behind a large keyframe (no head‑of‑line blocking on the control path).

## 1. Framing

Every message on both channels uses the same frame:

```
+----------------+---------+---------------------+
| length: u32 BE | type:u8 | payload (length-1)  |
+----------------+---------+---------------------+
```

* `length` counts the type byte plus the payload (so `length >= 1`).
* All integers are **big‑endian**.
* Maximum `length`: **65 536** on the control channel, **8 388 608** (8 MiB) on the
  video channel. A receiver that sees a larger value MUST close the connection.
* `length == 0` is invalid and MUST close the connection.
* Readers must handle partial reads; writers must handle partial writes.

## 2. Message types

JSON payloads are UTF‑8 objects. Unknown JSON fields MUST be ignored. Unknown message
types on the control channel MUST be ignored (forward compatibility); on the video
channel they are skipped as well.

| Type | Name              | Channel | Dir | Payload |
|------|-------------------|---------|-----|---------|
| 0x01 | HELLO             | both    | C→S | JSON |
| 0x02 | CHALLENGE         | both    | S→C | JSON |
| 0x03 | AUTH              | both    | C→S | JSON |
| 0x04 | ACCEPT            | both    | S→C | JSON |
| 0x05 | REJECT            | both    | S→C | JSON `{code, message}` then close |
| 0x10 | STREAM_CONFIG     | control | S→C | JSON |
| 0x11 | STATS             | control | C→S | JSON |
| 0x12 | KEYFRAME_REQUEST  | control | C→S | empty |
| 0x13 | PING              | control | both| `u64 id, u64 senderMonotonicMicros` |
| 0x14 | PONG              | control | both| `u64 id, u64 echoedSenderMicros, u64 responderMonotonicMicros` |
| 0x15 | FRAME_ACK         | control | C→S | `u32 frameId, u32 receiveToRenderMicros` |
| 0x16 | SETTINGS_REQUEST  | control | C→S | JSON `{quality?, preset?, statsOverlay?}` |
| 0x17 | ERROR             | control | both| JSON `{code, message}` |
| 0x18 | BYE               | control | both| JSON `{reason}` then close |
| 0x19 | STREAM_PAUSE      | control | C→S | empty — tablet backgrounded / surface gone |
| 0x1A | STREAM_RESUME     | control | C→S | empty — implies a keyframe request |
| 0x20 | INPUT_POINTER     | control | C→S | binary, see §5 |
| 0x21 | CURSOR_IMAGE      | control | S→C | `u16 widthPt, u16 heightPt, u16 hotX, u16 hotY` (macOS points), PNG (2× scale) |
| 0x22 | CURSOR_POS        | control | S→C | `u16 x, u16 y` (0..65535 across the display), `u8 visible` — sent at up to 120 Hz on change |
| 0x30 | VIDEO_CONFIG      | video   | S→C | `u16 width, u16 height, u8 profileIdc, u8 levelIdc, u16 reserved, Annex‑B SPS+PPS` |
| 0x31 | VIDEO_FRAME       | video   | S→C | `u32 frameId, u8 flags, u64 ptsMicros, u64 captureMonotonicMicros, Annex‑B access unit` |

`VIDEO_FRAME.flags`: bit 0 = keyframe (IDR), bit 1 = idle refresh (re‑encode of an
unchanged screen to sharpen text). Other bits are reserved and must be 0.

A `VIDEO_CONFIG` is always sent before the first frame and before any frame that uses
new parameter sets (e.g. after a resolution change). The decoder (re)configures itself
when it sees a `VIDEO_CONFIG` whose bytes differ from the current one.

## 3. Handshake and authentication

The Mac app owns a 32‑byte random **pairing token** (hex encoded, 64 chars). It delivers
it to the tablet over the ADB USB link only:

```
adb -s <serial> shell am start -n com.extendpad.android/.ui.MainActivity \
    -a com.extendpad.action.CONNECT --es ep_token <hex> --ei ep_port 27183
```

The token never crosses a network interface and is never sent over the socket. Both
sides prove possession with HMAC‑SHA256:

```
client → HELLO     {"magic":"EXTENDPAD","protocol":1,"channel":"control"|"video",
                    "clientNonce":<hex 16B>, "sessionId":<string, video only>,
                    "device":{...}, "display":{...}, "decoder":{...}, "appVersion":"..."}
server → CHALLENGE {"protocol":1,"serverNonce":<hex 16B>,"serverName":"...","appVersion":"..."}
client → AUTH      {"mac": hex(HMAC(token, "EXTENDPAD-v1|client|" + channel + "|" + clientNonce + "|" + serverNonce))}
server → ACCEPT    {"sessionId":"...","serverProof": hex(HMAC(token, "EXTENDPAD-v1|server|" + channel + "|" + clientNonce + "|" + serverNonce))}
```

* HMAC key = the **raw 32 bytes** of the token (hex‑decoded).
* The HMAC message is the UTF‑8 string shown above, `|`‑separated, nonces as lowercase hex.
* The server compares in constant time; on mismatch it sends `REJECT{code:"auth"}` and
  closes. The client verifies `serverProof` and closes on mismatch.
* The server applies a 5 s handshake timeout.
* A `video` HELLO must carry the `sessionId` of a live authenticated control session.
* Test vectors live in `test-vectors.json` and are checked by both test suites.

### HELLO capability fields (control channel)

```json
"device":  {"manufacturer":"HUAWEI","model":"AGS5-W09","sdk":31,"release":"12",
            "harmony":"3.0.0","abi":"arm64-v8a"},
"display": {"widthPx":2000,"heightPx":1200,"densityDpi":240,"refreshHz":60.0},
"decoder": {"name":"c2.qti.avc.decoder","hardware":true,"lowLatency":true,
            "maxWidth":4096,"maxHeight":2176,"maxFps1080p":120,
            "highProfile":true,"maxLevel":"5.1"}
```

`widthPx`/`heightPx` are the landscape physical pixels of the tablet.

### STREAM_CONFIG

```json
{"mode":"extend","displayName":"ExtendPad Display","width":2000,"height":1200,
 "logicalWidth":1333,"logicalHeight":800,"hiDPI":true,"fps":60,"bitrate":16000000,
 "quality":"balanced","preset":"native","inputEnabled":true}
```

`width`/`height` are the encoded stream size; `logical*` is the macOS point size of the
virtual display (used only for UI). Touch coordinates are always normalised, so the
tablet never needs the logical size to map input.

## 4. Flow control (newest-frame-wins)

* The tablet sends `FRAME_ACK` when a decoded frame has been **released to the Surface**.
* The Mac keeps a window of un‑acknowledged frames. When the window is full (default
  6 frames or oldest unacked older than 250 ms), new captured frames are **not encoded**.
  The most recent skipped frame is held in a single "latest" slot and encoded as soon
  as the window opens, so the final screen state always arrives.
* Frames are dropped **before** the encoder, never after, so the H.264 reference chain is
  never broken.
* Adaptive bitrate: sustained drops reduce the bitrate by 15 %; 3 s without drops raise it
  by 5 % up to the quality target.
* `KEYFRAME_REQUEST` (or `STREAM_RESUME`) forces the next encoded frame to be an IDR.
* The tablet keeps a bounded decode queue (8 access units). On overflow it flushes,
  discards until the next keyframe and sends `KEYFRAME_REQUEST`.

## 5. INPUT_POINTER (0x20)

```
u8  action   0=move 1=down 2=up 3=scroll 4=cancel
u8  button   0=left 1=right
u16 x        normalised 0..65535 across the video content width
u16 y        normalised 0..65535 across the video content height
i16 scrollX  pixels (positive = content moves right)
i16 scrollY  pixels (positive = content moves down)
u16 reserved (0)
```

Total payload = 12 bytes. The Mac injects events **only** if the user enabled
"Allow touch input" and macOS Accessibility permission is granted; otherwise the
messages are ignored. Values are clamped to the target display bounds.

## 5b. Local cursor

When `STREAM_CONFIG.localCursor` is true the Mac captures the video **without** the cursor and
streams CURSOR_POS / CURSOR_IMAGE instead; the tablet draws the cursor itself over the video's
content rectangle (size = points × contentWidthPx / logicalWidth). The cursor then moves at the
tablet's refresh rate with only the USB round-trip as latency, independent of the video frame rate.

## 6. Heartbeats and liveness

* Each side sends `PING` every 1 s on the control channel and answers `PING` with `PONG`.
* A control connection with no received bytes for 5 s is considered stale and closed.
* Closing the control connection terminates the session and its video connection.

## 7. Connection state machines

### Android client
```
Idle ─start─▶ WaitingForMac ──tcp ok──▶ Handshaking ──ACCEPT──▶ Connected(streaming)
   ▲              ▲   │ refused/EOF (retry with backoff 0.5 s → 2 s)       │
   │              └───┴────────────── error / stale / BYE ◀────────────────┘
   └── user "Disconnect" (stays Idle until "Connect" or a new CONNECT intent)
```

### Mac server
```
Stopped ─Connect─▶ Listening ──device on USB──▶ TunnelReady ──auth ok──▶ Streaming
                     ▲                              ▲                       │
                     └──── device gone ─────────────┴──── session ends ◀────┘
                                                      (virtual display kept for a
                                                       grace period, then removed)
```
