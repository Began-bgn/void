#!/usr/bin/env bash
# Archive, Developer ID export, notarize, staple and package NotchDeck as a DMG.
#
# One-time setup:
#   security find-identity -v -p codesigning        # must list "Developer ID Application: … (F63KU4246G)"
#   xcrun notarytool store-credentials notchdeck-notary --apple-id <apple-id> --team-id F63KU4246G
#
# Usage: scripts/release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-F63KU4246G}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notchdeck-notary}"
SIGN_ID="${SIGN_ID:-Developer ID Application}"
VERSION="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)"

OUT="build/release"
ARCHIVE="$OUT/NotchDeck.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/Void.app"
ZIP="$OUT/NotchDeck-$VERSION.zip"
DMG="$OUT/NotchDeck-$VERSION.dmg"
STAGING="$OUT/dmg"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Archive (Release)"
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates archive | tail -n 3

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF

echo "==> Export (Developer ID)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates | tail -n 3

echo "==> Verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority=Developer ID Application|TeamIdentifier=$TEAM_ID" >/dev/null \
  || { echo "App is not Developer ID signed with team $TEAM_ID" >&2; exit 1; }

echo "==> Notarize app"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Build DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "NotchDeck $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

echo "==> Notarize DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "==> Done: $DMG"
