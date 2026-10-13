#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$PWD/build"
[ -d "$BUILD" ] || exit 0
if [ -L "$BUILD" ]; then
    printf 'Refusing to clean a symlinked build directory.\n' >&2
    exit 1
fi
APP="$BUILD/Nighty Keyboard.app"
KEEP_DMG=""; KEEP_ZIP=""
if [ -f "$APP/Contents/Info.plist" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
    BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
    KEEP_DMG="$BUILD/NightyKeyboard-$VERSION-build$BUILD_NUMBER.dmg"
    KEEP_ZIP="$BUILD/NightyKeyboard-$VERSION-build$BUILD_NUMBER.zip"
fi
# Preserve diagnostic records outside disposable build output. They remain ignored.
shopt -s nullglob
for RECORD in "$BUILD"/*.json "$BUILD"/*.log; do
    mkdir -p .local-diagnostics
    NAME=$(basename "$RECORD")
    DEST="$PWD/.local-diagnostics/$NAME"
    SUFFIX=1
    while [ -e "$DEST" ]; do
        DEST="$PWD/.local-diagnostics/$NAME.$SUFFIX"
        SUFFIX=$((SUFFIX + 1))
    done
    mv "$RECORD" "$DEST"
done
for ARCHIVE in "$BUILD"/NightyKeyboard*.dmg "$BUILD"/NightyKeyboard*.zip; do
    if [ "$ARCHIVE" != "$KEEP_DMG" ] && [ "$ARCHIVE" != "$KEEP_ZIP" ]; then
        rm "$ARCHIVE"
    fi
done
rm -rf "$BUILD/module-cache" "$BUILD/objects" "$BUILD/tests" \
    "$BUILD/NightyKeyboard.iconset" "$BUILD/nighty-package"
rm -f "$BUILD/preview.png" "$BUILD/NightyKeyboard-preview.png" \
    "$BUILD/PWMCapabilities" "$BUILD/PWMProbe" "$BUILD/ReadKeyboardState" \
    "$BUILD/RestoreMacControl" "$BUILD/RestoreSavedKeyboard"
printf 'Cleaned build caches and old artifacts; kept current app and build-numbered packages.\n'
