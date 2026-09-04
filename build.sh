#!/usr/bin/env bash
# Builds Respawken.app into ./dist.
#   --run      relaunch the dist copy (iterate)
#   --install  copy to /Applications and relaunch that (wrap-up / daily driver)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

RUN=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --run) RUN=1 ;;
        --install) INSTALL=1 ;;
        *)
            echo "usage: $0 [--run] [--install]" >&2
            exit 2
            ;;
    esac
done

APP_NAME="Respawken"
# New suffix so Notification Center drops the blank icon it cached against the
# original bundle id (from builds that shipped before Assets.car existed).
BUNDLE_ID="com.bjardon.respawken.app"
VERSION="${RESPAWKEN_VERSION:-0.1.3}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
INSTALLED="/Applications/$APP_NAME.app"

swift build -c release --disable-sandbox

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Notification Center on macOS 26 resolves the app icon from a compiled Assets.car
# that contains an Icon Composer stack (IconImageStack). A loose .icns — or even a
# classic appiconset-only Assets.car — still leaves NC banners on the blank
# placeholder. Prefer AppIcon.icon; fall back to Assets.xcassets; then iconutil.
ICON_NAME_PLIST=""
ICON_DOC="$ROOT/Resources/AppIcon.icon"
XCASSETS="$ROOT/Resources/Assets.xcassets"
ACTOOL_PLIST="$DIST/actool-partial.plist"
ACTOOL_INPUT=""
if [[ -d "$ICON_DOC" ]]; then
    ACTOOL_INPUT="$ICON_DOC"
elif [[ -d "$XCASSETS" ]]; then
    ACTOOL_INPUT="$XCASSETS"
fi
if [[ -n "$ACTOOL_INPUT" ]] && xcrun --find actool >/dev/null 2>&1; then
    if xcrun actool "$ACTOOL_INPUT" \
        --compile "$APP/Contents/Resources" \
        --app-icon AppIcon \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --include-all-app-icons \
        --enable-on-demand-resources NO \
        --development-region en \
        --target-device mac \
        --output-partial-info-plist "$ACTOOL_PLIST" \
        >/dev/null \
        && [[ -f "$APP/Contents/Resources/Assets.car" ]]; then
        ICON_NAME_PLIST=$'\n    <key>CFBundleIconName</key><string>AppIcon</string>'
    else
        echo "warning: actool failed — shipping without Assets.car (notification icon may be blank)" >&2
    fi
    rm -f "$ACTOOL_PLIST"
fi
# Prefer a full multi-resolution .icns from the PNG ladder over actool's small
# generated stub — Finder and some NC fallbacks still read CFBundleIconFile.
if [[ -d "$XCASSETS/AppIcon.appiconset" ]]; then
    TMP_ICONSET="$DIST/AppIcon.iconset"
    rm -rf "$TMP_ICONSET"
    mkdir -p "$TMP_ICONSET"
    cp "$XCASSETS/AppIcon.appiconset/"icon_*.png "$TMP_ICONSET/"
    iconutil -c icns "$TMP_ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$TMP_ICONSET"
fi

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
    <key>CFBundleIconFile</key><string>AppIcon</string>$ICON_NAME_PLIST
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <!-- Banner clicks go through Launch Services, which otherwise starts a second copy. -->
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || true

echo "Built $APP"

if [[ "$INSTALL" -eq 1 ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.3
    rm -rf "$INSTALLED"
    ditto "$APP" "$INSTALLED"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$INSTALLED" >/dev/null 2>&1 || true
    open "$INSTALLED"
    echo "Installed $INSTALLED"
elif [[ "$RUN" -eq 1 ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.3
    open "$APP"
    echo "Launched $APP_NAME"
fi
