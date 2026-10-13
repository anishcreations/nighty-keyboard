# Development

## Requirements

- macOS with Apple Command Line Tools, Swift, and the macOS SDK.
- No third-party packages or Xcode project are required.

## Scripts

| Script | Result |
| --- | --- |
| `./scripts/test.sh` | Compiles and runs device-free controller checks |
| `./scripts/build.sh` | Builds and ad hoc signs a universal app |
| `./scripts/package.sh` | Packages the built app as a DMG and ZIP |
| `scripts/make-icon.swift` | Generates the native app icon |

The build targets arm64 on macOS 11+ and x86_64 on macOS 13+. Set
`INTEL_MIN_VERSION` to adjust the Intel target; support depends on the installed
Swift toolchain. Set `REGENERATE_ICON=1` when rebuilding the icon.

Build outputs and module caches are under `build/` and are excluded from Git.
The packaging script uses an existing app when available; rebuild first after
changing source or app metadata.

## Preview and UI checks

These modes use a fake keyboard and make no hardware brightness changes:

```sh
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --preview
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --verify-ui
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --render-preview /tmp/nighty.png
```

## Read-only diagnostics

```sh
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --diagnose
"build/Nighty Keyboard.app/Contents/MacOS/NightyKeyboard" --diagnose-pwm
```

Diagnostics report the interface, keyboard state, and guarded raw-HID availability.
Logical readback confirms software-visible state, not emitted light. The everyday
app disables `--verify-hardware` and `--verify-pwm`.

## Standalone tools

| Source | Purpose |
| --- | --- |
| `ReadKeyboardState.m` | Reads keyboard properties without setters |
| `PWMCapabilities.m` | Inspects HID capabilities |
| `PWMProbe.m` | Manual hardware-changing probe |
| `RestoreMacControl.m` | Manual idle-state and brightness repair |
| `RestoreSavedKeyboard.m` | Restores a saved snapshot and checks readback |

The hardware-changing utilities are separate from the build and test scripts.
Run them deliberately; they can alter keyboard settings. Saved-state repair backs
up the snapshot and removes the recovery record only after confirmation.

## Working on the app

Use `KeyboardDevice` and `PWMDriver` fakes for controller changes. Keep hardware
calls in the bridges, lifecycle coordination in `main.swift`, and presentation in
`Panel.swift`. Recovery records must be durable before the first write. Do not treat
a successful setter return as proof that the keyboard applied a change.

Run the controller checks after behavioral changes and the fake-device UI check
after changing controls or layout. Validate hardware and optical behavior separately
before claiming support for a new Mac or macOS release.
