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
    private(set) var trusted: Bool

    /// The demo field. The view binds to it; retypes edit it in place.
    var demoText = ""
    private(set) var didRetype = false
    private(set) var didUndo = false

    /// The window that shows this model. The key monitor ignores other windows.
    @ObservationIgnored weak var window: NSWindow?
    /// True when the system should be asked and polled. Snapshots turn it off.
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: Any?
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
        pollTask?.cancel()
        pollTask = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: - Navigation

    var canGoForward: Bool { step != .access || trusted }

    func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        step = following
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func stepChanged() {
        guard isLive else { return }
        // Poll only while the access step shows: no timer runs for nothing.
        pollTask?.cancel()
        pollTask = nil
        if step == .access {
            trusted = AXIsProcessTrusted()
            pollTask = Task { [weak self] in
                // `AXIsProcessTrusted` can lag behind the toggle; once per second is enough.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    let now = AXIsProcessTrusted()
                    if now != trusted { trusted = now }
                }
            }
        }
        if step == .demo {
            startDemo()
        } else if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    // MARK: - Accessibility

    /// Asks macOS to list Perekey, then opens the pane where the user switches it on.
    func requestAccess() {
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

    private func startDemo() {
        demoText = ""
        didRetype = false
        didUndo = false
        machine = InputMachine(settings: store.snapshot, layouts: sources.layouts, currentLayout: sources.currentLayout)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.feed(event) }
            return event
        }
    }

    private func feed(_ event: NSEvent) {
        guard event.window != nil, event.window === window, step == .demo else { return }
        if engineIsRunning() {
            // The text field updates after this event; judge it then.
            DispatchQueue.main.async { [weak self] in self?.judge() }
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
            judge()
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
    private func judge() {
        if demoSolved { didRetype = true }
        if didRetype, demoText == "ghbdtn" { didUndo = true }
    }

    #if DEBUG
    /// Snapshot setup: show a finished demo without typing.
    func fakeSolvedDemo() {
        demoText = "привет"
        didRetype = true
        didUndo = true
    }
    #endif
}
