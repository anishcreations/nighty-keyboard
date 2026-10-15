import Foundation

protocol KeyboardDevice: AnyObject {
    var id: UInt64 { get }
    var brightness: Float { get }
    var automatic: Bool { get }
    var suppressed: Bool { get }
    var idleDimmed: Bool { get }
    var idleDimmingSuspended: Bool? { get }
    func setIdleDimmingSuspended(_ suspended: Bool) -> Bool
    func restoreBrightness(_ value: Float) -> Bool
    func setBrightness(_ value: Float) -> Bool
    func setAutomatic(_ enabled: Bool) -> Bool
    func releaseControl()
    var supportsFades: Bool { get }
    func setFade(_ value: Float, milliseconds: Int) -> Bool
}

extension KeyboardDevice {
    func releaseControl() {}
    func restoreBrightness(_ value: Float) -> Bool { setBrightness(value) }
    var supportsFades: Bool { false }
    func setFade(_ value: Float, milliseconds: Int) -> Bool { false }
    var idleDimmingSuspended: Bool? { nil }
    func setIdleDimmingSuspended(_ suspended: Bool) -> Bool { false }
}

struct BrightnessScale {
    // Logical requests, not measured PWM duty or perceived light output.
    // The eight night levels approach the direct interface's nonzero floor.
    static let levels: [Float] = [0, 0.0001, 0.0002, 0.0004, 0.0008, 0.0015, 0.003, 0.005, 0.01]
        + (1...16).map { Float($0) / 16 }
    static let nightRange = 1...8
    static func clampedIndex(_ index: Int) -> Int { max(0, min(levels.count - 1, index)) }
    static func nearest(_ brightness: Float) -> Int {
        guard brightness.isFinite else { return 0 }
        return levels.indices.min { abs(levels[$0] - brightness) < abs(levels[$1] - brightness) } ?? 0
    }
    static func title(_ index: Int) -> String {
        let index = clampedIndex(index)
        if index == 0 { return "Off" }
        if nightRange.contains(index) { return "Night \(index)" }
        return percent(index)
    }
    static func percent(_ index: Int) -> String {
        return percentage(of: levels[clampedIndex(index)])
    }
    static func percentage(of brightness: Float) -> String {
        let value = brightness * 100
        if value == 0 { return "0%" }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "%"
    }
}

/// All methods are called on the main thread. Writes happen only in response to
/// user actions or wake. Observation never corrects drift or wakes an idle keyboard.
final class BrightnessController {
    enum State: Equatable { case unavailable, ready, controlling, sleeping, paused, failed }
    struct Snapshot: Codable {
        let keyboardID: UInt64
        let brightness: Float
        let automatic: Bool
        // Optional compatibility field for older recovery records.
        let idleDimmingSuspended: Bool?
        init(keyboardID: UInt64, brightness: Float, automatic: Bool, idleDimmingSuspended: Bool? = nil) {
            self.keyboardID = keyboardID; self.brightness = brightness; self.automatic = automatic
            self.idleDimmingSuspended = idleDimmingSuspended
        }
    }
    private(set) var state: State = .unavailable
    private(set) var observedBrightness: Float = 0
    private(set) var selectedIndex = 0
    private(set) var verificationPending = false
    private(set) var recoveryStaged = false
    private(set) var restorationPending = false
    private(set) var message = "Looking for a backlit keyboard…"
    private(set) var snapshot: Snapshot?
    var onChange: (() -> Void)?
    // Saving a recovery record before any write allows restoration after a crash.
    var saveRecovery: ((Snapshot?) -> Bool)?
    private var device: KeyboardDevice?
    private var resumeAfterSleep = false
    private var pendingIndex: Int?

    var isControlling: Bool { state == .controlling }
    var canAdjust: Bool { device != nil && state != .sleeping && state != .failed && !(device?.idleDimmed ?? false) && (!(device?.suppressed ?? false) || device?.brightness == 0) }
    var canRestore: Bool { snapshot != nil && state != .sleeping && !restorationPending }

    func attach(_ device: KeyboardDevice?, reason: String = "No backlit keyboard found. Connect or open your MacBook, then retry.") {
        // Never discard a snapshot during a reconnection attempt.
        guard snapshot == nil else { return }
        self.device = device
        guard let device = device, device.brightness.isFinite, device.brightness >= 0, device.brightness <= 1 else {
            self.device = nil; state = .unavailable; message = reason; notify(); return
        }
        observedBrightness = device.brightness
        selectedIndex = BrightnessScale.nearest(observedBrightness)
        state = .ready; message = "Ready. Choose a comfortable level."; notify()
    }

    func select(_ index: Int) {
        guard let device = device, state != .sleeping else { return }
        if index == 0 && device.brightness == 0 && device.idleDimmed {
            selectedIndex = 0; observedBrightness = 0; verificationPending = false
            state = .controlling; message = "Keyboard light off."; notify(); return
        }
        guard !device.idleDimmed && (!device.suppressed || device.brightness == 0) else {
            message = "macOS has the keyboard off. Wake it to adjust your level."; notify(); return
        }
        let index = BrightnessScale.clampedIndex(index)
        if state == .controlling && selectedIndex == index { return }
        if snapshot == nil {
            let current = device.brightness
            guard current.isFinite && current >= 0 && current <= 1 else {
                fail("Could not read keyboard brightness. Try reconnecting."); return
            }
            snapshot = Snapshot(keyboardID: device.id, brightness: current, automatic: device.automatic)
            guard saveRecovery?(snapshot) ?? true else {
                self.snapshot = nil; fail("Could not save recovery settings. No keyboard changes were made."); return
            }
        }
        guard !device.automatic || device.setAutomatic(false) else {
            rollback("Could not disable automatic brightness."); return
        }
        // A single direct command per selection. No dim/off pulse loop.
        let applied = index == 0 && device.supportsFades
            ? device.setFade(0, milliseconds: 0)
            : device.setBrightness(BrightnessScale.levels[index])
        guard applied else {
            rollback("The keyboard rejected this brightness level."); return
        }
        selectedIndex = index
        state = .controlling
        verificationPending = true
        message = "Checking the keyboard response…"
        notify()
    }

    func refresh() {
        if state == .controlling { observe(); return }
        if state == .ready || state == .paused, let device = device {
            let actual = device.brightness
            if actual.isFinite && (0...1).contains(actual) { observedBrightness = actual; selectedIndex = BrightnessScale.nearest(actual) }
            message = device.idleDimmed || device.suppressed
                ? "macOS has the keyboard off. Wake it to adjust your level."
                : "Ready. Choose a comfortable level."
        }
        notify()
    }

    func verifySelection() {
        guard state == .controlling && verificationPending, let device = device else { return }
        if device.idleDimmed || device.suppressed {
            verificationPending = false; message = statusMessage(device); notify(); return
        }
        verificationPending = false
        let actual = device.brightness, target = BrightnessScale.levels[selectedIndex]
        if actual.isFinite && (0...1).contains(actual) { observedBrightness = actual }
        guard actual.isFinite && (0...1).contains(actual) else {
            if let snapshot = snapshot, !device.automatic { _ = device.setAutomatic(snapshot.automatic) }
            device.releaseControl()
            fail("Keyboard connection lost. Previous settings are saved for recovery."); return
        }
        if actual.isFinite && actual >= 0 && actual <= 1
            && abs(actual - target) <= max(0.00001, target * 0.02) {
            message = statusMessage(device); notify(); return
        }
        // Acknowledged-but-ignored requests must not be presented as successful.
        // Preserve the current macOS level; only return our sensor preference.
        let sensorOK = snapshot.map { device.automatic || device.setAutomatic($0.automatic) } ?? true
        device.releaseControl()
        if sensorOK && (saveRecovery?(nil) ?? true) {
            snapshot = nil; state = .paused
            if actual.isFinite && (0...1).contains(actual) { observedBrightness = actual; selectedIndex = BrightnessScale.nearest(actual) }
            message = "That level could not be confirmed. macOS has control."
        } else {
            state = .failed; message = "Control returned to macOS; previous settings still need recovery."
        }
        notify()
    }

    func observe() {
        guard state == .controlling, let device = device else { return }
        if verificationPending { verifySelection(); if state != .controlling { return } }
        if device.suppressed || device.idleDimmed {
            message = statusMessage(device); notify(); return
        }
        let actual = device.brightness
        guard actual.isFinite && actual >= 0 && actual <= 1 else {
            fail("Keyboard connection lost. Retry restoring your settings."); return
        }
        let target = BrightnessScale.levels[selectedIndex]
        // Account for float representation, without swallowing low-level changes.
        if device.automatic || abs(actual - target) > max(0.00001, target * 0.02) {
            // Hand back control rather than fighting Control Center or brightness keys.
            // Preserve the user's newer brightness while restoring the sensor preference.
            guard let snapshot = snapshot, (device.automatic || device.setAutomatic(snapshot.automatic)) else {
                device.releaseControl()
                fail("Could not return automatic brightness to macOS. Try Restore."); return
            }
            guard saveRecovery?(nil) ?? true else {
                device.releaseControl()
                fail("macOS has control. Could not clear the recovery record; try Restore."); return
            }
            device.releaseControl()
            self.snapshot = nil
            observedBrightness = actual; selectedIndex = BrightnessScale.nearest(actual)
            state = .paused; message = "macOS changed the level. Nighty Keyboard is paused."; notify()
            return
        }
        message = statusMessage(device); notify()
    }

    @discardableResult func restore() -> Bool {
        guard !restorationPending else { return false }
        recoveryStaged = false
        if state == .controlling { observe() }
        guard let snapshot = snapshot else { return true }
        guard let device = device else { return false }
        if state == .sleeping {
            _ = device.setAutomatic(snapshot.automatic)
            device.releaseControl(); verificationPending = false
            message = "macOS has control. Saved brightness can be restored after waking."
            return false
        }
        // Attempt both operations even if one fails. Keep the record until both succeed.
        let levelRestored = device.restoreBrightness(snapshot.brightness)
        let actual = device.brightness
        let levelConfirmed = actual.isFinite && abs(actual - snapshot.brightness) <= max(0.00001, snapshot.brightness * 0.02)
        let autoRestored = device.setAutomatic(snapshot.automatic)
        let idleRestored = snapshot.idleDimmingSuspended.map { device.setIdleDimmingSuspended($0) } ?? true
        device.releaseControl()
        verificationPending = false
        if levelRestored && autoRestored && idleRestored && (!levelConfirmed || device.automatic != snapshot.automatic) {
            waitForRestoration(); return false
        }
        guard levelRestored && levelConfirmed && autoRestored && device.automatic == snapshot.automatic && idleRestored else {
            fail("Restoration was incomplete. Retry Restore before quitting."); return false
        }
        guard saveRecovery?(nil) ?? true else {
            fail("Settings restored, but the recovery record could not be cleared. Retry Restore."); return false
        }
        self.snapshot = nil
        let current = device.brightness
        observedBrightness = current.isFinite && (0...1).contains(current) ? current : snapshot.brightness
        selectedIndex = BrightnessScale.nearest(observedBrightness)
        state = .paused; message = "Your previous keyboard settings are restored."; notify()
        return true
    }

    func waitForRestoration() {
        guard snapshot != nil else { return }
        restorationPending = true; state = .failed
        message = "Waiting for macOS to finish restoring your settings…"; notify()
    }

    func verifyRestoration() {
        guard restorationPending, let saved = snapshot, let device = device else { return }
        restorationPending = false
        let actual = device.brightness
        guard actual.isFinite, abs(actual - saved.brightness) <= max(0.00001, saved.brightness * 0.02),
              device.automatic == saved.automatic else {
            fail("macOS did not confirm restoration. Saved settings are retained."); return
        }
        guard saveRecovery?(nil) ?? true else { fail("Settings restored; recovery file could not be cleared."); return }
        snapshot = nil; recoveryStaged = false; state = .paused
        observedBrightness = actual; selectedIndex = BrightnessScale.nearest(actual)
        message = "Your previous keyboard settings are restored."; notify()
    }

    /// Explicitly choose current macOS settings instead of restoring the saved level.
    /// No hardware writes; do not use this to hide a failed restore automatically.
    @discardableResult func keepCurrentSettings() -> Bool {
        guard let device = device, let saved = snapshot, !restorationPending,
              saved.idleDimmingSuspended == nil, device.automatic == saved.automatic,
              device.brightness.isFinite, (0...1).contains(device.brightness) else { return false }
        guard saveRecovery?(nil) ?? true else { fail("Could not clear the recovery file."); return false }
        device.releaseControl(); snapshot = nil; recoveryStaged = false; state = .paused
        observedBrightness = device.brightness; selectedIndex = BrightnessScale.nearest(observedBrightness)
        message = "Current macOS settings kept. You can choose a level."; notify(); return true
    }

    @discardableResult func adoptForResume(_ saved: Snapshot, device: KeyboardDevice) -> Bool {
        guard snapshot == nil, saved.keyboardID == device.id, saved.brightness.isFinite,
              (0...1).contains(saved.brightness), saved.idleDimmingSuspended == nil else { return false }
        self.device = device; snapshot = saved; state = .paused; recoveryStaged = false
        return true
    }
    /// Move ownership to the fade session without restoring and rewriting hardware.
    /// The existing recovery record remains on disk throughout the transfer.
    func takeSnapshotForDeeperMode() -> Snapshot? {
        guard state != .failed, !restorationPending, !recoveryStaged,
              let saved = snapshot, saved.idleDimmingSuspended == nil else { return nil }
        snapshot = nil; verificationPending = false; pendingIndex = nil
        device?.releaseControl(); state = .paused
        return saved
    }
    func requireRecovery(_ reason: String) { fail(reason) }
    func pauseRememberedLevel() {
        verificationPending = false; restorationPending = false
        device?.releaseControl(); state = .paused
        message = "Paused while idle. Your level is remembered."; notify()
    }
    func resumeRememberedLevel(_ index: Int) { state = .paused; select(index) }
    @discardableResult func yieldToMacOS() -> Bool {
        guard let device = device else { return false }
        let sensorOK = snapshot.map { device.automatic || device.setAutomatic($0.automatic) } ?? true
        device.releaseControl()
        guard sensorOK && (saveRecovery?(nil) ?? true) else { fail("Could not release saved settings. Try Restore."); return false }
        snapshot = nil; verificationPending = false; recoveryStaged = false; state = .paused
        observedBrightness = device.brightness; selectedIndex = BrightnessScale.nearest(observedBrightness)
        message = "macOS has control."; notify(); return true
    }

    func stageRecovery(_ snapshot: Snapshot, device: KeyboardDevice) -> Bool {
        guard self.snapshot == nil, snapshot.keyboardID == device.id, snapshot.brightness.isFinite, (0...1).contains(snapshot.brightness) else { return false }
        self.device = device; self.snapshot = snapshot; state = .failed; recoveryStaged = true
        selectedIndex = BrightnessScale.nearest(device.brightness)
        message = "Previous settings are saved. Restore them when you are ready."; notify(); return true
    }

    func recover(_ snapshot: Snapshot, device: KeyboardDevice) -> Bool {
        guard self.snapshot == nil, snapshot.keyboardID == device.id,
              snapshot.brightness.isFinite, (0...1).contains(snapshot.brightness) else { return false }
        self.device = device; self.snapshot = snapshot; state = .failed
        return restore()
    }

    func sleep() {
        guard state != .sleeping else { return }
        resumeAfterSleep = state == .controlling
        pendingIndex = resumeAfterSleep ? selectedIndex : nil
        // macOS owns sleep, lid, and idle dimming. Do not write Off or change its flags.
        verificationPending = false; restorationPending = false
        state = .sleeping; message = "Keyboard resting."; notify()
    }

    func wake() {
        guard state == .sleeping else { return }
        state = .paused
        if resumeAfterSleep, let index = pendingIndex, let device = device {
            if device.suppressed || device.idleDimmed {
                // The host retries this only when normal activity resumes.
                state = .sleeping; message = "Waiting for your keyboard to wake."; notify(); return
            }
            let actual = device.brightness
            let target = BrightnessScale.levels[index]
            if !actual.isFinite || actual < 0 || actual > 1 {
                fail("Keyboard did not reconnect. Try Restore."); return
            }
            if device.automatic || (abs(actual - target) > max(0.00001, target * 0.02)) {
                // Someone changed the level while we were asleep. Do not overwrite it.
                resumeAfterSleep = false; state = .controlling; observe(); return
            }
            resumeAfterSleep = false
            state = .controlling; selectedIndex = index
            message = statusMessage(device); notify()
        } else {
            resumeAfterSleep = false
            message = "Ready. Choose a comfortable level."; notify()
        }
        pendingIndex = nil
    }

    func wakeTimedOut() {
        guard state == .sleeping else { return }
        resumeAfterSleep = false; pendingIndex = nil
        fail("Keyboard is still unavailable. Try Restore after waking it.")
    }

    private func statusMessage(_ device: KeyboardDevice) -> String {
        if device.suppressed { return "macOS is keeping the keyboard off right now." }
        if device.idleDimmed { return "Dimmed by macOS while idle. Your level is remembered." }
        return selectedIndex == 0 ? "Backlight off. No background brightness writes." : "Your chosen level is active. macOS still handles idle dimming."
    }
    private func rollback(_ reason: String) {
        _ = restore()
        fail(snapshot == nil ? reason + " Previous settings restored." : reason + " Try Restore.")
    }
    private func fail(_ reason: String) {
        device?.releaseControl()
        state = .failed; message = reason; notify()
    }
    private func notify() { onChange?() }
}
