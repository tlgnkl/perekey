// SPDX-License-Identifier: GPL-3.0-or-later

/// All of Perekey's input logic as a state machine: events in, effects out.
///
/// The system layer only delivers `InputEvent`s and carries out the `Effect`s,
/// so every behavior can be tested on recorded event sequences without a
/// keyboard. `handle(_:)` runs on the event tap thread for every key press:
/// keep it free of I/O, locks and allocations in the common path.
///
/// **The fence.** A layout switch reaches the application asynchronously, so
/// keys typed right after a retype could land in the old layout or between the
/// synthetic keys. After a retype the machine holds user keyboard input until
/// the tap has seen the last synthetic event and the system has confirmed the
/// layout change, or until `Settings.fenceTimeout` has passed. Held events
/// come back as `.replayed` and are handled as usual. A replayed event can
/// start a new retype; the replayed events after it are held again, or they
/// would overtake that retype.
///
/// Converting a selection starts the fence at once, before the text is known:
/// the system layer reads the selection (`Effect.convertSelection`), answers
/// with `.selectionRead`, and from there it goes like a word retype. Keys the
/// user types meanwhile are held the whole time.
///
/// Clicks cannot be held: the mouse tap only listens, since an active mouse
/// tap would delay all pointer input. A click during the fence reaches the
/// app before the held keys. The fence lasts milliseconds, so this is rare.
///
/// **Automatic switching** (docs/classifier.md, «Автопереключение») uses the
/// same fence. The key that ends a word (space, sentence punctuation, Return,
/// Tab) is held, the word is judged by the `Classifier`, and on
/// `.switch(to:)` the word is retyped in the target layout. The held key and
/// everything typed after it come back as `.replayed` once the new layout has
/// reached the app, so they land in it: fast "ghbdtn vbh" gives "привет мир".
/// Inside a word only an impossible prefix ("ghb") switches early: the
/// letters before it are retyped and the key that made it impossible is held.
/// Backspace right after a switch puts the word back (`Effect.learned` when
/// the user wants Perekey to learn from that). The undo is a retype like any
/// other: it reports only once posted, and when the caret check cancels it,
/// the Backspace goes through as an ordinary one.
public struct InputMachine: Sendable {
    public private(set) var settings: Settings
    public private(set) var buffer = WordBuffer()
    /// The layout Perekey believes is selected: the last one it selected, or
    /// the last one the system reported.
    public private(set) var currentLayout: LayoutID? {
        didSet { currentMap = currentLayout.flatMap { layouts[$0] } }
    }
    /// The table of `currentLayout`, looked up once per change, not per key.
    private var currentMap: LayoutMap?

    private var detector: ChordDetector<HotkeyAction>
    /// Key triggers, with modifiers as a `kindMask` so matching does not allocate.
    private var keyHotkeys: [(keyCode: UInt16, modifiers: UInt8, action: HotkeyAction)] = []
    private var layouts: [LayoutID: LayoutMap] = [:]
    private var layoutOrder: [LayoutID] = []
    private var previousLayout: LayoutID?
    /// Layouts Perekey selected that the system has not confirmed yet, oldest
    /// first. A late confirmation of an earlier one must not undo a later one.
    private var pendingSelections: [LayoutID] = []
    /// The layout the system last reported as selected.
    private var confirmedLayout: LayoutID?
    private var secureInput = false
    private var focus: Focus?
    private var fence: Fence?
    private var nextSeq: UInt32 = 1
    /// Key ups of keys that ran a shortcut on key down: swallow them too.
    private var swallowedKeyUps: Set<UInt16> = []

    // Automatic switching
    private var classifier: Classifier?
    private var appMode: AppMode = .auto
    /// The language of the last judged word: context for the next one.
    private var previousLanguage: String?
    /// The word in the buffer was judged at a boundary and nothing was added
    /// since: "hello!" and then a space is not judged twice.
    private var wordJudged = false
    /// No automatic switching for the rest of this word: the user undid a
    /// switch, retyped the word by hand, or the switch was cancelled.
    private var wordSuppressed = false
    /// A switch inside this word was undone: learn the whole word at its end.
    private var learnAtWordEnd = false
    /// The key held by an automatic switch. Its replay belongs to the switch:
    /// it is neither judged again nor counts as typing after the correction.
    private var heldBoundary: (keyCode: UInt16, endsWord: Bool)?
    /// The last automatic switch, while Backspace or the undo action can
    /// still take it back. Anything that may move the caret or change the
    /// text ends it: a key that does not continue the word, a click outside
    /// the hint's button, a shortcut, a focus change.
    private var lastCorrection: PendingCorrection?
    /// The Backspace that asked for an undo is held, and the undo was posted:
    /// drop the Backspace when it comes back. After a cancelled undo it comes
    /// back as an ordinary Backspace.
    private var dropUndoKey = false

    // Word corrections at the boundary (stage 4)
    /// Typo correction over the model of `classifier`; nil without a model.
    private var typoCorrector: TypoCorrector?
    /// The next word starts a sentence (after `. ! ?`, a line end or a focus
    /// change): a capital there is no name.
    private var sentenceStart = true

    private struct Fence: Sendable {
        var seq: UInt32
        var lastOwnEventSeen = false
        /// The layout whose selection the system has not confirmed yet.
        var awaitedLayout: LayoutID?
        var deadline: Double
        /// The layout to go back to if the retype is cancelled.
        var layoutBefore: LayoutID?
        /// The selection is being read; `.selectionRead` has not come yet.
        var awaitsSelection = false
        /// The retype replaces the selection through accessibility: no own
        /// events will come, `.retypePosted` stands for the last one.
        var viaAccessibility = false
        /// What to do with the selection once it is read.
        var selectionAction = SelectionAction.convertLayout
        /// An automatic switch: reported as `.corrected` once posted.
        var correction: PendingCorrection?
        /// An undo of one: reported as `.correctionUndone` once posted.
        var undo: UndoInFlight?
    }

    /// What an undo reports once its retype is posted. Nothing of it happens
    /// before: a cancelled undo leaves the text corrected and learns nothing.
    private struct UndoInFlight: Sendable {
        /// The `Correction.seq` being undone.
        var seq: UInt32
        /// `.corrected` went out, so the hint shows it.
        var reported: Bool
        /// Only the start of the word is known: learn it when it ends.
        var isOpen: Bool
        /// The word to learn, if `Settings.learnFromUndos`.
        var learn: String?
        /// The Backspace that asked for the undo is the first held event.
        var heldKey: Bool
    }

    /// The transform a shortcut applies to the selection.
    private enum SelectionAction: Sendable {
        /// Retype in the other layout (`convertLastWord`).
        case convertLayout
        /// Next case of the cycle (`changeCase`).
        case changeCase
        /// Other script (`transliterate`).
        case transliterate
    }

    /// What it takes to undo an automatic switch.
    ///
    /// A switch at a word's end is closed at once. A switch inside the word
    /// stays open while the word goes on: the letters typed after it join
    /// it, and the key that ends the word closes it and reports it, so the
    /// hint and the undo cover the whole word ("ghbdtn" → "привет").
    private struct PendingCorrection: Sendable {
        var correction: Correction
        /// The strokes to put back: the word, plus the key that ended it when
        /// that key typed a character (space, punctuation).
        var strokes: [KeyStroke]
        /// How many of `strokes` are the word itself.
        var wordLength: Int
        /// The word is still being typed.
        var isOpen: Bool
        /// Letters were typed after the switch: Backspace now fixes a typo,
        /// it does not undo, until the word ends.
        var extended = false
        /// `.corrected` went out, so an undo reports `.correctionUndone`.
        var reported = false
        /// False after a click on the hint's button: the hint's Undo still
        /// works, Backspace is an ordinary one.
        var backspaceUndoes = true
        /// A click outside the hint came while the retype was in flight: the
        /// caret may have moved, so the switch cannot be undone or extended.
        var clicked = false
        /// The strokes that stand for the word in the text now, when a word
        /// correction changed them (a typo fixed: "прривет" became "привет").
        /// Nil when they are the word's own strokes. The undo deletes these
        /// and types `strokes` back.
        var typed: [KeyStroke]?
    }

    /// A word-level correction of the word in its layout (`correctWord`).
    private struct WordFix {
        /// The keys that type the corrected word.
        var strokes: [KeyStroke]
        var kind: Correction.Kind
    }

    /// The synthetic keys of a word retype, or why there are none.
    private enum WordKeys {
        case keys((keys: [Retype.Key], expected: String))
        case refused(Refusal)
    }

    /// Everything automatic switching needs, or nothing when it must not act.
    private struct AutoContext {
        var classifier: Classifier
        var typed: LayoutMap
        var other: LayoutMap
    }

    /// Everything typo correction needs in the current layout, or nothing
    /// when it must not act.
    private struct TypoContext {
        var corrector: TypoCorrector
        var typed: LayoutMap
    }

    public init(settings: Settings = Settings(), layouts: [LayoutMap] = [], currentLayout: LayoutID? = nil,
                classifier: Classifier? = nil)
    {
        self.settings = settings
        detector = ChordDetector(bindings: [])
        self.classifier = classifier
        typoCorrector = classifier.map { TypoCorrector(model: $0.model) }
        apply(settings)
        setLayouts(layouts)
        self.currentLayout = currentLayout
        currentMap = currentLayout.flatMap { self.layouts[$0] }
        confirmedLayout = currentLayout
    }

    /// Whether user input is being held back right now.
    public var isHolding: Bool { fence != nil }

    /// The retype the fence waits for; post a retype only while this is its `seq`.
    public var pendingRetypeSeq: UInt32? { fence?.seq }

    public mutating func handle(_ event: InputEvent) -> Output {
        var effects: [Effect] = []
        let output = handle(event, effects: &effects)
        return Output(output, effects)
    }

    private mutating func handle(_ event: InputEvent, effects: inout [Effect]) -> Disposition {
        switch event {
        case let .key(key, time):
            // A user key that arrives after the deadline joins the held keys,
            // or it would overtake them.
            if expireFence(at: time, effects: &effects), !key.origin.isOwn { return .hold }
            return handleKey(key, at: time, effects: &effects)

        case let .flagsChanged(keyCode, flags, origin, time):
            if expireFence(at: time, effects: &effects), !origin.isOwn { return .hold }
            if case .own = origin { return .pass }
            if fence != nil { return .hold }
            guard !secureInput else { return .pass }
            if keyCode == KeyCode.capsLock {
                detector.otherInput(at: time)
            } else if let action = detector.modifiersChanged(to: Self.modifiers(keyCode: keyCode, flags: flags),
                                                             at: time)
            {
                perform(action, at: time, effects: &effects)
            }
            return .pass

        case let .click(time, onHint):
            expireFence(at: time, effects: &effects)
            detector.otherInput(at: time)
            buffer.clear()
            if onHint, lastCorrection?.isOpen == false {
                // The hint's button takes the click and the caret stays; the
                // Undo it sends comes next. Backspace is an ordinary one now.
                lastCorrection?.backspaceUndoes = false
            } else {
                // The caret may be anywhere now: an undo would erase text
                // there, and the next letters are no part of the word.
                lastCorrection = nil
                if !onHint { fence?.correction?.clicked = true }
            }

        case let .scroll(time):
            detector.otherInput(at: time)

        case let .focusChanged(newFocus):
            focus = newFocus
            buffer.clear()
            previousLanguage = nil
            sentenceStart = true
            lastCorrection = nil

        case let .layoutChanged(id):
            confirmedLayout = id
            if let index = pendingSelections.firstIndex(of: id) {
                pendingSelections.removeSubrange(...index)
            } else {
                // Someone else switched: the user from the menu, or another app.
                pendingSelections.removeAll()
                if id != currentLayout {
                    if let currentLayout, layouts[currentLayout] != nil { previousLayout = currentLayout }
                    currentLayout = id
                }
            }
            if layouts[id] == nil { buffer.clear() }
            if fence?.awaitedLayout == id {
                fence?.awaitedLayout = nil
                releaseIfDone(effects: &effects)
            }

        case let .layoutsChanged(maps):
            setLayouts(maps)
            buffer.clear()
            lastCorrection = nil

        case let .secureInputChanged(isOn):
            // Key presses do not reach the tap under Secure Input, but modifier
            // changes do: every capital letter of a password would look like a
            // Shift tap. Keep the detector off until Secure Input ends.
            secureInput = isOn
            detector.reset()
            buffer.clear()
            swallowedKeyUps.removeAll()
            lastCorrection = nil

        case let .retypePosted(seq, time):
            guard let posted = fence, posted.seq == seq, !posted.awaitsSelection else { break }
            let deadline = time + settings.fenceTimeout
            fence?.deadline = deadline
            effects.append(.scheduleDeadline(at: deadline))
            if var pending = posted.correction {
                fence?.correction = nil
                if pending.clicked { pending.correction.undoable = false }
                if !pending.isOpen {
                    pending.reported = true
                    effects.append(.corrected(pending.correction))
                }
                lastCorrection = pending.clicked ? nil : pending
            }
            if let undo = posted.undo {
                fence?.undo = nil
                if undo.reported { effects.append(.correctionUndone(seq: undo.seq)) }
                if undo.isOpen {
                    learnAtWordEnd = true
                } else if let word = undo.learn {
                    effects.append(.learned(word))
                }
                dropUndoKey = undo.heldKey
            }
            if posted.viaAccessibility {
                fence?.lastOwnEventSeen = true
                releaseIfDone(effects: &effects)
            }

        case let .selectionRead(seq, text, viaAccessibility):
            guard let pending = fence, pending.seq == seq, pending.awaitsSelection else { break }
            retypeSelection(text, viaAccessibility: viaAccessibility, effects: &effects)

        case let .retypeCancelled(seq):
            // The text before the caret was not what the buffer expected, so
            // the buffer is wrong too. Put the layout back and let input go.
            guard let cancelled = fence, cancelled.seq == seq else { break }
            if let undo = cancelled.undo {
                // The caret is not after the corrected word: the text stays,
                // nothing is learned, and the held Backspace comes back as an
                // ordinary one. The hint's Undo could not work either.
                if undo.reported { effects.append(.correctionUndoFailed(seq: undo.seq)) }
                buffer.abandonWord()
                wordSuppressed = true
            } else if cancelled.correction != nil {
                // The held key comes back next and may finish an impossible
                // prefix again: ignore the rest of this word.
                buffer.abandonWord()
                wordSuppressed = true
            } else {
                buffer.clear()
            }
            if let layout = cancelled.layoutBefore { select(layout, effects: &effects) }
            release(effects: &effects)

        case let .settingsChanged(newSettings):
            apply(newSettings)

        case .inputLost:
            detector.reset()
            buffer.clear()
            swallowedKeyUps.removeAll()
            previousLanguage = nil
            heldBoundary = nil
            lastCorrection = nil
            release(effects: &effects)

        case let .deadline(time):
            expireFence(at: time, effects: &effects)

        case let .appModeChanged(mode):
            appMode = mode

        case let .classifierChanged(newClassifier):
            classifier = newClassifier
            typoCorrector = newClassifier.map { TypoCorrector(model: $0.model) }
            previousLanguage = nil

        case let .undoLastCorrection(seq, time):
            // A hint left over from an older switch must not undo a newer one.
            guard lastCorrection?.correction.seq == seq else { break }
            undoCorrection(at: time, heldKey: false, effects: &effects)
        }
        return .pass
    }

    // MARK: - Keys

    private mutating func handleKey(_ key: KeyEvent, at time: Double, effects: inout [Effect]) -> Disposition {
        switch key.origin {
        case let .own(seq, last):
            if last, fence?.seq == seq {
                fence?.lastOwnEventSeen = true
                releaseIfDone(effects: &effects)
            }
            return .pass
        case .user, .replayed:
            if fence != nil { return .hold }
        }
        if dropUndoKey, key.phase == .down {
            // The held events come back in order, the Backspace first.
            dropUndoKey = false
            if key.origin == .replayed, key.keyCode == KeyCode.delete {
                swallowedKeyUps.insert(key.keyCode)
                return .drop
            }
        }
        guard !secureInput else { return .pass }

        if key.phase == .up {
            detector.keyReleased()
            return swallowedKeyUps.remove(key.keyCode) != nil ? .drop : .pass
        }

        detector.otherInput(at: time)
        // F-keys and arrows always carry the fn bit, so fn never takes part.
        let held = ModifierKind.kindMask(inEventFlags: key.flags) & ~ModifierKind.function.maskBit
        if let hotkey = keyHotkeys.first(where: { $0.keyCode == key.keyCode && $0.modifiers == held }) {
            swallowedKeyUps.insert(key.keyCode)
            if !key.isRepeat { perform(hotkey.action, at: time, effects: &effects) }
            return .drop
        }
        // Auto-repeat of a key whose press was swallowed (the undoing Backspace).
        if key.isRepeat, swallowedKeyUps.contains(key.keyCode) { return .drop }

        // The key an automatic switch held comes back first after the fence.
        var isHeldBoundary = false
        var heldEndsWord = false
        if let boundary = heldBoundary {
            heldBoundary = nil
            isHeldBoundary = key.keyCode == boundary.keyCode && key.origin == .replayed
            heldEndsWord = boundary.endsWord
        }
        // Any other key ends the chance to undo, except Backspace, which is
        // the undo, and the rest of a word switched inside it.
        var extendsCorrection = false
        if !isHeldBoundary, let last = lastCorrection {
            lastCorrection = nil
            if key.keyCode == KeyCode.delete, held == 0, last.backspaceUndoes, !(last.isOpen && last.extended) {
                lastCorrection = last
                // Held, not dropped: if the undo is cancelled, the Backspace
                // still does what the user pressed it for.
                if undoCorrection(at: time, heldKey: true, effects: &effects) { return .hold }
            } else if last.isOpen, key.keyCode != KeyCode.delete, !KeyCode.navigation.contains(key.keyCode),
                      held & (ModifierKind.command.maskBit | ModifierKind.control.maskBit) == 0
            {
                lastCorrection = last
                extendsCorrection = true
            }
        }

        if !isHeldBoundary, judgeWord(endedBy: key, held: held, at: time, effects: &effects) {
            return .hold
        }
        updateBuffer(with: key, held: held)
        if extendsCorrection { extendCorrection(with: key, effects: &effects) }
        if isHeldBoundary {
            // The word it ended was judged already; a held letter continues it.
            if heldEndsWord { wordJudged = true }
        } else if switchInsideWord(at: time, effects: &effects) {
            return .hold
        }
        return .pass
    }

    private mutating func updateBuffer(with key: KeyEvent, held: UInt8) {
        if held & (ModifierKind.command.maskBit | ModifierKind.control.maskBit) != 0
            || KeyCode.navigation.contains(key.keyCode)
            || focus?.isSecureField == true
        {
            buffer.clear()
            return
        }
        if key.keyCode == KeyCode.delete {
            if held & ModifierKind.option.maskBit != 0 { buffer.clear() } else { buffer.deleteBackward() }
            wordJudged = false
            return
        }
        let stroke = KeyStroke(key.keyCode, LayoutModifiers(eventFlags: key.flags))
        guard let currentLayout, let map = currentMap else {
            buffer.clear()
            return
        }
        if map.isDeadKey(stroke) {
            // A dead key and the next key make one character, so keys and
            // characters no longer match one to one. Give up on this word.
            buffer.abandonWord()
        } else if map.text(for: stroke) != nil {
            if stroke.keyCode != KeyCode.space {
                if buffer.isEmpty || buffer.entries.last?.isSpace == true {
                    // A new word: whatever was decided about the last one is over.
                    wordSuppressed = false
                    learnAtWordEnd = false
                }
                wordJudged = false
            }
            buffer.type(stroke, in: currentLayout)
        } else {
            buffer.clear()
        }
    }

    // MARK: - Automatic switching

    /// The flags that let automatic switching act, without any lookup: the
    /// per-key path checks this first.
    private var autoswitchMayAct: Bool {
        settings.autoswitch && appMode == .auto && classifier != nil
    }

    /// Automatic switching may act now, between this layout and its counterpart.
    private func autoContext() -> AutoContext? {
        guard settings.autoswitch, appMode == .auto, !secureInput, let classifier,
              let focus, focus.isKnown, !focus.isSecureField,
              let currentLayout, let typed = currentMap,
              let otherID = counterpart(of: currentLayout), let other = layouts[otherID],
              typed.language != other.language
        else { return nil }
        return AutoContext(classifier: classifier, typed: typed, other: other)
    }

    /// Every key of the word typed in the current layout, without ⌥.
    private func wordIsPlain() -> Bool {
        guard let currentLayout else { return false }
        for entry in buffer.entries where entry.layout != currentLayout || entry.stroke.modifiers.contains(.option) {
            return false
        }
        return true
    }

    /// At a key that ends the word: judge the word, and on a switch retype it
    /// and hold the key. Returns true when the key is to be held.
    ///
    /// The word-boundary pipeline (docs/PLAN.md, «Этап 4»): first the layout
    /// is decided, then the word in the layout decided for it goes through the
    /// word corrections (`correctWord`). A typo in the wrong layout is fixed
    /// by the one retype that switches the layout.
    private mutating func judgeWord(endedBy key: KeyEvent, held: UInt8, at time: Double,
                                    effects: inout [Effect]) -> Bool
    {
        // Cheap exits first: this runs on every key press.
        guard autoswitchMayAct || typoMayAct, !wordJudged, let last = buffer.entries.last, !last.isSpace,
              held & (ModifierKind.command.maskBit | ModifierKind.control.maskBit | ModifierKind.option.maskBit) == 0
        else { return false }
        let endsLine = key.keyCode == KeyCode.return || key.keyCode == KeyCode.tab
            || key.keyCode == KeyCode.keypadEnter
        let stroke = KeyStroke(key.keyCode, LayoutModifiers(eventFlags: key.flags))
        guard let typed = currentMap,
              endsLine || stroke.keyCode == KeyCode.space || Self.isPunctuation(stroke, in: typed)
        else { return false }
        let auto = autoContext()
        let typo = typoContext()
        guard auto != nil || typo != nil else { return false }
        // Russian letters sit on punctuation keys: the other layout says
        // whether the key ends the word.
        let other = auto?.other ?? currentLayout.flatMap(counterpart).flatMap { layouts[$0] } ?? typed
        guard endsLine || Self.endsWord(stroke, typed: typed, other: other) else { return false }
        if !endsLine, stroke.keyCode != KeyCode.space,
           buffer.entries.dropFirst().contains(where: { $0.stroke.modifiers.contains(.shift) })
        {
            // "ghBdtn!x" may be a password: its symbol is the "!". Wait for the
            // space, where the classifier sees the whole token.
            return false
        }
        wordJudged = true
        // The word after this key starts a sentence after `. ! ?` or a line
        // end. The space after "hello." judges the word again: the period is
        // in the buffer then.
        let startsSentence = endsLine || Self.endsSentence(stroke, in: typed)
            || (stroke.keyCode == KeyCode.space && Self.endsSentence(last.stroke, in: typed))
        defer { sentenceStart = startsSentence }

        if wordSuppressed {
            if learnAtWordEnd {
                learnAtWordEnd = false
                if settings.learnFromUndos,
                   let word = Self.learnable(text(of: buffer.entries, in: typed), or: text(of: buffer.entries, in: other))
                {
                    effects.append(.learned(word))
                }
            }
            previousLanguage = typed.language
            return false
        }
        guard wordIsPlain() else { return false }

        // The held key goes back into the text after the word; Return and Tab
        // end the line, so there is nothing to undo after them.
        let boundary: KeyStroke? = endsLine ? nil : stroke
        if let auto {
            let decision = auto.classifier.classify(
                buffer.entries.lazy.map(\.stroke), typed: auto.typed, other: auto.other,
                context: Classifier.Context(previousLanguage: previousLanguage)
            )
            if decision.verdict == .switch(to: auto.other.id) {
                if isException(auto) {
                    previousLanguage = auto.typed.language
                    return false
                }
                guard autoRetype(auto, held: boundary, heldKeyCode: key.keyCode, midWord: false, undoable: !endsLine,
                                 at: time, effects: &effects)
                else { return false }
                previousLanguage = auto.other.language
                return true
            }
            previousLanguage = decision.language
        } else {
            previousLanguage = typed.language
        }
        // The word stays in its layout: fix it there.
        guard let typo, !isException(in: typo.typed) else { return false }
        return typoRetype(typo, held: boundary, heldKeyCode: key.keyCode, undoable: !endsLine, at: time,
                          effects: &effects)
    }

    // MARK: - Word corrections

    /// The flags that let typo correction act, without any lookup.
    private var typoMayAct: Bool {
        settings.typoCorrection && appMode == .auto && typoCorrector != nil
    }

    /// Typo correction may act now, in the current layout. The same gates as
    /// automatic switching: never in «manual only» or «off», in a password
    /// field, on an unknown focus or under Secure Input.
    private func typoContext() -> TypoContext? {
        guard settings.typoCorrection, appMode == .auto, !secureInput, let typoCorrector,
              let focus, focus.isKnown, !focus.isSecureField,
              let typed = currentMap, typed.language != nil
        else { return nil }
        return TypoContext(corrector: typoCorrector, typed: typed)
    }

    /// The word corrections at a word boundary, in order, on the word in the
    /// layout decided for it (`map`). The first step that changes the word
    /// wins; each step is off by its own setting. Steps:
    /// 1. Typos: one key off (`TypoCorrector`, `Settings.typoCorrection`).
    /// 2. Dictionary corrections (double capitals, Caps Lock, abbreviations,
    ///    ё) go here, after typos: they expect a word the dictionary knows.
    private func correctWord(_ entries: [WordBuffer.Entry], in map: LayoutMap) -> WordFix? {
        if settings.typoCorrection, let typoCorrector,
           let candidate = typoCorrector.correct(entries.lazy.map(\.stroke), in: map, sentenceStart: sentenceStart)
        {
            return WordFix(strokes: candidate.strokes, kind: .typo)
        }
        return nil
    }

    /// Retypes the buffered word corrected in its own layout behind the
    /// fence, as `autoRetype` does for a switch. False when there is nothing
    /// to correct; nothing has changed then.
    private mutating func typoRetype(_ context: TypoContext, held: KeyStroke?, heldKeyCode: UInt16, undoable: Bool,
                                     at time: Double, effects: inout [Effect]) -> Bool
    {
        guard let fix = correctWord(buffer.entries, in: context.typed) else { return false }
        var keys: [Retype.Key] = []
        var expected = ""
        keys.reserveCapacity(fix.strokes.count)
        for entry in buffer.entries {
            guard let text = context.typed.text(for: entry.stroke) else { return false }
            expected += text
        }
        for stroke in fix.strokes {
            guard let text = context.typed.text(for: stroke) else { return false }
            keys.append(Retype.Key(stroke: stroke, text: text))
        }
        var strokes = buffer.entries.map(\.stroke)
        let wordLength = strokes.count
        if let held, context.typed.text(for: held) != nil { strokes.append(held) }
        let seq = takeSeq()
        var pending = PendingCorrection(
            correction: Correction(seq: seq, original: "", replacement: "", source: context.typed.id,
                                   target: context.typed.id, undoable: undoable, kind: fix.kind),
            strokes: strokes, wordLength: wordLength, isOpen: false, typed: fix.strokes
        )
        describe(&pending)
        startRetype((keys, expected), deleteCount: wordLength, target: context.typed.id, seq: seq, at: time,
                    effects: &effects)
        fence?.correction = pending
        buffer.clear()
        for stroke in fix.strokes { buffer.type(stroke, in: context.typed.id) }
        heldBoundary = (heldKeyCode, true)
        lastCorrection = nil
        return true
    }

    /// Whether the stroke ends a sentence in this layout: `. ! ? …`.
    static func endsSentence(_ stroke: KeyStroke, in map: LayoutMap) -> Bool {
        guard !stroke.modifiers.contains(.option), let text = map.text(for: stroke) else { return false }
        var scalars = text.unicodeScalars.makeIterator()
        guard let scalar = scalars.next(), scalars.next() == nil else { return false }
        switch scalar.value {
        case 0x2E, 0x21, 0x3F, 0x2026: return true
        default: return false
        }
    }

    /// After a letter: switch at once if the word so far cannot start a word
    /// of this layout's language but can of the other's ("ghb"). The letter
    /// is held and comes back in the new layout.
    private mutating func switchInsideWord(at time: Double, effects: inout [Effect]) -> Bool {
        let count = buffer.entries.count
        guard count == 3 || count == 4, autoswitchMayAct, !wordSuppressed, buffer.entries.last?.isSpace == false,
              let context = autoContext(), wordIsPlain(),
              context.classifier.impossiblePrefix(buffer.entries.lazy.map(\.stroke), typed: context.typed,
                                                  other: context.other),
              !isExceptionPrefix(context)
        else { return false }
        let trigger = buffer.entries[count - 1]
        buffer.deleteBackward()
        guard autoRetype(context, held: trigger.stroke, heldKeyCode: trigger.stroke.keyCode, midWord: true,
                         undoable: true, at: time, effects: &effects)
        else {
            buffer.type(trigger.stroke, in: trigger.layout)
            return false
        }
        // Decided for the whole word: the end of it must not switch it back.
        wordSuppressed = true
        return true
    }

    /// Retypes the buffered word in `context.other` behind the fence, with a
    /// correction to report once posted. False when the word cannot be typed
    /// there; nothing has changed then.
    private mutating func autoRetype(_ context: AutoContext, held: KeyStroke?, heldKeyCode: UInt16, midWord: Bool,
                                     undoable: Bool, at time: Double, effects: inout [Effect]) -> Bool
    {
        guard case let .keys(word) = retypeKeys(for: buffer.entries, into: context.other) else { return false }
        var strokes = buffer.entries.map(\.stroke)
        var wordLength = strokes.count
        if let held, context.typed.text(for: held) != nil, context.other.text(for: held) != nil {
            strokes.append(held)
            if midWord { wordLength += 1 }
        }
        // The whole word is known: the word corrections see it in its new layout.
        var keys = word.keys
        var fix: WordFix?
        if !midWord, let found = correctWord(buffer.entries, in: context.other) {
            keys.removeAll(keepingCapacity: true)
            for stroke in found.strokes {
                guard let text = context.other.text(for: stroke) else { return false }
                keys.append(Retype.Key(stroke: stroke, text: text))
            }
            fix = found
        }
        let seq = takeSeq()
        var pending = PendingCorrection(
            correction: Correction(seq: seq, original: "", replacement: "", source: context.typed.id,
                                   target: context.other.id, undoable: undoable, kind: fix?.kind ?? .layout),
            strokes: strokes, wordLength: wordLength, isOpen: midWord, typed: fix?.strokes
        )
        describe(&pending)
        startRetype((keys, word.expected), deleteCount: word.keys.count, target: context.other.id, seq: seq, at: time,
                    effects: &effects)
        fence?.correction = pending
        if let fix {
            buffer.clear()
            for stroke in fix.strokes { buffer.type(stroke, in: context.other.id) }
        } else {
            buffer.relabel(to: context.other.id)
        }
        heldBoundary = (heldKeyCode, !midWord)
        lastCorrection = nil
        return true
    }

    /// Puts back the last automatic switch: the word in its layout, through
    /// the fence. Returns false when there is nothing to undo. What the undo
    /// reports waits in the fence for `.retypePosted`. `heldKey`: the
    /// Backspace that asked for it is held, to be dropped once the undo is
    /// posted and let through if it is cancelled.
    @discardableResult
    private mutating func undoCorrection(at time: Double, heldKey: Bool, effects: inout [Effect]) -> Bool {
        guard fence == nil, let last = lastCorrection else { return false }
        lastCorrection = nil
        let correction = last.correction
        guard correction.undoable, let source = layouts[correction.source], let target = layouts[correction.target]
        else { return false }

        var keys: [Retype.Key] = []
        var expected = ""
        keys.reserveCapacity(last.strokes.count)
        for stroke in last.strokes {
            guard let back = source.text(for: stroke) else { return false }
            keys.append(Retype.Key(stroke: stroke, text: back))
        }
        // What stands in the text: the corrected word, then the held key.
        var deleteCount = last.strokes.count
        if let typed = last.typed {
            deleteCount = typed.count + last.strokes.count - last.wordLength
            for stroke in typed {
                guard let now = target.text(for: stroke) else { return false }
                expected += now
            }
        }
        for stroke in last.strokes.dropFirst(last.typed == nil ? 0 : last.wordLength) {
            guard let now = target.text(for: stroke) else { return false }
            expected += now
        }
        let seq = takeSeq()
        startRetype((keys, expected), deleteCount: deleteCount, target: source.id, seq: seq, at: time,
                    effects: &effects)
        buffer.clear()
        for stroke in last.strokes { buffer.type(stroke, in: source.id) }
        wordSuppressed = true
        wordJudged = true
        previousLanguage = source.language
        let learn = last.isOpen || !settings.learnFromUndos
            ? nil : Self.learnable(correction.original, or: correction.replacement)
        fence?.undo = UndoInFlight(seq: correction.seq, reported: last.reported, isOpen: last.isOpen, learn: learn,
                                   heldKey: heldKey)
        return true
    }

    /// The word to put on the learned list: the typed reading if
    /// `WordExceptions` takes it ("ghbdtn"), else the same without the
    /// punctuation around it ("[jhjij" gives "jhjij"), else the other reading
    /// ("ds,jh" gives "выбор"). Either reading keeps the word: the check
    /// looks at both.
    static func learnable(_ typed: String?, or other: String?) -> String? {
        let list = WordExceptions()
        for candidate in [typed, typed.map(exceptionKey), other.map(exceptionKey)] {
            guard let candidate else { continue }
            switch list.validate(candidate) {
            case .ok, .frequent: return WordExceptions.normalize(candidate)
            default: continue
            }
        }
        return nil
    }

    /// Fills the correction's texts from its word strokes.
    private func describe(_ pending: inout PendingCorrection) {
        guard let source = layouts[pending.correction.source], let target = layouts[pending.correction.target]
        else { return }
        var original = ""
        var replacement = ""
        for stroke in pending.strokes.prefix(pending.wordLength) {
            original += source.text(for: stroke) ?? ""
            if pending.typed == nil { replacement += target.text(for: stroke) ?? "" }
        }
        for stroke in pending.typed ?? [] { replacement += target.text(for: stroke) ?? "" }
        pending.correction.original = original
        pending.correction.replacement = replacement
    }

    /// A key typed while a switch inside the word is open: a letter joins
    /// the word, a key that ends the word closes the correction and reports it.
    private mutating func extendCorrection(with key: KeyEvent, effects: inout [Effect]) {
        guard var last = lastCorrection, last.isOpen else { return }
        lastCorrection = nil
        let stroke = KeyStroke(key.keyCode, LayoutModifiers(eventFlags: key.flags))
        let endsLine = key.keyCode == KeyCode.return || key.keyCode == KeyCode.tab
            || key.keyCode == KeyCode.keypadEnter
        if endsLine {
            last.correction.undoable = false
        } else {
            // The key must have gone into the word, in the new layout.
            guard let entry = buffer.entries.last, entry.stroke == stroke, entry.layout == last.correction.target,
                  let source = layouts[last.correction.source], let target = layouts[last.correction.target]
            else { return }
            last.strokes.append(stroke)
            if !entry.isSpace, !Self.endsWord(stroke, typed: target, other: source) {
                last.wordLength += 1
                last.extended = true
                describe(&last)
                lastCorrection = last
                return
            }
        }
        last.isOpen = false
        last.extended = false
        last.reported = true
        effects.append(.corrected(last.correction))
        lastCorrection = last
    }

    /// The word is on the user's list, in either reading.
    private func isException(_ context: AutoContext) -> Bool {
        isException(in: context.typed) || isException(in: context.other)
    }

    /// The word is on the user's list as this layout reads it.
    private func isException(in map: LayoutMap) -> Bool {
        guard !settings.exceptions.isEmpty, let word = text(of: buffer.entries, in: map) else { return false }
        return settings.exceptions.contains(Self.exceptionKey(word))
    }

    /// Some word on the user's list starts with the word so far, in either
    /// reading: do not switch it early.
    private func isExceptionPrefix(_ context: AutoContext) -> Bool {
        guard !settings.exceptions.isEmpty else { return false }
        for map in [context.typed, context.other] {
            guard let word = text(of: buffer.entries, in: map) else { continue }
            let prefix = Self.exceptionKey(word)
            if settings.exceptions.contains(where: { $0.hasPrefix(prefix) }) { return true }
        }
        return false
    }

    private func text(of entries: [WordBuffer.Entry], in map: LayoutMap) -> String? {
        var text = ""
        for entry in entries where !entry.isSpace {
            guard let typed = map.text(for: entry.stroke) else { return nil }
            text += typed
        }
        return text
    }

    /// The word as `WordExceptions` stores it, without the punctuation around it.
    static func exceptionKey(_ word: String) -> String {
        var text = Substring(word)
        func isPart(_ character: Character) -> Bool {
            character.isLetter || character.isNumber
        }
        while let first = text.first, !isPart(first) { text.removeFirst() }
        while let last = text.last, !isPart(last) { text.removeLast() }
        return WordExceptions.normalize(String(text))
    }

    /// Whether the stroke types sentence punctuation in this layout:
    /// `. , ! ? ; : " ) » …`. Symbols of code and URLs (`/ @ - _ =`) are not:
    /// they stay in the token, and the classifier keeps it at the next space.
    static func isPunctuation(_ stroke: KeyStroke, in map: LayoutMap) -> Bool {
        guard !stroke.modifiers.contains(.option), let text = map.text(for: stroke) else { return false }
        var scalars = text.unicodeScalars.makeIterator()
        guard let scalar = scalars.next(), scalars.next() == nil else { return false }
        switch scalar.value {
        case 0x2E, 0x2C, 0x21, 0x3F, 0x3B, 0x3A, 0x22, 0x29, 0xBB, 0x2026: return true
        default: return false
        }
    }

    /// Whether a key ends the word typed before it: a space, or punctuation in
    /// the typed layout that is no letter or digit in the other one. "," on the
    /// ABC keys is "б" in Russian, so it stays in the word ("ghbdtn," may be
    /// "приветб"); Shift+1 is "!" in both and ends it.
    static func endsWord(_ stroke: KeyStroke, typed: LayoutMap, other: LayoutMap) -> Bool {
        if stroke.keyCode == KeyCode.space { return true }
        guard isPunctuation(stroke, in: typed) else { return false }
        guard let otherText = other.text(for: stroke) else { return true }
        return !otherText.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
    }

    // MARK: - Actions

    private mutating func perform(_ action: HotkeyAction, at time: Double, effects: inout [Effect]) {
        // A shortcut may change the text or the layout (a plain paste, a
        // retype): Backspace after it must not undo a switch from before.
        if case .undoLastCorrection = action {} else { lastCorrection = nil }
        switch action {
        case .switchLayout:
            let next: LayoutID? = if let currentLayout, let index = layoutOrder.firstIndex(of: currentLayout) {
                layoutOrder[(index + 1) % layoutOrder.count]
            } else {
                layoutOrder.first
            }
            if let next { select(next, effects: &effects) }

        case let .selectLanguage(language):
            if let id = layoutOrder.first(where: { layouts[$0]?.language == language }) {
                select(id, effects: &effects)
            }

        case .toggleAutoswitch:
            settings.autoswitch.toggle()
            effects.append(.autoswitchChanged(settings.autoswitch))

        case .convertLastWord:
            retypeWord(at: time, effects: &effects)

        case .changeCase:
            changeCaseOfWord(at: time, effects: &effects)

        case .transliterate:
            if focus?.isSecureField == true {
                effects.append(.refused(.secureField))
            } else {
                startSelectionConversion(at: time, action: .transliterate, effects: &effects)
            }

        case .pastePlain:
            effects.append(.pastePlain)

        case .undoLastCorrection:
            undoCorrection(at: time, heldKey: false, effects: &effects)
        }
    }

    private mutating func select(_ id: LayoutID, effects: inout [Effect]) {
        guard id != currentLayout else { return }
        if let currentLayout, layouts[currentLayout] != nil { previousLayout = currentLayout }
        currentLayout = id
        if pendingSelections.count == 8 { pendingSelections.removeFirst() }
        pendingSelections.append(id)
        effects.append(.selectLayout(id))
    }

    private mutating func retypeWord(at time: Double, effects: inout [Effect]) {
        if focus?.isSecureField == true {
            effects.append(.refused(.secureField))
            return
        }
        lastCorrection = nil
        guard let source = buffer.wordLayout else {
            startSelectionConversion(at: time, effects: &effects)
            return
        }
        guard let currentLayout, layouts[currentLayout] != nil,
              let target = counterpart(of: source), let targetMap = layouts[target]
        else {
            effects.append(.refused(.unsupportedLayout))
            return
        }
        switch retypeKeys(for: buffer.entries, into: targetMap) {
        case let .refused(refusal):
            effects.append(.refused(refusal))
        case let .keys(word):
            startRetype(word, target: target, seq: takeSeq(), at: time, effects: &effects)
            buffer.relabel(to: target)
            // The user said which layout the word is in: leave it alone.
            wordSuppressed = true
        }
    }

    /// The synthetic keys that type `entries` in `targetMap`, and the text they
    /// replace.
    private func retypeKeys(for entries: [WordBuffer.Entry], into targetMap: LayoutMap)
        -> WordKeys
    {
        var keys: [Retype.Key] = []
        var expected = ""
        keys.reserveCapacity(entries.count)
        for entry in entries {
            guard let sourceMap = layouts[entry.layout], let typed = sourceMap.text(for: entry.stroke),
                  !entry.stroke.modifiers.contains(.option)
            else { return .refused(.unconvertibleWord) }
            guard let text = targetMap.text(for: entry.stroke) else { return .refused(.missingKeys) }
            expected += typed
            keys.append(Retype.Key(stroke: entry.stroke, text: text))
        }
        return .keys((keys, expected))
    }

    /// Selects `target`, asks for the retype and raises the fence.
    /// `deleteCount`: the keys of `expected`, when not as many as typed.
    private mutating func startRetype(_ word: (keys: [Retype.Key], expected: String), deleteCount: Int? = nil,
                                      target: LayoutID, seq: UInt32, at time: Double, effects: inout [Effect])
    {
        let layoutBefore = target == currentLayout ? nil : currentLayout
        select(target, effects: &effects)
        effects.append(.retype(Retype(deleteCount: deleteCount ?? word.keys.count, keys: word.keys, target: target,
                                      expected: word.expected, seq: seq)))
        // Long until the retype is posted; `.retypePosted` shortens it.
        let deadline = time + settings.postTimeout
        fence = Fence(seq: seq, awaitedLayout: target == confirmedLayout ? nil : target, deadline: deadline,
                      layoutBefore: layoutBefore)
        effects.append(.scheduleDeadline(at: deadline))
    }

    private mutating func takeSeq() -> UInt32 {
        let seq = nextSeq
        nextSeq = nextSeq == .max ? 1 : nextSeq + 1
        return seq
    }

    /// Nothing typed: hold input and ask the system layer for the selection.
    private mutating func startSelectionConversion(at time: Double, action: SelectionAction = .convertLayout,
                                                   effects: inout [Effect])
    {
        let seq = takeSeq()
        buffer.clear()
        // Long: reading may go through the pasteboard; `.retypePosted` shortens it.
        let deadline = time + settings.postTimeout
        fence = Fence(seq: seq, deadline: deadline, awaitsSelection: true, selectionAction: action)
        effects.append(.convertSelection(seq: seq))
        effects.append(.scheduleDeadline(at: deadline))
    }

    /// The selected text arrived: retype it as the shortcut asks, or refuse
    /// and let input go.
    private mutating func retypeSelection(_ text: String, viaAccessibility: Bool, effects: inout [Effect]) {
        fence?.awaitsSelection = false
        var candidates: [LayoutMap] = []
        candidates.reserveCapacity(layoutOrder.count)
        if let currentLayout, let map = layouts[currentLayout] { candidates.append(map) }
        for id in layoutOrder where id != currentLayout {
            if let map = layouts[id] { candidates.append(map) }
        }
        switch fence?.selectionAction ?? .convertLayout {
        case .convertLayout:
            let result = SelectionConversion.convert(text, layouts: candidates) { source in
                counterpart(of: source).flatMap { layouts[$0] }
            }
            guard case let .keys(source, keys) = result, let target = counterpart(of: source) else {
                if case let .refused(refusal) = result { effects.append(.refused(refusal)) }
                release(effects: &effects)
                return
            }
            emitSelectionRetype(text, target: target, keys: keys, viaAccessibility: viaAccessibility, effects: &effects)
        case .changeCase:
            retypeSelection(text, as: TextCase.next(after:), candidates: candidates, typedIn: .source,
                            viaAccessibility: viaAccessibility, effects: &effects)
        case .transliterate:
            retypeSelection(text, as: Transliteration.convert, candidates: candidates, typedIn: .result,
                            viaAccessibility: viaAccessibility, effects: &effects)
        }
    }

    /// Which text decides the layout a transformed selection is typed in.
    private enum LayoutChoice { case source, result }

    /// Types `transform(text)` over the selection, on the layout that types
    /// the source text (case) or the result (script).
    private mutating func retypeSelection(_ text: String, as transform: (String) -> String?,
                                           candidates: [LayoutMap], typedIn: LayoutChoice,
                                           viaAccessibility: Bool, effects: inout [Effect])
    {
        guard !text.isEmpty else { return refuseSelection(.nothingSelected, effects: &effects) }
        guard SelectionConversion.isTypable(text), let new = transform(text), new != text,
              let map = SelectionConversion.sourceLayout(of: typedIn == .source ? text : new, among: candidates)
        else { return refuseSelection(.unsupportedSelection, effects: &effects) }
        emitSelectionRetype(text, target: map.id, keys: SelectionConversion.keys(typing: new, in: map),
                            viaAccessibility: viaAccessibility, effects: &effects)
    }

    private mutating func refuseSelection(_ refusal: Refusal, effects: inout [Effect]) {
        effects.append(.refused(refusal))
        release(effects: &effects)
    }

    private mutating func emitSelectionRetype(_ text: String, target: LayoutID, keys: [Retype.Key],
                                              viaAccessibility: Bool, effects: inout [Effect])
    {
        guard let seq = fence?.seq else { return }
        let layoutBefore = target == currentLayout ? nil : currentLayout
        select(target, effects: &effects)
        effects.append(.retype(Retype(deleteCount: 0, keys: keys, target: target, expected: text, seq: seq,
                                      viaAccessibility: viaAccessibility)))
        fence?.awaitedLayout = target == confirmedLayout ? nil : target
        fence?.layoutBefore = layoutBefore
        fence?.viaAccessibility = viaAccessibility
    }

    /// Cycles the case of the word before the caret by retyping it with the
    /// same keys and the Shift flags of the new case, in the layout it was
    /// typed in. Without a word, the selection goes through the same cycle.
    private mutating func changeCaseOfWord(at time: Double, effects: inout [Effect]) {
        if focus?.isSecureField == true {
            effects.append(.refused(.secureField))
            return
        }
        lastCorrection = nil
        guard let wordLayout = buffer.wordLayout else {
            startSelectionConversion(at: time, action: .changeCase, effects: &effects)
            return
        }
        guard let currentLayout, wordLayout == currentLayout, let map = layouts[currentLayout] else {
            effects.append(.refused(.unsupportedLayout))
            return
        }
        var typed: [Character] = []
        typed.reserveCapacity(buffer.entries.count)
        for entry in buffer.entries {
            guard entry.layout == currentLayout, !entry.stroke.modifiers.contains(.option),
                  let text = map.text(for: entry.stroke), text.count == 1, let character = text.first
            else {
                effects.append(.refused(.unconvertibleWord))
                return
            }
            typed.append(character)
        }
        let old = String(typed)
        guard let new = TextCase.next(after: old) else {
            effects.append(.refused(.unconvertibleWord))
            return
        }
        var keys: [Retype.Key] = []
        var strokes: [KeyStroke] = []
        keys.reserveCapacity(typed.count)
        strokes.reserveCapacity(typed.count)
        for (entry, character) in zip(buffer.entries, new) {
            var stroke = entry.stroke
            if map.text(for: stroke) != String(character) {
                guard let other = map.stroke(for: character), !other.modifiers.contains(.option) else {
                    effects.append(.refused(.missingKeys))
                    return
                }
                stroke = other
            }
            strokes.append(stroke)
            keys.append(Retype.Key(stroke: stroke, text: String(character)))
        }

        let seq = takeSeq()
        effects.append(.retype(Retype(deleteCount: keys.count, keys: keys, target: currentLayout,
                                      expected: old, seq: seq)))
        buffer.replaceStrokes(strokes)
        let deadline = time + settings.postTimeout
        fence = Fence(seq: seq, deadline: deadline)
        effects.append(.scheduleDeadline(at: deadline))
    }

    /// The layout a word typed in `source` should be retyped into.
    ///
    /// With two layouts it is simply the other one. With more, prefer the
    /// layout the user just switched to (double Shift switches first, then
    /// retypes), then the one used before, then another language.
    private func counterpart(of source: LayoutID) -> LayoutID? {
        if let currentLayout, currentLayout != source, layouts[currentLayout] != nil { return currentLayout }
        if let previousLayout, previousLayout != source, layouts[previousLayout] != nil { return previousLayout }
        let language = layouts[source]?.language
        var fallback: LayoutID?
        for id in layoutOrder where id != source {
            if layouts[id]?.language != language { return id }
            if fallback == nil { fallback = id }
        }
        return fallback
    }

    // MARK: - Fence

    private mutating func releaseIfDone(effects: inout [Effect]) {
        if let fence, fence.lastOwnEventSeen, fence.awaitedLayout == nil, !fence.awaitsSelection {
            release(effects: &effects)
        }
    }

    @discardableResult
    private mutating func expireFence(at time: Double, effects: inout [Effect]) -> Bool {
        guard let fence, time >= fence.deadline else { return false }
        release(effects: &effects)
        return true
    }

    private mutating func release(effects: inout [Effect]) {
        guard fence != nil else { return }
        fence = nil
        effects.append(.releaseHeld)
    }

    // MARK: - Setup

    private mutating func apply(_ newSettings: Settings) {
        settings = newSettings
        var chords: [ChordDetector<HotkeyAction>.Binding] = []
        keyHotkeys = []
        for hotkey in newSettings.hotkeys {
            switch hotkey.trigger {
            case let .modifiers(chord, taps):
                guard hotkey.action.acceptsModifierOnlyTrigger else { continue }
                chords.append(.init(chord, taps: taps.rawValue, action: hotkey.action))
            case let .key(keyCode, modifiers):
                let mask = modifiers.reduce(UInt8(0)) { $0 | $1.maskBit } & ~ModifierKind.function.maskBit
                keyHotkeys.append((keyCode, mask, hotkey.action))
            }
        }
        detector = ChordDetector(bindings: chords)
    }

    private mutating func setLayouts(_ maps: [LayoutMap]) {
        layoutOrder = maps.map(\.id)
        layouts = Dictionary(maps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        currentMap = currentLayout.flatMap { layouts[$0] }
    }

    /// The modifiers held after a `flagsChanged` event.
    ///
    /// Reads the device-dependent side bits. Some virtual keyboards and
    /// synthetic events set only the device-independent bits; then the key that
    /// changed gives its side, and other held kinds count as their left key.
    static func modifiers(keyCode: UInt16, flags: UInt64) -> Set<ModifierKey> {
        let pressed = ModifierKey.pressed(inEventFlags: flags)
        guard pressed.isEmpty else { return pressed }
        let changed = ModifierKey(keyCode: keyCode)
        return Set(ModifierKind.held(inEventFlags: flags).map { kind in
            if let changed, changed.kind == kind { return changed }
            return ModifierKey.allCases.first { $0.kind == kind && !$0.isRight }!
        })
    }
}
