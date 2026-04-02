#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Building CC-HP..."
swift build -c release 2>&1

APP="CC-HP.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CCHP "$APP/Contents/MacOS/CCHP"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Build complete: $APP"
