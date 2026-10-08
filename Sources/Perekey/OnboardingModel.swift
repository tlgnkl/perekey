// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import Observation
import PerekeyCore
import PerekeyInput

/// The state of the onboarding window: the current step, the Accessibility
/// status and the demo field.
///
/// The demo runs its own `InputMachine` on the key events of this window only.
/// The global event tap does not exist yet, and the window must prove that the
/// shortcut works before the user leaves it.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable {
        case welcome, access, preset, demo
    }

    let store: SettingsStore
    let sources: InputSources

    var step: Step {
        didSet { if step != oldValue { stepChanged() } }
    }
    /// 1 when the last move went forward, -1 backward: the way a step slides.
    private(set) var direction = 1
    private(set) var trusted: Bool
    /// The user went to System Settings and came back, and access is still off.
    private(set) var returnedWithoutAccess = false
    /// The real event tap runs, so the automatic demo can work.
    private(set) var engineReady = false

    /// The field of the shortcut demo. The view binds to it; retypes edit it in place.
    var demoText = "" {
        didSet { if demoText != oldValue { judgeRetype() } }
    }
    private(set) var didRetype = false
    private(set) var didUndo = false

    /// The field of the automatic demo: «ghbdtn» and a space become «привет» by themselves.
    var autoText = "" {
        didSet { if autoText != oldValue { judgeAuto() } }
    }
    /// The demo field with the cursor; the private machine serves the shortcut field only.
    enum DemoField { case shortcut, auto }
    var activeField = DemoField.shortcut {
        didSet {
            guard activeField != oldValue else { return }
            machine = InputMachine(settings: store.snapshot, layouts: sources.layouts, currentLayout: sources.currentLayout)
        }
    }
    private(set) var didAutoSwitch = false
    private(set) var didAutoUndo = false

    /// The window that shows this model. The key monitor ignores other windows.
    @ObservationIgnored weak var window: NSWindow?
    /// True when the system should be asked and polled. Snapshots turn it off.
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var didRequestAccess = false
    /// The window closed: nothing may start again.
    @ObservationIgnored private var stopped = false
    /// The step a move is heading to during its short delay; clicks that follow count from it.
    @ObservationIgnored private var pendingStep: Step?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var activeToken: (any NSObjectProtocol)?
    /// Tells the app that the demo is on screen: Perekey's own window then
    /// counts as «Auto» mode, and an undone demo word is not learned.
    @ObservationIgnored var demoActive: @MainActor (Bool) -> Void = { _ in }
    /// Once the real event tap runs, it retypes in the demo field like
    /// anywhere else; the private machine would retype a second time.
    @ObservationIgnored var engineIsRunning: @MainActor () -> Bool = { false }
    @ObservationIgnored private var machine: InputMachine

    init(store: SettingsStore, sources: InputSources, step: Step = .welcome, live: Bool = true) {
        self.store = store
        self.sources = sources
        self.step = step
        isLive = live
        trusted = live ? AXIsProcessTrusted() : false
        machine = InputMachine(settings: store.snapshot, layouts: sources.layouts, currentLayout: sources.currentLayout)
        stepChanged()
    }

    /// Stops polling and the key monitor. Called when the window closes.
    func stop() {
        stopped = true
        pendingStep = nil
        pollTask?.cancel()
        pollTask = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let activeToken { NotificationCenter.default.removeObserver(activeToken) }
        activeToken = nil
        demoActive(false)
    }

    // MARK: - Navigation

    var canGoForward: Bool { step != .access || trusted }

    func next() {
        guard let following = Step(rawValue: (pendingStep ?? step).rawValue + 1) else { return }
        go(to: following)
    }

    func back() {
        guard let previous = Step(rawValue: (pendingStep ?? step).rawValue - 1) else { return }
        go(to: previous)
    }

    /// Sets the direction first and moves a moment later: the step that leaves
    /// must already know which way to slide when it is removed.
    private func go(to new: Step) {
        direction = new.rawValue > (pendingStep ?? step).rawValue ? 1 : -1
        guard isLive else { step = new; return }
        pendingStep = new
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, !stopped else { return }
            step = new
            if pendingStep == new { pendingStep = nil }
        }
    }

    /// What the status pill says.
    var access: AccessStatus {
        if trusted { return .granted }
        return returnedWithoutAccess ? .denied : .waiting
    }

    enum AccessStatus { case waiting, denied, granted }

    private func stepChanged() {
        guard isLive, !stopped else { return }
        // Poll only while a step needs it: no timer runs for nothing.
        pollTask?.cancel()
        pollTask = nil
        if let activeToken { NotificationCenter.default.removeObserver(activeToken) }
        activeToken = nil
        if step == .access {
            refreshTrust()
            // Coming back from System Settings: check at once, and say so if access is still off.
            activeToken = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshTrust()
                    if self.didRequestAccess, !self.trusted { self.returnedWithoutAccess = true }
                }
            }
        }
        if step == .access || step == .demo {
            engineReady = engineIsRunning()
            pollTask = Task { [weak self] in
                // `AXIsProcessTrusted` can lag behind the toggle; once per second is enough.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    refreshTrust()
                    let running = engineIsRunning()
                    if running != engineReady { engineReady = running }
                }
            }
        }
        demoActive(step == .demo)
        if step == .demo {
            startDemo()
        } else if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func refreshTrust() {
        let now = AXIsProcessTrusted()
        if now != trusted { trusted = now }
        if now { returnedWithoutAccess = false }
    }

    // MARK: - Accessibility

    /// Asks macOS to list Perekey, then opens the pane where the user switches it on.
    func requestAccess() {
        didRequestAccess = true
        // The literal is `kAXTrustedCheckOptionPrompt`; the C global is not concurrency-safe in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Presets

    var capsLockChosen: Bool { store.settings.capsLock == .instant }

    /// Someone else already remaps Caps Lock: onboarding does not replace it silently.
    var capsLockBlocked: Bool { !capsLockChosen && CapsLockRemapper.foreignCapsLockRemap != nil }

    /// The shortcuts of the current choice, for the preset step. Caps Lock
    /// takes the place of the layout shortcut.
    var shortcutRows: [(name: String, keys: [String])] {
        var rows: [(name: String, keys: [String])] = []
        if capsLockChosen {
            rows.append((TriggerText.name(of: .switchLayout), ["Caps Lock"]))
        }
        // The pause shortcut is the same in every preset: last.
        let bindings = store.settings.hotkeys.filter { !(capsLockChosen && $0.action == .switchLayout) }
        for binding in bindings.filter({ $0.action != .toggleAutoswitch }) + bindings.filter({ $0.action == .toggleAutoswitch }) {
            rows.append((TriggerText.name(of: binding.action), TriggerText.keycaps(of: binding.trigger)))
        }
        return rows
    }

    func choose(_ preset: HotkeyPreset) {
        store.update { $0.apply(preset) }
        if capsLockChosen { store.setCapsLock(.untouched) }
    }

    func chooseCapsLock() {
        store.update { $0.apply(.standard) }
        store.setCapsLock(.instant)
    }

    // MARK: - Demo

    var retypeTrigger: Trigger? { store.settings.trigger(for: .convertLastWord) }

    var needsSecondLayout: Bool { sources.layouts.count < 2 }

    var demoSolved: Bool { demoText == "привет" }

    /// Automatic switching needs the real tap and the switch on: the private
    /// machine of this window has no language model.
    var autoSwitchOff: Bool { !store.settings.autoswitch }

    private func startDemo() {
        demoText = ""
        autoText = ""
        didRetype = false
        didUndo = false
        didAutoSwitch = false
        didAutoUndo = false
        machine = InputMachine(settings: store.snapshot, layouts: sources.layouts, currentLayout: sources.currentLayout)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.feed(event) }
            return event
        }
    }

    private func feed(_ event: NSEvent) {
        guard event.window != nil, event.window === window, step == .demo, activeField == .shortcut else { return }
        if engineIsRunning() {
            // The real tap retypes; the text fields report their changes themselves.
            return
        }
        // The system may have switched layouts under us (menu bar, another shortcut).
        if let actual = sources.currentLayout, actual != machine.currentLayout, !machine.isHolding {
            _ = machine.handle(.layoutChanged(actual))
        }
        let flags = UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
        let time = event.timestamp
        let input: InputEvent
        switch event.type {
        case .keyDown:
            input = .key(KeyEvent(.down, keyCode: event.keyCode, flags: flags, isRepeat: event.isARepeat), time: time)
        case .keyUp:
            input = .key(KeyEvent(.up, keyCode: event.keyCode, flags: flags), time: time)
        default:
            input = .flagsChanged(keyCode: event.keyCode, flags: flags, origin: .user, time: time)
        }
        for effect in machine.handle(input).effects { perform(effect) }
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case let .selectLayout(id):
            sources.select(id)
        case let .retype(retype):
            let keep = max(demoText.count - retype.deleteCount, 0)
            demoText = String(demoText.prefix(keep)) + retype.text
            // No tap and no synthetic events here, so answer the fence ourselves:
            // the last own event, then the layout confirmation.
            let now = ProcessInfo.processInfo.systemUptime
            _ = machine.handle(.key(KeyEvent(.down, keyCode: 0, origin: .own(seq: retype.seq, last: true)), time: now))
            _ = machine.handle(.layoutChanged(retype.target))
        default:
            // Selection conversion, deadlines and refusals need the real tap.
            break
        }
    }

    /// Ticks the checklist: the word became Russian, and the same shortcut turned it back.
    private func judgeRetype() {
        if demoSolved { didRetype = true }
        if didRetype, demoText == "ghbdtn" { didUndo = true }
    }

    /// The word became Russian by itself, and Backspace brought it back.
    private func judgeAuto() {
        let word = autoText.trimmingCharacters(in: .whitespaces)
        if word == "привет" { didAutoSwitch = true }
        if didAutoSwitch, word == "ghbdtn" { didAutoUndo = true }
    }

    #if DEBUG
    /// Snapshot setup: the access pill in a given state.
    func fakeAccess(_ status: AccessStatus) {
        trusted = status == .granted
        returnedWithoutAccess = status == .denied
    }

    /// Snapshot setup: show a finished demo without typing.
    func fakeSolvedDemo() {
        demoText = "привет"
        didRetype = true
        didUndo = true
    }

    /// Snapshot setup: the automatic demo mid-way (`undone` false) or finished.
    func fakeAutoDemo(undone: Bool) {
        didRetype = true
        didUndo = true
        demoText = "ghbdtn"
        autoText = undone ? "ghbdtn " : "привет "
        didAutoSwitch = true
        didAutoUndo = undone
        engineReady = true
    }
    #endif
}
