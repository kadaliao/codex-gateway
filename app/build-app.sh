#!/usr/bin/env bash
# Build a runnable, native window and menu-bar macOS .app for Codex Gateway.
# Requires Xcode / Swift toolchain. Output: ./build/Codex Gateway.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Codex Gateway"
BUNDLE_ID="com.kadaliao.codex-gateway"
CONFIG=release
ZSTD_PREFIX="$(brew --prefix zstd)"
ZSTD_LIB="$ZSTD_PREFIX/lib/libzstd.1.dylib"
if [[ ! -f "$ZSTD_LIB" ]]; then
  echo "Missing zstd build dependency. Run: brew install zstd" >&2
  exit 1
fi
SWIFT_VERSION=$(command -v swift >/dev/null && swift --version 2>/dev/null | sed -n '1p')
echo "Building with: $SWIFT_VERSION"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/CodexGatewayApp"
APP="build/$APP_NAME.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp -L "$ZSTD_LIB" "$APP/Contents/Frameworks/libzstd.1.dylib"
cp "$ZSTD_PREFIX/LICENSE" "$APP/Contents/Resources/zstd-LICENSE"
codesign --force --sign - "$APP/Contents/Frameworks/libzstd.1.dylib"
cp "$BIN" "$APP/Contents/MacOS/CodexGatewayApp"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc sign (no Developer ID / notarization). Run locally; on first launch,
# right-click -> Open -> Open if Gatekeeper blocks an unsigned app.
echo "==> Ad-hoc codesigning"
codesign --force --deep --sign - "$APP"

echo
echo "Done. Launch:"
echo "  open \"$APP\""
echo
echo "Launch opens the full control window; the menu bar provides quick access."
echo "Note: unsigned/ad-hoc app — if macOS blocks it, right-click the app -> Open -> Open."
