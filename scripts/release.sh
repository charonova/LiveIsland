#!/bin/bash
# Builds dist/LiveIsland.zip for a GitHub release: universal (Apple silicon and Intel), plus its
# SHA-256. With a Developer ID it's signed for distribution and notarized, so it opens without
# a warning however it was downloaded:
#
#   LIVEISLAND_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   LIVEISLAND_NOTARY_PROFILE=liveisland   # once: xcrun notarytool store-credentials liveisland
#
# Without them the app is signed ad hoc, which runs fine when installed with the README's
# Terminal command; a browser download needs "Open Anyway" once (see the README).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
UNIVERSAL=1 ./scripts/build.sh
APP="build/LiveIsland.app"
IDENTITY="${LIVEISLAND_IDENTITY:-}"

if [ -n "$IDENTITY" ]; then
    # Inside out: the adapter framework first, then the app that seals it.
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/MediaRemoteAdapter.framework"
    codesign --force --timestamp --options runtime --entitlements Resources/LiveIsland.entitlements \
        --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --deep "$APP"
for binary in "$APP/Contents/MacOS/LiveIsland" "$APP/Contents/Resources/MediaRemoteAdapter.framework/MediaRemoteAdapter"; do
    echo "$(basename "$binary"): $(lipo -archs "$binary"), macOS $(vtool -show-build "$binary" | awk '/minos/ {print $2; exit}')+"
done

mkdir -p dist
ZIP="dist/LiveIsland.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

if [ -n "$IDENTITY" ] && [ -n "${LIVEISLAND_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$LIVEISLAND_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose "$APP"
fi

(cd dist && shasum -a 256 LiveIsland.zip > LiveIsland.zip.sha256)
echo "LiveIsland $VERSION → $ZIP ($(du -h "$ZIP" | cut -f1)), $(cat dist/LiveIsland.zip.sha256 | cut -c1-16)…"
