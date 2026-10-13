#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Nighty Keyboard.app"
if [ ! -d "$APP" ]; then ./scripts/build.sh; fi
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
OUTPUT="$PWD/build/NightyKeyboard-$VERSION-build$BUILD_NUMBER"
PACKAGE=$(mktemp -d "$PWD/build/package.XXXXXX")
trap 'rm -rf "$PACKAGE"' EXIT
cp -R "$APP" "$PACKAGE/"
cp README.md CHANGELOG.md LICENSE "$PACKAGE/"
mkdir -p "$PACKAGE/docs"
cp docs/ARCHITECTURE.md docs/DEVELOPMENT.md docs/preview.png "$PACKAGE/docs/"
ln -s /Applications "$PACKAGE/Applications"
hdiutil create -volname "Nighty Keyboard" -srcfolder "$PACKAGE" -ov -format UDZO "$OUTPUT.dmg"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT.zip"
printf 'Packaged: %s.dmg and %s.zip\n' "$OUTPUT" "$OUTPUT"
