import AppKit
import IOKit

/// Aggregate HID idle age only: no event taps, key events, or input contents.
final class NativeActivity {
    private var service: io_service_t = 0
    private var powerService: io_service_t = 0
    deinit { if service != 0 { IOObjectRelease(service) }; if powerService != 0 { IOObjectRelease(powerService) } }
    func age() -> TimeInterval? {
        if service == 0 { service = IOServiceGetMatchingService(0, IOServiceMatching("IOHIDSystem")) }
        guard service != 0 else { return nil }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            IOObjectRelease(service); service = 0; return nil
        }
        if let number = value as? NSNumber { return number.doubleValue / 1_000_000_000 }
        if let data = value as? Data, data.count == 8 {
            var nanoseconds: UInt64 = 0; _ = withUnsafeMutableBytes(of: &nanoseconds) { data.copyBytes(to: $0) }
            return Double(nanoseconds) / 1_000_000_000
        }
        return nil
    }
    func snapshot(bridge: BLKeyboardBridge, keyboard: UInt64) -> ActivitySnapshot {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        if powerService == 0 { powerService = IOServiceGetMatchingService(0, IOServiceMatching("IOPMrootDomain")) }
        var lidClosed = false
        if powerService != 0, let value = IORegistryEntryCreateCFProperty(powerService, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            lidClosed = value.boolValue
        }
        return ActivitySnapshot(age: age(), timeout: bridge.idleTimeout(keyboard)?.doubleValue,
                                keyboardIdle: bridge.idleActive(keyboard)?.boolValue, blocked: locked || displayAsleep || lidClosed || session == nil)
    }
}

final class LightingPreferencesStore {
    let url: URL
    init() {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nighty Keyboard/preferences.json")
    }
    func load() -> LightingPreferences {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(LightingPreferences.self, from: data), value.valid else { return LightingPreferences() }
        return value
    }
    func save(_ value: LightingPreferences) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic); return true
        } catch { return false }
    }
}
