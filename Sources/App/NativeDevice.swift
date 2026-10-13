import Foundation

final class NativeKeyboard: KeyboardDevice {
    let id: UInt64
    private let bridge: BLKeyboardBridge
    init(id: UInt64, bridge: BLKeyboardBridge) { self.id = id; self.bridge = bridge }
    var brightness: Float { bridge.brightness(id) }
    var automatic: Bool { bridge.automaticBrightness(id) }
    var suppressed: Bool { bridge.isSuppressed(id) }
    var idleDimmed: Bool { bridge.isIdleDimmed(id) }
    var idleDimmingSuspended: Bool? { bridge.supportsIdleSuspension() ? bridge.idleDimmingSuspended(id) : nil }
    func setIdleDimmingSuspended(_ suspended: Bool) -> Bool { bridge.setIdleDimmingSuspended(suspended, keyboard: id) }
    func restoreBrightness(_ value: Float) -> Bool { bridge.restoreBrightness(value, keyboard: id) }
    func setBrightness(_ value: Float) -> Bool { bridge.setBrightness(value, keyboard: id) }
    func setAutomatic(_ enabled: Bool) -> Bool { bridge.setAutomaticBrightness(enabled, keyboard: id) }
    var supportsFades: Bool { bridge.available && bridge.isBuiltIn(id) }
    func setFade(_ value: Float, milliseconds: Int) -> Bool { bridge.setFade(value, milliseconds: Int32(milliseconds), keyboard: id) }
    func releaseControl() { bridge.releaseManualControl() }
}

final class PreviewKeyboard: KeyboardDevice {
    let id: UInt64 = 1
    var brightness: Float = 0.0004
    var automatic = false
    var suppressed = false
    var idleDimmed = false
    func setBrightness(_ value: Float) -> Bool { brightness = value; return true }
    func setAutomatic(_ enabled: Bool) -> Bool { automatic = enabled; return true }
    var supportsFades: Bool { true }
    func setFade(_ value: Float, milliseconds: Int) -> Bool { brightness = value; return true }
}

/// A small atomic recovery file, containing only the keyboard ID and prior settings.
final class RecoveryStore {
    let url: URL
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = root.appendingPathComponent("Nighty Keyboard/keyboard-session.json")
    }
    func load() -> BrightnessController.Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BrightnessController.Snapshot.self, from: data)
    }
    @discardableResult func save(_ snapshot: BrightnessController.Snapshot?) -> Bool {
        do {
            if let snapshot = snapshot {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch { return false }
    }
}
