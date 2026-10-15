#!/bin/bash
# Renderiza o painel com dados fictícios (não fala com o Chromecast).
#   docs/*.png → inglês · docs/pt-BR/*.png → português
set -euo pipefail
cd "$(dirname "$0")"
APP=.build/Snapshot.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" docs/pt-BR
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/snapshot" \
  $(find Sources/CastMenubar -name '*.swift' ! -name App.swift) Snapshot/Snapshot.swift 2>&1 | grep "error:" || true
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.local.CastMenubar.snapshot</string>
  <key>CFBundleExecutable</key><string>snapshot</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
PLIST
"$APP/Contents/MacOS/snapshot" "${1:-docs}" -AppleLanguages '(en)'
"$APP/Contents/MacOS/snapshot" "${2:-docs/pt-BR}" -AppleLanguages '(pt-BR)'
