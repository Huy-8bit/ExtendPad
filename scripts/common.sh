# Shared helpers for ExtendPad scripts (sourced).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${EXTENDPAD_PORT:-27183}"
PKG="com.extendpad.android"
COMPONENT="com.extendpad.android/.ui.MainActivity"
TOKEN_FILE="$HOME/Library/Application Support/ExtendPad/pairing-token"

find_adb() {
  for c in "${ADB:-}" "${ANDROID_HOME:-}/platform-tools/adb" "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
           "$HOME/Library/Android/sdk/platform-tools/adb" /opt/homebrew/bin/adb /usr/local/bin/adb "$(command -v adb 2>/dev/null)"; do
    [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# Picks the first USB-attached device (lines with "usb:"), unless ANDROID_SERIAL is set.
pick_device() {
  local adb="$1"
  if [[ -n "${ANDROID_SERIAL:-}" ]]; then echo "$ANDROID_SERIAL"; return 0; fi
  "$adb" devices -l | awk 'NR>1 && /usb:/ {print $1; exit}'
}

device_state() { "$1" devices | awk -v s="$2" '$1==s {print $2}'; }
