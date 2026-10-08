// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import PerekeyCore

/// Records a shortcut for one action at a time and keeps what the pane shows
/// about it: the recording state, a hint and the conflicts of the last recording.
///
/// Events come from a local monitor, so only a key window of Perekey hears
/// them. `NSEvent.timestamp` and `ProcessInfo.systemUptime` share one clock,
/// which is the clock `ShortcutRecorder` expects for its double tap deadline.
@MainActor
@Observable
final class ShortcutRecording {
    private(set) var action: HotkeyAction?
    private(set) var hint: String?
    private(set) var conflictTexts: [String] = []

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var recorder = ShortcutRecorder()
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var lastStopped: (action: HotkeyAction, time: Double)?

    init(store: SettingsStore) {
        self.store = store
    }

    func toggle(_ target: HotkeyAction) {
        if action == target {
            stop()
        } else if let lastStopped, lastStopped.action == target, now - lastStopped.time < 0.5 {
            // The click that ended this recording also pressed the button.
            self.lastStopped = nil
        } else {
            start(target)
        }
    }

    func start(_ target: HotkeyAction) {
        stop()
        let others = store.settings.hotkeys.filter { $0.action != target }
        recorder = ShortcutRecorder(otherBindings: others)
        action = target
        hint = nil
        conflictTexts = []
        store.isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown]) { [weak self] event in
            let input = Input(event)
            let swallow = MainActor.assumeIsolated { self?.handle(input) ?? false }
            return swallow ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        if let action { lastStopped = (action, now) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        action = nil
        hint = nil
        store.isRecording = false
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// The parts of an `NSEvent` the recorder reads; the event itself is not `Sendable`.
    private struct Input: Sendable {
        let type: NSEvent.EventType
        let flags: UInt64
        let keyCode: UInt16
        let timestamp: Double
        let isRepeat: Bool

        init(_ event: NSEvent) {
            type = event.type
            flags = UInt64(event.modifierFlags.rawValue)
            keyCode = event.type == .leftMouseDown ? 0 : event.keyCode
            timestamp = event.timestamp
            isRepeat = event.type == .keyDown && event.isARepeat
        }
    }

    /// Returns true to swallow the event. Clicks are not swallowed: they end the
    /// recording and still reach the control under the pointer.
    private func handle(_ input: Input) -> Bool {
        guard action != nil else { return false }
        switch input.type {
        case .leftMouseDown:
            stop()
            return false
        case .flagsChanged:
            finish(recorder.modifiersChanged(to: ModifierKey.pressed(inEventFlags: input.flags), at: input.timestamp))
        case .keyDown:
            if !input.isRepeat {
                finish(recorder.keyDown(keyCode: input.keyCode, flags: input.flags, at: input.timestamp))
            }
        default:
            return false
        }
        return true
    }

    private func finish(_ result: ShortcutRecorder.Result?) {
        guard let target = action else { return }
        switch result {
        case let .recorded(trigger):
            if case .modifiers = trigger, !target.acceptsModifierOnlyTrigger {
                hint = String(localized: "This one needs a key with modifiers, not modifiers alone.")
                return
            }
            store.update { $0.setTrigger(trigger, for: target) }
            let conflicts = ShortcutConflicts.check(trigger, for: target, among: store.settings.hotkeys)
            stop()
            conflictTexts = conflicts.map(TriggerText.warning(for:))
        case .cancelled:
            stop()
        case .cleared:
            store.update { $0.setTrigger(nil, for: target) }
            stop()
        case .needsModifier:
            hint = String(localized: "Hold a modifier key together with it.")
        case nil:
            hint = nil
            scheduleDeadline()
        }
    }

    /// A single tap is final only after the double tap interval; wait for it.
    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = recorder.deadline else { return }
        let delay = max(0, deadline - now) + 0.01
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let result = recorder.deadlinePassed(at: now)
            finish(result)
        }
    }
}
