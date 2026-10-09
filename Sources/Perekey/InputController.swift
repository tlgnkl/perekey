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
    /// Language counts per app and site; the prior of the one in front goes to the tap.
    let languages: LanguageStatsStore

    @ObservationIgnored private let sources: InputSources
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let pause: PauseState
    @ObservationIgnored private let secureInput = SecureInputMonitor()
    @ObservationIgnored private var engine: InputEngine!
    @ObservationIgnored private var focus: FocusObserver!
    @ObservationIgnored private var selection: SelectionReader!
    @ObservationIgnored private var plainPaste: PlainPaste!
    @ObservationIgnored private var lastSettings: PerekeyCore.Settings
    /// The languages the classifier was loaded for, and its model.
    @ObservationIgnored private var modelLanguages: Set<String> = []
    @ObservationIgnored private var model: LanguageModel?
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
    /// The user retyped by hand (a shortcut or a selection). Carries no text.
    @ObservationIgnored var onManualRetype: (() -> Void)?
    /// Corrections of the onboarding demo, by `seq`: they count for nothing,
    /// neither the menu's list nor the statistics, nor their undo.
    @ObservationIgnored private var demoCorrections = Set<UInt32>()

    init(sources: InputSources, store: SettingsStore, pause: PauseState,
         languages: LanguageStatsStore = LanguageStatsStore())
    {
        self.sources = sources
        self.store = store
        self.pause = pause
        self.languages = languages
        appModes = AppModeController(sources: sources, store: store, pause: pause)
        lastSettings = store.snapshot
        lastSettings = effectiveSettings

        plainPaste = PlainPaste { [weak self] in
            PlainPaste.postCommandV(keyCode: self?.keyCode(typing: "v", fallback: 9) ?? 9) // kVK_ANSI_V
        }

        let textProbe = TextProbe()
        selection = SelectionReader(probe: textProbe)
        // Memory-mapped, so loading is quick; without a model there is no
        // automatic switching and the reason is in the log. Only the
        // languages of the installed layouts are mapped.
        modelLanguages = ModelStore.languages(of: sources.layouts)
        model = ModelStore.model(languages: modelLanguages)
        let classifier = model.map { Classifier(model: $0) }
        var machine = InputMachine(settings: lastSettings, layouts: sources.layouts,
                                   currentLayout: sources.currentLayout, classifier: classifier)
        _ = machine.handle(.appModeChanged(appModes.mode))
        engine = InputEngine(machine: machine, textProbe: textProbe) { [weak self] message in self?.receive(message) }

        let engine = engine!
        hint.onButtonFrame = { engine.setHintButtonFrame($0) }
        sources.onLayoutsChanged = { [weak self] layouts in
            engine.send(.layoutsChanged(layouts))
            self?.loadModel(for: layouts)
        }
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
        // After start: before it the tap thread has no run loop, and the
        // context of the first app would be dropped.
        observeLanguageContext()
        focus.start()
    }

    /// Maps the files of languages that came with new layouts and lets the
    /// files of removed ones go: the tap drops its classifier for the new one.
    private func loadModel(for layouts: [LayoutMap]) {
        let languages = ModelStore.languages(of: layouts)
        guard languages != modelLanguages else { return }
        modelLanguages = languages
        model = ModelStore.model(languages: languages, reusing: model)
        engine.send(.classifierChanged(model.map { Classifier(model: $0) }))
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

    /// The app and site in front go to the tap with the prior of their
    /// counts; again whenever the counts change.
    private func observeLanguageContext() {
        let context = withObservationTracking {
            languageContext
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLanguageContext() }
        }
        engine.send(.languageContextChanged(context))
    }

    private var languageContext: LanguageContext {
        // The onboarding demo types its own words: they count for no app.
        guard !appModes.isDemoFront, let app = appModes.frontmost?.bundleID else {
            return LanguageContext(generation: languages.stats.generation)
        }
        let site = SiteObserver.browserBundleIDs.contains(app) ? appModes.frontHost : nil
        return languages.context(app: app, site: site)
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
        case let .retyped(original, text, origin, decision):
            SystemSounds.play(store.settings.correctionSound)
            // An automatic switch has its own hint, from `corrected`; an undo hides it.
            if manualAction(of: origin) != nil, !isDemo(original, text) { onManualRetype?() }
            if let manual = manualAction(of: origin), store.settings.caretHint.shows(automatic: false),
               original != text
            {
                var why: HintWhy?
                if let decision {
                    let explanation = Explanation(decision: decision, typed: original, other: text)
                    why = HintWhy(title: ExplanationText.title(switched: explanation.switched),
                                  lines: ExplanationText.lines(explanation))
                }
                var onAlwaysFix: (() -> Void)?
                if let decision, offersAlwaysFix(decision, original: original, text: text) {
                    onAlwaysFix = { [weak self] in self?.confirmAlwaysFix(text, typed: original) }
                }
                hint.showRetyped(original: original, word: text,
                                 shortcut: manual.onSelection ? nil : shortcut(of: manual.action), why: why,
                                 onAlwaysFix: onAlwaysFix)
                shownCorrection = nil
            }
        case let .corrected(correction):
            if !store.settings.caretHint.shows(automatic: true) {
                // Hint off: Backspace still undoes it.
            } else if correction.undoable {
                shownCorrection = correction.seq
                let engine = engine!
                let seq = correction.seq
                // The button undoes this correction only, never a newer one.
                hint.show(original: correction.original, replacement: correction.replacement) {
                    engine.undoLastCorrection(seq: seq)
                }
            } else {
                // An older hint, its Undo or a manual retype's buttons, would
                // do nothing useful now: take it away.
                shownCorrection = nil
                hint.hide()
            }
            if isDemo(correction.original, correction.replacement) {
                demoCorrections.insert(correction.seq)
            } else {
                onCorrection?(correction)
            }
        case let .correctionUndone(seq):
            if shownCorrection == seq {
                shownCorrection = nil
                hint.hide()
            }
            if demoCorrections.remove(seq) == nil { onCorrectionUndone?(seq) }
        case let .correctionUndoFailed(seq):
            // The caret moved away from the word; the text stays as it is.
            log.info("Undo of correction \(seq, privacy: .public) cancelled by the caret check")
            if shownCorrection == seq {
                shownCorrection = nil
                hint.hide()
            }
        case let .learned(word):
            learn(word)
        case let .alwaysFixWithdrawn(word):
            store.update { $0.words.stopFixing(word) }
            // After the `correctionUndone` of the same undo, which hid the old hint.
            if store.settings.caretHint != .off { hint.showAlwaysFixWithdrawn(word: word) }
        case .capsLockOff:
            CapsLockState.turnOff()
        case let .languagesCounted(tally):
            // The demo's words count for no app, whatever the context said.
            if !appModes.isDemoFront { languages.record(tally) }
        }
    }

    /// Puts an undone word on the learned list and says so at the caret, with
    /// «Forget» to take it back.
    private func learn(_ word: String) {
        // The onboarding demo undoes «ghbdtn» on purpose: that teaches nothing.
        guard !(appModes.isDemoFront && AppModeController.isDemoWord(word)) else { return }
        var added = false
        let readings = WordRules.readings(of: word, in: sources.layouts)
        store.update { added = $0.words.learn(word, at: Date().timeIntervalSince1970, readings: readings) }
        guard added else { return }
        guard store.settings.caretHint != .off else { return }
        hint.showLearned(word: word) { [weak self] in
            self?.store.update { $0.words.forget(word) }
            self?.hint.hide()
        }
    }

    /// Puts a word on "Всегда исправлять": from now on it switches at the
    /// word end whatever the score, unless a guard keeps it. `word` is the
    /// form it should come out in, `typed` what the user typed (a learned
    /// copy of it, or of another reading in the installed layouts, is forgotten). For the hint after a manual retype, when
    /// `WordRules.offerAlwaysFix` says so. Returns false when the word is
    /// invalid, already there, or on "Не трогать: мои".
    @discardableResult
    func alwaysFix(_ word: String, typed: String? = nil) -> Bool {
        var added = false
        let readings = WordRules.readings(of: word, in: sources.layouts)
        store.update { added = $0.words.alwaysFix(word, typed: typed, readings: readings) }
        return added
    }

    /// Whether the hint after this manual retype offers «Always fix»
    /// (`WordRules.offerAlwaysFix`): the word is on no list, in either reading.
    private func offersAlwaysFix(_ decision: Classifier.Decision, original: String, text: String) -> Bool {
        let words = store.settings.words
        let listed = words.section(of: original) != nil || words.section(of: text) != nil
        return WordRules.offerAlwaysFix(
            decision: decision,
            context: WordRules.OfferContext(autoswitch: store.settings.autoswitch, appMode: appModes.mode, listed: listed)
        )
    }

    /// «Always fix» was pressed: list the word and say so, with «Undo».
    private func confirmAlwaysFix(_ word: String, typed: String) {
        guard alwaysFix(word, typed: typed) else {
            hint.hide()
            return
        }
        hint.showAlwaysFixed(word: word) { [weak self] in
            guard let self else { return }
            store.update { $0.words.stopFixing(word) }
            if store.settings.caretHint != .off { hint.showAlwaysFixWithdrawn(word: word) }
        }
    }

    /// The onboarding demo's own words: they are corrected and undone for the
    /// show, and leave no trace in the lists of corrections or the counts.
    private func isDemo(_ typed: String, _ other: String) -> Bool {
        appModes.isDemoFront && (AppModeController.isDemoWord(typed) || AppModeController.isDemoWord(other))
    }

    private func manualAction(of origin: Retype.Origin) -> (action: HotkeyAction, onSelection: Bool)? {
        switch origin {
        case let .manual(action): (action, false)
        case let .manualSelection(action): (action, true)
        case .automatic, .undo: nil
        }
    }

    /// The user's own shortcut, as keycaps, to press again and put the word
    /// back. Only the retype of a word does that: the next press of the case
    /// shortcut changes the case again, and a selection is gone once typed over.
    private func shortcut(of action: HotkeyAction) -> String? {
        guard action == .convertLastWord, let trigger = store.settings.trigger(for: action) else { return nil }
        return TriggerText.keycaps(of: trigger).joined(separator: " ")
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
