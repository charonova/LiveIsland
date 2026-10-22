#!/bin/bash
# Builds LiveIsland.app into ./build without needing Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. The now-playing adapter (vendored, BSD-3), built once and reused.
ADAPTER_SRC="ThirdParty/mediaremote-adapter"
ADAPTER_BUILD=".build/mediaremote-adapter"
ADAPTER_FRAMEWORK="$ADAPTER_BUILD/MediaRemoteAdapter.framework"
if [ ! -d "$ADAPTER_FRAMEWORK" ]; then
    command -v cmake >/dev/null || { echo "cmake is required to build the media adapter (brew install cmake)"; exit 1; }
    cmake -S "$ADAPTER_SRC" -B "$ADAPTER_BUILD" -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$ADAPTER_BUILD" --target MediaRemoteAdapter -j 8 >/dev/null
fi

# 2. The app.
swift build -c release
BIN="$(swift build -c release --show-bin-path)/LiveIsland"

APP="build/LiveIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LiveIsland"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ADAPTER_FRAMEWORK" "$APP/Contents/Resources/"
cp "$ADAPTER_SRC/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp "$ADAPTER_SRC/LICENSE" "$APP/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"

codesign --force --sign - "$APP/Contents/Resources/MediaRemoteAdapter.framework" >/dev/null
codesign --force --options runtime --entitlements Resources/LiveIsland.entitlements --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"
