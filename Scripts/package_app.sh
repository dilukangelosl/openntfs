#!/usr/bin/env bash
# Builds a universal, ad-hoc signed OpenNTFS.app into build/.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-0.1.0}
APP=build/OpenNTFS.app

swift build -c release --arch arm64 --arch x86_64
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/Icon.icns "$APP/Contents/Resources/"
cp .build/apple/Products/Release/OpenNTFS "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>OpenNTFS</string>
  <key>CFBundleIdentifier</key><string>org.openntfs.OpenNTFS</string>
  <key>CFBundleExecutable</key><string>OpenNTFS</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>Icon</string>
  <key>NSAppleEventsUsageDescription</key><string>OpenNTFS opens Terminal to install ntfs-3g.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
