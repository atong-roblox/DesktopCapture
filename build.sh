#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/build/Capture.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

SDK="$(xcrun --show-sdk-path)"
swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos15.0 \
  -sdk "$SDK" \
  -framework AppKit \
  -framework SwiftUI \
  -framework ScreenCaptureKit \
  -framework AVFoundation \
  -framework AVKit \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework CoreImage \
  -framework Carbon \
  -framework ServiceManagement \
  -framework UniformTypeIdentifiers \
  -framework ImageIO \
  -framework CoreGraphics \
  -framework ApplicationServices \
  -parse-as-library \
  -o "$APP/Contents/MacOS/Capture" \
  "$ROOT"/Sources/*.swift

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
