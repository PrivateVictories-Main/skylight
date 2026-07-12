#!/bin/zsh
# Build Skylight and assemble a runnable .app bundle at build/Skylight.app
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Skylight"
APP="build/Skylight.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Skylight</string>
    <key>CFBundleIdentifier</key><string>com.ryan.skylight</string>
    <key>CFBundleName</key><string>Skylight</string>
    <key>CFBundleDisplayName</key><string>Skylight</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/Skylight"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
