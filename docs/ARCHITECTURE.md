# ExtendPad architecture

ExtendPad turns an Android tablet (target: Huawei MatePad SE) into a **real extended macOS display**
over a USB‑C data cable. It is a software display: macOS renders a virtual monitor, ExtendPad
captures and encodes it, and the tablet decodes and shows it. Nothing here is "DisplayPort over USB";
the tablet has no video input.

```
┌──────────────────────────── Mac (ExtendPad.app) ────────────────────────────┐
│                                                                             │
│  VirtualDisplayManager ──► "ExtendPad Display" (CGVirtualDisplay, private)  │
│        │  macOS treats it as a real monitor: Displays settings, arrangement,│
│        │  windows, Mission Control, cursor, keyboard focus …                 │
│        ▼                                                                    │
│  ScreenCaptureEngine (ScreenCaptureKit, only that display, NV12 IOSurfaces) │
│        │  frames only when content changes; queueDepth 6                    │
│        ▼                                                                    │
│  StreamingSession ── single "latest frame" slot (newest wins, never queues) │
│        │  FlowController: ≤1 encode in flight, ≤6 unacked, ≤250 ms age      │
│        ▼                                                                    │
│  H264Encoder (VideoToolbox HW, low-latency RC, no B-frames, IDR on demand)  │
│        │  AVCC → Annex-B, SPS/PPS as VIDEO_CONFIG                           │
│        ▼                                                                    │
│  StreamServer (Network.framework, bound to 127.0.0.1:27183 only, HMAC auth) │
│        ▲                                                                    │
│  DeviceMonitor ── adb devices / adb reverse / am start (every 2 s)          │
└────────│────────────────────────────────────────────────────────────────────┘
         │  adb server ⇄ USB cable ⇄ adbd     (`adb reverse tcp:27183 tcp:27183`)
┌────────▼──────────────── Tablet (ExtendPad.apk) ────────────────────────────┐
│  SessionClient ── control socket + video socket to 127.0.0.1:27183          │
│        ▼                                                                    │
│  VideoDecoder (MediaCodec HW, KEY_LOW_LATENCY + vendor keys, queue ≤ 8)     │
│        ▼                                                                    │
│  SurfaceView inside AspectFitLayout (letterbox, never stretch), immersive   │
│        ▲                                                                    │
│  GestureEngine (optional touch → pointer events back over control socket)   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Repository layout

```
macos/                       Swift package (swift build / swift test)
  ExtendPadMac/
    App/                     @main entry, menu-bar app, AppController (settings persistence)
    UI/                      SwiftUI menu panel, Settings window, EN/VI strings
    VirtualDisplay/Bridge/   Objective-C shim: private CGVirtualDisplay API, resolved at runtime
    VirtualDisplay/Swift/    DisplayPlanner (pure), VirtualDisplayManager (create/reconfigure/remove)
    Capture/                 ScreenCaptureKit engine
    Encoder/                 VideoToolbox H.264 encoder + Annex-B conversion
    Transport/               wire protocol, framing, loopback server + handshake
    Connection/              ADB, DeviceMonitor, FlowController, StreamingSession, ExtendPadEngine
    Input/                   CGEvent pointer injection (opt-in, Accessibility)
    Diagnostics/             logging, built-in end-to-end self-test
  Tests/ExtendPadCoreTests/  XCTest unit tests
  packaging/                 Info.plist, icon generator
android/app/src/main/java/com/extendpad/android/
  connection/                SessionClient (state machine, reconnect, heartbeat)
  transport/                 framing, payloads, HMAC, MiniJson
  decoder/                   MediaCodec decoder + capability detection
  display/                   AspectFitLayout, panel info, immersive mode
  input/                     GestureEngine (pure) + MotionEvent adapter
  settings/                  SharedPreferences
  ui/                        MainActivity
android/app/src/test/        JVM unit tests
shared/protocol/             PROTOCOL.md (wire spec) + test-vectors.json used by BOTH test suites
scripts/                     build / install / dev / diagnostics helpers
dist/                        build outputs
```

## Virtual display (the critical part)

* **API**: `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`, `CGVirtualDisplayMode`
  — private CoreGraphics classes that WindowServer has shipped since macOS 11 and that projects such
  as DeskPad, BetterDisplay and SimpleDisplay rely on. There is **no public API** that creates a
  display macOS treats as a real monitor; `CGDisplayStream`/ScreenCaptureKit can only capture
  existing displays (that would be mirroring).
* **Isolation**: all private calls live in `VirtualDisplay/Bridge/EPVirtualDisplayBridge.m`. Classes
  and selectors are looked up with `NSClassFromString`/`respondsToSelector:` — there are no link-time
  references, so a future macOS that removes the API gives a clear error
  ("Missing private CoreGraphics API: …") instead of a crash at launch. ExtendPad then refuses to
  pretend: it reports the failure and does **not** silently fall back to mirroring.
* **Verified signatures** (runtime introspection on macOS 15.7.4, 24G517):
  `-[CGVirtualDisplayMode initWithWidth:(uint32) height:(uint32) refreshRate:(double)]` — note `uint32`,
  not `NSUInteger` as some third-party headers declare.
* **Identity**: fixed vendor/product/serial, name "ExtendPad Display" → macOS remembers the
  arrangement and scaling the user chooses in System Settings → Displays.
* **Modes**: the planner gives WindowServer a short mode list. With `hiDPI = 1`, every W×H mode is also
  offered as Retina "looks like W/2 × H/2". macOS picks an arbitrary default for new virtual
  displays (observed: 1000×600), so ExtendPad selects its mode explicitly with the public
  `CGConfigureDisplayWithDisplayMode`.
* **Presets** (for a 2000×1200 panel):

  | Preset | macOS points | backing pixels | stream |
  |---|---|---|---|
  | Native | 2000×1200 | 2000×1200 | 2000×1200 |
  | Comfortable (default) | 1332×800 HiDPI | 2664×1600 | 2000×1200 |
  | Large | 1000×600 HiDPI | 2000×1200 | 2000×1200 |
  | Performance | 1280×768 | 1280×768 | 1280×768 |

* **No orphans**: the display belongs to the ExtendPad process's WindowServer connection. Quit or
  crash → macOS removes it and moves its windows to the remaining screens (verified: display count
  returns to 1 immediately after release).
* **Disconnect policy**: after the tablet goes away the display is kept for a grace period
  (default 20 s) so a cable wiggle does not reshuffle windows, then removed so no window stays
  stranded on an invisible screen. "Move windows back to Mac screen" removes it immediately.
  During Mac sleep the display is kept.

## Capture → encode

* ScreenCaptureKit `SCContentFilter(display:excludingWindows:[])` for the ExtendPad display only;
  `width/height` = stream size (GPU scaling for HiDPI presets), NV12 video range, BT.709,
  `minimumFrameInterval = 1/fps`, `queueDepth = 6`, cursor drawn into the stream.
* SCK delivers frames only when something changed; `.idle` frames are ignored. A static screen
  costs nothing. 300 ms after the last change, the last frame is re-encoded **once** ("idle refresh")
  so the low-latency rate control can sharpen text.
* VideoToolbox: `EnableLowLatencyRateControl` + `RequireHardwareAcceleratedVideoEncoder` (falls back
  to normal HW, then software, and says so in logs/UI), `RealTime`, `AllowFrameReordering = false`,
  Constrained High (or Constrained Baseline if the tablet decoder lacks High), 10 s max GOP,
  keyframes on request.
* Low-latency VT encodes synchronously inside `VTCompressionSessionEncodeFrame`, so encoding runs on
  its own queue; acks and heartbeats are never stuck behind an encode.

## Smart frame pipeline (bounded everywhere)

| Stage | Bound | Overflow policy |
|---|---|---|
| Capture (SCK) | 6 surfaces | SCK drops |
| Capture → encoder | **1 slot** | newer frame replaces older (counted as skipped) |
| Encoder | 1 in flight | wait for slot |
| Network (unacked) | 6 frames / 250 ms / 3 MiB queued | pause encoding (frames replaced in the slot) |
| Stall | no ack for 1.5 s | reset window, force IDR |
| Tablet decoder | 8 access units | flush, wait for IDR, KEYFRAME_REQUEST |

Frames are dropped **before** the encoder, never after, so the H.264 reference chain stays valid and
no keyframe storm is needed. Adaptive bitrate: −15 % when ≥ max(3, fps/5) frames per second are
skipped, +5 % after 3 clean seconds, bounded by the quality target.

An early version used one dispatch block per captured frame; when the encoder slowed down, blocks
queued up and latency grew past 200 ms. The single-slot design replaced it — see `docs/BENCHMARKS.md`.

## Transport

* `adb reverse tcp:27183 tcp:27183` makes the tablet's `127.0.0.1:27183` reach the Mac's
  `127.0.0.1:27183` through the adb server and the USB cable. The Mac listener is bound to the IPv4
  loopback address with `acceptLocalOnly`, and additionally rejects non-loopback peers.
* DeviceMonitor polls adb every 2 s: uses only devices with a `usb:` transport (ADB over Wi‑Fi is
  ignored and reported; the emulator is allowed only via a developer toggle), re-creates the reverse
  tunnel after every replug/adbd restart, restarts the adb server if it stops answering, and opens
  the tablet app with the pairing token (`am start … --es ep_token`).
* Two TCP connections: **control** (handshake, config, ping/pong, acks, stats, input, settings) and
  **video**. Separate sockets keep heartbeats/acks/input free of head-of-line blocking behind large
  keyframes.
* Framing `[u32 length][u8 type][payload]`, max 64 KiB control / 8 MiB video, strict validation.
  Full spec: `shared/protocol/PROTOCOL.md`.

## Security model

* Pairing token: 32 random bytes in `~/Library/Application Support/ExtendPad/pairing-token` (0600),
  delivered to the tablet only through ADB (requires the user-authorised USB debugging key),
  stored in app-private SharedPreferences. Never sent on the socket.
* Mutual HMAC-SHA256 challenge/response on **both** sockets; constant-time comparison; 5 s
  handshake timeout. A rogue app on the tablet (which can reach 127.0.0.1:27183) cannot get video
  or inject input without the token.
* No public listener, no internet, no accounts, no telemetry. The only Android permission is
  `INTERNET` (required for loopback sockets).
* Untrusted input: HELLO fields are clamped/sanitised, pointer events are strictly validated and
  only injected when the user enabled touch input **and** granted Accessibility. adb is invoked with
  argv arrays (no shell); remote shell commands are fixed literals; the token is hex-only.

## Android decoder

* Picks a hardware AVC decoder (`isSoftwareOnly` on API 29+, name heuristics before), reports max
  size, High-profile support, low-latency feature and max fps at panel size in HELLO.
* `KEY_LOW_LATENCY` (API 30+ when supported), `KEY_PRIORITY = 0`, and vendor low-latency keys for
  Qualcomm / HiSilicon / MediaTek / Exynos; if configure fails with vendor keys it retries without
  them, then tries the next decoder.
* Decodes straight to the SurfaceView surface; output buffers are released for rendering
  immediately. `presentationTimeUs` carries the frame id, so the FRAME_ACK maps exactly.
* Surface destroyed → codec released synchronously; surface recreated → reconfigure with the stored
  SPS/PPS and request an IDR.

## Session lifecycle & recovery

| Event | Behaviour |
|---|---|
| Cable unplugged | DeviceMonitor sees the device vanish → session ends at once (heartbeat would catch it within 5 s); display kept for the grace period |
| Cable replugged | reverse tunnel recreated, tablet app re-opened; the app's own reconnect loop (0.5–2 s back-off) connects; display reused if still alive — windows stay where they were |
| adb server restarted/killed | adb restarted automatically after two failed polls, tunnel recreated |
| Tablet screen off / app backgrounded | STREAM_PAUSE (Mac stops encoding); after 60 s the tablet disconnects |
| Back to foreground | STREAM_RESUME → immediate IDR of the current screen |
| Android process killed | Mac heartbeat timeout (5 s) → session ends; app relaunch reconnects |
| Mac sleeps / wakes | session ends with BYE, display kept; on wake adb is re-polled and the tablet reconnects |
| Screen Recording revoked | capture stops → clear error on both sides |
| Capture stopped by WindowServer | restarted up to 3 times |
| Encoder / decoder error | encoder recreated / decoder recreated + IDR request |
| Virtual display creation fails | explicit error naming the missing API; no silent mirror fallback |
| Resolution / preset change while streaming | same display reconfigured in place when possible (windows stay), capture + encoder updated, new VIDEO_CONFIG |
| App Nap | an `NSProcessInfo` activity (`latencyCritical`) is held while streaming |
