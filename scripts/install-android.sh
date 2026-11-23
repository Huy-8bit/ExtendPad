#!/usr/bin/env bash
# Installs dist/ExtendPad.apk on the USB tablet, sets up `adb reverse`, and opens the app paired with this Mac.
set -euo pipefail
source "$(dirname "$0")/common.sh"
APK="${1:-$ROOT/dist/ExtendPad.apk}"
ADBP=$(find_adb) || { echo "✗ adb not found"; exit 1; }
"$ADBP" start-server >/dev/null
SERIAL=$(pick_device "$ADBP")
[[ -n "$SERIAL" ]] || { echo "✗ No USB device. Enable USB debugging and connect a USB-C data cable."; exit 1; }
for i in $(seq 1 30); do
  ST=$(device_state "$ADBP" "$SERIAL")
  [[ "$ST" == "device" ]] && break
  [[ "$ST" == "unauthorized" && $i == 1 ]] && echo "… tap 'Allow' on the tablet's USB debugging prompt"
  sleep 1
done
[[ "$(device_state "$ADBP" "$SERIAL")" == "device" ]] || { echo "✗ $SERIAL is not authorised"; exit 1; }
echo "▸ Device $SERIAL: $("$ADBP" -s "$SERIAL" shell getprop ro.product.model | tr -d '\r')"
[[ -f "$APK" ]] || { echo "✗ $APK missing — run scripts/build-android.sh"; exit 1; }
echo "▸ Installing $APK"
"$ADBP" -s "$SERIAL" install -r "$APK"
echo "▸ adb reverse tcp:$PORT tcp:$PORT"
"$ADBP" -s "$SERIAL" reverse "tcp:$PORT" "tcp:$PORT"
if [[ -f "$TOKEN_FILE" ]]; then
  TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
  "$ADBP" -s "$SERIAL" shell am start -n "$COMPONENT" -a com.extendpad.action.CONNECT --es ep_token "$TOKEN" --ei ep_port "$PORT" >/dev/null
  echo "✓ Installed and opened (paired with this Mac)"
else
  "$ADBP" -s "$SERIAL" shell am start -n "$COMPONENT" >/dev/null
  echo "✓ Installed. Start ExtendPad on the Mac once — it pairs the tablet automatically."
fi
