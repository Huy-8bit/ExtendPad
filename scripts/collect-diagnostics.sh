#!/usr/bin/env bash
# Collects local diagnostics (Mac log + tablet logcat + device facts) into one folder. Nothing is uploaded.
source "$(dirname "$0")/common.sh"
OUT="${1:-$ROOT/dist/diagnostics-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
{ sw_vers; uname -a; system_profiler SPDisplaysDataType 2>/dev/null; } > "$OUT/mac.txt"
cp ~/Library/Logs/ExtendPad/extendpad*.log "$OUT/" 2>/dev/null || true
if ADBP=$(find_adb); then
  "$ADBP" devices -l > "$OUT/adb-devices.txt" 2>&1
  SERIAL=$(pick_device "$ADBP")
  if [[ -n "$SERIAL" ]]; then
    "$ADBP" -s "$SERIAL" shell getprop > "$OUT/tablet-getprop.txt" 2>&1
    "$ADBP" -s "$SERIAL" shell wm size > "$OUT/tablet-display.txt" 2>&1
    "$ADBP" -s "$SERIAL" shell wm density >> "$OUT/tablet-display.txt" 2>&1
    "$ADBP" -s "$SERIAL" shell dumpsys media.player 2>/dev/null | head -200 > "$OUT/tablet-media.txt"
    "$ADBP" -s "$SERIAL" reverse --list > "$OUT/adb-reverse.txt" 2>&1
    "$ADBP" -s "$SERIAL" logcat -d -v time -s ExtendPad ExtendPad.Session ExtendPad.Decoder ExtendPad.Caps MediaCodec ActivityManager:W > "$OUT/tablet-logcat.txt" 2>&1
  fi
fi
echo "✓ Diagnostics written to $OUT"
