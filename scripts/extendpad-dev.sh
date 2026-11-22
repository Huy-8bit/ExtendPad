#!/usr/bin/env bash
# One-shot developer workflow: check deps → (build) → install APK → start the Mac app.
# The Mac app then keeps the USB tunnel alive and opens/pairs the tablet app by itself.
#   scripts/extendpad-dev.sh            use existing dist/ artifacts
#   scripts/extendpad-dev.sh --build    rebuild both apps first
set -euo pipefail
source "$(dirname "$0")/common.sh"
if [[ "${1:-}" == "--build" ]]; then
  "$ROOT/scripts/build-android.sh"
  "$ROOT/scripts/build-macos.sh" --no-dmg
fi
"$ROOT/scripts/check-deps.sh" || true
"$ROOT/scripts/install-android.sh"
[[ -d "$ROOT/dist/ExtendPad.app" ]] || { echo "✗ dist/ExtendPad.app missing — run with --build"; exit 1; }
pkill -x ExtendPad 2>/dev/null || true
open "$ROOT/dist/ExtendPad.app"
echo "✓ ExtendPad started (menu bar). Logs: ~/Library/Logs/ExtendPad/extendpad.log"
