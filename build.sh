#!/bin/sh
# Builds build/MicroCast.app from the Swift package (no Xcode project needed) and signs it ad hoc.
set -eu
cd "$(dirname "$0")"

APP=MicroCast
BUNDLE="build/$APP.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

if [ ! -f Resources/hls.min.js ]; then
	curl -fsSL -o Resources/hls.min.js https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.6.15/hls.min.js \
		|| echo "warning: could not download hls.js; the page will load it from the CDN"
fi

if [ ! -f Resources/AppIcon.icns ] || [ Resources/AppIcon.icns -ot Tools/make-icon.swift ]; then
	rm -rf build/AppIcon.iconset
	swift Tools/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
	cp build/AppIcon.iconset/icon_256x256.png Resources/icon.png
fi

swift build -c release --product "$APP"
cp "$(swift build -c release --show-bin-path)/$APP" "$BUNDLE/Contents/MacOS/$APP"
cp Info.plist "$BUNDLE/Contents/"
cp Resources/* "$BUNDLE/Contents/Resources/"
codesign -f -s - "$BUNDLE"
echo "built $BUNDLE"
