#!/usr/bin/env bash
# Builds Multitool.app at the root of the repo.
#
#   scripts/build-app.sh
#
# Version: the VERSION file (MULTITOOL_VERSION overrides it).
# Build number: number of commits on HEAD (MULTITOOL_BUILD overrides it). Sparkle
# compares this number to decide whether a release is newer.
# Update token: keychain item "multitool-update-token" (MULTITOOL_UPDATE_TOKEN
# overrides it). Only needed if the repo is private.
# Signing identity: SIGN_IDENTITY, by default the Apple Development certificate.
# A stable identity keeps the Accessibility permission across updates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Multitool"
BUNDLE_ID="com.mmengual.multitool"
HELPER_ID="com.mmengual.multitool.helper"
APP="$ROOT/$APP_NAME.app"
FEED_URL="https://raw.githubusercontent.com/mmengual/multitool/releases/appcast.xml"
DEFAULT_IDENTITY="6049975204961E83D9BD36350013067DBA1D1307" # Apple Development certificate of the main Mac

VERSION="${MULTITOOL_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${MULTITOOL_BUILD:-$(git rev-list --count HEAD)}"
PUBLIC_KEY="$(tr -d '[:space:]' < Resources/Sparkle/public-key.txt)"
TOKEN="${MULTITOOL_UPDATE_TOKEN:-$(security find-generic-password -s multitool-update-token -w 2>/dev/null || true)}"
IDENTITY="${SIGN_IDENTITY:-$DEFAULT_IDENTITY}"

IDENTITIES="$(security find-identity -v -p codesigning | grep -v REVOKED)"
if [[ -z "${SIGN_IDENTITY:-}" ]] && ! grep -q "$IDENTITY" <<<"$IDENTITIES"; then
    # Each Mac has its own Apple Development certificate. They share the same name,
    # which is what the Accessibility permission checks, so any valid one will do.
    # The first Apple Development identity is taken: no address in the repo.
    FALLBACK="$(awk '/"Apple Development: / { print $2; exit }' <<<"$IDENTITIES")"
    if [[ -n "$FALLBACK" ]]; then
        echo "note: default identity not on this Mac, signing with $FALLBACK." >&2
        IDENTITY="$FALLBACK"
    fi
fi
if ! grep -q "$IDENTITY" <<<"$IDENTITIES"; then
    echo "warning: signing identity $IDENTITY not found, signing ad hoc." >&2
    echo "         Accessibility will have to be granted again after each update." >&2
    IDENTITY="-"
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" \
         "$APP/Contents/Library/LaunchDaemons"

cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# Read-only privileged helper, registered by the app with SMAppService.daemon.
cp ".build/release/MultitoolHelper" "$APP/Contents/MacOS/MultitoolHelper"
# Menu Bar module: the tool that flips macOS's per-app menu bar switches.
cp ".build/release/MultitoolVisibility" "$APP/Contents/MacOS/MultitoolVisibility"
cat > "$APP/Contents/Library/LaunchDaemons/$HELPER_ID.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$HELPER_ID</string>
    <key>BundleProgram</key><string>Contents/MacOS/MultitoolHelper</string>
    <key>MachServices</key><dict><key>$HELPER_ID</key><true/></dict>
    <key>AssociatedBundleIdentifiers</key><array><string>$BUNDLE_ID</string></array>
</dict>
</plist>
EOF
ditto ".build/release/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Orbe fonts (Outfit, Manrope, JetBrains Mono, SIL OFL), loaded through ATSApplicationFontsPath.
cp -R "$ROOT/Resources/Fonts" "$APP/Contents/Resources/Fonts"

TOKEN_ENTRY=""
if [[ -n "$TOKEN" ]]; then
    TOKEN_ENTRY="<key>MTUpdateToken</key><string>$TOKEN</string>"
else
    echo "note: no update token (keychain item multitool-update-token): fine while the repo is public." >&2
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    $TOKEN_ENTRY
</dict>
</plist>
EOF

# Sign inside out: Sparkle's helpers, the privileged helper, the visibility tool, then the app.
# The helper checks that its client is com.mmengual.multitool signed by this team,
# and the app checks the same of the helper (MultitoolShared/HelperProtocol.swift).
codesign --force --deep --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" --identifier "$HELPER_ID" "$APP/Contents/MacOS/MultitoolHelper"
# MultitoolVisibility needs an entitlement macOS only accepts from a Developer ID
# signature (an Apple Development one gets the process killed at launch). Without a
# Developer ID identity on this Mac it is signed like the rest, and the Menu Bar
# module says that hiding is unavailable.
VISIBILITY_ID="${VISIBILITY_IDENTITY:-$(awk '/"Developer ID Application: / { print $2; exit }' <<<"$IDENTITIES")}"
if [[ -n "$VISIBILITY_ID" ]]; then
    codesign --force --sign "$VISIBILITY_ID" --options runtime --identifier "$BUNDLE_ID.visibility" \
        --entitlements "$ROOT/Resources/MultitoolVisibility.entitlements" "$APP/Contents/MacOS/MultitoolVisibility"
else
    echo "note: no Developer ID identity on this Mac: the Menu Bar module can't hide icons in this build." >&2
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.visibility" "$APP/Contents/MacOS/MultitoolVisibility"
fi
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo ""
echo "Built: $APP ($VERSION, build $BUILD)"
echo "Install: rm -rf /Applications/$APP_NAME.app && mv \"$APP\" /Applications/"
