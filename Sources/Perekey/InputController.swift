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

    /// Follows the frontmost app and its mode. The autoswitch decision reads
    /// `appModes.mode`: `.auto` fixes by itself, `.manualOnly` only on command,
    /// `.off` never (shortcuts are already off then, see `effectiveSettings`).
    let appModes: AppModeController

    @ObservationIgnored private let sources: InputSources
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let pause: PauseState
    @ObservationIgnored private let secureInput = SecureInputMonitor()
    @ObservationIgnored private var engine: InputEngine!
    @ObservationIgnored private var focus: FocusObserver!
    @ObservationIgnored private var selection: SelectionReader!
    @ObservationIgnored private var plainPaste: PlainPaste!
    @ObservationIgnored private var lastSettings: PerekeyCore.Settings
    @ObservationIgnored private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private let log = Logger(subsystem: "app.perekey", category: "input")
    @ObservationIgnored private let hint = HintController()
    /// The correction the hint shows, so a late undo of an older one leaves it.
    @ObservationIgnored private var shownCorrection: UInt32?

    /// An automatic switch was posted. The caret hint is shown already; this
    /// is for anyone else who cares.
    @ObservationIgnored var onCorrection: ((Correction) -> Void)?
    /// The correction with this `seq` was undone.
    @ObservationIgnored var onCorrectionUndone: ((UInt32) -> Void)?
    /// An undo taught Perekey this word; it is in `AppSettings.words` already.
    @ObservationIgnored var onLearned: ((String) -> Void)?

    init(sources: InputSources, store: SettingsStore, pause: PauseState) {
        self.sources = sources
        self.store = store
        self.pause = pause
        appModes = AppModeController(sources: sources, store: store, pause: pause)
        lastSettings = store.snapshot
        lastSettings = effectiveSettings

        plainPaste = PlainPaste { [weak self] in
            PlainPaste.postCommandV(keyCode: self?.keyCode(typing: "v", fallback: 9) ?? 9) // kVK_ANSI_V
        }

        let textProbe = TextProbe()
        selection = SelectionReader(probe: textProbe)
        // Memory-mapped, so loading is quick; without a model there is no
        // automatic switching and the reason is in the log.
        let classifier = ModelStore.classifier()
        var machine = InputMachine(settings: lastSettings, layouts: sources.layouts,
                                   currentLayout: sources.currentLayout, classifier: classifier)
        _ = machine.handle(.appModeChanged(appModes.mode))
        engine = InputEngine(machine: machine, textProbe: textProbe) { [weak self] message in self?.receive(message) }

        let engine = engine!
        hint.onButtonFrame = { engine.setHintButtonFrame($0) }
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
        observeAppMode()
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

    /// The frontmost app's mode goes to the tap: only `.auto` switches by itself.
    private func observeAppMode() {
        let mode = withObservationTracking {
            appModes.mode
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAppMode() }
        }
        engine.send(.appModeChanged(mode))
    }

    /// Undoes the automatic switch the hint shows, as its Undo button does.
    func undoLastCorrection() {
        guard let shownCorrection else { return }
        engine.undoLastCorrection(seq: shownCorrection)
    }

    private func receive(_ message: EngineMessage) {
        switch message {
        case let .tapState(state):
            tapState = state
        case let .select(id, then):
            // Without a retype it is a layout shortcut; a retype has its own sound.
            if then == nil { SystemSounds.play(store.settings.layoutSound) }
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
            let copyKey = keyCode(typing: "c", fallback: 8) // kVK_ANSI_C
            Task {
                let read = await reader.read(seq: seq, copyKeyCode: copyKey)
                engine.send(.selectionRead(seq: seq, text: read.text, viaAccessibility: read.viaAccessibility))
            }
        case .secureInputChanged:
            secureInput.refresh()
        case .pastePlain:
            plainPaste.paste()
        case .retyped:
            SystemSounds.play(store.settings.correctionSound)
        case let .corrected(correction):
            if correction.undoable {
                shownCorrection = correction.seq
                let engine = engine!
                let seq = correction.seq
                // The button undoes this correction only, never a newer one.
                hint.show(original: correction.original, replacement: correction.replacement) {
                    engine.undoLastCorrection(seq: seq)
                }
            } else if shownCorrection != nil {
                // An older hint's Undo would do nothing now: take it away.
                shownCorrection = nil
                hint.hide()
            }
            onCorrection?(correction)
        case let .correctionUndone(seq):
            if shownCorrection == seq {
                shownCorrection = nil
                hint.hide()
            }
            onCorrectionUndone?(seq)
        case let .correctionUndoFailed(seq):
            // The caret moved away from the word; the text stays as it is.
            log.info("Undo of correction \(seq, privacy: .public) cancelled by the caret check")
            if shownCorrection == seq {
                shownCorrection = nil
                hint.hide()
            }
        case let .learned(word):
            learn(word)
        case .capsLockOff:
            CapsLockState.turnOff()
        }
    }

    /// Puts an undone word on the learned list and says so at the caret, with
    /// «Forget» to take it back.
    private func learn(_ word: String) {
        // The onboarding demo undoes «ghbdtn» on purpose: that teaches nothing.
        guard !(appModes.isDemoFront && AppModeController.isDemoWord(word)) else { return }
        var added = false
        store.update { added = $0.words.learn(word, at: Date().timeIntervalSince1970) }
        guard added else { return }
        hint.showLearned(word: word) { [weak self] in
            self?.store.update { $0.words.forget(word) }
            self?.hint.hide()
        }
        onLearned?(word)
    }

    /// The key that types a shortcut letter such as "c" or "v": ⌘C and ⌘V are
    /// matched on the layout macOS uses for shortcuts, the current one if it
    /// types Latin letters, else a Latin one.
    private func keyCode(typing letter: Character, fallback: UInt16) -> UInt16 {
        let current = sources.layouts.first { $0.id == sources.currentLayout }
        for map in [current].compactMap({ $0 }) + sources.layouts {
            if let stroke = map.stroke(for: letter), stroke.modifiers.isEmpty { return stroke.keyCode }
        }
        return fallback
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
