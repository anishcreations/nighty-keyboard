import Foundation

struct LightingPreferences: Codable, Equatable {
    enum Mode: String, Codable { case system, steady, deep }
    var formatVersion = 1
    var mode: Mode = .system
    var steadyIndex = 10
    var depthIndex = DeepDimmingSession.Depth.balanced.rawValue
    var cleanShutdown = false
    var valid: Bool {
        formatVersion == 1 && BrightnessScale.levels.indices.contains(steadyIndex) && DeepDimmingSession.Depth(rawValue: depthIndex) != nil
    }
}

struct ActivitySnapshot {
    let age: TimeInterval?
    let timeout: TimeInterval?
    let keyboardIdle: Bool?
    var blocked = false
    enum Decision { case active, idle, unavailable, blocked }
    var decision: Decision {
        if blocked { return .blocked }
        guard let age = age, age.isFinite, age >= 0,
              let timeout = timeout, timeout.isFinite, timeout >= 0,
              let idle = keyboardIdle else { return .unavailable }
        if idle || (timeout > 0 && age >= timeout) { return .idle }
        return .active
    }
    static let preview = ActivitySnapshot(age: 0, timeout: 10, keyboardIdle: false)
}

/// Preferences are independent of the hardware recovery snapshot.
final class LightingMemory {
    enum State { case system, active, idlePaused, sleepPaused, waiting, failed }
    private(set) var preferences: LightingPreferences
    private(set) var state: State
    let previousExitWasClean: Bool
    var persist: ((LightingPreferences) -> Bool)?
    var onPersistenceFailure: (() -> Void)?
    var enabled: Bool { preferences.mode != .system }
    var paused: Bool { state == .idlePaused || state == .sleepPaused || state == .waiting }
    init(_ preferences: LightingPreferences = LightingPreferences()) {
        self.preferences = preferences.valid ? preferences : LightingPreferences()
        previousExitWasClean = self.preferences.cleanShutdown
        state = self.preferences.mode == .system ? .system : (previousExitWasClean ? .waiting : .failed)
    }
    @discardableResult func beginLaunch() -> Bool { update { $0.cleanShutdown = false } }
    @discardableResult func select(_ mode: LightingPreferences.Mode, index: Int? = nil, depth: Int? = nil) -> Bool {
        guard update({ value in
            value.mode = mode; value.cleanShutdown = false
            if let index = index { value.steadyIndex = index }
            if let depth = depth { value.depthIndex = depth }
        }) else { return false }
        state = mode == .system ? .system : .waiting; return true
    }
    @discardableResult func rememberDepth(_ depth: Int) -> Bool { update { $0.depthIndex = depth } }
    func activate() { if enabled { state = .active } }
    func pause(sleeping: Bool = false) { if enabled && state != .failed { state = sleeping ? .sleepPaused : .idlePaused } }
    func fail() { state = .failed }
    func wait() { if enabled && state != .failed { state = .waiting } }
    func shouldResume(_ activity: ActivitySnapshot) -> Bool { enabled && paused && activity.decision == .active }
    @discardableResult func markCleanExit() -> Bool {
        guard state != .failed else { return false }
        return update { $0.cleanShutdown = true }
    }
    private func update(_ change: (inout LightingPreferences) -> Void) -> Bool {
        var next = preferences; change(&next)
        guard next.valid, persist?(next) ?? true else { state = .failed; onPersistenceFailure?(); return false }
        preferences = next; return true
    }
}
