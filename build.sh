#!/usr/bin/env bash
# Builds Respawken.app into ./dist. Pass --run to relaunch it afterwards.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Respawken"
BUNDLE_ID="com.bjardon.respawken"
VERSION="${RESPAWKEN_VERSION:-0.1.0}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

swift build -c release --disable-sandbox

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || true

echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.3
    open "$APP"
    echo "Launched $APP_NAME"
fi
