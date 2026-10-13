import AppKit

let arguments = CommandLine.arguments

func diagnostic() {
    let bridge = BLKeyboardBridge()
    let keyboards = bridge.keyboardIDs().map { number -> [String: Any] in
        let id = number.uint64Value
        return ["id": id, "builtIn": bridge.isBuiltIn(id), "brightnessRequest": bridge.brightness(id),
                "backlightLevel": bridge.backlightLevel(id), "automatic": bridge.automaticBrightness(id),
                "suppressed": bridge.isSuppressed(id), "idleDimmed": bridge.isIdleDimmed(id)]
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

    init(preview: Bool) { self.preview = preview; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !preview, let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        controller.saveRecovery = preview ? nil : { [weak self] snapshot in self?.recovery.save(snapshot) ?? false }
        connect()
        panel = PanelController(controller: controller)
        panel.onRetry = { [weak self] in self?.connect() }
        panel.onDeepDimming = { [weak self] in self?.toggleDeepDimming() }
        panel.onDepthChanged = { [weak self] index in
            guard let self = self, let depth = DeepDimmingSession.Depth(rawValue: index) else { return }
            self.selectedDepth = depth
            self.deepSession?.selectDepth(depth, at: ProcessInfo.processInfo.systemUptime)
            if self.deepSession?.running == false { self.finishDeepDimming() }
            else if self.deepSession?.running == true { self.scheduleNextFadeTick() }
            self.panel.update()
        }
        panel.onDeepOff = { [weak self] in
            guard let self = self, let session = self.deepSession else { return }
            _ = session.stop(); self.finishDeepDimming()
            if self.controller.snapshot == nil { self.controller.select(0) }
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
                let work = DispatchWorkItem { [weak self] in self?.controller.verifySelection() }
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
            startObservation()
            if UserDefaults.standard.bool(forKey: "hasOpened") == false {
                UserDefaults.standard.set(true, forKey: "hasOpened")
                DispatchQueue.main.async { [weak self] in self?.togglePanel() }
            }
        }
    }

    func connect() {
        if preview { let device = PreviewKeyboard(); connectedDevice = device; controller.attach(device); controller.select(3); controller.verifySelection(); return }
        let pwmRecovery = PWMRecoveryStore()
        if pwmRecovery.exists {
            controller.attach(nil, reason: "A legacy PWM recovery file needs review. This build will not send raw hardware reports.")
            return
        }
        let ids = bridge.keyboardIDs()
        if let pending = recovery.load() {
            if let match = ids.first(where: { $0.uint64Value == pending.keyboardID }) {
                let device = NativeKeyboard(id: match.uint64Value, bridge: bridge)
                connectedDevice = device
                _ = controller.stageRecovery(pending, device: device)
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

    func toggleDeepDimming() {
        if let trial = deepSession { _ = trial.stop(); finishDeepDimming(); return }
        guard controller.restore(), let device = connectedDevice else { return }
        verificationWork?.cancel()
        let trial = DeepDimmingSession(device: device)
        trial.saveRecovery = preview ? nil : { [weak self] in self?.recovery.save($0) ?? false }
        deepSession = trial
        trial.selectDepth(selectedDepth, at: ProcessInfo.processInfo.systemUptime)
        _ = trial.start(at: ProcessInfo.processInfo.systemUptime)
        panel.deepMessage = trial.message; panel.deepRunning = trial.running; panel.update()
        guard trial.running else { finishDeepDimming(); return }
        observation?.invalidate(); observation = nil
        scheduleNextFadeTick()
    }
    func scheduleNextFadeTick() {
        fadeTimer?.invalidate(); fadeTimer = nil
        guard let trial = deepSession, let deadline = trial.nextWakeTime else { return }
        let delay = max(0.001, deadline - ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, let trial = self.deepSession else { return }
            self.fadeTimer = nil; self.fadeWakeCount += 1
            self.fadeMaxLateness = max(self.fadeMaxLateness, ProcessInfo.processInfo.systemUptime - deadline)
            trial.tick(at: ProcessInfo.processInfo.systemUptime)
            if trial.running { self.scheduleNextFadeTick() } else { self.finishDeepDimming() }
        }
        timer.tolerance = 0.002
        fadeTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func startObservation() {
        guard !preview else { return }
        observation?.invalidate()
        observation = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, self.deepSession == nil else { return }
            if self.popover.isShown { self.controller.refresh() } else { self.controller.observe() }
        }
        observation?.tolerance = 0.4
    }
    func finishDeepDimming() {
        guard let trial = deepSession else { return }
        fadeTimer?.invalidate(); fadeTimer = nil
        let message = trial.message
        if let saved = trial.snapshot, let device = connectedDevice {
            _ = controller.stageRecovery(saved, device: device)
            if trial.restorationAwaitingConfirmation { controller.waitForRestoration() }
        } else if let device = connectedDevice { controller.attach(device) }
        deepSession = nil; panel.deepRunning = false; panel.deepMessage = message; panel.update()
        startObservation()
    }

    @objc func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        if deepSession == nil { panel.deepMessage = nil; controller.refresh() }; panel.update()
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel.view.window?.makeFirstResponder(panel.view.subviews.first { $0 is NSControl && !($0 is NSButton) })
    }

    func installLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sleep() })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.wake() })
        }
        let distributed = DistributedNotificationCenter.default()
        distributedTokens.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.sleep() })
        distributedTokens.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.wake() })
    }
    func sleep() {
        deepSession?.suspend(); finishDeepDimming()
        wakeTimer?.invalidate(); wakeTimer = nil
        verificationWork?.cancel()
        controller.sleep(); popover.performClose(nil)
    }
    func wake() {
        wakeTimer?.invalidate()
        var attempts = 0
        // No high frequency loop during normal use. Only bounded wake retries.
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            attempts += 1; self.controller.wake()
            if self.controller.state != .sleeping || attempts >= 20 {
                if attempts >= 20 { self.controller.wakeTimedOut() }
                timer.invalidate(); self.wakeTimer = nil
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        wakeTimer?.invalidate()
        guard !preview else { return .terminateNow }
        if let trial = deepSession { _ = trial.stop(); finishDeepDimming() }
        if controller.recoveryStaged { return .terminateNow }
        if controller.restore() { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Keyboard settings still need restoring"
        alert.informativeText = controller.message + "\n\nYou can retry after the keyboard wakes. If you quit now, Nighty Keyboard will retain the recovery record and offer restoration on its next launch."
        alert.addButton(withTitle: "Keep Nighty Keyboard open"); alert.addButton(withTitle: "Quit with recovery saved")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        fadeTimer?.invalidate()
        bridge.releaseManualControl()
        observation?.invalidate(); wakeTimer?.invalidate(); verificationWork?.cancel()
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }
    func showPreview() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 648), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Nighty Keyboard · Preview (no hardware changes)"
        window.contentViewController = panel; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true); previewWindow = window
        if arguments.contains("--profile-preview") {
            toggleDeepDimming()
            let began = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                let active = self.deepSession?.running == true
                print("PROFILE: fake keyboard; elapsed=\(String(format: "%.2f", elapsed))s; active=\(active); fadeWakeups=\(self.fadeWakeCount); oldPollingWakeups=\(Int(elapsed * 50)); maxLateness=\(String(format: "%.3f", self.fadeMaxLateness))s; endStatus=\(self.panel.deepMessage ?? ""); hardwareWrites=0")
                if let trial = self.deepSession { _ = trial.stop(); self.finishDeepDimming() }
                NSApp.terminate(nil)
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
let delegate = AppDelegate(preview: arguments.contains("--preview") || arguments.contains("--render-preview") || arguments.contains("--verify-ui") || arguments.contains("--profile-preview"))
app.delegate = delegate
app.run()
