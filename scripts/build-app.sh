#!/bin/bash
# Builds dist/ContactMirror.app (universal) and dist/ContactMirror.zip.
#
# Signing: set SIGN_IDENTITY (and optionally SIGN_KEYCHAIN). Releases must always be signed
# with the same certificate, because the in-app updater refuses updates signed by anything else.
# Without SIGN_IDENTITY the app is ad-hoc signed (fine for local testing, can't self-update).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP=dist/ContactMirror.app
BUNDLE_ID=io.github.contactmirror.app

echo "==> Building ContactMirror $VERSION ($BUILD_NUMBER)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ContactMirror"

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ContactMirror"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ContactMirror</string>
    <key>CFBundleDisplayName</key><string>ContactMirror</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>ContactMirror</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSContactsUsageDescription</key><string>ContactMirror keeps your iCloud contacts identical to your Google contacts.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>ContactMirror keeps your iCloud calendars identical to your Google calendars.</string>
    <key>NSCalendarsUsageDescription</key><string>ContactMirror keeps your iCloud calendars identical to your Google calendars.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>ContactMirror keeps your iCloud Reminders identical to your Google Tasks.</string>
    <key>NSRemindersUsageDescription</key><string>ContactMirror keeps your iCloud Reminders identical to your Google Tasks.</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with: $SIGN_IDENTITY"
    KC_ARGS=()
    [[ -n "${SIGN_KEYCHAIN:-}" ]] && KC_ARGS=(--keychain "$SIGN_KEYCHAIN")
    codesign --force --sign "$SIGN_IDENTITY" "${KC_ARGS[@]}" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
else
    echo "==> SIGN_IDENTITY not set: ad-hoc signing (in-app updates will be refused for this build)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true

(cd dist && ditto -c -k --sequesterRsrc --keepParent ContactMirror.app ContactMirror.zip)
shasum -a 256 dist/ContactMirror.zip
echo "==> Done: dist/ContactMirror.zip"
