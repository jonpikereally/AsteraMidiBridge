#!/bin/bash
# Builds "Astera MIDI Bridge.app" into ../build using only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-$(cat VERSION)}"
OUT="${OUT:-../build}"
APP="$OUT/Astera MIDI Bridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library -O -swift-version 5 -target arm64-apple-macos13.0 \
  main.swift -o "$APP/Contents/MacOS/AsteraMidiBridge"

cp ../config.json "$APP/Contents/Resources/config.json"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Astera MIDI Bridge</string>
  <key>CFBundleDisplayName</key><string>Astera MIDI Bridge</string>
  <key>CFBundleIdentifier</key><string>com.jonpike.asteramidibridge</string>
  <key>CFBundleExecutable</key><string>AsteraMidiBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSLocalNetworkUsageDescription</key><string>Sends commands to AsteraApp's Remote Control server.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $APP (version $VERSION)"
