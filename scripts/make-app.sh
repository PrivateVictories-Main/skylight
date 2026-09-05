#!/bin/zsh
# Build Skylight and assemble a runnable .app bundle at build/Skylight.app
set -euo pipefail
cd "$(dirname "$0")/.."

# Release by default: the bundle is the artifact people RUN, and Swift's
# debug mode is several times slower in the daemon's hot paths. The dev
# loop (swift build / swift test) is unaffected; pass "debug" to override.
CONFIG="${1:-release}"
[[ "$CONFIG" == "debug" || "$CONFIG" == "release" ]] || { echo "usage: $0 [debug|release]" >&2; exit 2; }
BUILD_DIR="${SKYLIGHT_BUILD_DIR:-.build}"
swift build --scratch-path "$BUILD_DIR" -c "$CONFIG"

BIN="$BUILD_DIR/$CONFIG/Skylight"
APP_NAME="${SKYLIGHT_APP_NAME:-Skylight}"
[[ -n "$APP_NAME" && "$APP_NAME" != *[/\\]* && "$APP_NAME" != .* ]] || { echo "Invalid app bundle name" >&2; exit 2; }
APP="build/$APP_NAME.app"

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
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Ryan Stallings</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

mkdir -p "$APP/Contents/Resources"
cp Sources/Skylight/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE.md "$APP/Contents/Resources/Licenses/Skylight.md"
cp Vendor/GhosttyKit/LICENSE "$APP/Contents/Resources/Licenses/GhosttyKit.txt"
cp Vendor/GhosttyKit/Sources/GhosttyTheme/LICENSE "$APP/Contents/Resources/Licenses/GhosttyTheme.txt"
cp "$BIN" "$APP/Contents/MacOS/Skylight"
# Resources belong in Contents/Resources, not the nested-code directory.
# The vendored wrapper resolves here before consulting SwiftPM's build fallback.
for bundle in "$BUILD_DIR"/"$CONFIG"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done
# The session keeper rides beside the app binary; the app spawns it on the
# first terminal and it outlives every app run that has live sessions.
cp "$BUILD_DIR/$CONFIG/skylightd" "$APP/Contents/MacOS/skylightd"
# A stable identity is what makes macOS permission grants survive a rebuild:
# ad-hoc signatures give every build a new code identity, so TCC forgets every
# grant. Detection only — this script never creates or trusts anything, and so
# can never raise a dialog of its own. scripts/setup-signing.sh does that once,
# by hand.
IDENTITY="${SKYLIGHT_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Skylight Dev"'; then
    IDENTITY="Skylight Dev"
  else
    IDENTITY="-"
    echo "note: ad-hoc signed — macOS will re-ask permissions after rebuilds." >&2
    echo "      run scripts/setup-signing.sh once to fix that." >&2
  fi
fi
# A failed signature is a failed build, never a successful-looking artifact.
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/skylightd"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/Skylight" --verify-bundle-resources
echo "Built and verified $APP"
