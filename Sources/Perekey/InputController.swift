// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import os
import PerekeyCore
import PerekeyInput

/// Connects the event engine to the rest of the app: layouts, settings, the
/// pause reasons, focus and Secure Input, sleep and session changes.
///
/// Runs on the main thread. The engine runs on its own tap thread; this class
/// talks to it only through `InputEngine.send(_:)` and `EngineMessage`.
@MainActor
@Observable
final class InputController {
    private(set) var tapState: TapState = .waitingForAccess

    @ObservationIgnored private let sources: InputSources
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let pause: PauseState
    @ObservationIgnored private let secureInput = SecureInputMonitor()
    @ObservationIgnored private var engine: InputEngine!
    @ObservationIgnored private var focus: FocusObserver!
    @ObservationIgnored private var selection: SelectionReader!
    @ObservationIgnored private var lastSettings: PerekeyCore.Settings
    @ObservationIgnored private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private let log = Logger(subsystem: "app.perekey", category: "input")

    init(sources: InputSources, store: SettingsStore, pause: PauseState) {
        self.sources = sources
        self.store = store
        self.pause = pause
        lastSettings = store.snapshot
        lastSettings = effectiveSettings

        let textProbe = TextProbe()
        selection = SelectionReader(probe: textProbe)
        engine = InputEngine(
            machine: InputMachine(settings: lastSettings, layouts: sources.layouts, currentLayout: sources.currentLayout),
            textProbe: textProbe
        ) { [weak self] message in self?.receive(message) }

        let engine = engine!
        sources.onLayoutsChanged = { engine.send(.layoutsChanged($0)) }
        sources.onCurrentChanged = { engine.send(.layoutChanged($0)) }
        store.onChange = { [weak self] in self?.pushSettings() }

        focus = FocusObserver { focus in
            // Called on the accessibility thread.
            engine.send(.focusChanged(focus))
            Task { @MainActor in pause.setPasswordField(focus.isKnown && focus.isSecureField) }
        }
        secureInput.onChange = { [secureInput] isOn in
            pause.setSecureInput(isOn, owner: secureInput.ownerName)
        }
        pause.setSecureInput(secureInput.isOn, owner: secureInput.ownerName)

        observeSystem()
        observePause()
        engine.start()
        focus.start()
    }

    /// The settings the tap uses: no shortcuts while the user records one, or
    /// while Perekey is paused by the user or for this app.
    private var effectiveSettings: PerekeyCore.Settings {
        var settings = store.snapshot
        let appOff: Bool = if case .appOff = pause.current { true } else { false }
        if store.isRecording || pause.isTimedPauseActive || appOff {
            settings.hotkeys = []
        }
        return settings
    }

    private func pushSettings() {
        let settings = effectiveSettings
        guard settings != lastSettings else { return }
        lastSettings = settings
        engine.send(.settingsChanged(settings))
    }

    private func observePause() {
        withObservationTracking {
            _ = pause.current
            _ = pause.isTimedPauseActive
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.pushSettings()
                self?.observePause()
            }
        }
    }

    private func receive(_ message: EngineMessage) {
        switch message {
        case let .tapState(state):
            tapState = state
        case let .select(id, then):
            let selected = sources.select(id)
            guard let then else { break }
            guard selected else {
                log.error("Cannot select \(id.rawValue, privacy: .public); retype cancelled")
                engine.cancel(then)
                break
            }
            // Selecting the layout that is already current sends no
            // notification, and the fence would wait its full timeout.
            if LayoutReader.currentLayoutID() == id { engine.send(.layoutChanged(id)) }
            engine.post(then)
        case let .autoswitchChanged(on):
            store.update { $0.autoswitch = on }
        case let .refused(refusal):
            log.info("Retype refused: \(String(describing: refusal), privacy: .public)")
        case let .convertSelection(seq):
            let reader = selection!
            let engine = engine!
            let keyCode = copyKeyCode
            Task {
                let read = await reader.read(seq: seq, copyKeyCode: keyCode)
                engine.send(.selectionRead(seq: seq, text: read.text, viaAccessibility: read.viaAccessibility))
            }
        case .secureInputChanged:
            secureInput.refresh()
        }
    }

    /// The key that types "c": ⌘C is matched on the layout macOS uses for
    /// shortcuts, the current one if it types Latin letters, else a Latin one.
    private var copyKeyCode: UInt16 {
        let current = sources.layouts.first { $0.id == sources.currentLayout }
        for map in [current].compactMap({ $0 }) + sources.layouts {
            if let stroke = map.stroke(for: "c"), stroke.modifiers.isEmpty { return stroke.keyCode }
        }
        return 8 // kVK_ANSI_C
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let engine = engine!
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            }
            tokens.append((center, token))
        }
        // A tap may come back disabled after sleep; it would silently turn
        // Perekey off. Check it and forget what was typed before.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification]
        {
            on(workspace, name) { engine.checkTaps() }
        }
        on(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) {
            engine.checkTaps()
        }
        // Leaving the session: let held keys go.
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { engine.send(.inputLost) }
        // Access can be revoked at any time; there is no notification for it.
        on(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] in
            guard let self, tapState == .running, !AXIsProcessTrusted() else { return }
            log.info("Accessibility revoked; waiting for it again")
            engine.accessRevoked()
        }
    }
}
