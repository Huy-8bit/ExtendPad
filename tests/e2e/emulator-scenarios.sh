#!/usr/bin/env bash
# End-to-end recovery scenarios against a RUNNING ExtendPad Mac app and an Android device/emulator
# that is already streaming. Drives the tablet UI through uiautomator and checks the Mac log.
#
#   ANDROID_SERIAL=emulator-5554 tests/e2e/emulator-scenarios.sh
#
# Requires the Mac app's "Allow Android emulator" setting when using an emulator.
set -uo pipefail
source "$(dirname "$0")/../../scripts/common.sh"
ADBP=$(find_adb) || { echo "adb not found"; exit 1; }
SERIAL="${ANDROID_SERIAL:-$(pick_device "$ADBP")}"
A() { "$ADBP" -s "$SERIAL" "$@"; }
MACLOG="$HOME/Library/Logs/ExtendPad/extendpad.log"
OUT="${OUT:-$ROOT/dist/e2e-$(date +%Y%m%d-%H%M%S)}"; mkdir -p "$OUT"
PASS=0; FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
mark() { wc -l < "$MACLOG" | tr -d ' '; }
# wait_log <from-line> <regex> <timeout-s>  → prints seconds waited, returns 1 on timeout
wait_log() {
  local from=$1 re=$2 t=$3 start; start=$(date +%s)
  while (( $(date +%s) - start < t )); do
    tail -n +"$((from+1))" "$MACLOG" | grep -qE "$re" && { echo $(( $(date +%s) - start )); return 0; }
    sleep 0.25
  done
  return 1
}
# tap_id <resource-id> [package]: taps a view by id. Bounds come from a uiautomator dump and are
# cached, because dumps wait for an idle UI (up to 10 s) while the panel auto-hides after 6 s.
BOUNDS_FILE="$(mktemp)"; trap 'rm -f "$BOUNDS_FILE"' EXIT
bounds_of() { grep "^$1 " "$BOUNDS_FILE" | tail -1 | cut -d' ' -f2-; }
refresh_bounds() {
  A shell uiautomator dump /data/local/tmp/ep.xml >/dev/null 2>&1
  A shell cat /data/local/tmp/ep.xml | tr '>' '\n' | grep 'resource-id="[^"]' | while IFS= read -r line; do
    id=$(echo "$line" | grep -oE 'resource-id="[^"]+"' | sed 's/resource-id="//; s/"$//')
    b=$(echo "$line" | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | grep -oE '[0-9]+' | tr '\n' ' ')
    [[ -n "$id" && -n "$b" ]] && echo "$id $b" >> "$BOUNDS_FILE"
  done
}
tap_id() {
  local key="${2:-com.extendpad.android}:id/$1"
  [[ -z "$(bounds_of "$key")" ]] && refresh_bounds
  local n=($(bounds_of "$key"))
  [[ ${#n[@]} -eq 4 ]] || return 1
  A shell input tap $(( (n[0]+n[2])/2 )) $(( (n[1]+n[3])/2 ))
}
shot() { A exec-out screencap -p > "$OUT/$1.png"; }
# Opens the floating control panel (it toggles, so check first; learn its button bounds once).
open_panel() {
  if [[ -z "$(bounds_of com.extendpad.android:id/btnDisconnect)" ]]; then
    tap_id controlHandle; sleep 0.7; refresh_bounds
    [[ -n "$(bounds_of com.extendpad.android:id/btnDisconnect)" ]] && return 0
  fi
  tap_id controlHandle; sleep 0.7
}
# Android shows a one-time "Viewing full screen" hint over immersive apps; dismiss it.
dismiss_cling() { A shell uiautomator dump /data/local/tmp/ep.xml >/dev/null 2>&1
  if A shell cat /data/local/tmp/ep.xml | grep -q immersive_cling; then refresh_bounds; tap_id ok android; sleep 0.5; fi; return 0; }

echo "ExtendPad e2e scenarios on $SERIAL ($(A shell getprop ro.product.model | tr -d '\r'))"

echo "1. Session is streaming"
if grep -q "capturing display" "$MACLOG"; then ok "Mac is capturing the ExtendPad display"; else bad "no active capture"; fi
shot 01-streaming

if [[ "${ONLY_UI:-0}" != 1 ]]; then
echo "2. Tablet backgrounded → Mac pauses encoding; foreground → resumes with a keyframe"
m=$(mark); A shell input keyevent KEYCODE_HOME
if s=$(wait_log "$m" "tablet paused stream" 5); then ok "paused after ${s}s"; else bad "no STREAM_PAUSE"; fi
m=$(mark); A shell am start -n "$COMPONENT" >/dev/null 2>&1
if s=$(wait_log "$m" "tablet resumed stream" 5); then ok "resumed after ${s}s"; else bad "no STREAM_RESUME"; fi
sleep 2; shot 02-resumed
fi

echo "3. Quality change from the tablet's floating control"
dismiss_cling
m=$(mark)
open_panel; tap_id btnQuality
if s=$(wait_log "$m" "tablet changed settings: quality=" 6); then ok "Mac applied $(tail -n +"$((m+1))" "$MACLOG" | grep -oE 'quality=[a-z]+' | tail -1) in ${s}s"; else bad "settings request not applied"; fi
sleep 0.5; open_panel; tap_id btnStats; sleep 2; shot 03-stats-overlay
# The overlay redraws twice a second, which keeps uiautomator from ever seeing an idle UI: turn it off again.
open_panel; tap_id btnStats; sleep 7
open_panel; tap_id btnQuality; sleep 0.5; open_panel; tap_id btnQuality   # cycle back to the original quality

if [[ "${ONLY_UI:-0}" != 1 ]]; then
echo "4. adb server restart (simulates ADB/USB transport loss)"
m=$(mark); t0=$(date +%s)
"$ADBP" kill-server
if s=$(wait_log "$m" "session .* ended" 12); then ok "session ended ${s}s after adb died"; else bad "session did not end"; fi
if s=$(wait_log "$m" "adb reverse tcp:$PORT established" 30); then ok "tunnel re-established after ${s}s (adb restarted automatically)"; else bad "tunnel not re-established"; fi
if s=$(wait_log "$m" "capturing display" 40); then ok "streaming again $(( $(date +%s) - t0 ))s after the transport loss"; else bad "did not resume streaming"; fi
"$ADBP" wait-for-device >/dev/null 2>&1
fi

echo "5. Disconnect on the tablet → display kept for the grace period, then removed"
sleep 3; dismiss_cling; m=$(mark)
open_panel; tap_id btnDisconnect
if s=$(wait_log "$m" "session .* ended" 8); then ok "Mac saw the disconnect after ${s}s"; else bad "no session end"; fi
if s=$(wait_log "$m" "removing ExtendPad Display" 40); then ok "virtual display removed after grace period (${s}s)"; else bad "display not removed"; fi
sleep 1; shot 05-disconnected

echo "6. Reconnect from the tablet"
m=$(mark); tap_id btnConnect
if s=$(wait_log "$m" "capturing display" 20); then ok "streaming again after ${s}s (display recreated)"; else bad "reconnect failed"; fi
sleep 2; shot 06-reconnected

echo
echo "Result: $PASS passed, $FAIL failed — screenshots in $OUT"
exit $FAIL
