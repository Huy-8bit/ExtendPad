#!/usr/bin/env bash
# Builds and unit-tests the tablet app, then copies it to dist/ExtendPad.apk.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/android"
if [[ ! -f local.properties ]]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  echo "sdk.dir=$SDK" > local.properties
fi
OFFLINE=""
[[ "${EXTENDPAD_OFFLINE:-1}" == "1" ]] && OFFLINE="--offline"
./gradlew $OFFLINE clean test assembleDebug
mkdir -p "$ROOT/dist"
cp app/build/outputs/apk/debug/app-debug.apk "$ROOT/dist/ExtendPad.apk"
echo "✓ dist/ExtendPad.apk ($(du -h "$ROOT/dist/ExtendPad.apk" | cut -f1))"
