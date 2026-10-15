import AppKit
import ServiceManagement

private enum Ink {
    static let background = NSColor(srgbRed: 0.070, green: 0.060, blue: 0.090, alpha: 1)
    static let surface = NSColor(srgbRed: 0.110, green: 0.094, blue: 0.139, alpha: 1)
    static let line = NSColor(srgbRed: 0.235, green: 0.204, blue: 0.282, alpha: 1)
    static let primary = NSColor(srgbRed: 0.955, green: 0.922, blue: 0.858, alpha: 1)
    static let muted = NSColor(srgbRed: 0.620, green: 0.576, blue: 0.663, alpha: 1)
    static let accent = NSColor(srgbRed: 0.925, green: 0.710, blue: 0.400, alpha: 1)
}

// Draw the menu bar dial icon.
func keycapIcon(size: CGFloat = 18, template: Bool = true) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    (template ? NSColor.black : Ink.accent).setStroke()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2), radius: size * 0.35, startAngle: -40, endAngle: 220)
    arc.lineWidth = size * 0.08; arc.lineCapStyle = .round; arc.stroke()
    let hand = NSBezierPath(); hand.move(to: NSPoint(x: size / 2, y: size / 2))
    hand.line(to: NSPoint(x: size * 0.68, y: size * 0.70)); hand.lineWidth = size * 0.09; hand.lineCapStyle = .round; hand.stroke()
    image.unlockFocus(); image.isTemplate = template; return image
}

private final class PanelBackground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Ink.background.setFill(); bounds.fill() }
}

private final class LightDial: NSControl {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); cell = NSActionCell(); cell?.isEnabled = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    var maximumIndex = BrightnessScale.levels.count - 1
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var modeTitle: String?
    var captionOverride: String?
    var externalValue: Float? { didSet { needsDisplay = true } }
    var onPreview: ((Int) -> Void)?
    private(set) var tracking = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private let start: CGFloat = 135
    private let sweep: CGFloat = 270

    private func point(_ angle: CGFloat, radius: CGFloat) -> NSPoint {
        let rad = angle * .pi / 180
        return NSPoint(x: center.x + cos(rad) * radius, y: center.y + sin(rad) * radius)
    }
    private func arc(_ fraction: CGFloat, radius: CGFloat, color: NSColor, width: CGFloat) {
        let path = NSBezierPath()
        let steps = max(1, Int(90 * fraction))
        for i in 0...steps {
            let angle = start + sweep * fraction * CGFloat(i) / CGFloat(steps)
            let position = point(angle, radius: radius)
            if i == 0 { path.move(to: position) } else { path.line(to: position) }
        }
        color.setStroke(); path.lineWidth = width; path.lineCapStyle = .round; path.stroke()
    }
    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 91
        let enabledAlpha: CGFloat = isEnabled ? 1 : 0.4
        Ink.surface.withAlphaComponent(enabledAlpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 77, y: center.y - 77, width: 154, height: 154)).fill()
        arc(1, radius: radius, color: Ink.line, width: 5)
        let fraction = CGFloat(selectedIndex) / CGFloat(maximumIndex)
        if selectedIndex > 0 { arc(fraction, radius: radius, color: Ink.accent.withAlphaComponent(enabledAlpha), width: 5) }
        for index in 0...maximumIndex {
            let angle = start + sweep * CGFloat(index) / CGFloat(maximumIndex)
            let tick = NSBezierPath(); tick.move(to: point(angle, radius: 102)); tick.line(to: point(angle, radius: index % 4 == 0 ? 110 : 106))
            (index <= selectedIndex ? Ink.accent.withAlphaComponent(0.8 * enabledAlpha) : Ink.line).setStroke()
            tick.lineWidth = 1.5; tick.stroke()
        }
        let thumb = point(start + sweep * fraction, radius: radius)
        Ink.background.setFill(); NSBezierPath(ovalIn: NSRect(x: thumb.x - 10, y: thumb.y - 10, width: 20, height: 20)).fill()
        Ink.accent.withAlphaComponent(enabledAlpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: thumb.x - 6, y: thumb.y - 6, width: 12, height: 12)).fill()
        let isNight = modeTitle == nil && externalValue == nil && BrightnessScale.nightRange.contains(selectedIndex)
        let number = modeTitle ?? externalValue.map { BrightnessScale.percentage(of: $0) } ?? (selectedIndex == 0 ? "Off" : isNight ? String(selectedIndex) : BrightnessScale.percent(selectedIndex))
        let font = NSFont.monospacedDigitSystemFont(ofSize: isNight ? 52 : 33, weight: .light)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Ink.primary.withAlphaComponent(enabledAlpha)]
        let textSize = (number as NSString).size(withAttributes: attributes)
        (number as NSString).draw(at: NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2 - 24), withAttributes: attributes)
        let caption = captionOverride ?? (modeTitle != nil ? "DEEPER" : externalValue != nil ? "MACOS LEVEL" : isNight ? "NIGHT LEVEL" : "KEYBOARD LIGHT")
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: Ink.muted]
        let captionSize = (caption as NSString).size(withAttributes: small)
        (caption as NSString).draw(at: NSPoint(x: center.x - captionSize.width / 2, y: center.y + 4), withAttributes: small)
    }
    private func index(at location: NSPoint) -> Int {
        var angle = atan2(location.y - center.y, location.x - center.x) * 180 / .pi
        if angle < start { angle += 360 }
        if angle > start + sweep { angle = angle < start + sweep + 45 ? start + sweep : start }
        let fraction = max(0, min(1, (angle - start) / sweep))
        return max(0, min(maximumIndex, Int((fraction * CGFloat(maximumIndex)).rounded())))
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - center.x, location.y - center.y) >= 65 else { return }
        externalValue = nil
        tracking = true
        selectedIndex = index(at: convert(event.locationInWindow, from: nil)); onPreview?(selectedIndex)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            selectedIndex = index(at: convert(next.locationInWindow, from: nil)); onPreview?(selectedIndex); displayIfNeeded()
            if next.type == .leftMouseUp { break }
        }
        tracking = false
        _ = sendAction(action, to: target) // Commit once, when the drag ends.
    }
    private func step(_ direction: Int) {
        guard isEnabled else { return }
        externalValue = nil
        selectedIndex = max(0, min(maximumIndex, selectedIndex + direction))
        _ = sendAction(action, to: target)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: step(-1)
        case 124, 126: step(1)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Keyboard light dial" }
    override func accessibilityValue() -> Any? { modeTitle ?? externalValue.map { "macOS level " + BrightnessScale.percentage(of: $0) } ?? (BrightnessScale.title(selectedIndex) + ", requested " + BrightnessScale.percent(selectedIndex)) }
    override func accessibilityPerformIncrement() -> Bool { guard isEnabled else { return false }; step(1); return true }
    override func accessibilityPerformDecrement() -> Bool { guard isEnabled else { return false }; step(-1); return true }
}

final class PanelController: NSViewController {
    let controller: BrightnessController
    var onRetry: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSupport: (() -> Void)?
    var onSteadySelection: ((Int) -> Void)?
    var onUseMacOS: (() -> Void)?
    var onKeepCurrent: (() -> Void)?
    var pausedMessage: String?
    var statusTitleOverride: String?
    var rememberedSteadyIndex: Int?
    var onDeepDimming: (() -> Void)?
    var deepRunning = false
    var deepMessage: String?
    var onDepthChanged: ((Int) -> Void)?
    var onDeepOff: (() -> Void)?
    private let depthCaption = NSTextField(labelWithString: "")
    private let depths = NSSlider(value: Double(DeepDimmingSession.Depth.balanced.rawValue), minValue: 0, maxValue: Double(DeepDimmingSession.Depth.allCases.count - 1), target: nil, action: nil)
    private let keepCurrentButton = NSButton(title: "Keep current macOS settings", target: nil, action: nil)
    private let deepButton = NSButton(title: "Enable deeper dimming", target: nil, action: nil)
    private let dial = LightDial(frame: NSRect(x: 64, y: 70, width: 232, height: 232))
    private let detail = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let returnButton = NSButton(title: "Use macOS", target: nil, action: nil)
    private let offButton = NSButton(title: "Off", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    init(controller: BrightnessController) { self.controller = controller; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Not supported") }

    override func loadView() {
        view = PanelBackground(frame: NSRect(x: 0, y: 0, width: 360, height: 510))
        view.appearance = NSAppearance(named: .darkAqua)
        let brand = label("Nighty", NSRect(x: 24, y: 24, width: 250, height: 39), size: 30)
        brand.font = .systemFont(ofSize: 25, weight: .semibold)
        let info = button("About", frame: NSRect(x: 285, y: 29, width: 52, height: 27), action: #selector(showInfo), filled: false)
        info.font = .systemFont(ofSize: 11)
        dial.target = self; dial.action = #selector(dialChanged)
        dial.onPreview = { [weak self] index in
            guard let self = self else { return }
            if self.deepRunning { self.dial.modeTitle = "\(index + 1)/7"; self.detail.stringValue = DeepDimmingSession.Depth(rawValue: index)?.title ?? "" }
            else { self.showDetail(index) }
        }
        view.addSubview(dial)
        detail.frame = NSRect(x: 24, y: 307, width: 312, height: 20)
        detail.font = .systemFont(ofSize: 11); detail.textColor = Ink.muted; detail.alignment = .center; view.addSubview(detail)
        style(offButton, frame: NSRect(x: 135, y: 220, width: 90, height: 27), action: #selector(togglePower), filled: false)
        offButton.font = .systemFont(ofSize: 11, weight: .medium)
        deepButton.setButtonType(.switch)
        deepButton.frame = NSRect(x: 50, y: 344, width: 286, height: 26)
        deepButton.target = self; deepButton.action = #selector(deepSession)
        deepButton.font = .systemFont(ofSize: 12, weight: .medium)
        deepButton.contentTintColor = Ink.accent
        let moon = NSImageView(frame: NSRect(x: 24, y: 349, width: 16, height: 16))
        moon.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)
        moon.contentTintColor = Ink.accent; view.addSubview(moon)
        deepButton.toolTip = "Enable or disable deeper dimming"
        view.addSubview(deepButton)
        style(returnButton, frame: NSRect(x: 24, y: 378, width: 312, height: 28), action: #selector(restore))
        style(keepCurrentButton, frame: NSRect(x: 24, y: 410, width: 312, height: 26), action: #selector(keepCurrent), filled: false)
        keepCurrentButton.font = .systemFont(ofSize: 11)
        depths.frame = NSRect(x: 24, y: 378, width: 312, height: 26)
        depths.integerValue = DeepDimmingSession.Depth.balanced.rawValue; depths.numberOfTickMarks = DeepDimmingSession.Depth.allCases.count; depths.allowsTickMarkValuesOnly = true; depths.isContinuous = true; depths.setAccessibilityLabel("Deeper dimming level, 1 darkest to 7 brightest"); depths.target = self; depths.action = #selector(depthChanged); view.addSubview(depths)
        depthCaption.frame = NSRect(x: 24, y: 410, width: 312, height: 16)
        depthCaption.font = .systemFont(ofSize: 10); depthCaption.textColor = Ink.muted; depthCaption.alignment = .center; view.addSubview(depthCaption)
        message.frame = NSRect(x: 24, y: 441, width: 312, height: 31)
        message.font = .systemFont(ofSize: 11); message.textColor = Ink.muted
        message.maximumNumberOfLines = 2; view.addSubview(message)
        login.frame = NSRect(x: 24, y: 482, width: 145, height: 18); login.font = .systemFont(ofSize: 10)
        login.target = self; login.action = #selector(toggleLogin); view.addSubview(login)
        if #available(macOS 13, *) { refreshLogin() } else { login.isHidden = true }
        let support = button("", frame: NSRect(x: 237, y: 477, width: 30, height: 25), action: #selector(supportApp), filled: false)
        support.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Support Nighty")
        support.imageScaling = .scaleProportionallyDown
        support.contentTintColor = Ink.primary.withAlphaComponent(0.45)
        support.toolTip = "Support me <3"
        support.setAccessibilityLabel("Support me")
        let quit = button("Quit", frame: NSRect(x: 287, y: 477, width: 51, height: 25), action: #selector(quitApp), filled: false)
        quit.font = .systemFont(ofSize: 10)
        update()
    }
    func update() {
        guard isViewLoaded else { return }
        if !dial.tracking {
            dial.externalValue = controller.state == .ready || controller.state == .paused ? controller.observedBrightness : nil
            dial.selectedIndex = rememberedSteadyIndex ?? controller.selectedIndex; showDetail(dial.selectedIndex)
            if rememberedSteadyIndex != nil { dial.externalValue = nil }
        }
        dial.maximumIndex = deepRunning ? DeepDimmingSession.Depth.allCases.count - 1 : BrightnessScale.levels.count - 1
        if deepRunning && !dial.tracking { dial.selectedIndex = depths.integerValue; dial.externalValue = nil }
        dial.captionOverride = pausedMessage == nil ? nil : "SAVED LEVEL"
        dial.modeTitle = deepRunning ? "\(depths.integerValue + 1)/7" : nil
        if let depth = DeepDimmingSession.Depth(rawValue: depths.integerValue) {
            depthCaption.stringValue = "Dimmer                                      Brighter"
            if deepRunning { detail.stringValue = depth.title }
        }
        dial.isEnabled = controller.canAdjust || deepRunning; dial.needsDisplay = true
        let isOn = deepRunning || (rememberedSteadyIndex ?? controller.selectedIndex) > 0 || (dial.externalValue ?? 0) > 0
        offButton.title = isOn ? "Turn off" : "Turn on"
        offButton.setAccessibilityLabel(isOn ? "Turn keyboard light off" : "Turn keyboard light on")
        offButton.isEnabled = controller.canAdjust || deepRunning
        returnButton.isEnabled = controller.canRestore || controller.state == .unavailable
        returnButton.title = controller.state == .unavailable ? "Find keyboard" : "Restore saved settings"
        deepButton.title = "Deeper dimming"
        deepButton.state = deepRunning ? .on : .off
        deepButton.isEnabled = deepRunning || controller.canAdjust || (controller.state != .failed && controller.state != .unavailable)
        depths.isEnabled = deepRunning || controller.canAdjust
        let recoveryVisible = controller.snapshot != nil && controller.state == .failed
        depths.isHidden = recoveryVisible; depthCaption.isHidden = recoveryVisible; keepCurrentButton.isHidden = !recoveryVisible
        returnButton.isHidden = !recoveryVisible && controller.state != .unavailable
        keepCurrentButton.isEnabled = !controller.restorationPending
        if let paused = pausedMessage { message.stringValue = paused }
        else if controller.state == .failed || controller.state == .unavailable { message.stringValue = deepMessage ?? controller.message }
        else if deepRunning { message.stringValue = "Turns off when idle. Resumes when you return." }
        else if let result = deepMessage { message.stringValue = result }
        else if controller.verificationPending { message.stringValue = "Applying…" }
        else { message.stringValue = "" }
    }
    func validatePreview() -> [String] {
        view.layoutSubtreeIfNeeded()
        var failures: [String] = []
        for child in view.subviews where !view.bounds.contains(child.frame) {
            failures.append("Subview exceeds panel bounds: \(type(of: child))")
        }
        let about = makeAboutAlert()
        let credit = about.accessoryView as? NSTextField
        if credit?.stringValue != "by anisharyal09" || credit?.alignment != .center || credit?.font?.pointSize != 11 {
            failures.append("About author credit is missing")
        }
        let original = controller.selectedIndex
        if !dial.accessibilityPerformIncrement() || controller.selectedIndex != BrightnessScale.clampedIndex(original + 1) {
            failures.append("Dial increment is not connected to the controller")
        }
        controller.verifySelection()
        if !dial.accessibilityPerformDecrement() || controller.selectedIndex != original { failures.append("Dial decrement failed") }
        controller.verifySelection()
        togglePower()
        if controller.selectedIndex != 0 { failures.append("Off action failed") }
        controller.verifySelection()
        if !controller.restore() || controller.snapshot != nil { failures.append("Use macOS action failed") }
        deepSession()
        if !deepRunning || !offButton.isEnabled || !dial.isEnabled { failures.append("Continuous dimming controls failed") }
        let oldDepth = depths.integerValue
        if !dial.accessibilityPerformDecrement() || depths.integerValue != max(0, oldDepth - 1) { failures.append("Deep dial did not change depth") }
        depths.integerValue = 0; depthChanged()
        restore()
        if deepRunning { failures.append("Use macOS did not stop deeper dimming") }
        deepSession(); togglePower()
        if deepRunning || controller.selectedIndex != 0 || dial.modeTitle != nil || offButton.title != "Turn on" {
            failures.append("Center power did not immediately display Off")
        }
        controller.verifySelection()
        togglePower()
        if !deepRunning { failures.append("Center power did not resume the chosen deeper mode") }
        restore()
        _ = controller.restore()
        let recoveryDevice = PreviewKeyboard()
        _ = controller.stageRecovery(.init(keyboardID: recoveryDevice.id, brightness: 0.04, automatic: false), device: recoveryDevice)
        update()
        if keepCurrentButton.isHidden || !keepCurrentButton.isEnabled || !depths.isHidden { failures.append("Recovery choice is unavailable") }
        keepCurrent()
        if controller.snapshot != nil || !controller.canAdjust { failures.append("Keep-current recovery did not unlock controls") }
        controller.select(original); controller.verifySelection(); update()
        return failures
    }

    func setDepthSelection(_ index: Int) { _ = view; depths.integerValue = index; update() }

    private func showDetail(_ index: Int) {
        let hint = "Drag the rim to adjust"
        detail.stringValue = hint
    }
    @objc private func keepCurrent() { deepMessage = nil; if let action = onKeepCurrent { action() } else { _ = controller.keepCurrentSettings() } }
    @objc private func deepSession() { onDeepDimming?() }
    @objc private func depthChanged() { onDepthChanged?(depths.integerValue) }
    @objc private func dialChanged() { if deepRunning { depths.integerValue = dial.selectedIndex; depthChanged() } else { chooseSteady(dial.selectedIndex) } }
    @objc private func togglePower() {
        if deepRunning || (rememberedSteadyIndex ?? controller.selectedIndex) > 0 || (dial.externalValue ?? 0) > 0 { turnOff() }
        else if lastPowerWasDeep { onDeepDimming?() }
        else { chooseSteady(lastOnIndex) }
    }
    private var lastPowerWasDeep = false
    private var lastOnIndex = 10
    @objc private func turnOff() { lastPowerWasDeep = deepRunning; if deepRunning { onDeepOff?() } else { chooseSteady(0) } }
    private func chooseSteady(_ index: Int) { if index > 0 { lastOnIndex = index }; if let action = onSteadySelection { action(index) } else { controller.select(index) } }
    @objc private func restore() { if let action = onUseMacOS { action(); return }; deepMessage = nil; if deepRunning { onDeepDimming?(); return }; if controller.state == .unavailable { onRetry?() } else { _ = controller.restore() } }
    @objc private func supportApp() { onSupport?() }
    @objc private func quitApp() { onQuit?() }
    private func makeAboutAlert() -> NSAlert {
        let alert = NSAlert(); alert.messageText = "Nighty Keyboard"
        alert.informativeText = "Free and open source.\n\nDrag the dial for brightness. Click its center to turn the light on or off. Deeper dimming adds seven lower levels and follows your macOS idle timeout.\n\nRight-click the menu bar icon for macOS control and support.\n\nExperimental deeper dimming uses private macOS controls. Brightness and flicker vary by keyboard; battery and energy impact have not been measured.\n\nProvided as is, without warranties of any kind. See the MIT license.\n\nNo accounts, analytics, or input logging."
        let credit = NSTextField(labelWithString: "by anisharyal09")
        credit.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        credit.alignment = .center
        credit.textColor = .labelColor
        credit.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = credit
        alert.addButton(withTitle: "Done")
        return alert
    }
    @objc private func showInfo() { makeAboutAlert().runModal() }
    @available(macOS 13, *) private func refreshLogin() { login.state = SMAppService.mainApp.status == .enabled ? .on : .off }
    @objc private func toggleLogin() {
        guard #available(macOS 13, *) else { return }
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let alert = NSAlert(); alert.messageText = "Could not change login settings"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
        refreshLogin()
    }
    @discardableResult private func label(_ text: String, _ frame: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = Ink.primary) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.frame = frame; field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color; view.addSubview(field); return field
    }
    @discardableResult private func button(_ title: String, frame: NSRect, action: Selector, filled: Bool = true) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        style(control, frame: frame, action: action, filled: filled); return control
    }
    private func style(_ button: NSButton, frame: NSRect, action: Selector, filled: Bool = true, primary: Bool = false) {
        button.frame = frame; button.target = self; button.action = action; button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium); button.contentTintColor = primary ? Ink.background : Ink.primary
        button.wantsLayer = true; button.layer?.cornerRadius = 10
        button.layer?.backgroundColor = (primary ? Ink.accent : filled ? Ink.surface : .clear).cgColor
        view.addSubview(button)
    }
}
