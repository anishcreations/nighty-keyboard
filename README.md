# Nighty Keyboard

A native macOS menu bar app for keyboard brightness. Swift, AppKit, and MIT licensed.

<p align="center">
  <img src="docs/preview.png" alt="Nighty Keyboard brightness controls" width="360">
</p>

## Features

- Brightness dial, arrow-key navigation, and Low, Work, and Bright presets.
- Seven deeper-dimming levels, from Barely lit to Gentler.
- Remember the chosen mode and level through idle, sleep, and normal relaunches.
- Restore previous settings, keep current macOS settings, or turn the light off.
- Open at login on macOS 13+.

Free, with no time limit, accounts, analytics, or input logging.
Deeper dimming is experimental; physical brightness and flicker are not measured.

## Build and use

Requires Apple Command Line Tools.

```sh
./scripts/test.sh
./scripts/build.sh
open "build/Nighty Keyboard.app"
```

Click the menu bar dial and drag its rim or choose a preset. **Enable deeper
dimming** runs with the panel closed; move its slider left for less light.

Nighty follows the macOS keyboard idle timeout. Typing, mouse, and trackpad
activity count as use. Idle, lock, and sleep pause fade commands; the saved mode
resumes when activity returns and macOS releases the keyboard. A normal relaunch
also remembers the enabled mode. **Off**, **Stop deeper dimming**, or **Use macOS**
cancel automatic resume. The darkest levels may still pulse.

```sh
./scripts/package.sh
```

Packages use `build/NightyKeyboard-<version>-build<number>.dmg` and `.zip`.
Quit the previous copy before installing. Run `./scripts/clean.sh` to remove
caches and obsolete artifacts while keeping the current app and packages.

## Compatibility

| Architecture | Minimum macOS build target |
| --- | --- |
| Apple Silicon · arm64 | 11.0 |
| Intel · x86_64 | 13.0 |

Requires a built-in backlit keyboard and Apple's private CoreBrightness interface.
Intel and older macOS targets need hardware validation. Packages are ad hoc signed,
not notarized.

## Codebase

```text
Sources/
├── App/
│   ├── main.swift                  Lifecycle, menu bar, timers, and CLI
│   ├── Panel.swift                 Dial, presets, and recovery UI
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

## Recovery

**Restore saved settings** waits for macOS confirmation and retains the record
on failure. A nonzero restore can clear macOS's idle-dim state. **Keep current
macOS settings** clears recovery without a hardware write when the sensor
preference already matches. Records are stored in
`~/Library/Application Support/Nighty Keyboard/`. `preferences.json` stores the
chosen mode and levels separately from the original macOS snapshot. Crashes,
invalid records, and failed restoration require explicit recovery; they never
automatically reapply a level. After upgrading, enable a mode once to remember it.

[Architecture](docs/ARCHITECTURE.md) · [Development](docs/DEVELOPMENT.md) ·
[Changelog](CHANGELOG.md) · [MIT license](LICENSE)
