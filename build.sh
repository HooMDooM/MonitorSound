#!/bin/zsh
# Builds MonitorSound.app and installs it to /Applications.
set -e
cd "$(dirname "$0")"
APP=build/MonitorSound.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/MonitorSound" Sources/DDC.swift Sources/main.swift \
  -framework IOKit -framework AppKit -framework CoreAudio -framework ServiceManagement
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MonitorSound</string>
  <key>CFBundleIdentifier</key><string>local.monitorsound</string>
  <key>CFBundleExecutable</key><string>MonitorSound</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
if [[ "$1" == "--install" ]]; then
  pkill -x MonitorSound || true
  rm -rf /Applications/MonitorSound.app
  cp -R "$APP" /Applications/
  open /Applications/MonitorSound.app
fi
