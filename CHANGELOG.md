# Changelog

## 0.0.0 · build 9 — 2026-10-14

- Replaced 50 Hz polling with one-shot fade and readback deadlines.
- Paused normal observation during deeper mode; scheduled status checks every 500 ms.
- Allowed scheduling pauses only while estimated light drift stays bounded.
- Added `--profile-preview`: 154 fade wakeups in 15.04 seconds versus 751 polling ticks.
- Added build cleanup and build-numbered packaging without duplicate installers.

Validation: 208 device-free checks and native UI checks pass. Actual battery drain
and hardware-call overhead remain unmeasured.

## 0.0.0 · build 8 — 2026-10-14

- Added seven deeper levels, including four below the previous Deeper target.
- Narrowed fade envelopes and adapted durations to the selected level.
- Preserved the current ramp and recovery snapshot when switching levels.

## 0.0.0 · build 7 — 2026-10-14

- Narrowed deeper-mode envelopes and increased fade duration to 10 seconds.
- Compensated for timer drift and removed the Off restart when changing depth.
- Added regression checks and trimmed documentation.

User feedback reported reduced pulsing on one Mac. Optical measurements and other
hardware validation remain pending.

## 0.0.0 · initial source release

- Native dial, presets, deeper mode, and login option.
- Atomic recovery, delayed restoration checks, and keep-current recovery.
- Runtime-checked CoreBrightness, guarded HID interfaces, and universal packaging.
