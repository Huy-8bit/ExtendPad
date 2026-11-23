#!/usr/bin/env bash
# Checks the development/runtime dependencies and prints what is missing.
source "$(dirname "$0")/common.sh"
ok() { printf "  ✓ %s\n" "$*"; }
bad() { printf "  ✗ %s\n" "$*"; MISSING=1; }
MISSING=0
echo "macOS"
ok "$(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
xcrun --find swift >/dev/null 2>&1 && ok "Swift $(swift --version 2>/dev/null | head -1 | sed 's/.*Swift version \([0-9.]*\).*/\1/')" || bad "Swift toolchain (install Xcode or the Command Line Tools)"
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 ]] && ok "macOS ≥ 13 (ScreenCaptureKit + MenuBarExtra)" || bad "macOS 13 or newer is required"
echo "Android"
if ADBP=$(find_adb); then ok "adb: $ADBP ($("$ADBP" version | head -1))"; else bad "adb not found (brew install android-platform-tools)"; fi
java -version >/dev/null 2>&1 && ok "Java: $(java -version 2>&1 | head -1)" || bad "JDK 17 (needed only to build the APK)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
[[ -d "$SDK/platforms" ]] && ok "Android SDK: $SDK ($(ls "$SDK/platforms" | tr '\n' ' '))" || bad "Android SDK (needed only to build the APK)"
echo "Device"
if [[ -n "${ADBP:-}" ]]; then
  "$ADBP" start-server >/dev/null 2>&1
  SERIAL=$(pick_device "$ADBP")
  if [[ -z "$SERIAL" ]]; then bad "no USB Android device (enable USB debugging, use a data cable)"
  else
    ST=$(device_state "$ADBP" "$SERIAL")
    case "$ST" in
      device) ok "$SERIAL authorised — $("$ADBP" -s "$SERIAL" shell getprop ro.product.model | tr -d '\r') (Android $("$ADBP" -s "$SERIAL" shell getprop ro.build.version.release | tr -d '\r'))" ;;
      unauthorized) bad "$SERIAL unauthorised — tap Allow on the tablet's USB debugging prompt" ;;
      *) bad "$SERIAL state: $ST" ;;
    esac
  fi
fi
exit $MISSING
