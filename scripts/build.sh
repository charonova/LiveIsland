#!/bin/bash
# Builds LiveIsland.app into ./build without needing Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. The now-playing adapter (vendored, BSD-3), built once and reused. It's built for macOS 14
#    like the app: left to CMake, it would only load on the SDK's own macOS version.
ADAPTER_SRC="ThirdParty/mediaremote-adapter"
ADAPTER_BUILD=".build/mediaremote-adapter-macos14"
ADAPTER_FRAMEWORK="$ADAPTER_BUILD/MediaRemoteAdapter.framework"
if [ ! -d "$ADAPTER_FRAMEWORK" ]; then
    command -v cmake >/dev/null || { echo "cmake is required to build the media adapter (brew install cmake)"; exit 1; }
    cmake -S "$ADAPTER_SRC" -B "$ADAPTER_BUILD" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >/dev/null
    cmake --build "$ADAPTER_BUILD" --target MediaRemoteAdapter -j 8 >/dev/null
fi

# 2. The app. UNIVERSAL=1 builds for Intel Macs too (releases do).
ARCHS=()
[ "${UNIVERSAL:-0}" = 1 ] && ARCHS=(--arch arm64 --arch x86_64)
# ${ARCHS[@]+…}: macOS's bash 3.2 calls an empty array unbound under `set -u`.
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/LiveIsland"

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
