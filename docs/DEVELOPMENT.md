# Development

Requires macOS, Apple Command Line Tools, Swift, and the macOS SDK.
No third-party packages or Xcode project are needed.

## Build

```sh
./scripts/test.sh
./scripts/build.sh
./scripts/package.sh
```

Outputs and caches live in ignored `build/`. Rebuild before packaging source or
metadata changes; packaging otherwise uses the existing app.

- `INTEL_MIN_VERSION`: override the default Intel target of macOS 13.
- `REGENERATE_ICON=1`: regenerate the icon during a build.

## Device-free preview and UI checks

```sh
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --preview
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --verify-ui
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --render-preview /tmp/nighty.png
```

Controller tests use `KeyboardDevice` and `PWMDriver` fakes. UI checks exercise
bounds, accessibility, presets, depth, recovery, Off, and Use macOS. These checks
do not measure physical light output.

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
