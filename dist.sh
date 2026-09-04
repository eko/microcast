#!/bin/sh
# Builds the app and packages build/MicroCast-<version>.dmg (the app plus an Applications shortcut).
#
#   ./dist.sh                                   ad-hoc signed: fine on this Mac; other Macs must right-click → Open once
#   VERSION=1.2.0 ./dist.sh                     stamps that version into the bundle (CI passes the git tag)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./dist.sh
#   SIGN_IDENTITY=… NOTARY_PROFILE=my-notary ./dist.sh      also notarizes and staples (profile from `xcrun notarytool store-credentials`)
set -eu
cd "$(dirname "$0")"

./build.sh
APP=build/MicroCast.app
PLIST="$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
	BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
	codesign -f -s - "$APP"
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")
DMG="build/MicroCast-$VERSION.dmg"

if [ -n "${SIGN_IDENTITY:-}" ]; then
	codesign -f --timestamp --options runtime --entitlements entitlements.plist -s "$SIGN_IDENTITY" "$APP"
fi

STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "MicroCast" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
rm -rf "$STAGE"

if [ -n "${SIGN_IDENTITY:-}" ]; then
	codesign --timestamp -s "$SIGN_IDENTITY" "$DMG"
	if [ -n "${NOTARY_PROFILE:-}" ]; then
		xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
		xcrun stapler staple "$DMG"
	fi
fi

shasum -a 256 "$DMG" | sed 's|build/||' > "$DMG.sha256"
echo "packaged $DMG ($(du -h "$DMG" | cut -f1)), checksum in $DMG.sha256"
