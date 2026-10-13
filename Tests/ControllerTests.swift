import Foundation

final class FakeKeyboard: KeyboardDevice {
    let id: UInt64 = 42
    var brightness: Float = 0.4
    var automatic = true
    var suppressed = false
    var idleDimmed = false
    var idleDimmingSuspended: Bool? = false
    var idleWrites: [Bool] = []
    func setIdleDimmingSuspended(_ suspended: Bool) -> Bool { idleWrites.append(suspended); idleDimmingSuspended = suspended; return true }
    var brightnessWrites: [Float] = []
    var automaticWrites: [Bool] = []
    var releaseCount = 0
    var ignoreLevelWrites = false
    func releaseControl() { releaseCount += 1 }
    var supportsFades = true
    var fades: [(Float, Int)] = []
    var suppressionFollowsOff = false
    var ignoreFades = false
    var rejectFades = false
    func setFade(_ value: Float, milliseconds: Int) -> Bool {
        fades.append((value, milliseconds))
        if rejectFades { return false }
        if !ignoreFades { brightness = value; if suppressionFollowsOff { suppressed = value == 0 } }; return true
    }
    var rejectLevel = false
    var rejectAutomatic = false
    func setBrightness(_ value: Float) -> Bool {
        brightnessWrites.append(value)
        if rejectLevel { return false }
        if !ignoreLevelWrites { brightness = value }; return true
    }
    func setAutomatic(_ enabled: Bool) -> Bool {
        automaticWrites.append(enabled)
        if rejectAutomatic { return false }
        automatic = enabled; return true
    }
}

final class FakePWM: PWMDriver {
    var canAttemptControl = true
    var registryID: UInt64 = 1234
    var minimumCount: UInt32 = 100
    var maximumCount: UInt32 = 1000
    var count: Int64 = 120
    var writes: [UInt32] = []
    var ignoreWrites = false
    var loseReadbackOnWrite = false
    func readCount() -> Int64 { count }
    func setCount(_ value: UInt32) -> Bool {
        writes.append(value)
        if loseReadbackOnWrite { canAttemptControl = false; count = -1; return true }
        if !ignoreWrites { count = Int64(value) }
        return true
    }
}

@main struct ControllerTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String, line: Int = #line) {
        assertions += 1
        if !condition() { fputs("FAIL line \(line): \(name)\n", stderr); exit(1) }
    }
    static func pair() -> (BrightnessController, FakeKeyboard) {
        let device = FakeKeyboard(); let controller = BrightnessController(); controller.attach(device)
        return (controller, device)
    }
    static func main() {
        expect(BrightnessScale.levels.count == 25, "25 positions")
        expect(zip(BrightnessScale.levels, BrightnessScale.levels.dropFirst()).allSatisfy { $0 < $1 }, "Strictly increasing requests")
        expect(BrightnessScale.levels.last == 1, "Full brightness endpoint")
        expect(BrightnessScale.nearest(.nan) == 0, "Invalid scale input")
        expect(BrightnessScale.clampedIndex(-100) == 0 && BrightnessScale.clampedIndex(100) == 24, "Clamp scale indices")
        do {
            let (c, d) = pair(); expect(d.brightnessWrites.isEmpty && d.automaticWrites.isEmpty, "Launch only reads")
            var saved: BrightnessController.Snapshot?
            c.saveRecovery = { saved = $0; return true }
            c.select(3)
            expect(c.isControlling && !d.automatic, "Explicit action takes control")
            expect(saved?.brightness == 0.4 && saved?.automatic == true, "Save original state")
            c.select(6); c.select(6)
            expect(d.brightnessWrites.count == 2, "Duplicate selections don't write")
            for _ in 0..<100 { c.observe() }
            expect(d.brightnessWrites.count == 2, "Observation never pulses hardware")
            expect(c.restore(), "Restore succeeds")
            expect(d.brightness == 0.4 && d.automatic, "Restore original after many levels")
            expect(saved == nil && c.snapshot == nil, "Clear recovery only after restoration")
        }
        do {
            let (c, d) = pair(); c.saveRecovery = { _ in false }; c.select(2)
            expect(d.brightnessWrites.isEmpty && d.automaticWrites.isEmpty, "No writes if durable snapshot fails")
            expect(c.state == .failed && c.snapshot == nil, "Save failure is visible")
        }
        do {
            let (c, d) = pair(); c.select(1); d.brightness = 0.8
            let count = d.brightnessWrites.count; c.observe()
            expect(c.state == .paused && c.snapshot == nil && d.automatic, "Yield on external brightness change")
            expect(d.brightness == 0.8 && d.brightnessWrites.count == count, "Never overwrite external brightness")
        }
        do {
            let (c, d) = pair(); c.select(1); d.automatic = true; c.observe()
            expect(c.state == .paused && d.automatic, "Yield when auto brightness is reenabled")
        }
        do {
            let (c, d) = pair(); c.select(1); d.idleDimmed = true; d.brightness = 0
            let count = d.brightnessWrites.count; c.observe()
            expect(c.isControlling && d.brightnessWrites.count == count, "Respect idle dimming")
        }
        do {
            let (c, d) = pair(); c.select(4); c.sleep(); c.sleep()
            expect(d.brightness == BrightnessScale.levels[4] && d.brightnessWrites.count == 1, "Sleep makes no hardware writes")
            expect(c.snapshot?.brightness == 0.4, "Sleeping zero never replaces original")
            c.select(8); expect(d.brightnessWrites.count == 1, "No selection while asleep")
            d.suppressed = true; c.wake()
            expect(c.state == .sleeping && d.brightnessWrites.count == 1, "No wake writes while suppressed")
            d.suppressed = false; c.wake()
            expect(c.isControlling && d.brightness == BrightnessScale.levels[4] && d.brightnessWrites.count == 1, "Wake observes the chosen level without reassertion")
            expect(c.restore() && d.brightness == 0.4 && d.automatic, "Restore original after sleep cycle")
        }
        do {
            let (c, d) = pair(); c.select(3); c.sleep(); d.brightness = 0.75; c.wake()
            expect(c.state == .paused && d.brightness == 0.75, "Yield if user changes level during sleep")
        }
        do {
            let (c, d) = pair(); c.sleep(); c.wake()
            expect(d.brightnessWrites.isEmpty && d.automaticWrites.isEmpty, "Sleep before first selection makes no writes")
        }
        do {
            let (c, d) = pair(); c.select(3); d.rejectLevel = true
            expect(!c.restore() && c.snapshot != nil && c.state == .failed, "Retain snapshot on partial restoration")
            expect(d.automatic, "Attempt sensor restore even when level restore fails")
            d.rejectLevel = false
            expect(c.restore() && c.snapshot == nil, "Retry restores after partial failure")
        }
        do {
            let (c, d) = pair(); d.rejectAutomatic = true; c.select(3)
            expect(c.state == .failed && c.snapshot != nil, "Retain snapshot when sensor writes fail")
            expect(d.brightnessWrites == [0.4], "Do not apply selected brightness when sensor control fails")
        }
        do {
            let (c, d) = pair(); d.brightness = -1; c.select(3)
            expect(c.state == .failed && d.brightnessWrites.isEmpty, "Invalid readback never becomes a snapshot")
        }
        do {
            let (c, d) = pair(); c.select(2); d.brightness = .nan; c.observe()
            expect(c.state == .failed && c.snapshot != nil, "Lost connection retains restoration state")
        }
        do {
            let (c, d) = pair()
            let record = BrightnessController.Snapshot(keyboardID: 42, brightness: 0.2, automatic: false)
            expect(c.recover(record, device: d) && d.brightness == 0.2 && !d.automatic, "Recover original state from prior process")
            let mismatch = BrightnessController.Snapshot(keyboardID: 99, brightness: 0.8, automatic: true)
            expect(!c.recover(mismatch, device: d) && d.brightness == 0.2, "Do not restore wrong keyboard")
        }
        do {
            let (c, d) = pair(); c.select(2); c.sleep(); d.suppressed = true; c.wake(); c.wakeTimedOut()
            expect(c.state == .failed && c.canRestore && c.snapshot != nil, "Bounded wake failure leaves Restore available")
        }
        do {
            let c = BrightnessController(); c.attach(nil); c.select(10)
            expect(c.state == .unavailable && !c.canAdjust, "Unsupported hardware fails safely")
        }
        do {
            let (c, d) = pair(); d.idleDimmed = true; c.select(4)
            expect(d.brightnessWrites.isEmpty && d.automaticWrites.isEmpty && c.snapshot == nil, "No writes when selecting an idle keyboard")
            expect(!c.canAdjust, "Disable adjustment while idle")
            d.idleDimmed = false; d.suppressed = true; c.select(4)
            expect(d.brightnessWrites.isEmpty && !c.canAdjust, "No writes while suppressed")
            d.suppressed = false; c.refresh()
            expect(c.canAdjust, "Enable adjustment after normal activity resumes")
        }
        do {
            let (c, d) = pair(); var allowClear = false
            c.saveRecovery = { $0 != nil || allowClear }; c.select(3)
            expect(!c.restore() && c.snapshot != nil, "Retain recovery if record deletion fails")
            expect(d.brightness == 0.4 && d.automatic, "Settings restored despite record cleanup failure")
            allowClear = true
            expect(c.restore() && c.snapshot == nil, "Retry recovery cleanup")
        }
        do {
            let c = BrightnessController(); let d = FakeKeyboard(); d.brightness = -1; c.attach(d)
            expect(!c.canAdjust && c.state == .unavailable, "Invalid attachment cannot adjust hardware")
        }
        do {
            let (c, d) = pair(); d.idleDimmingSuspended = true
            let legacy = BrightnessController.Snapshot(keyboardID: 42, brightness: 0.4, automatic: true, idleDimmingSuspended: false)
            expect(c.stageRecovery(legacy, device: d) && d.idleWrites.isEmpty, "Legacy recovery is staged without changing idle flags")
            expect(c.restore() && d.idleDimmingSuspended == false, "Explicit legacy restoration restores the recorded idle flag")
            c.select(4); c.restore()
            expect(d.idleWrites == [false], "Normal sessions never change idle suspension")
        }
        do {
            let d = FakePWM(); d.canAttemptControl = false; let c = PWMSession(driver: d)
            expect(!c.select(150) && d.writes.isEmpty && c.snapshot == nil, "Protected PWM driver receives no write")
        }
        do {
            let d = FakePWM(); let c = PWMSession(driver: d)
            expect(!c.select(99) && !c.select(1001) && d.writes.isEmpty, "Reject out-of-descriptor PWM counts")
            d.count = -1
            expect(!c.select(150) && d.writes.isEmpty, "Reject unreadable PWM baseline")
        }
        do {
            let d = FakePWM(); let c = PWMSession(driver: d); c.saveRecovery = { _ in false }
            expect(!c.select(150) && d.writes.isEmpty, "PWM snapshot must be durable before write")
        }
        do {
            let d = FakePWM(); let c = PWMSession(driver: d); var record: PWMSession.Snapshot?
            c.saveRecovery = { record = $0; if $0 != nil { expect(d.writes.isEmpty, "Snapshot precedes first PWM write") }; return true }
            expect(c.select(150) && c.select(170), "Distinct steady PWM counts can be selected")
            expect(record?.count == 120 && d.writes == [150, 170], "PWM session preserves original and never repeats writes")
            expect(c.restore() && d.count == 120 && record == nil, "Verified PWM restoration clears recovery")
        }
        do {
            let d = FakePWM(); d.ignoreWrites = true; let c = PWMSession(driver: d)
            expect(!c.select(150) && d.count == 120, "Success return alone does not confirm a PWM write")
            expect(c.snapshot == nil && d.writes == [150, 120], "Ignored write rolls back and clears restored session")
        }
        do {
            let d = FakePWM(); d.loseReadbackOnWrite = true; let c = PWMSession(driver: d)
            expect(!c.select(150) && c.snapshot?.count == 120, "Lost PWM readback retains recovery")
            expect(d.writes == [150], "Do not blindly write again after PWM readback is lost")
        }
        do {
            let d = FakePWM(); let c = PWMSession(driver: d)
            expect(!c.recover(.init(registryID: 999, count: 150)) && d.writes.isEmpty, "PWM recovery cannot target another device")
            expect(c.recover(.init(registryID: 1234, count: 125)) && d.count == 125, "Recover an interrupted PWM session")
        }
        do {
            let d = FakePWM(); let c = PWMSession(driver: d); var allowCleanup = false
            c.saveRecovery = { $0 != nil || allowCleanup }
            expect(c.select(150), "PWM selection with recovery recording")
            expect(!c.restore() && c.snapshot != nil && d.count == 120, "PWM cleanup failure retains restored record")
            allowCleanup = true; expect(c.restore() && c.snapshot == nil, "Retry PWM recovery cleanup")
        }
        do {
            let d = FakePWM(); d.minimumCount = 2000; let c = PWMSession(driver: d)
            expect(!c.select(0) && d.writes.isEmpty, "Reject invalid PWM descriptor, including off writes")
        }
        do {
            let (c, d) = pair(); d.ignoreLevelWrites = true; c.select(3)
            expect(c.verificationPending, "Accepted selection still requires response verification")
            c.verifySelection()
            expect(c.state == .paused && c.snapshot == nil && d.brightness == 0.4, "Ignored normal brightness command releases control without overwriting macOS")
            expect(d.releaseCount == 1 && d.automatic, "Failed verification closes the writer and returns sensor control")
        }
        do {
            let (c, d) = pair(); c.select(3); c.verifySelection(); c.restore()
            expect(d.releaseCount == 1, "Return to macOS releases the write connection")
        }
        do {
            let (c, d) = pair(); d.automatic = false; c.select(3); c.verifySelection(); d.automatic = true; c.observe()
            expect(d.automatic && c.state == .paused && d.releaseCount == 1, "Explicit user enabling auto brightness takes priority")
        }
        do {
            let (c, d) = pair(); let record = BrightnessController.Snapshot(keyboardID: 42, brightness: 0.2, automatic: true)
            expect(c.stageRecovery(record, device: d), "Prepare recovery without writes")
            expect(d.brightnessWrites.isEmpty && d.automaticWrites.isEmpty && c.recoveryStaged, "Opening saved recovery never silently changes brightness")
            expect(c.restore() && d.brightness == 0.2, "Explicit restore applies staged recovery")
        }
        expect(BrightnessScale.percent(10) == "12.5%", "Display precise standard-step percentages")
        do {
            let (c, d) = pair(); d.automatic = false; c.select(3)
            d.automatic = true; d.brightness = 0.8; c.verifySelection()
            expect(c.state == .paused && d.automatic && d.brightness == 0.8, "Pending verification preserves the user's newer brightness and auto setting")
            expect(d.releaseCount == 1 && d.brightnessWrites.count == 1, "Unconfirmed selection hands back control without another brightness write")
        }
        do {
            let (c, d) = pair(); c.select(3); c.verifySelection(); c.sleep()
            let writes = d.brightnessWrites.count
            expect(!c.restore() && d.brightnessWrites.count == writes, "Returning control while asleep does not write brightness")
            expect(d.automatic && d.releaseCount == 1 && c.snapshot != nil, "Sleep quit restores sensor preference, closes writer, and keeps level recovery")
        }
        do {
            let (c, d) = pair(); d.brightness = 0.75; c.refresh()
            expect(c.selectedIndex == BrightnessScale.nearest(0.75) && c.observedBrightness == 0.75 && d.brightnessWrites.isEmpty, "Idle app reflects newer macOS brightness without writing")
        }
        do {
            let (c, d) = pair(); c.select(3); c.verifySelection(); d.brightness = .nan; c.observe()
            expect(c.state == .failed && c.snapshot != nil && d.releaseCount > 0, "Connection loss after verification releases the writer and retains recovery")
        }
        do {
            let d = FakeKeyboard(); let t = DeepDimmingSession(device: d); var record: BrightnessController.Snapshot?
            t.saveRecovery = { record = $0; return true }
            expect(t.start(at: 100), "Explicit fade trial starts")
            expect(record?.brightness == 0.4 && !d.automatic, "Trial saves baseline before taking control")
            for i in 1...6000 { t.tick(at: 100 + Double(i) / 100) }
            expect(t.running && t.snapshot != nil && record != nil, "Deeper dimming stays active past sixty seconds without a time limit")
            expect(t.stop() && t.snapshot == nil && record == nil, "Explicit stop clears verified recovery")
            expect(d.brightness == 0.4 && d.automatic && d.releaseCount == 1, "Trial cancels ramp and restores original preferences")
            expect(d.fades.count > 100 && d.fades.count < 600, "Hardware ramp train, not high-frequency app-side PWM")
            expect(d.fades.dropLast().allSatisfy { $0.1 > 0 && ($0.0 == 0 || $0.0 == DeepDimmingSession.floorRequest) }, "Only low endpoints with hardware fade durations")
            expect(d.fades.last?.1 == 0 && d.idleWrites.isEmpty, "Restoration cancels ramp without modifying idle flags")
            let count = d.fades.count; t.tick(at: 200)
            expect(d.fades.count == count, "No writes after trial ends")
        }
        do {
            let d = FakeKeyboard(); let t = DeepDimmingSession(device: d); t.saveRecovery = { _ in false }
            expect(!t.start(at: 0) && d.fades.isEmpty && d.automaticWrites.isEmpty, "Undurable recovery prevents all trial writes")
        }
        do {
            let d = FakeKeyboard(); d.supportsFades = false; let t = DeepDimmingSession(device: d)
            expect(!t.start(at: 0) && d.fades.isEmpty, "Unsupported device cannot enter trial")
            d.supportsFades = true; d.idleDimmed = true
            expect(!t.start(at: 0) && d.fades.isEmpty, "Idle keyboard cannot enter trial")
        }
        do {
            let d = FakeKeyboard(); let t = DeepDimmingSession(device: d); _ = t.start(at: 0)
            t.tick(at: 0.8)
            expect(!t.running && d.fades.count == 2 && d.brightness == 0.4, "Late timer stops and restores without catching up")
        }
        do {
            let d = FakeKeyboard(); d.ignoreFades = true; let t = DeepDimmingSession(device: d); _ = t.start(at: 0)
            t.tick(at: 0.1)
            expect(!t.running && d.fades.count == 2, "Acknowledged but ignored fade stops at first readback")
        }
        do {
            let d = FakeKeyboard(); let t = DeepDimmingSession(device: d); _ = t.start(at: 0)
            d.suppressed = true; d.idleDimmed = true; t.tick(at: 0.1)
            expect(!t.running && t.snapshot != nil && d.fades.count == 1, "Suppression retains recovery with no brightness restoration write")
            expect(d.automatic && d.releaseCount == 1 && d.idleWrites.isEmpty, "Suppression restores sensor and closes connection without idle flag changes")
            d.suppressed = false; d.idleDimmed = false
            expect(t.stop() && d.brightness == 0.4, "Saved trial baseline can be restored after activity resumes")
        }
        do {
            let d = FakeKeyboard(); let t = DeepDimmingSession(device: d); _ = t.start(at: 0)
            d.automatic = true; d.brightness = 0.7; t.tick(at: 0.1)
            expect(!t.running && d.brightness == 0.7 && d.fades.count == 1, "User automatic brightness change takes priority")
        }
        do {
            let d = FakeKeyboard(); let t = DeepDimmingSession(device: d); _ = t.start(at: 0)
            d.rejectFades = true; d.rejectLevel = true
            expect(!t.stop() && t.snapshot != nil && d.releaseCount == 1, "Rejected restoration retains recovery and releases connection")
        }
        do {
            let d = FakeKeyboard(); let t = DeepDimmingSession(device: d); _ = t.start(at: 0)
            t.tick(at: 0.1); d.brightness = 0.75; t.tick(at: 0.12)
            expect(!t.running && d.brightness == 0.75 && d.fades.count == 1, "Manual macOS change interrupts verified ramp without overwrite")
        }
        do {
            let d = FakeKeyboard(); let t = DeepDimmingSession(device: d); _ = t.start(at: 0)
            d.rejectFades = true
            expect(t.stop() && d.brightnessWrites == [0.4] && t.snapshot == nil, "Normal numeric restoration is available when fade commands fail")
        }
        for depth in DeepDimmingSession.Depth.allCases {
            let d = FakeKeyboard(); let t = DeepDimmingSession(device: d)
            t.selectDepth(depth, at: 0); _ = t.start(at: 0)
            for i in 1...3000 { t.tick(at: Double(i) / 100) }
            expect(t.running && t.depth == depth, "Every depth runs continuously beyond the old limit")
            expect(t.stop() && d.brightness == 0.4 && d.automatic, "Every depth restores saved state")
        }
        do {
            let d = FakeKeyboard(); let t = DeepDimmingSession(device: d); _ = t.start(at: 0)
            t.tick(at: 0.1); t.selectDepth(.deepest, at: 0.2)
            for i in 1...2000 { t.tick(at: 0.2 + Double(i) / 100) }
            expect(t.running && t.snapshot?.brightness == 0.4, "Changing depth preserves the original baseline")
            let count = d.fades.count; t.selectDepth(.deepest, at: 20.2)
            expect(d.fades.count == count, "Repeated depth selection does not restart fades")
            expect(t.stop() && d.brightness == 0.4, "Stop after a depth change restores original settings")
        }
        do {
            let d = FakeKeyboard(); d.suppressionFollowsOff = true
            let t = DeepDimmingSession(device: d); _ = t.start(at: 0)
            for i in 1...1000 { t.tick(at: Double(i) / 100) }
            expect(t.running && t.snapshot != nil, "Expected Off suppression does not stop the fade mode")
            expect(t.stop() && d.brightness == 0.4 && !d.suppressed, "Restore can leave intentional Off suppression")
        }
        do {
            let d = FakeKeyboard(); d.brightness = 0; d.suppressed = true
            let c = BrightnessController(); c.attach(d)
            expect(c.canAdjust, "Manual Off does not lock the normal brightness controls")
            c.select(10)
            expect(d.brightness == 0.125, "A user can raise brightness from Off")
        }
        do {
            let (c, d) = pair(); c.select(3); c.verifySelection(); d.ignoreLevelWrites = true
            expect(!c.restore() && c.restorationPending, "Async restoration waits instead of failing immediately")
            d.brightness = 0.4; c.verifyRestoration()
            expect(c.snapshot == nil && !c.restorationPending && c.canAdjust, "Delayed readback unlocks restored settings")
        }
        do {
            let (c, d) = pair(); c.select(3); c.verifySelection(); d.ignoreLevelWrites = true
            _ = c.restore(); c.verifyRestoration()
            expect(c.snapshot != nil && !c.restorationPending, "Unconfirmed delayed restoration retains recovery")
        }
        do {
            let d = FakeKeyboard(); d.automatic = false; d.brightness = 0
            let c = BrightnessController(); _ = c.stageRecovery(.init(keyboardID: d.id, brightness: 0.04, automatic: false), device: d)
            var cleared = false; c.saveRecovery = { cleared = $0 == nil; return true }
            expect(c.keepCurrentSettings() && cleared && c.snapshot == nil && c.canAdjust, "Explicit keep-current action exits recovery")
            expect(d.brightnessWrites.isEmpty && d.automaticWrites.isEmpty, "Keep-current recovery choice makes no hardware writes")
        }
        print("PASS: \(assertions) assertions covering state ownership, no repeated writes, recovery, sleep, PWM readback, continuous fades, and failures.")
    }
}
