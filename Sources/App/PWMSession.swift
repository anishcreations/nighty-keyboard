import Foundation

protocol PWMDriver: AnyObject {
    var canAttemptControl: Bool { get }
    var registryID: UInt64 { get }
    var minimumCount: UInt32 { get }
    var maximumCount: UInt32 { get }
    func readCount() -> Int64
    func setCount(_ count: UInt32) -> Bool
}

/// A direct hardware-report session, with no software PWM timer or fade loop.
/// Currently exposed only by the explicit CLI verification, not the main slider.
final class PWMSession {
    struct Snapshot: Codable {
        let registryID: UInt64
        let count: UInt32
    }
    private let driver: PWMDriver
    private(set) var snapshot: Snapshot?
    private(set) var message = ""
    var saveRecovery: ((Snapshot?) -> Bool)?
    init(driver: PWMDriver) { self.driver = driver }
    private func valid(_ count: UInt32) -> Bool {
        guard driver.minimumCount > 0 && driver.maximumCount > driver.minimumCount else { return false }
        return count == 0 || (driver.minimumCount...driver.maximumCount).contains(count)
    }
    @discardableResult func select(_ count: UInt32) -> Bool {
        guard valid(count) else { message = "Count is outside the hardware range. No write made."; return false }
        guard driver.canAttemptControl else { message = "Firmware readback is unavailable. No write made."; return false }
        if snapshot == nil {
            let current = driver.readCount()
            guard current >= 0 && current <= Int64(UInt32.max) && valid(UInt32(current)) else {
                message = "Cannot capture a restorable PWM state. No write made."; return false
            }
            let record = Snapshot(registryID: driver.registryID, count: UInt32(current))
            guard saveRecovery?(record) ?? true else { message = "Recovery save failed. No write made."; return false }
            snapshot = record
        }
        guard driver.setCount(count), driver.readCount() == Int64(count) else {
            let restored = restore()
            message = restored ? "PWM write was not verified; original state restored." : "PWM write was not verified. Recovery is still required."
            return false
        }
        message = "Hardware report readback confirmed. PWM frequency is managed by the keyboard."
        return true
    }
    @discardableResult func restore() -> Bool {
        guard let record = snapshot else { return true }
        guard record.registryID == driver.registryID, valid(record.count), driver.canAttemptControl,
              driver.setCount(record.count), driver.readCount() == Int64(record.count) else {
            message = "Could not verify PWM restoration. Recovery record retained."; return false
        }
        guard saveRecovery?(nil) ?? true else { message = "PWM restored, but recovery cleanup failed."; return false }
        snapshot = nil; message = "Original PWM state restored."; return true
    }
    func recover(_ record: Snapshot) -> Bool {
        guard snapshot == nil, record.registryID == driver.registryID, valid(record.count) else {
            message = "PWM recovery does not match this device. No write made."; return false
        }
        snapshot = record
        return restore()
    }
}
