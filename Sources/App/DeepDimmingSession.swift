import Foundation

/// Continuous, user-selected hardware fades with recovery and timing checks.
/// The envelope is a model of a linear ramp; it is NOT measured optical brightness.
final class DeepDimmingSession {
    static let floorRequest: Float = 0.0001
    static let rampMilliseconds = 400
    private let device: KeyboardDevice
    private(set) var snapshot: BrightnessController.Snapshot?
    private(set) var running = false
    private(set) var restorationAwaitingConfirmation = false
    private(set) var message = ""
    var saveRecovery: ((BrightnessController.Snapshot?) -> Bool)?
    private var started: TimeInterval = 0
    private var nextCommand: TimeInterval = 0
    private var verifyAt: TimeInterval = 0
    private var awaitingReadback = false
    private var target: Float = 0
    private var rising = true
    private var initialized = false
    enum Depth: Int, CaseIterable { case deepest, balanced, gentler
        var lower: Double { [0.15, 0.25, 0.45][rawValue] }
        var upper: Double { [0.35, 0.45, 0.65][rawValue] }
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
        initialized = false; rising = true
        _ = command(0, duration: 600, at: now, next: 0.7)
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
        running = true; started = now; initialized = false; rising = true
        // Establish Off with a smooth ramp before entering the nominal subminimum envelope.
        guard command(0, duration: 600, at: now, next: 0.7) else { return false }
        message = "Deeper dimming active until stopped. Physical light output is unverified."
        return true
    }

    /// The host uses monotonic uptime. Never catch up by sending a burst of stale commands.
    func tick(at now: TimeInterval) {
        guard running else { return }
        guard now.isFinite, now >= started else { _ = stop(reason: "Clock changed; deeper dimming stopped."); return }
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
        if now - nextCommand > 0.05 { _ = stop(reason: "Timing slipped; deeper dimming stopped."); return }
        let seconds = Double(Self.rampMilliseconds) / 1000
        if !initialized {
            initialized = true; rising = true
            _ = command(Self.floorRequest, duration: Self.rampMilliseconds, at: now, next: seconds * upper)
        } else if rising {
            rising = false
            _ = command(0, duration: Self.rampMilliseconds, at: now, next: seconds * (1 - lower / upper))
        } else {
            rising = true
            _ = command(Self.floorRequest, duration: Self.rampMilliseconds, at: now, next: seconds * (upper - lower) / (1 - lower))
        }
    }

    private func command(_ value: Float, duration: Int, at now: TimeInterval, next interval: TimeInterval) -> Bool {
        guard device.setFade(value, milliseconds: duration) else { _ = stop(reason: "macOS rejected the fade."); return false }
        target = value; nextCommand = now + interval; verifyAt = now + 0.08; awaitingReadback = true
        return true
    }

    /// Sleep/lock does not write brightness or modify macOS idle flags. Keep recovery for later.
    func suspend() {
        guard snapshot != nil else { return }
        running = false; awaitingReadback = false
        if let saved = snapshot, !device.automatic { _ = device.setAutomatic(saved.automatic) }
        device.releaseControl()
        message = "Deeper dimming stopped for sleep or idle. Saved brightness needs restoration after waking."
    }

    @discardableResult func stop(reason: String = "Deeper dimming stopped.", preserveCurrent: Bool = false) -> Bool {
        running = false; awaitingReadback = false
        guard let saved = snapshot else { return true }
        if device.idleDimmed || (device.suppressed && target != 0) { suspend(); return false }
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
