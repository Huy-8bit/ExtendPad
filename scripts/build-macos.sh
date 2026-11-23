#!/usr/bin/env bash
# Builds dist/ExtendPad.app (universal arm64 + x86_64, ad-hoc signed) and dist/ExtendPad.dmg.
# Usage: scripts/build-macos.sh [--no-dmg] [--arch native]
#   CODESIGN_IDENTITY="Apple Development: …" to sign with a real identity (keeps TCC permissions across rebuilds).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC="$ROOT/macos"
DIST="$ROOT/dist"
APP="$DIST/ExtendPad.app"
MAKE_DMG=1
ARCHS=(--arch arm64 --arch x86_64)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-dmg) MAKE_DMG=0 ;;
    --arch) shift; [[ "${1:-}" == "native" ]] && ARCHS=() ;;
  esac
  shift
done

echo "▸ Running macOS unit tests"
(cd "$MAC" && swift test 2>&1 | grep -E "error:|Executed [0-9]+ tests" | tail -1)

echo "▸ Building release binary ${ARCHS[*]:-(native)}"
(cd "$MAC" && swift build -c release "${ARCHS[@]}" 2>&1 | grep -E "error|warning: unre|Compiling|Build" | tail -5)
if [[ ${#ARCHS[@]} -gt 0 ]]; then
  BIN="$MAC/.build/apple/Products/Release/ExtendPad"
else
  BIN="$MAC/.build/release/ExtendPad"
fi
[[ -x "$BIN" ]] || { echo "✗ binary not found at $BIN"; exit 1; }

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ExtendPad"
cp "$MAC/packaging/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$MAC/packaging/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Bundle the tablet APK so the Mac app can install it over USB ("Install app on tablet").
if [[ -f "$DIST/ExtendPad.apk" ]]; then
  cp "$DIST/ExtendPad.apk" "$APP/Contents/Resources/ExtendPad.apk"
  echo "  bundled ExtendPad.apk"
else
  echo "  (no dist/ExtendPad.apk yet — run scripts/build-android.sh first to bundle it)"
fi

IDENTITY="${CODESIGN_IDENTITY:--}"
echo "▸ Code signing (${IDENTITY/-/ad-hoc})"
codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -1
lipo -info "$APP/Contents/MacOS/ExtendPad"

if [[ $MAKE_DMG == 1 ]]; then
  echo "▸ Creating $DIST/ExtendPad.dmg"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DIST/ExtendPad.dmg"
  hdiutil create -quiet -volname "ExtendPad" -srcfolder "$STAGE" -ov -format UDZO "$DIST/ExtendPad.dmg"
  rm -rf "$STAGE"
fi
echo "✓ Done: $APP"
