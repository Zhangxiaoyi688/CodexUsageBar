#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexUsageBar"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
EXECUTABLE="$ROOT_DIR/.build/release/$APP_NAME"
ICON_PATH="$ROOT_DIR/Assets/AppIcon.icns"

cd "$ROOT_DIR"
./scripts/generate-icon.swift >/dev/null
swift build -c release --product "$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex-usage-bar</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Local-only Codex usage monitor.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null
echo "$APP_DIR"
