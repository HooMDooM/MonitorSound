import AppKit
import ApplicationServices
import CoreAudio
import ServiceManagement

// MARK: - Logging

func log(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MonitorSound.log")
    let line = "\(Date()) \(message)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Default audio output

enum AudioOutput {
    static func defaultDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr else { return nil }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    static func onDefaultDeviceChange(_ handler: @escaping () -> Void) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in handler() }
    }
}

// MARK: - Volume controller

final class VolumeController {
    static let shared = VolumeController()

    private(set) var display: DDCDisplay?
    private(set) var volume: Double = 0      // 0...1
    private(set) var muted = false
    private var maxValue: Double = 100
    private var volumeBeforeMute: Double = 0.25

    private let queue = DispatchQueue(label: "ddc")
    private var pendingValue: UInt16?
    private var writing = false

    var onChange: (() -> Void)?

    var isActive: Bool { display != nil }

    /// Picks the DDC display whose name matches the current default audio output.
    func refresh() {
        let outputName = AudioOutput.defaultDeviceName()
        queue.async {
            let displays = DDCDisplay.all()
            let match = displays.first { d in outputName.map { $0 == d.name || $0.contains(d.name) || d.name.contains($0) } ?? false }
            let reading = match?.read(.volume)
            log("refresh: output=\(outputName ?? "nil") displays=\(displays.map(\.name)) match=\(match?.name ?? "nil") reading=\(String(describing: reading))")
            DispatchQueue.main.async {
                self.display = match
                if let reading, reading.max > 0 {
                    self.maxValue = Double(reading.max)
                    self.volume = Double(reading.current) / self.maxValue
                    self.muted = reading.current == 0 && self.muted
                }
                self.onChange?()
            }
        }
    }

    func step(up: Bool, fine: Bool) {
        // 5 monitor units per press (5% on a 0–100 monitor), 1 unit with ⌥⇧.
        let step = (fine ? 1.0 : 5.0) / maxValue
        if muted { muted = false; volume = volumeBeforeMute }
        let snapped = (volume / step).rounded() * step
        set(max(0, min(1, snapped + (up ? step : -step))))
    }

    func set(_ value: Double) {
        volume = max(0, min(1, value))
        if volume > 0 { muted = false }
        apply()
    }

    func toggleMute() {
        if muted {
            muted = false
            volume = volumeBeforeMute
        } else {
            volumeBeforeMute = volume > 0 ? volume : 0.25
            muted = true
        }
        apply()
    }

    private func apply() {
        onChange?()
        let raw = UInt16((muted ? 0 : volume) * maxValue)
        queue.async {
            self.pendingValue = raw
            guard !self.writing else { return }
            self.writing = true
            // Coalesce rapid key presses: always write the latest requested value.
            while let v = self.pendingValue {
                self.pendingValue = nil
                if self.display?.write(.volume, v) == false { log("DDC write failed") }
            }
            self.writing = false
        }
    }
}

// MARK: - Media key interception

enum MediaKeys {
    private static let soundUp = 0, soundDown = 1, mute = 7
    private static var tap: CFMachPort?

    static func start() -> Bool {
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: nil) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private static let callback: CGEventTapCallBack = { _, type, cgEvent, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = MediaKeys.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(cgEvent)
        }
        guard type.rawValue == 14,
              let event = NSEvent(cgEvent: cgEvent), event.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(cgEvent)
        }
        let key = (event.data1 & 0xFFFF0000) >> 16
        let isDown = ((event.data1 & 0xFF00) >> 8) == 0xA
        guard [soundUp, soundDown, mute].contains(key), VolumeController.shared.isActive else {
            return Unmanaged.passUnretained(cgEvent)
        }
        if isDown {
            let fine = event.modifierFlags.contains([.option, .shift])
            DispatchQueue.main.async {
                let vc = VolumeController.shared
                switch key {
                case soundUp: vc.step(up: true, fine: fine)
                case soundDown: vc.step(up: false, fine: fine)
                default: vc.toggleMute()
                }
                HUD.shared.show()
            }
        }
        return nil // swallow the event so macOS doesn't show its "not available" HUD
    }
}

// MARK: - On-screen HUD

/// Volume bar that can be clicked, dragged and scrolled.
final class LevelView: NSView {
    var level: Double = 0 { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    private let barHeight: CGFloat = 8

    private var barRect: NSRect {
        NSRect(x: 0, y: (bounds.height - barHeight) / 2, width: bounds.width, height: barHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = barRect
        let r = bar.height / 2
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bar, xRadius: r, yRadius: r).fill()
        guard level > 0 else { return }
        var fill = bar
        fill.size.width = max(bar.height, bar.width * level)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }

    private func track(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        onChange?(max(0, min(1, x / bounds.width)))
    }
}

/// HUD background: keeps the HUD open while hovered and turns scrolling into volume changes.
final class HUDContentView: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?
    var onScroll: ((Double) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func scrollWheel(with event: NSEvent) {
        // Positive = wheel/fingers moved up, regardless of the "natural scrolling" setting.
        let raw = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        onScroll?(event.hasPreciseScrollingDeltas ? raw / 300 : raw / 20)
    }
}

final class HUD {
    static let shared = HUD()

    private let panel: NSPanel
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let levelView = LevelView()
    private var hideWork: DispatchWorkItem?
    private var hovered = false

    private init() {
        let size = NSSize(width: 300, height: 64)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let bg = HUDContentView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 18
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        icon.frame = NSRect(x: 16, y: 16, width: 32, height: 32)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .semibold)
        title.frame = NSRect(x: 58, y: 34, width: 226, height: 18)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        levelView.frame = NSRect(x: 58, y: 8, width: 226, height: 24) // taller than the bar for an easier grab
        [icon, title, levelView].forEach(bg.addSubview)

        levelView.onChange = { [weak self] value in
            VolumeController.shared.set(value)
            self?.update()
        }
        bg.onScroll = { [weak self] delta in
            let vc = VolumeController.shared
            vc.set((vc.muted ? 0 : vc.volume) + delta)
            self?.update()
        }
        bg.onHover = { [weak self] inside in
            self?.hovered = inside
            if inside { self?.hideWork?.cancel(); self?.panel.alphaValue = 1 } else { self?.scheduleHide() }
        }
    }

    private func update() {
        let vc = VolumeController.shared
        let level = vc.muted ? 0 : vc.volume
        icon.image = NSImage(systemSymbolName: StatusIcon.symbol(for: level, muted: vc.muted), accessibilityDescription: nil)
        title.stringValue = vc.display.map { "\($0.name) — \(Int((level * 100).rounded()))%" } ?? ""
        levelView.level = level
    }

    func show() {
        update()
        if !panel.isVisible, let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 12, y: f.maxY - panel.frame.height - 12))
        }
        panel.animator().alphaValue = 1
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        guard !hovered else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovered else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; self.panel.animator().alphaValue = 0 },
                                                 completionHandler: { if !self.hovered { self.panel.orderOut(nil) } else { self.panel.alphaValue = 1 } })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

// MARK: - Menu bar

enum StatusIcon {
    static func symbol(for level: Double, muted: Bool) -> String {
        if muted || level == 0 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let headerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let muteItem = NSMenuItem(title: "Без звука", action: #selector(toggleMute), keyEquivalent: "")
    private let accessItem = NSMenuItem(title: "⚠︎ Дайте доступ в «Универсальный доступ»…", action: #selector(openAccessibility), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
    private var tapStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let vc = VolumeController.shared
        vc.onChange = { [weak self] in self?.updateUI() }
        vc.refresh()

        AudioOutput.onDefaultDeviceChange { vc.refresh() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in vc.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in vc.refresh() }

        enableLaunchAtLoginOnFirstRun()
        startTapWhenTrusted(prompt: true)
    }

    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didSetUpLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            log("login item: \(error)")
        }
    }

    private func startTapWhenTrusted(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if trusted, MediaKeys.start() {
            log("event tap started")
            tapStarted = true
            updateUI()
        } else {
            updateUI()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startTapWhenTrusted(prompt: false) }
        }
    }

    private func buildMenu() {
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        slider.frame = NSRect(x: 18, y: 4, width: 204, height: 22)
        container.addSubview(slider)
        let sliderItem = NSMenuItem()
        sliderItem.view = container
        menu.addItem(sliderItem)

        muteItem.target = self
        menu.addItem(muteItem)
        menu.addItem(.separator())
        accessItem.target = self
        menu.addItem(accessItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Pick up changes made with the monitor's own buttons.
        VolumeController.shared.refresh()
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func updateUI() {
        let vc = VolumeController.shared
        let level = vc.muted ? 0 : vc.volume
        statusItem.button?.image = NSImage(systemSymbolName: vc.isActive ? StatusIcon.symbol(for: level, muted: vc.muted) : "speaker.badge.exclamationmark",
                                           accessibilityDescription: "MonitorSound")
        headerItem.title = vc.display.map { "Монитор: \($0.name) — \(Int((level * 100).rounded()))%" }
            ?? "Звук идёт не на монитор с DDC"
        slider.doubleValue = level
        slider.isEnabled = vc.isActive
        muteItem.isEnabled = vc.isActive
        muteItem.state = vc.muted ? .on : .off
        accessItem.isHidden = tapStarted
    }

    @objc private func sliderChanged() { VolumeController.shared.set(slider.doubleValue) }
    @objc private func toggleMute() { VolumeController.shared.toggleMute() }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            log("login item: \(error)")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
