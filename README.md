# ExtendPad

Use an Android tablet as a **real extended display** for your Mac, over a **USB‑C cable**.

ExtendPad creates a genuine second monitor ("ExtendPad Display") that macOS shows in
**System Settings → Displays**. You can drag windows onto the tablet, keep different apps on each screen,
and arrange it like any other monitor. It streams that display to the tablet as low‑latency H.264
through the ADB USB connection. You don't need Wi‑Fi, an account, or root, and you don't have to
disable SIP or install a kernel extension. Internet is used only once, if you let ExtendPad download
Google's `adb` tool for you.

> Built and tested with a **Huawei MatePad SE (AGS6‑W09, HarmonyOS 2 / Android 10)** and a
> **MacBook Pro M1 Pro (macOS 15.7.4)**. Other Android 8+ tablets should work too, but they are untested.

## Download

Prebuilt files are in [`dist/`](dist):

| File | What it is |
| --- | --- |
| `ExtendPad.dmg` | Mac app (universal: Apple Silicon + Intel, macOS 13+). |
| `ExtendPad.apk` | Tablet app (Android 8+ / HarmonyOS 2–4). The Mac app also contains it and can install it for you. |

## Quick start

**On the tablet (one time):**

1. Settings → About tablet → tap *Build number* 7 times to unlock Developer options.
2. Developer options → turn on **USB debugging**. On Huawei, also turn on **"Allow ADB debugging in charge only mode"**.

**On the Mac:**

1. Open `ExtendPad.dmg` and drag ExtendPad into Applications.
2. The build is ad‑hoc signed, not notarized. The first time, right‑click ExtendPad → **Open** → Open.
3. Grant **Screen Recording** when macOS asks (System Settings → Privacy & Security), then reopen ExtendPad.
   It runs in the menu bar.
4. If the menu says adb is missing, click **Install adb**. ExtendPad downloads Google's official Android
   SDK Platform‑Tools once (≈17 MB), checks Google's code signature, and keeps them in its own folder
   (`~/Library/Application Support/ExtendPad/platform-tools`). You don't need Homebrew or the Terminal.
   If you already have `adb` (Android Studio or `brew install android-platform-tools`), ExtendPad uses
   that one and skips this step.

**Connect:**

1. Plug the tablet in with a **data‑capable** USB‑C cable and tap **Allow** on the USB debugging prompt
   (tick "Always allow from this computer").
2. If the tablet app isn't installed yet, click **Install app on tablet** in the ExtendPad menu
   (Huawei asks you to confirm the install on the tablet).
3. ExtendPad sets up the USB tunnel, opens the tablet app, and pairs with it automatically.
   The tablet now shows the extended desktop.

Move the mouse past the screen edge to reach the tablet. Use **System Settings → Displays → Arrange**
to put the tablet on the correct side. The **⋯** button on the tablet changes quality and scaling,
toggles the statistics overlay, and disconnects.

## How it works

```text
Mac:     CGVirtualDisplay → ScreenCaptureKit → VideoToolbox H.264 (hardware)
         → 127.0.0.1:27183 ──adb reverse──USB──▶ tablet 127.0.0.1:27183
Tablet:  MediaCodec (hardware) → SurfaceView, plus a locally drawn mouse cursor
```

- **Virtual display:** uses Apple's private `CGVirtualDisplay` API (the same one DeskPad, BetterDisplay
  and others use). There is no public API for a real extra monitor. The private calls are isolated
  in one Objective‑C file and checked at runtime. If a future macOS removes the API, ExtendPad reports
  that clearly and never silently falls back to mirroring.

- **Transport:** the Mac listens only on `127.0.0.1`, and `adb reverse` carries the connection over USB.
  The two sides authenticate with HMAC‑SHA256 using a pairing token that is delivered only over ADB.

- **Smooth cursor:** the Mac sends the cursor position at 120 Hz on the control channel, and the tablet
  draws the cursor itself. The cursor therefore doesn't wait for video frames.

- **Bounded pipeline:** the newest frame always wins. Frames are skipped *before* encoding, never
  queued, so latency can't build up. When the screen is static, no frames are sent. After 1 s of
  stillness, one full keyframe repairs any glitch.

Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · wire protocol: [shared/protocol/PROTOCOL.md](shared/protocol/PROTOCOL.md)

## Measured performance

Measured on the hardware above, with Comfortable scaling (macOS 1280×800 HiDPI, streamed at 1920×1200)
and Balanced/Quality settings:

| Metric | Value |
| --- | --- |
| Estimated capture → shown on tablet | ~30–40 ms |
| Mac H.264 encode per frame | ~8 ms at first, ~18 ms after a few seconds (M1 Pro media‑engine clocking; not configurable) |
| Tablet hardware decode (`OMX.hisi.video.decoder.avc`) | ~7–12 ms |
| USB round trip (adb reverse) | ~5–7 ms |
| Frame rate while windows move | ~36–55 fps (cursor is drawn by the tablet independently) |
| Static screen | ~0 fps / a few kbit/s |

**Image accuracy test:** a script compares what the Mac renders with a screenshot from the tablet.
After the fixes in this version, there was no wrong‑colour area in 6 of 6 runs.

## Build from source

Requirements: Xcode 16 / Swift 6 toolchain, JDK 17, and an Android SDK (platform 36).

```bash
scripts/build-android.sh       # tests + dist/ExtendPad.apk
scripts/build-macos.sh         # tests + universal dist/ExtendPad.app + dist/ExtendPad.dmg (bundles the APK)
scripts/install-android.sh     # install the APK over USB, set up adb reverse, open & pair the app
scripts/extendpad-dev.sh       # all of the above + launch the Mac app
scripts/check-deps.sh          # check tools and the connected device
scripts/collect-diagnostics.sh # local logs + device facts (nothing is uploaded)
```

Tests:

- **Unit tests:** `cd macos && swift test` (49 tests) and `cd android && ./gradlew test`.
  Both suites check the same protocol and HMAC test vectors in `shared/protocol/test-vectors.json`.

- **Mac self‑test:** `ExtendPad.app/Contents/MacOS/ExtendPad --selftest 10` runs the real virtual display,
  capture, encoder and protocol with an in‑process client.

- **End‑to‑end:** `tests/e2e/emulator-scenarios.sh` runs recovery scenarios against a running session:
  pause/resume, settings from the tablet, adb restart, disconnect/grace period, and reconnect.

## Known limitations

- **Private macOS API:** a macOS update could break virtual display creation. ExtendPad then shows an error.
- **Ad‑hoc signing:** macOS ties permissions to the exact binary, so after installing a new build you may
  need to re‑grant Screen Recording.

- **Debug‑signed APK:** Huawei asks you to confirm every install over USB.
- **adb:** if no `adb` is installed, the one-click download needs internet once. ExtendPad then uses
  Google's Platform-Tools under [Google's terms](https://developer.android.com/tools/releases/platform-tools).
- **Touch input** (tap = click, long‑press = right‑click, two fingers = scroll) is implemented and
  unit‑tested but **not yet verified on a real device**. It needs the *Allow touch input* setting plus
  macOS Accessibility permission. It is pointer emulation, not native multitouch.

- **Not yet tested:** a physical cable unplug/replug cycle, Mac sleep/wake with a live session, and long
  (multi‑hour) sessions. Reconnect after an adb restart, an app restart or a tablet‑side disconnect was
  tested on the Android emulator.

- **HarmonyOS NEXT** cannot run Android APKs. You need HarmonyOS 2–4 or Android.
- Window movement is limited to roughly 36–55 fps by the Mac's hardware encoder at 1920×1200. The
  **Performance** scaling preset (≈1280×768) runs at ~58 fps.

## Hướng dẫn nhanh (Tiếng Việt)

1. Trên máy tính bảng, bật **Tuỳ chọn nhà phát triển → Gỡ lỗi USB**. Với Huawei, bật thêm *Cho phép gỡ lỗi ADB ở chế độ chỉ sạc*.
2. Trên Mac, mở `ExtendPad.dmg`, kéo vào Applications, rồi chuột phải → **Mở**. Cấp quyền **Ghi màn hình**. Nếu menu báo thiếu adb, bấm **Cài adb** (tải một lần ≈17 MB từ Google, không cần Terminal).
3. Cắm cáp USB‑C có truyền dữ liệu và bấm **Cho phép** trên máy tính bảng. Nếu chưa có app trên tablet, chọn *Cài ứng dụng lên máy tính bảng* trong menu ExtendPad.
4. Máy tính bảng sẽ tự mở và hiển thị màn hình mở rộng. Sắp xếp vị trí màn hình trong **Cài đặt hệ thống → Màn hình**.
