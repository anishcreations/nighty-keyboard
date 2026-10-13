# Changelog

## 0.0.0 · build 7 — 2026-10-14

### Changed

- Reduced deeper-mode envelopes from a 0.20-wide range to 0.01 around each target.
- Increased hardware fade duration from 400 ms to 10 seconds.
- Compensated retarget timing for actual elapsed time to avoid accumulating drift.
- Kept the current ramp when changing depth instead of restarting from Off.
- Trimmed the README and developer docs.

### Validation

- 137 device-free assertions pass, including all depths and uneven timer delivery.
- Modeled steady swing stays below 0.016 of the minimum endpoint in jitter tests.
- Native UI checks, universal build, code signature, and installer verification pass.
- User feedback reports improved pulsing on one Mac. Optical measurements and
  validation on other hardware remain pending.

## 0.0.0 · initial source release

- Native menu bar dial, presets, continuous deeper mode, and login option.
- Atomic recovery records, delayed restoration checks, and keep-current recovery.
- Runtime-checked CoreBrightness and guarded raw-HID interfaces.
- Universal build, device-free checks, and DMG/ZIP packaging.
