#!/bin/bash
# Builds ScreenshotTool.app and installs it to /Applications.
#
#   ./build.sh               native architecture only (smallest)
#   ./build.sh --universal   Apple Silicon + Intel
#
# Uses swiftc directly rather than `swift build` so it works with just the
# Command Line Tools (SwiftPM's manifest loading breaks on some CLT installs).
set -euo pipefail
cd "$(dirname "$0")"

ARCHS="$(uname -m)"
[[ "${1:-}" == "--universal" ]] && ARCHS="arm64 x86_64"

SDK="$(xcrun --show-sdk-path)"
OUT=.build/bin
rm -rf "$OUT"
mkdir -p "$OUT"

for arch in $ARCHS; do
    swiftc -Osize -wmo -target "$arch-apple-macos12.0" -sdk "$SDK" \
        Sources/ScreenshotTool/*.swift -o "$OUT/ScreenshotTool-$arch"
done
lipo -create "$OUT"/ScreenshotTool-* -output "$OUT/ScreenshotTool"
strip -x "$OUT/ScreenshotTool"

APP=.build/ScreenshotTool.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT/ScreenshotTool" "$APP/Contents/MacOS/ScreenshotTool"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign with a requirement tied to the bundle ID rather than the build's
# hash, so the Screen Recording permission survives rebuilds. (Without this,
# every rebuild silently loses the permission and captures show only the wallpaper.)
codesign --force --sign - \
    --identifier com.zachglabman.screenshottool \
    -r='designated => identifier "com.zachglabman.screenshottool"' \
    "$APP"

# Install where launch-at-login expects a stable path
DEST=/Applications/ScreenshotTool.app
pkill -x ScreenshotTool 2>/dev/null || true
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "Installed $DEST ($(du -sh "$DEST" | cut -f1))"
