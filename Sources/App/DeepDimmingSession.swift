import Foundation

/// Continuous, user-selected hardware fades with recovery and timing checks.
/// The envelope is a model of a linear ramp; it is NOT measured optical brightness.
final class DeepDimmingSession {
    static let floorRequest: Float = 0.0001
    static let transitionMilliseconds = 4_000
    private let device: KeyboardDevice
    private(set) var snapshot: BrightnessController.Snapshot?
    private(set) var running = false
    private(set) var isPaused = false
    private(set) var restorationAwaitingConfirmation = false
    private(set) var message = ""
    var saveRecovery: ((BrightnessController.Snapshot?) -> Bool)?
    private var started: TimeInterval = 0
    private var nextCommand: TimeInterval = 0
    private var nextStatusCheck: TimeInterval = 0

    var nextWakeTime: TimeInterval? {
        guard running else { return nil }
        return min(nextCommand, nextStatusCheck, awaitingReadback ? verifyAt : .infinity)
    }
    private var verifyAt: TimeInterval = 0
    private var awaitingReadback = false
    private var target: Float = 0
    private var rising = true
    private var initialized = false
    private var ramp: FadeRamp?
    enum Depth: Int, CaseIterable { case barely, veryLow, low, dim, deepest, balanced, gentler
        var center: Double { [0.04, 0.06, 0.10, 0.16, 0.25, 0.50, 0.75][rawValue] }
        var title: String { ["Barely lit", "Very low", "Low", "Dim", "Deeper", "Balanced", "Gentler"][rawValue] }
        var halfWidth: Double { max(0.0006, center * 0.003) }
        var lower: Double { center - halfWidth }
        var upper: Double { center + halfWidth }
        var rampMilliseconds: Int {
            // Keep corrections about 200 ms apart without widening dim envelopes.
            let seconds = 0.2 * max(center, 1 - center) / (2 * halfWidth)
            return min(60_000, max(10_000, Int(ceil(seconds * 1000))))
        }
    }
    private(set) var depth: Depth = .balanced
    private var lower: Double { depth.lower }
    private var upper: Double { depth.upper }

    func selectDepth(_ depth: Depth, at now: TimeInterval) {
        guard self.depth != depth else { return }
        self.depth = depth
        guard running else { return }
        guard now.isFinite, now >= started else { _ = stop(reason: "Clock changed; deeper dimming stopped."); return }
        if device.idleDimmed || (device.suppressed && target != 0) { suspend(); return }
        if device.automatic { _ = stop(reason: "macOS took control.", preserveCurrent: true); return }
        // Keep the in-flight light level; changing depth must not restart from Off.
        guard initialized else { return }
        let current = ramp?.value(at: now) ?? 0
        issueRamp(up: current < depth.center, at: now, transitioning: true)
    }

    init(device: KeyboardDevice) { self.device = device }

    @discardableResult func start(at now: TimeInterval) -> Bool {
        guard !running, snapshot == nil, now.isFinite, device.supportsFades,
              (!device.suppressed || device.brightness == 0), !device.idleDimmed, device.brightness.isFinite,
              (0...1).contains(device.brightness) else {
            message = "Deeper dimming unavailable while the keyboard is idle or unsupported."; return false
        }
        let saved = BrightnessController.Snapshot(keyboardID: device.id, brightness: device.brightness, automatic: device.automatic)
        guard saveRecovery?(saved) ?? true else { message = "Could not save settings. No changes made."; return false }
        snapshot = saved
        guard !device.automatic || device.setAutomatic(false) else { _ = stop(); return false }
        isPaused = false
        running = true; started = now; initialized = false; rising = true; ramp = nil
        nextStatusCheck = now + 0.5
        // Establish Off with a smooth ramp before entering the nominal subminimum envelope.
        guard command(0, duration: 600, at: now, next: 0.7) else { return false }
        message = "Your deeper level is active. Idle and sleep pause it automatically."
        return true
    }

    /// The host uses monotonic uptime. Never catch up by sending a burst of stale commands.
    func tick(at now: TimeInterval) {
        guard running else { return }
        guard now.isFinite, now >= started else { _ = stop(reason: "Clock changed; deeper dimming stopped."); return }
        if now >= nextStatusCheck { nextStatusCheck = now + 0.5 }
        if device.idleDimmed || (device.suppressed && target != 0) {
            suspend(); return
        }
        if device.automatic { _ = stop(reason: "macOS automatic brightness took control.", preserveCurrent: true); return }
        if awaitingReadback && now >= verifyAt {
            let actual = device.brightness
            guard actual.isFinite, (0...1).contains(actual), abs(actual - target) <= 0.00001 else {
                _ = stop(reason: "Fade target was not confirmed; deeper dimming stopped."); return
            }
            awaitingReadback = false
        }
        if !awaitingReadback {
            let actual = device.brightness
            if actual.isFinite && (0...1).contains(actual) && abs(actual - target) > 0.00001 {
                _ = stop(reason: "macOS changed brightness; deeper dimming stopped.", preserveCurrent: true); return
            }
        }
        guard now >= nextCommand else { return }
        let lateness = now - nextCommand
        if lateness > 0.05 {
            if let ramp = ramp {
                let value = ramp.value(at: now)
                let excess = rising ? max(0, value - upper) : max(0, lower - value)
                // Long fades can tolerate scheduling pauses if nominal drift remains
                // bounded. Stop rather than correcting a large excursion or a stale tick.
                let allowed = max(depth.halfWidth, depth.center * 0.04)
                if excess > allowed || lateness > 1.5 { _ = stop(reason: "Timing drift exceeded the limit; deeper dimming stopped."); return }
            } else { _ = stop(reason: "Timing slipped; deeper dimming stopped."); return }
        }
        if !initialized {
            initialized = true
            ramp = FadeRamp(value: 0, target: 0, started: now, duration: 0)
            issueRamp(up: true, at: now, transitioning: true)
        } else {
            issueRamp(up: !rising, at: now)
        }
    }

    /// Nominal ramp state, not a measurement of emitted light.
    func modeledFraction(at now: TimeInterval) -> Double? { ramp?.value(at: now) }

    private func issueRamp(up: Bool, at now: TimeInterval, transitioning: Bool = false) {
        let current = ramp?.value(at: now) ?? 0
        let endpoint: Double = up ? 1 : 0
        let boundary = up ? upper : lower
        let milliseconds = transitioning ? Self.transitionMilliseconds : depth.rampMilliseconds
        let seconds = Double(milliseconds) / 1000
        // Compensate for elapsed scheduling time instead of assuming that the last
        // correction landed exactly at the nominal lower/upper bound.
        let interval = seconds * abs(boundary - current) / max(0.000001, abs(endpoint - current))
        let next = max(0.1, interval) // Leave time for command readback before retargeting.
        guard command(up ? Self.floorRequest : 0, duration: milliseconds, at: now, next: next) else { return }
        rising = up
        ramp = FadeRamp(value: current, target: endpoint, started: now, duration: seconds)
    }

    private func command(_ value: Float, duration: Int, at now: TimeInterval, next interval: TimeInterval) -> Bool {
        guard device.setFade(value, milliseconds: duration) else { _ = stop(reason: "macOS rejected the fade."); return false }
        target = value; nextCommand = now + interval; verifyAt = now + 0.08; awaitingReadback = true
        return true
    }

    /// Pause ownership without restoring the sensor or saving idle-zero as a baseline.
    func suspend() {
        guard snapshot != nil else { return }
        running = false; isPaused = true; awaitingReadback = false
        device.releaseControl()
        message = "Paused while idle. Your level is remembered."
    }

    func adopt(_ saved: BrightnessController.Snapshot) -> Bool {
        guard snapshot == nil, saved.keyboardID == device.id, saved.brightness.isFinite,
              (0...1).contains(saved.brightness), saved.idleDimmingSuspended == nil else { return false }
        snapshot = saved; isPaused = true; return true
    }

    @discardableResult func resume(at now: TimeInterval, allowAutomaticDisable: Bool = false) -> Bool {
        guard isPaused, let saved = snapshot, saved.keyboardID == device.id, now.isFinite,
              !device.idleDimmed, !device.suppressed || device.brightness == 0 else { return false }
        guard !device.automatic || (allowAutomaticDisable && device.setAutomatic(false)) else { return false }
        let actual = device.brightness
        guard actual.isFinite, (0...1).contains(actual) else { return false }
        running = true; isPaused = false; started = now; nextStatusCheck = now + 0.5
        initialized = false; rising = true; awaitingReadback = false; ramp = nil
        if actual == 0 {
            initialized = true; ramp = FadeRamp(value: 0, target: 0, started: now, duration: 0)
            issueRamp(up: true, at: now, transitioning: true)
        } else if !command(0, duration: 600, at: now, next: 0.7) { return false }
        message = "Your remembered deeper level is active."; return running
    }

    @discardableResult func stop(reason: String = "Deeper dimming stopped.", preserveCurrent: Bool = false) -> Bool {
        running = false; isPaused = false; awaitingReadback = false
        guard let saved = snapshot else { return true }
        if !preserveCurrent && (device.idleDimmed || (device.suppressed && target != 0)) {
            suspend(); if !device.automatic { _ = device.setAutomatic(saved.automatic) }; device.releaseControl(); return false
        }
        // Zero duration cancels the in-flight ramp before releasing our connection.
        let restored = preserveCurrent || device.setFade(saved.brightness, milliseconds: 0) || device.setBrightness(saved.brightness)
        let actual = device.brightness
        let confirmed = preserveCurrent || (actual.isFinite && abs(actual - saved.brightness) <= max(0.00001, saved.brightness * 0.02))
        let sensor = device.automatic || device.setAutomatic(saved.automatic)
        device.releaseControl()
        restorationAwaitingConfirmation = restored && !confirmed && sensor
        guard restored && confirmed && sensor && (saveRecovery?(nil) ?? true) else {
            message = reason + " Saved settings still need recovery."; return false
        }
        snapshot = nil; message = reason + " Settings returned to macOS."; return true
    }
}

/// A monotonic linear-ramp estimate used to account for timer delivery jitter.
struct FadeRamp {
    let value: Double
    let target: Double
    let started: TimeInterval
    let duration: TimeInterval
    func value(at now: TimeInterval) -> Double {
        guard duration > 0 else { return target }
        let progress = max(0, min(1, (now - started) / duration))
        return value + (target - value) * progress
    }
}
