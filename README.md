# Nighty Keyboard

A small macOS menu bar app for turning down your keyboard light.
Built with Swift and AppKit. Free, open source, and MIT licensed.

<p align="center">
  <img src="docs/preview.png" alt="Nighty Keyboard's amber brightness dial and deeper dimming controls" width="360">
</p>

## Light, your way

- **A brightness dial** with arrow-key navigation and Low, Work, and Bright presets.
- **Deeper dimming** with Deeper, Balanced, and Gentler settings, without a time limit.
- **Use macOS** to restore your previous settings; **Off** to switch the light off.
- **Recovery controls** to restore saved settings or explicitly keep the current ones.
- **Open at login** on macOS 13 and later.

No accounts, subscriptions, analytics, network requests, or keyboard-input monitoring.

Deeper dimming uses repeated hardware fades near the steady brightness minimum.
It is experimental: physical dimming depth and flicker have not been verified.
Nearby dial settings may produce the same visible brightness on some keyboards.

## Build and run

Install Apple's Command Line Tools, then run:

```sh
./scripts/test.sh
./scripts/build.sh
open "build/Nighty Keyboard.app"
```

Click the menu bar dial to open Nighty. Drag the dial's rim or choose a preset.
For deeper dimming, click **Enable deeper dimming** and select a setting.
It keeps running with the panel closed; **Stop deeper dimming**, **Use macOS**,
and **Off** end the mode. Sleep, idle, macOS brightness changes, and timing or
command failures also stop it. It does not automatically restart after sleep.

To create a DMG and ZIP:

```sh
./scripts/package.sh
```

The packages are written to `build/`. Quit an older copy before installing or
opening a replacement. Drag the app from the DMG into Applications.

## Compatibility

| Build | Minimum macOS |
| --- | --- |
| Apple Silicon · arm64 | 11.0 |
| Intel · x86_64 | 13.0 |

These are build targets, not a guarantee of hardware support. Nighty needs a
built-in backlit keyboard and uses Apple's private CoreBrightness interface,
which may change between macOS releases. Intel and older macOS versions need
hardware validation. Local packages are ad hoc signed, not notarized.

## Codebase

```text
Sources/
├── App/
│   ├── main.swift                  App lifecycle, menu bar, timers, and CLI
│   ├── Panel.swift                 Native dial, presets, and recovery UI
│   ├── BrightnessController.swift  Steady brightness and settings ownership
│   ├── DeepDimmingSession.swift    Continuous fade scheduling and depth settings
│   ├── NativeDevice.swift          Keyboard adapter and atomic recovery storage
│   ├── NativePWM.swift             Raw HID adapter and diagnostic status
│   └── PWMSession.swift            Guarded raw-report session and recovery
└── Hardware/
    ├── KeyboardBridge.h/.m         Runtime-checked CoreBrightness boundary
    └── PWMBridge.h/.m              HID descriptor discovery and readback guards
Tests/                              Device-free controller regression checks
Resources/                          App metadata and icon
scripts/                            Build, test, package, and icon generation
tools/                              Standalone diagnostics and repair utilities
docs/                               Architecture, development, and UI preview
```

Read the [architecture guide](docs/ARCHITECTURE.md) for control flow and recovery,
or the [development guide](docs/DEVELOPMENT.md) for previews and diagnostics.

## Recovery

If Nighty shows **Settings need attention**, choose **Restore saved settings**.
Restoration waits for macOS readback and retains the record if it cannot be
confirmed. An explicit nonzero restore can clear macOS's idle-dim state.

**Keep current macOS settings** discards the saved brightness without a hardware
write, when the automatic-brightness preference already matches. Recovery records
live in `~/Library/Application Support/Nighty Keyboard/`.

## License

[MIT](LICENSE)
