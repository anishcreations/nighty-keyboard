#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
    Sources/App/BrightnessController.swift Sources/App/PWMSession.swift Sources/App/DeepDimmingSession.swift Sources/App/LightingMemory.swift Tests/ControllerTests.swift -o build/tests/ControllerTests
build/tests/ControllerTests
