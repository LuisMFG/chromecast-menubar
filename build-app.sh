#!/bin/bash
# Compila e empacota "Chromecast.app" (só barra de menus, sem ícone no Dock).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="build/Chromecast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CastMenubar "$APP/Contents/MacOS/"
[ -d Resources ] && cp -R Resources/*.lproj "$APP/Contents/Resources/" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Chromecast</string>
  <key>CFBundleIdentifier</key><string>dev.local.CastMenubar</string>
  <key>CFBundleExecutable</key><string>CastMenubar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>pt-BR</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Used to find and control Chromecast devices on your network.</string>
  <key>NSBonjourServices</key><array><string>_googlecast._tcp</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Pronto: $APP"
