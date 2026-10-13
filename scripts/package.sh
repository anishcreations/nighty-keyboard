#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Nighty Keyboard.app"
if [ ! -d "$APP" ]; then ./scripts/build.sh; fi
codesign --verify --deep --strict "$APP"
PACKAGE="$PWD/build/nighty-package"
if [ -d "$PACKAGE" ]; then rm -r "$PACKAGE"; fi
mkdir -p "$PACKAGE"
cp -R "$APP" build/nighty-package/
cp README.md LICENSE build/nighty-package/
mkdir -p build/nighty-package/docs
cp docs/ARCHITECTURE.md docs/DEVELOPMENT.md docs/preview.png build/nighty-package/docs/
if [ ! -L build/nighty-package/Applications ]; then ln -s /Applications build/nighty-package/Applications; fi
hdiutil create -volname "Nighty Keyboard" -srcfolder build/nighty-package -ov -format UDZO build/NightyKeyboard.dmg
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" build/NightyKeyboard.zip
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
cp build/NightyKeyboard.dmg "build/NightyKeyboard-$VERSION.dmg"
cp build/NightyKeyboard.zip "build/NightyKeyboard-$VERSION.zip"
printf 'Packaged: build/NightyKeyboard-%s.dmg and build/NightyKeyboard-%s.zip\n' "$VERSION" "$VERSION"
