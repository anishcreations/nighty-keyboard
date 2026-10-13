import Foundation

final class NativePWMDriver: PWMDriver {
    let bridge: BLPWMBridge
    init(bridge: BLPWMBridge) { self.bridge = bridge }
    var canAttemptControl: Bool { bridge.canAttemptControl }
    var registryID: UInt64 { bridge.registryID }
    var minimumCount: UInt32 { bridge.minimumCount }
    var maximumCount: UInt32 { bridge.maximumCount }
    func readCount() -> Int64 { bridge.readCount() }
    func setCount(_ count: UInt32) -> Bool { bridge.setCount(count) }
}

final class PWMRecoveryStore {
    let url: URL
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = root.appendingPathComponent("Nighty Keyboard/pwm-session.json")
    }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    func load() -> PWMSession.Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PWMSession.Snapshot.self, from: data)
    }
    func save(_ record: PWMSession.Snapshot?) -> Bool {
        do {
            if let record = record {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(record).write(to: url, options: .atomic)
            } else if exists { try FileManager.default.removeItem(at: url) }
            return true
        } catch { return false }
    }
}

func pwmDiagnostic() -> [String: Any] {
    let bridge = BLPWMBridge()
    return ["descriptorAvailable": bridge.descriptorAvailable, "firmwareReadbackAvailable": bridge.canAttemptControl,
            "minimumCount": bridge.minimumCount, "maximumCount": bridge.maximumCount,
            "reason": bridge.reason, "frequencyControlExposed": false,
            "strategy": "one zero-fade hardware report, verified firmware readback; no software PWM loop"]
}
