#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Nighty Keyboard.app"
SDK="$(xcrun --show-sdk-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/objects build/module-cache
for ARCH in arm64 x86_64; do
    MIN="${INTEL_MIN_VERSION:-13.0}"
    if [ "$ARCH" = arm64 ]; then MIN=11.0; fi
    TARGET="$ARCH-apple-macosx$MIN"
    xcrun clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -O2 -Wall -Wextra \
        -fmodules-cache-path="$PWD/build/module-cache" -c Sources/Hardware/KeyboardBridge.m -o "build/objects/KeyboardBridge-$ARCH.o"
    xcrun clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -O2 -Wall -Wextra \
        -fmodules-cache-path="$PWD/build/module-cache" -c Sources/Hardware/PWMBridge.m -o "build/objects/PWMBridge-$ARCH.o"
    xcrun swiftc -target "$TARGET" -sdk "$SDK" -swift-version 5 -O \
        -module-cache-path "$PWD/build/module-cache" -import-objc-header Sources/Hardware/KeyboardBridge.h \
        Sources/App/*.swift "build/objects/KeyboardBridge-$ARCH.o" "build/objects/PWMBridge-$ARCH.o" \
        -framework AppKit -framework Foundation -framework ServiceManagement -framework IOKit \
        -o "build/objects/NightyKeyboard-$ARCH"
done
if [ ! -f Resources/NightyKeyboard.icns ] || [ "${REGENERATE_ICON:-0}" = 1 ]; then
    xcrun swiftc -module-cache-path "$PWD/build/module-cache" scripts/make-icon.swift -o build/objects/make-icon
    build/objects/make-icon build/NightyKeyboard.iconset
    xcrun iconutil -c icns build/NightyKeyboard.iconset -o Resources/NightyKeyboard.icns
fi
xcrun lipo -create build/objects/NightyKeyboard-arm64 build/objects/NightyKeyboard-x86_64 -output "$APP/Contents/MacOS/NightyKeyboard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersionByArchitecture:x86_64 ${INTEL_MIN_VERSION:-13.0}" "$APP/Contents/Info.plist"
if [ -f Resources/NightyKeyboard.icns ]; then cp Resources/NightyKeyboard.icns "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
