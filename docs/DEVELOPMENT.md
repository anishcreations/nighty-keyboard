# Development

Requires macOS, Apple Command Line Tools, Swift, and the macOS SDK.
No third-party packages or Xcode project are needed.

## Build

```sh
./scripts/test.sh
./scripts/build.sh
./scripts/package.sh
```

Outputs live in ignored `build/`. Rebuild after source or metadata changes.
Packaging creates one build-numbered DMG/ZIP pair and removes temporary staging.
`./scripts/clean.sh` removes caches and older packages, keeps the current app and
installers, and moves diagnostic records to ignored `.local-diagnostics/`.

- `INTEL_MIN_VERSION`: override the default Intel target of macOS 13.
- `REGENERATE_ICON=1`: regenerate the icon during a build.

## Device-free preview and UI checks

```sh
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --preview
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --verify-ui
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --verify-lifecycle
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --profile-preview
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --render-preview /tmp/nighty.png
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --render-preview /tmp/nighty-idle.png --preview-idle
```

Tests use fake devices. `--verify-lifecycle` checks repeated idle/wake cycles,
nested sleep and lock, clean and unclean relaunches, sensor ownership, and failed
preference storage without reading or changing real user settings. `--verify-ui` checks controls and layout; `--profile-preview`
reports wakeups during 15 seconds of simulated dimming. Neither measures battery
drain, hardware-call overhead, or physical light output.

## Read-only diagnostics

```sh
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --diagnose
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --diagnose-pwm
```

`--verify-hardware` and `--verify-pwm` are disabled in the app.

## Standalone tools

| Source | Purpose |
| --- | --- |
| `ReadKeyboardState.m` | Read properties without setters |
| `PWMCapabilities.m` | Inspect HID capabilities |
| `PWMProbe.m` | Manual hardware-changing probe |
| `RestoreMacControl.m` | Manual idle-state and brightness repair |
| `RestoreSavedKeyboard.m` | Restore a saved snapshot and check readback |

Hardware-changing tools are outside the build/test workflow. Saved-state repair
backs up the record and removes it only after confirmation.
