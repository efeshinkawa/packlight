#!/bin/bash
# Builds Packlight.app (with its icon) and installs it to ~/Applications, then launches it.
#   ./build.sh                build + install + launch
#   ./build.sh --no-install   only build build/Packlight.app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Packlight.app"
DEST="$HOME/Applications/Packlight.app"
BUNDLE_ID="io.github.efeshinkawa.packlight"
VERSION="1.0.0"

swift build -c release
BIN=.build/release/Packlight

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Packlight"

# App icon, drawn by the app itself (see PacklightMark in MenuBarIcon.swift).
ICONSET=build/Packlight.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  "$BIN" --make-icon "$ICONSET/icon_${s}x${s}.png" "$s"
  "$BIN" --make-icon "$ICONSET/icon_${s}x${s}@2x.png" "$((s * 2))"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Packlight.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Packlight</string>
    <key>CFBundleDisplayName</key><string>Packlight</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Packlight</string>
    <key>CFBundleIconFile</key><string>Packlight</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <key>NSAppleEventsUsageDescription</key><string>Packlight asks for your admin password once to install its password-free helper.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>${BUNDLE_ID}</string>
            <key>CFBundleURLSchemes</key><array><string>packlight</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $APP"

[ "${1:-}" = "--no-install" ] && exit 0

pkill -x Packlight 2>/dev/null || true
pkill -x LapDesktop 2>/dev/null || true          # pre-release name
rm -rf "$HOME/Applications/LapDesktop.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
open "$DEST"
echo "Installed: $DEST"
