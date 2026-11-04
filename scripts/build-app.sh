#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Multitool"
BUNDLE_ID="com.mmengual.multitool"
APP="$ROOT/$APP_NAME.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# Orbe fonts (Outfit, Manrope, JetBrains Mono, SIL OFL), loaded through ATSApplicationFontsPath.
cp -R "$ROOT/Resources/Fonts" "$APP/Contents/Resources/Fonts"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"

echo ""
echo "Built: $APP"
echo ""
echo "Install:"
echo "  mv \"$APP\" /Applications/"
echo ""
echo "Then open /Applications/$APP_NAME.app once, grant Accessibility,"
echo "and (important) REMOVE any previous Multitool entry from the"
echo "Accessibility list before re-adding — stale cdhash entries block reprompts."
