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
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

mkdir -p "$APP/Contents/Resources"
cp Sources/Skylight/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/Skylight"
# The session keeper rides beside the app binary; the app spawns it on the
# first terminal and it outlives every app run that has live sessions.
cp ".build/$CONFIG/skylightd" "$APP/Contents/MacOS/skylightd"
# A stable identity is what makes macOS permission grants survive a rebuild:
# ad-hoc signatures give every build a new code identity, so TCC forgets every
# grant. Detection only — this script never creates or trusts anything, and so
# can never raise a dialog of its own. scripts/setup-signing.sh does that once,
# by hand.
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Skylight Dev"'; then
  codesign --force --sign "Skylight Dev" "$APP/Contents/MacOS/skylightd" >/dev/null 2>&1 || true
  codesign --force --sign "Skylight Dev" "$APP" >/dev/null 2>&1 || echo "warning: signing with Skylight Dev FAILED — app is unsigned; permission grants will not persist. Check Keychain (locked? prompt declined?)." >&2
else
  codesign --force --sign - "$APP/Contents/MacOS/skylightd" >/dev/null 2>&1 || true
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "note: ad-hoc signed — macOS will re-ask permissions after rebuilds." >&2
  echo "      run scripts/setup-signing.sh once to fix that." >&2
fi
echo "Built $APP"
