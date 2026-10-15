import AppKit

let arguments = CommandLine.arguments

func diagnostic() {
    let bridge = BLKeyboardBridge()
    let keyboards = bridge.keyboardIDs().map { number -> [String: Any] in
        let id = number.uint64Value
        let activity = NativeActivity().snapshot(bridge: bridge, keyboard: id)
        return ["id": id, "builtIn": bridge.isBuiltIn(id), "brightnessRequest": bridge.brightness(id),
                "backlightLevel": bridge.backlightLevel(id), "automatic": bridge.automaticBrightness(id),
                "suppressed": bridge.isSuppressed(id), "idleDimmed": bridge.isIdleDimmed(id),
                "activityAgeSeconds": activity.age.map { $0 as Any } ?? NSNull(),
                "idleTimeoutSeconds": activity.timeout.map { $0 as Any } ?? NSNull(),
                "idleActive": activity.keyboardIdle.map { $0 as Any } ?? NSNull(), "activityBlocked": activity.blocked]
    }
    let output: [String: Any] = ["app": "Nighty Keyboard", "version": "0.0.0", "interfaceAvailable": bridge.available,
                                "reason": bridge.availabilityReason, "keyboards": keyboards,
                                "strategy": "normal macOS manual-brightness command; writer connection released when returning control", "hardwarePWM": pwmDiagnostic()]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
       let string = String(data: data, encoding: .utf8) { print(string) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let controller = BrightnessController()
    let bridge = BLKeyboardBridge()
    let recovery = RecoveryStore()
    let preview: Bool
    let preferenceStore: LightingPreferencesStore
    let memory: LightingMemory
    let activitySource = NativeActivity()
    var previewActivity = ActivitySnapshot.preview
    var restReasons = Set<String>()
    var persistenceReady = false
    var resumeAllowsAutomaticDisable = false
    var cleanExitPrepared = false
    var hasConnected = false
    var cachedActivity: (TimeInterval, ActivitySnapshot)?
    var item: NSStatusItem!
    var panel: PanelController!
    let popover = NSPopover()
    var observation: Timer?
    var connectedDevice: KeyboardDevice?
    var deepSession: DeepDimmingSession?
    var selectedDepth: DeepDimmingSession.Depth = .balanced
    var fadeTimer: Timer?
    var fadeWakeCount = 0
    var fadeMaxLateness: TimeInterval = 0
    var verificationWork: DispatchWorkItem?
    var wakeTimer: Timer?
    var previewWindow: NSWindow?
    var workspaceTokens: [NSObjectProtocol] = []
    var distributedTokens: [NSObjectProtocol] = []

    init(preview: Bool, initialPreferences: LightingPreferences? = nil) {
        self.preview = preview
        let store = LightingPreferencesStore(); preferenceStore = store
        memory = LightingMemory(preview ? (initialPreferences ?? LightingPreferences()) : store.load())
        super.init()
        memory.persist = preview ? nil : { store.save($0) }
        selectedDepth = DeepDimmingSession.Depth(rawValue: memory.preferences.depthIndex) ?? .balanced
        resumeAllowsAutomaticDisable = memory.previousExitWasClean && memory.enabled
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !preview, let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        persistenceReady = memory.beginLaunch()
        NSApp.setActivationPolicy(.accessory)
        controller.saveRecovery = preview ? nil : { [weak self] snapshot in self?.recovery.save(snapshot) ?? false }
        connect()
        panel = PanelController(controller: controller)
        panel.setDepthSelection(selectedDepth.rawValue)
        memory.onPersistenceFailure = { [weak self] in self?.preferenceStorageFailed() }
        panel.onSteadySelection = { [weak self] in self?.selectSteady($0) }
        panel.onUseMacOS = { [weak self] in self?.returnToMacOS() }
        panel.onKeepCurrent = { [weak self] in
            guard let self = self else { return }; _ = self.memory.select(.system)
            _ = self.controller.keepCurrentSettings(); self.updateRememberedUI()
        }
        panel.onRetry = { [weak self] in self?.connect() }
        panel.onDeepDimming = { [weak self] in self?.toggleDeepDimming() }
        panel.onDepthChanged = { [weak self] index in
            guard let self = self, let depth = DeepDimmingSession.Depth(rawValue: index) else { return }
            guard self.memory.rememberDepth(index) else { return }
            self.selectedDepth = depth
            self.deepSession?.selectDepth(depth, at: ProcessInfo.processInfo.systemUptime)
            if self.deepSession?.isPaused == true { self.pauseLighting() }
            else if self.deepSession?.running == false { self.finishDeepDimming() }
            else if self.deepSession?.running == true { self.scheduleNextFadeTick() }
            self.panel.update()
        }
        panel.onDeepOff = { [weak self] in
            self?.selectSteady(0)
        }
        panel.onQuit = { NSApp.terminate(nil) }
        controller.onChange = { [weak self] in
            if self?.deepSession == nil { self?.panel.deepMessage = nil }
            self?.panel.update()
            self?.verificationWork?.cancel()
            if self?.controller.restorationPending == true {
                let work = DispatchWorkItem { [weak self] in self?.controller.verifyRestoration() }
                self?.verificationWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
            } else if self?.controller.verificationPending == true {
                let work = DispatchWorkItem { [weak self] in self?.verifyRememberedSelection() }
                self?.verificationWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
            if let index = self?.controller.selectedIndex { self?.item?.button?.toolTip = "Nighty Keyboard · \(BrightnessScale.title(index))" }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = keycapIcon()
        item.button?.toolTip = "Nighty Keyboard · keyboard backlight"
        item.button?.target = self; item.button?.action = #selector(togglePanel)
        popover.contentViewController = panel; popover.contentSize = NSSize(width: 360, height: 648)
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        if preview {
            showPreview()
        } else {
            installLifecycle()
            startObservation(); pollLighting()
            if UserDefaults.standard.bool(forKey: "hasOpened") == false {
                UserDefaults.standard.set(true, forKey: "hasOpened")
                DispatchQueue.main.async { [weak self] in self?.togglePanel() }
            }
        }
    }

    func connect() {
        let initialConnection = !hasConnected; hasConnected = true
        guard persistenceReady else { controller.attach(nil, reason: "Could not save preferences. No lighting changes made."); return }
        if preview { let device = PreviewKeyboard(); connectedDevice = device; controller.attach(device); controller.select(3); controller.verifySelection(); return }
        let pwmRecovery = PWMRecoveryStore()
        if pwmRecovery.exists {
            controller.attach(nil, reason: "A legacy PWM recovery file needs review. This build will not send raw hardware reports.")
            return
        }
        if recovery.exists && recovery.load() == nil {
            memory.fail(); controller.attach(nil, reason: "Saved keyboard settings are unreadable. Keep the recovery file for review."); return
        }
        let ids = bridge.keyboardIDs()
        if let pending = recovery.load() {
            guard pending.brightness.isFinite, (0...1).contains(pending.brightness) else {
                memory.fail(); controller.attach(nil, reason: "Saved keyboard settings are invalid. Keep the recovery file for review."); return
            }
            if let match = ids.first(where: { $0.uint64Value == pending.keyboardID && bridge.isBuiltIn($0.uint64Value) }) {
                let device = NativeKeyboard(id: match.uint64Value, bridge: bridge)
                connectedDevice = device
                if initialConnection && persistenceReady && memory.previousExitWasClean && memory.enabled && pending.idleDimmingSuspended == nil {
                    resumeAllowsAutomaticDisable = true
                    if memory.preferences.mode == .deep {
                        controller.attach(device)
                        let session = DeepDimmingSession(device: device)
                        session.saveRecovery = { [weak self] in self?.recovery.save($0) ?? false }
                        if session.adopt(pending) { session.selectDepth(selectedDepth, at: ProcessInfo.processInfo.systemUptime); deepSession = session }
                        else { memory.fail(); _ = controller.stageRecovery(pending, device: device) }
                    } else { if !controller.adoptForResume(pending, device: device) { memory.fail() } }
                } else { memory.fail(); _ = controller.stageRecovery(pending, device: device) }
            } else {
                controller.attach(nil, reason: "Previous settings need recovery. Open the same MacBook keyboard and retry.")
            }
            return
        }
        let keyboard = ids.first { bridge.isBuiltIn($0.uint64Value) }
        let device = keyboard.map { NativeKeyboard(id: $0.uint64Value, bridge: bridge) }
        connectedDevice = device
        controller.attach(device, reason: bridge.available ? "No built-in backlit keyboard found. Open your MacBook and retry." : bridge.availabilityReason)
    }

    func preferenceStorageFailed() {
        persistenceReady = false; memory.fail()
        fadeTimer?.invalidate(); fadeTimer = nil; verificationWork?.cancel()
        let reason = "Could not save preferences. Saved keyboard settings still need recovery."
        if let session = deepSession {
            session.suspend()
            if let saved = session.snapshot, let device = connectedDevice { _ = controller.stageRecovery(saved, device: device) }
            deepSession = nil
        } else if controller.snapshot != nil { controller.requireRecovery(reason) }
        else { controller.attach(nil, reason: "Could not save preferences. Resolve storage access and relaunch Nighty.") }
        updateRememberedUI()
    }
    func toggleDeepDimming() {
        if memory.enabled && memory.state != .failed && memory.preferences.mode == .deep { returnToMacOS(); return }
        cachedActivity = nil
        guard persistenceReady, controller.restore(), memory.select(.deep, depth: selectedDepth.rawValue) else { return }
        resumeAllowsAutomaticDisable = true
        pollLighting()
    }
    func selectSteady(_ index: Int) {
        guard controller.state != .failed && !controller.restorationPending else { return }
        cachedActivity = nil
        guard persistenceReady else { return }
        if deepSession != nil { returnToMacOS(); if controller.snapshot != nil { return } }
        guard memory.select(index == 0 ? .system : .steady, index: index) else { return }
        if index == 0 { controller.select(0); updateRememberedUI(); return }
        resumeAllowsAutomaticDisable = true
        pollLighting()
    }
    func returnToMacOS() {
        if arguments.contains("--profile-preview") { print("PROFILE_EVENT: explicit handoff") }
        guard memory.select(.system) else { return }
        if let session = deepSession { _ = session.stop(); finishDeepDimming() }
        else if controller.state == .unavailable { connect() }
        else { _ = controller.restore() }
        updateRememberedUI()
    }
    func activity() -> ActivitySnapshot {
        guard !preview else { return previewActivity }
        guard let device = connectedDevice else { return ActivitySnapshot(age: nil, timeout: nil, keyboardIdle: nil) }
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = cachedActivity, now - cached.0 < 0.5 { return cached.1 }
        let value = activitySource.snapshot(bridge: bridge, keyboard: device.id)
        cachedActivity = (now, value); return value
    }
    func updateRememberedUI() {
        guard panel != nil else { return }
        panel.deepRunning = memory.enabled && memory.preferences.mode == .deep && memory.state != .failed
        panel.rememberedSteadyIndex = memory.paused && memory.preferences.mode == .steady ? memory.preferences.steadyIndex : nil
        panel.statusTitleOverride = nil
        if memory.state == .failed && memory.enabled && controller.snapshot == nil {
            panel.pausedMessage = "Automatic resume is off after an interrupted session. Choose a level to continue."
            panel.statusTitleOverride = "Choose a level to continue"
        } else if memory.paused {
            panel.pausedMessage = memory.state == .sleepPaused ? "Sleeping. Your level will resume when you return." :
                memory.state == .waiting ? "Waiting for macOS and activity. Your level is saved." : "Paused while idle. Your level is saved."
        } else { panel.pausedMessage = nil }
        panel.update()
    }
    func pauseLighting(sleeping: Bool = false) {
        guard memory.enabled && memory.state != .failed else { return }
        if memory.state == .active || (sleeping && memory.state != .sleepPaused) {
            deepSession?.suspend()
            if memory.preferences.mode == .steady { controller.pauseRememberedLevel() }
            fadeTimer?.invalidate(); fadeTimer = nil; verificationWork?.cancel()
        }
        memory.pause(sleeping: sleeping); updateRememberedUI()
        if restReasons.isEmpty { startObservation() }
    }
    @discardableResult func yieldRememberedMode() -> Bool {
        if arguments.contains("--profile-preview") { print("PROFILE_EVENT: external change; automatic=\(connectedDevice?.automatic ?? false); brightness=\(connectedDevice?.brightness ?? -1)") }
        guard memory.select(.system) else { return false }
        if let session = deepSession {
            let released = session.stop(preserveCurrent: true); finishDeepDimming(); return released
        }
        let released = controller.yieldToMacOS(); updateRememberedUI(); return released
    }
    func pollLighting() {
        guard persistenceReady else { return }
        if !restReasons.isEmpty { pauseLighting(sleeping: true); return }
        guard memory.enabled else {
            if popover.isShown { controller.refresh() } else { controller.observe() }
            return
        }
        guard memory.state != .failed else { updateRememberedUI(); return }
        if !resumeAllowsAutomaticDisable, let device = connectedDevice, device.automatic,
           deepSession?.snapshot != nil || controller.snapshot != nil {
            _ = yieldRememberedMode(); return
        }
        let status = activity()
        guard status.decision == .active else {
            pauseLighting(sleeping: status.decision == .blocked)
            if status.decision == .unavailable { memory.wait(); updateRememberedUI() }
            return
        }
        guard let device = connectedDevice else { memory.wait(); return }
        if device.idleDimmed || (device.suppressed && device.brightness > 0) {
            pauseLighting(); memory.wait(); updateRememberedUI(); return
        }
        if memory.shouldResume(status) {
            let desired = memory.preferences.mode == .deep ? DeepDimmingSession.floorRequest : BrightnessScale.levels[memory.preferences.steadyIndex]
            let newerLevel = device.brightness > 0 && (memory.preferences.mode == .deep ? device.brightness > desired : abs(device.brightness - desired) > max(0.00001, desired * 0.02))
            if !resumeAllowsAutomaticDisable && (device.automatic || newerLevel) {
                _ = yieldRememberedMode(); return
            }
            if memory.preferences.mode == .deep {
                if deepSession == nil {
                    let session = DeepDimmingSession(device: device)
                    session.saveRecovery = preview ? nil : { [weak self] in self?.recovery.save($0) ?? false }
                    session.selectDepth(selectedDepth, at: ProcessInfo.processInfo.systemUptime); deepSession = session
                    _ = session.start(at: ProcessInfo.processInfo.systemUptime)
                } else { _ = deepSession?.resume(at: ProcessInfo.processInfo.systemUptime, allowAutomaticDisable: resumeAllowsAutomaticDisable) }
                if deepSession?.running == true {
                    memory.activate(); resumeAllowsAutomaticDisable = false
                    observation?.invalidate(); observation = nil; scheduleNextFadeTick()
                } else { finishDeepDimming() }
            } else {
                controller.resumeRememberedLevel(memory.preferences.steadyIndex)
                if controller.isControlling { memory.activate(); resumeAllowsAutomaticDisable = false }
                else { memory.fail() }
            }
            updateRememberedUI(); return
        }
        if memory.preferences.mode == .steady && memory.state == .active {
            controller.observe()
            if !controller.isControlling { _ = memory.select(.system) }
            updateRememberedUI()
        }
    }
    func verifyRememberedSelection() {
        if memory.enabled && activity().decision != .active { pauseLighting(); return }
        controller.verifySelection()
        if memory.preferences.mode == .steady && !controller.isControlling { _ = memory.select(.system) }
        updateRememberedUI()
    }
    func scheduleNextFadeTick() {
        fadeTimer?.invalidate(); fadeTimer = nil
        guard let trial = deepSession, let deadline = trial.nextWakeTime else { return }
        let delay = max(0.001, deadline - ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, let trial = self.deepSession else { return }
            self.fadeTimer = nil
            self.pollLighting()
            guard self.memory.state == .active && trial.running else { return }
            self.fadeWakeCount += 1
            self.fadeMaxLateness = max(self.fadeMaxLateness, ProcessInfo.processInfo.systemUptime - deadline)
            trial.tick(at: ProcessInfo.processInfo.systemUptime)
            if trial.running { self.scheduleNextFadeTick() }
            else if trial.isPaused { self.pauseLighting(); self.startObservation() }
            else { self.finishDeepDimming() }
        }
        timer.tolerance = 0.002
        fadeTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func startObservation() {
        guard !preview, restReasons.isEmpty else { return }
        if observation?.isValid == true { return }
        observation?.invalidate()
        observation = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollLighting()
        }
        observation?.tolerance = 0.4
    }
    func finishDeepDimming() {
        guard let trial = deepSession else { return }
        fadeTimer?.invalidate(); fadeTimer = nil
        let message = trial.message
        if memory.enabled { _ = memory.select(.system) }
        if let saved = trial.snapshot, let device = connectedDevice {
            _ = controller.stageRecovery(saved, device: device)
            if trial.restorationAwaitingConfirmation { controller.waitForRestoration() }
        } else if let device = connectedDevice { controller.attach(device) }
        deepSession = nil; panel.deepRunning = false; panel.deepMessage = message; panel.update()
        startObservation()
    }

    @objc func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        if !memory.enabled { panel.deepMessage = nil; controller.refresh() }; pollLighting(); updateRememberedUI()
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel.view.window?.makeFirstResponder(panel.view.subviews.first { $0 is NSControl && !($0 is NSButton) })
    }

    func installLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, reason, resting) in [(NSWorkspace.willSleepNotification, "system", true),
                                        (NSWorkspace.screensDidSleepNotification, "display", true),
                                        (NSWorkspace.didWakeNotification, "system", false),
                                        (NSWorkspace.screensDidWakeNotification, "display", false)] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setRest(reason, resting: resting)
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, resting) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedTokens.append(distributed.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.setRest("lock", resting: resting)
            })
        }
    }
    func setRest(_ reason: String, resting: Bool) {
        cachedActivity = nil
        if resting { restReasons.insert(reason) } else { restReasons.remove(reason) }
        wakeTimer?.invalidate(); wakeTimer = nil
        if !restReasons.isEmpty {
            pauseLighting(sleeping: true); observation?.invalidate(); observation = nil
            fadeTimer?.invalidate(); fadeTimer = nil; verificationWork?.cancel(); popover.performClose(nil)
            return
        }
        memory.wait(); startObservation()
        var attempts = 0
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            attempts += 1; self.pollLighting()
            if self.memory.state == .active || !self.memory.enabled || attempts >= 20 {
                timer.invalidate(); self.wakeTimer = nil
            }
        }
    }
    func prepareCleanExit() -> Bool {
        guard !controller.recoveryStaged && !(memory.enabled && memory.state == .failed) else { return false }
        if !resumeAllowsAutomaticDisable, let device = connectedDevice, device.automatic,
           deepSession?.snapshot != nil || controller.snapshot != nil { return yieldRememberedMode() }
        let status = activity()
        if memory.paused || !restReasons.isEmpty || status.decision != .active {
            deepSession?.suspend()
            let saved = deepSession?.snapshot ?? controller.snapshot
            guard let saved = saved, let device = connectedDevice else { return savedModeHasNoSnapshot() }
            let sensorOK = device.setAutomatic(saved.automatic) && device.automatic == saved.automatic
            device.releaseControl(); return sensorOK
        }
        if let session = deepSession {
            let restored = session.stop()
            if !restored, let saved = session.snapshot, let device = connectedDevice {
                _ = controller.stageRecovery(saved, device: device)
                if session.restorationAwaitingConfirmation { controller.waitForRestoration() }
                deepSession = nil; memory.fail(); updateRememberedUI()
            }
            return restored
        }
        return controller.restore()
    }
    func savedModeHasNoSnapshot() -> Bool { controller.snapshot == nil && deepSession?.snapshot == nil }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        wakeTimer?.invalidate()
        guard !preview else { return .terminateNow }
        fadeTimer?.invalidate()
        let enteredWithRecovery = controller.recoveryStaged
        cleanExitPrepared = prepareCleanExit()
        if cleanExitPrepared { return .terminateNow }
        if enteredWithRecovery { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Keyboard settings still need restoring"
        alert.informativeText = controller.message + "\n\nYou can retry after the keyboard wakes. If you quit now, Nighty Keyboard will retain the recovery record and offer restoration on its next launch."
        alert.addButton(withTitle: "Keep Nighty Keyboard open"); alert.addButton(withTitle: "Quit with recovery saved")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        if !preview && cleanExitPrepared { _ = memory.markCleanExit() }
        fadeTimer?.invalidate()
        bridge.releaseManualControl()
        observation?.invalidate(); wakeTimer?.invalidate(); verificationWork?.cancel()
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }
    func validateLifecyclePreview() -> [String] {
        guard preview, let device = connectedDevice as? PreviewKeyboard else { return ["Lifecycle test requires a fake keyboard"] }
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        returnToMacOS(); selectedDepth = .barely; _ = memory.rememberDepth(selectedDepth.rawValue)
        panel.setDepthSelection(selectedDepth.rawValue)
        toggleDeepDimming()
        let original = deepSession?.snapshot?.brightness
        let session = deepSession
        check(memory.state == .active && session?.depth == .barely, "Saved depth did not activate")
        for _ in 0..<3 {
            device.brightness = 0; device.idleDimmed = true; device.suppressed = true
            previewActivity = ActivitySnapshot(age: 20, timeout: 10, keyboardIdle: true)
            pollLighting()
            check(memory.state == .idlePaused && deepSession === session, "Idle discarded the live session")
            check(fadeTimer == nil && !controller.recoveryStaged, "Idle kept a fade timer or entered recovery")
            check(deepSession?.snapshot?.brightness == original, "Idle replaced original settings with zero")
            device.idleDimmed = false; device.suppressed = false; previewActivity = .preview
            pollLighting()
            check(memory.state == .active && deepSession?.running == true, "Activity did not resume the remembered depth")
        }
        setRest("system", resting: true); setRest("lock", resting: true)
        device.brightness = 0
        check(memory.state == .sleepPaused && fadeTimer == nil && observation == nil, "Sleep retained active timers")
        setRest("system", resting: false)
        check(memory.state == .sleepPaused, "Wake resumed while still locked")
        setRest("lock", resting: false); pollLighting()
        check(memory.state == .active && deepSession?.snapshot?.brightness == original, "Unlock lost the remembered session")
        wakeTimer?.invalidate(); wakeTimer = nil
        selectSteady(0); controller.verifySelection(); pollLighting()
        check(!memory.enabled && deepSession == nil && device.brightness == 0, "Explicit Off allowed automatic relighting")
        returnToMacOS()
        toggleDeepDimming()
        device.brightness = 0; device.idleDimmed = true
        previewActivity = ActivitySnapshot(age: 20, timeout: 10, keyboardIdle: true); pollLighting()
        check(prepareCleanExit(), "Clean paused exit did not restore the sensor preference")
        check(deepSession?.snapshot?.brightness == original, "Clean paused exit lost the recovery baseline")
        device.automatic = true; pollLighting()
        check(!memory.enabled && device.automatic && deepSession == nil, "Manual macOS automatic brightness was overwritten while idle")
        device.idleDimmed = false; previewActivity = .preview
        for mode in [LightingPreferences.Mode.deep, .steady] {
            var saved = LightingPreferences(); saved.mode = mode; saved.depthIndex = 0; saved.cleanShutdown = true
            let relaunched = AppDelegate(preview: true, initialPreferences: saved)
            relaunched.persistenceReady = relaunched.memory.beginLaunch()
            let hardware = PreviewKeyboard(); hardware.brightness = 0.75; hardware.automatic = true
            relaunched.connectedDevice = hardware; relaunched.controller.attach(hardware)
            relaunched.panel = PanelController(controller: relaunched.controller); _ = relaunched.panel.view
            relaunched.pollLighting(); relaunched.verifyRememberedSelection()
            check(relaunched.memory.state == .active, "Clean relaunch failed to enable remembered mode")
            let baseline = relaunched.deepSession?.snapshot ?? relaunched.controller.snapshot
            check(baseline?.brightness == 0.75 && baseline?.automatic == true, "Relaunch did not preserve current macOS baseline")
            check(relaunched.prepareCleanExit() && hardware.brightness == 0.75 && hardware.automatic, "Relaunched mode failed to restore baseline")
            relaunched.fadeTimer?.invalidate()
            saved.cleanShutdown = false
            let crashed = AppDelegate(preview: true, initialPreferences: saved)
            crashed.persistenceReady = crashed.memory.beginLaunch(); crashed.connectedDevice = hardware
            crashed.controller.attach(hardware); crashed.panel = PanelController(controller: crashed.controller); _ = crashed.panel.view
            crashed.pollLighting()
            check(crashed.memory.state == .failed && hardware.brightness == 0.75 && hardware.automatic,
                  "An unclean restart performed automatic hardware changes")
        }
        toggleDeepDimming()
        let preserved = deepSession?.snapshot?.brightness
        memory.persist = { _ in false }
        _ = memory.rememberDepth(2)
        check(!persistenceReady && deepSession == nil && controller.snapshot?.brightness == preserved,
              "Preference failure lost the recovery snapshot or left fades running")
        check(controller.recoveryStaged && fadeTimer == nil, "Preference failure did not expose recovery")
        device.automatic = false
        return failures
    }

    func showPreview() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 648), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Nighty Keyboard · Preview (no hardware changes)"
        window.contentViewController = panel; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true); previewWindow = window
        if arguments.contains("--preview-idle"), let device = connectedDevice as? PreviewKeyboard {
            toggleDeepDimming(); device.brightness = 0; device.idleDimmed = true
            previewActivity = ActivitySnapshot(age: 20, timeout: 10, keyboardIdle: true); pollLighting()
        }
        if arguments.contains("--profile-preview") {
            // Profile the closed-panel case without stealing input or accepting
            // accidental clicks in the fake controls during the timed run.
            window.orderOut(nil); item.button?.isEnabled = false; NSApp.hide(nil)
            toggleDeepDimming()
            let began = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                let active = self.deepSession?.running == true
                print("PROFILE: fake keyboard; elapsed=\(String(format: "%.2f", elapsed))s; active=\(active); fadeWakeups=\(self.fadeWakeCount); oldPollingWakeups=\(Int(elapsed * 50)); maxLateness=\(String(format: "%.3f", self.fadeMaxLateness))s; endStatus=\(self.panel.deepMessage ?? ""); hardwareWrites=0")
                if let trial = self.deepSession { _ = trial.stop(); self.finishDeepDimming() }
                if !active { fputs("FAIL: simulated dimming did not stay active for the profile.\n", stderr); exit(1) }
                NSApp.terminate(nil)
            }
        }
        if arguments.contains("--verify-lifecycle") {
            DispatchQueue.main.async {
                let failures = self.validateLifecyclePreview()
                if failures.isEmpty { print("PASS: Fake-keyboard idle/resume cycles, original snapshot, nested sleep/lock, clean paused exit, explicit Off, and macOS handoff.") }
                else { failures.forEach { print("FAIL: " + $0) } }
                exit(failures.isEmpty ? 0 : 1)
            }
        }
        if arguments.contains("--verify-ui") {
            DispatchQueue.main.async {
                let failures = self.panel.validatePreview()
                if failures.isEmpty { print("PASS: Native panel bounds, accessibility dial actions, presets, continuous dimming, Off, and Use macOS; fake keyboard only.") }
                else { failures.forEach { print("FAIL: " + $0) } }
                exit(failures.isEmpty ? 0 : 1)
            }
        }
        if let index = arguments.firstIndex(of: "--render-preview"), arguments.count > index + 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.panel.view.layoutSubtreeIfNeeded()
                if let bitmap = self.panel.view.bitmapImageRepForCachingDisplay(in: self.panel.view.bounds) {
                    self.panel.view.cacheDisplay(in: self.panel.view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        do { try data.write(to: URL(fileURLWithPath: arguments[index + 1])); print("Preview saved.") }
                        catch { fputs("Preview render failed: \(error)\n", stderr) }
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }
}

if arguments.contains("--diagnose") { diagnostic(); exit(0) }
if arguments.contains("--verify-pwm") || arguments.contains("--verify-hardware") {
    print("Hardware-changing verification is disabled in this everyday build. Use --diagnose for read-only status.")
    exit(2)
}
if arguments.contains("--diagnose-pwm") {
    if let data = try? JSONSerialization.data(withJSONObject: pwmDiagnostic(), options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate(preview: arguments.contains("--preview") || arguments.contains("--render-preview") || arguments.contains("--verify-ui") || arguments.contains("--profile-preview") || arguments.contains("--verify-lifecycle") || arguments.contains("--preview-idle"))
app.delegate = delegate
app.run()
