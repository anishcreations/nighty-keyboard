# Nighty Keyboard — dim your keyboard further

A free macOS menu bar app for when the lowest keyboard brightness setting is
still too bright. Seven experimental deeper-dimming levels for built-in backlit
keyboards.

**Version 1.0.0 · MIT license.**

<p align="center">
  <img src="docs/preview.png" alt="Nighty Keyboard deeper dimming at level 6/7" width="360">
</p>

## Use

- Drag the dial or use arrow keys. Click its center for On/Off.
- Enable **Deeper dimming** for seven lower levels; adjust with the dial or slider.
- Idle, sleep, and lock pause lighting. Activity resumes the saved level using the macOS idle timeout.
- Normal relaunches remember the mode and level. Off and macOS handoff cancel automatic resume.
- Right-click the menu bar icon for deeper mode and **Use macOS settings**. Handoff requests the first regular level (6.25%), then releases control.
- The footer heart opens Support. Open at login requires macOS 13+.

No accounts, time limits, analytics, or input logging.

## Build

Requires Apple Command Line Tools.

```sh
./scripts/test.sh
./scripts/build.sh
open "build/Nighty Keyboard.app"
./scripts/package.sh
```

Installers: `build/NightyKeyboard-<version>-build<number>.dmg` and `.zip`.
Quit the old copy before replacing it. `./scripts/clean.sh` keeps the current app
and installers and removes obsolete build outputs.

## Compatibility and limitations

Built-in backlit keyboards only. Build targets: Apple Silicon macOS 11+;
Intel macOS 13+. Intel and older macOS versions need hardware validation.
Packages are ad hoc signed, not notarized.

Deeper dimming is experimental and uses private macOS controls. Brightness,
flicker, and energy impact are unmeasured; the darkest levels may pulse.
Provided as is, without warranties; see [LICENSE](LICENSE).

## Codebase

```text
Sources/
├── App/
│   ├── main.swift                  Lifecycle, menu bar, timers, and CLI
│   ├── Panel.swift                 Dial, center power, and recovery UI
│   ├── BrightnessController.swift  Steady brightness and settings ownership
│   ├── DeepDimmingSession.swift    Fade scheduling and depth settings
│   ├── LightingMemory.swift        Preferences and idle/resume policy
│   ├── NativeActivity.swift        Aggregate activity and preference storage
│   ├── NativeDevice.swift          Keyboard adapter and recovery storage
│   ├── NativePWM.swift             Raw HID adapter and diagnostics
│   └── PWMSession.swift            Raw-report session and recovery
└── Hardware/
    ├── KeyboardBridge.h/.m         CoreBrightness runtime boundary
    └── PWMBridge.h/.m              HID discovery and readback guards
Tests/                              Device-free regression checks
Resources/                          App metadata and icon
scripts/                            Build, test, package, and icon generation
tools/                              Diagnostics and manual repair utilities
docs/                               Architecture, development, and preview
```

## Saved settings

Preferences and the original macOS recovery snapshot are stored separately in
`~/Library/Application Support/Nighty Keyboard/`. Failed restoration retains the
snapshot. After interrupted sessions, use **Restore saved settings** or **Keep
current macOS settings**. Invalid records prevent automatic resume.

[Architecture](docs/ARCHITECTURE.md) · [Development](docs/DEVELOPMENT.md) ·
[Changelog](CHANGELOG.md)
