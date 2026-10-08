// SPDX-License-Identifier: GPL-3.0-or-later

/// All of Perekey's input logic as a state machine: events in, effects out.
///
/// The system layer only delivers `InputEvent`s and carries out the `Effect`s,
/// so every behavior can be tested on recorded event sequences without a
/// keyboard. `handle(_:)` runs on the event tap thread for every key press:
/// keep it free of I/O, locks and allocations in the common path.
///
/// The machine routes events to values that each own one part of the state:
/// - `Fence` holds user input while a retype is under way and numbers retypes;
/// - `LayoutState` knows the layouts, the selected one and `counterpart(of:)`;
/// - `WordJudge` decides automatic switching and the word corrections;
/// - `CorrectionUndo` keeps the last correction for Backspace and the undo action;
/// - `ManualActions` plans the shortcuts that retype the word, the phrase or
///   the selection;
/// - `Shortcuts` matches modifier chords and key triggers.
///
/// Their decisions come back here as values, and the machine carries them
/// out: a retype selects its layout, is posted and raises the fence
/// (`startRetype`), and the word in `buffer` follows it.
public struct InputMachine: Sendable {
    public private(set) var settings: Settings
    public private(set) var buffer = WordBuffer()
    /// The layout Perekey believes is selected: the last one it selected, or
    /// the last one the system reported.
    public var currentLayout: LayoutID? { layouts.current }

    private var layouts: LayoutState
    private var fence: Fence
    private var judge: WordJudge
    private var undo = CorrectionUndo()
    private var manual = ManualActions()
    private var shortcuts: Shortcuts
    private var secureInput = false
    private var focus: Focus?

    public init(settings: Settings = Settings(), layouts: [LayoutMap] = [], currentLayout: LayoutID? = nil,
                classifier: Classifier? = nil)
    {
        self.settings = settings
        shortcuts = Shortcuts(settings.hotkeys)
        self.layouts = LayoutState(layouts, current: currentLayout)
        fence = Fence(confirmedLayout: currentLayout)
        judge = WordJudge(classifier: classifier)
    }

    /// Whether user input is being held back right now.
    public var isHolding: Bool { fence.isHolding }

    /// The retype the fence waits for; post a retype only while this is its `seq`.
    public var pendingRetypeSeq: UInt32? { fence.hold?.seq }

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
            if fence.expire(at: time, effects: &effects), !key.origin.isOwn { return .hold }
            return handleKey(key, at: time, effects: &effects)

        case let .flagsChanged(keyCode, flags, origin, time):
            if fence.expire(at: time, effects: &effects), !origin.isOwn { return .hold }
            if case .own = origin { return .pass }
            if fence.isHolding { return .hold }
            guard !secureInput else { return .pass }
            if let action = shortcuts.modifiersChanged(keyCode: keyCode, flags: flags, at: time) {
                perform(action, at: time, effects: &effects)
            }
            return .pass

        case let .click(time, onHint):
            fence.expire(at: time, effects: &effects)
            shortcuts.otherInput(at: time)
            buffer.clear()
            manual.endPhrase()
            undo.clicked(onHint: onHint)
            if !onHint { fence.clickedDuringCorrection() }

        case let .scroll(time):
            shortcuts.otherInput(at: time)

        case let .focusChanged(newFocus):
            focus = newFocus
            forgetText()
            judge.forgetContext(newField: true)

        case let .layoutChanged(id):
            if !fence.confirmed(id, effects: &effects) {
                // Someone else switched: the user from the menu, or another app.
                layouts.makeCurrent(id)
            }
            if layouts[id] == nil { buffer.clear() }

        case let .layoutsChanged(maps):
            layouts.set(maps)
            forgetText()

        case let .secureInputChanged(isOn):
            // Key presses do not reach the tap under Secure Input, but modifier
            // changes do: every capital letter of a password would look like a
            // Shift tap. Keep the detector off until Secure Input ends.
            secureInput = isOn
            shortcuts.reset()
            forgetText()

        case let .retypePosted(seq, time):
            retypePosted(seq, at: time, effects: &effects)

        case let .selectionRead(seq, text, viaAccessibility):
            guard let action = fence.selectionRead(seq: seq) else { break }
            retypeSelection(text, action, viaAccessibility: viaAccessibility, effects: &effects)

        case let .retypeCancelled(seq):
            retypeCancelled(seq, effects: &effects)

        case let .settingsChanged(newSettings):
            settings = newSettings
            shortcuts.apply(newSettings.hotkeys)

        case .inputLost:
            shortcuts.reset()
            forgetText()
            judge.forgetContext(newField: false)
            fence.forgetBoundary()
            fence.release(effects: &effects)

        case let .deadline(time):
            fence.expire(at: time, effects: &effects)

        case let .appModeChanged(mode):
            judge.appMode = mode

        case let .classifierChanged(newClassifier):
            judge.setClassifier(newClassifier)

        case let .undoLastCorrection(seq, time):
            // A hint left over from an older switch must not undo a newer one.
            guard undo.isLast(seq: seq) else { break }
            undoCorrection(at: time, heldKey: false, effects: &effects)
        }
        return .pass
    }

    // MARK: - Keys

    private mutating func handleKey(_ key: KeyEvent, at time: Double, effects: inout [Effect]) -> Disposition {
        switch key.origin {
        case let .own(seq, last):
            fence.ownEvent(seq: seq, last: last, effects: &effects)
            return .pass
        case .user, .replayed:
            if fence.isHolding { return .hold }
        }
        if fence.takeUndoKey(key) {
            shortcuts.swallow(key.keyCode)
            return .drop
        }
        guard !secureInput else { return .pass }

        if key.phase == .up { return shortcuts.keyUp(key.keyCode) ? .drop : .pass }

        // F-keys and arrows always carry the fn bit, so fn never takes part.
        let held = ModifierKind.kindMask(inEventFlags: key.flags) & ~ModifierKind.function.maskBit
        switch shortcuts.keyDown(key, held: held, at: time) {
        case let .runs(action):
            perform(action, at: time, effects: &effects)
            return .drop
        case .swallowed:
            return .drop
        case .typing:
            break
        }
        // Typing ends a phrase retype: the next press starts over.
        manual.endPhrase()

        // The key a correction held comes back first after the fence.
        let boundary = fence.takeBoundary(key)
        let isHeldBoundary = boundary?.isHeldKey == true
        var extendsCorrection = false
        if !isHeldBoundary {
            switch undo.keyDown(key.keyCode, held: held) {
            case .undoes:
                // Held, not dropped: if the undo is cancelled, the Backspace
                // still does what the user pressed it for.
                if undoCorrection(at: time, heldKey: true, effects: &effects) { return .hold }
            case .extends:
                extendsCorrection = true
            case .ends:
                break
            }
            if judge.mayJudge(endedBy: key, held: held, buffer: buffer, layouts: layouts, settings: settings) {
                switch judge.judge(endedBy: key, held: held, buffer: buffer, layouts: layouts, settings: settings,
                                   focus: focus, secureInput: secureInput)
                {
                case .keep:
                    break
                case let .learn(word):
                    effects.append(.learned(word))
                case let .withdraw(word):
                    effects.append(.alwaysFixWithdrawn(word))
                case let .retype(retype):
                    startCorrection(retype, at: time, effects: &effects)
                    return .hold
                }
            }
        }
        updateBuffer(with: key, held: held)
        if extendsCorrection {
            undo.extend(with: key, buffer: buffer, layouts: layouts, alwaysFix: settings.alwaysFix, effects: &effects)
        }
        if isHeldBoundary {
            // The word it ended was judged already; a held letter continues it.
            if boundary?.endsWord == true { judge.boundaryReplayed() }
        } else if judge.mayActInsideWord(buffer: buffer, settings: settings),
                  let retype = judge.insideWord(buffer: buffer, layouts: layouts, settings: settings, focus: focus,
                                                secureInput: secureInput)
        {
            startCorrection(retype, at: time, effects: &effects)
            return .hold
        }
        return .pass
    }

    /// The caret may be anywhere now: the word, the last correction and
    /// the phrase are gone.
    private mutating func forgetText() {
        buffer.clear()
        undo.forget()
        manual.endPhrase()
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
            judge.deleted()
            return
        }
        let stroke = KeyStroke(key.keyCode, LayoutModifiers(eventFlags: key.flags))
        guard let current = layouts.current, let map = layouts.currentMap else {
            buffer.clear()
            return
        }
        if map.isDeadKey(stroke) {
            // A dead key and the next key make one character, so keys and
            // characters no longer match one to one. Give up on this word.
            buffer.abandonWord()
        } else if map.text(for: stroke) != nil {
            if stroke.keyCode != KeyCode.space {
                judge.typed(startsWord: buffer.isEmpty || buffer.entries.last?.isSpace == true)
            }
            buffer.type(stroke, in: current)
        } else {
            buffer.clear()
        }
    }

    // MARK: - Corrections

    /// Retypes the word as the judge decided, behind the fence, with the
    /// correction to report once posted.
    private mutating func startCorrection(_ retype: WordJudge.WordRetype, at time: Double, effects: inout [Effect]) {
        let seq = fence.takeSeq()
        var pending = retype.pending
        pending.correction.seq = seq
        if let decision = retype.decision { pending.correction.decision = decision }
        startRetype((retype.keys, retype.expected), deleteCount: retype.deleteCount, target: retype.target, seq: seq,
                    purpose: .correction(pending), origin: .automatic(pending.correction.kind),
                    decision: retype.decision, at: time, effects: &effects)
        if retype.dropsLastKey { buffer.deleteBackward() }
        if let word = retype.word {
            buffer.replaceWord(word, in: retype.target)
        } else {
            buffer.relabel(to: retype.target)
        }
        fence.holdsBoundary(retype.held)
        undo.forget()
    }

    /// Puts back the last automatic correction through the fence. Returns
    /// false when there is nothing to undo. What the undo reports waits in
    /// the fence for `.retypePosted`. `heldKey`: the Backspace that asked for
    /// it is held, to be dropped once the undo is posted and let through if
    /// it is cancelled.
    @discardableResult
    private mutating func undoCorrection(at time: Double, heldKey: Bool, effects: inout [Effect]) -> Bool {
        guard !fence.isHolding,
              let plan = undo.takeBack(layouts: layouts, learnFromUndos: settings.learnFromUndos, heldKey: heldKey)
        else { return false }
        startRetype((plan.keys, plan.expected), deleteCount: plan.deleteCount, target: plan.source,
                    seq: fence.takeSeq(), purpose: .undo(plan.inFlight), origin: .undo, at: time, effects: &effects)
        buffer.clear()
        for stroke in plan.strokes { buffer.type(stroke, in: plan.source) }
        judge.wordUndone(language: plan.language)
        return true
    }

    private mutating func retypePosted(_ seq: UInt32, at time: Double, effects: inout [Effect]) {
        guard let purpose = fence.posted(seq: seq, deadline: time + settings.fenceTimeout, effects: &effects)
        else { return }
        switch purpose {
        case let .correction(pending):
            undo.posted(pending, effects: &effects)
        case let .undo(inFlight):
            if inFlight.reported { effects.append(.correctionUndone(seq: inFlight.seq)) }
            if inFlight.isOpen {
                judge.learnAtWordEnd()
            } else if let word = inFlight.learn {
                effects.append(.learned(word))
            }
            if let word = inFlight.withdraw { effects.append(.alwaysFixWithdrawn(word)) }
            fence.undoPosted(heldKey: inFlight.heldKey)
        case .retype, .readingSelection:
            break
        }
        fence.finishPosted(effects: &effects)
    }

    /// The text before the caret was not what the buffer expected, so the
    /// buffer is wrong too. Put the layout back and let input go.
    private mutating func retypeCancelled(_ seq: UInt32, effects: inout [Effect]) {
        guard let cancelled = fence.hold, cancelled.seq == seq else { return }
        manual.endPhrase()
        switch cancelled.purpose {
        case let .undo(inFlight):
            // The caret is not after the corrected word: the text stays,
            // nothing is learned, and the held Backspace comes back as an
            // ordinary one. The hint's Undo could not work either.
            if inFlight.reported { effects.append(.correctionUndoFailed(seq: inFlight.seq)) }
            buffer.abandonWord()
            judge.leaveWordAlone()
        case .correction:
            // The held key comes back next and may finish an impossible
            // prefix again: ignore the rest of this word.
            buffer.abandonWord()
            judge.leaveWordAlone()
        case .retype, .readingSelection:
            buffer.clear()
        }
        if let layout = cancelled.layoutBefore { select(layout, effects: &effects) }
        fence.release(effects: &effects)
    }

    // MARK: - Actions

    private mutating func perform(_ action: HotkeyAction, at time: Double, effects: inout [Effect]) {
        // A shortcut may change the text or the layout (a plain paste, a
        // retype): Backspace after it must not undo a switch from before.
        // The word the last switch fixed is no word automatic switching
        // "left alone", whatever the retype does with it.
        let fixedByAutoswitch = undo.last != nil
        if case .undoLastCorrection = action {} else { undo.forget() }
        if action != .convertLastWord { manual.endPhrase() }
        let isSecureField = focus?.isSecureField == true
        switch action {
        case .switchLayout:
            if let next = layouts.next { select(next, effects: &effects) }

        case let .selectLanguage(language):
            if let id = layouts.first(language: language) { select(id, effects: &effects) }

        case .toggleAutoswitch:
            settings.autoswitch.toggle()
            effects.append(.autoswitchChanged(settings.autoswitch))

        case .convertLastWord:
            let plan = manual.retypeWord(buffer: buffer, layouts: layouts,
                                         phrases: settings.corrections.phraseRetype, isSecureField: isSecureField,
                                         classifier: judge.classifier)
            run(plan, as: action, fixedByAutoswitch: fixedByAutoswitch, at: time, effects: &effects)

        case .changeCase:
            run(ManualActions.changeCase(buffer: buffer, layouts: layouts, isSecureField: isSecureField),
                as: action, at: time, effects: &effects)

        case .transliterate:
            run(isSecureField ? .refuse(.secureField) : .readSelection(.transliterate), as: action, at: time,
                effects: &effects)

        case .pastePlain:
            effects.append(.pastePlain)

        case .undoLastCorrection:
            undoCorrection(at: time, heldKey: false, effects: &effects)
        }
    }

    private mutating func run(_ plan: ManualActions.Plan, as action: HotkeyAction, fixedByAutoswitch: Bool = false,
                              at time: Double, effects: inout [Effect])
    {
        switch plan {
        case let .refuse(refusal):
            effects.append(.refused(refusal))
        case let .readSelection(action):
            // Nothing typed: hold input and ask the system layer for the selection.
            let seq = fence.takeSeq()
            buffer.clear()
            effects.append(.convertSelection(seq: seq))
            // Long: reading may go through the pasteboard; `.retypePosted` shortens it.
            fence.raise(seq: seq, awaiting: nil, deadline: time + settings.postTimeout,
                        purpose: .readingSelection(action), effects: &effects)
        case let .retype(retype):
            // The first press on a word: what automatic switching made of it.
            let decision = retype.explainable && !fixedByAutoswitch
                ? judge.decisionForManualRetype(buffer: buffer, layouts: layouts, settings: settings, focus: focus,
                                                secureInput: secureInput, target: retype.target)
                : nil
            startRetype(retype.word, target: retype.target, awaitsLayout: retype.changesLayout,
                        seq: fence.takeSeq(), origin: .manual(action), decision: decision, at: time, effects: &effects)
            switch retype.edit {
            case let .relabel(layout): buffer.relabel(to: layout)
            case let .relabelPhrase(phrase): buffer.relabelPhrase(phrase)
            case let .replaceStrokes(strokes): buffer.replaceStrokes(strokes)
            }
            if retype.changesLayout { judge.leaveWordAlone() }
        }
    }

    /// The selected text arrived: retype it as the shortcut asks, or refuse
    /// and let input go.
    private mutating func retypeSelection(_ text: String, _ action: ManualActions.SelectionAction,
                                          viaAccessibility: Bool, effects: inout [Effect])
    {
        switch ManualActions.selectionRead(text, action: action, layouts: layouts) {
        case let .refuse(refusal):
            if let refusal { effects.append(.refused(refusal)) }
            fence.release(effects: &effects)
        case let .retype(target, keys):
            guard let seq = fence.hold?.seq else { return }
            let layoutBefore = target == layouts.current ? nil : layouts.current
            select(target, effects: &effects)
            effects.append(.retype(Retype(deleteCount: 0, keys: keys, target: target, expected: text, seq: seq,
                                          viaAccessibility: viaAccessibility, origin: .manualSelection(action.hotkeyAction))))
            fence.retypesSelection(into: target, layoutBefore: layoutBefore, viaAccessibility: viaAccessibility)
        }
    }

    private mutating func select(_ id: LayoutID, effects: inout [Effect]) {
        guard layouts.makeCurrent(id) else { return }
        fence.selected(id)
        effects.append(.selectLayout(id))
    }

    /// Selects `target`, asks for the retype and raises the fence.
    /// `deleteCount`: the keys of `expected`, when not as many as typed.
    /// `awaitsLayout`: the fence also waits for the system to confirm `target`.
    private mutating func startRetype(_ word: (keys: [Retype.Key], expected: String), deleteCount: Int? = nil,
                                      target: LayoutID, awaitsLayout: Bool = true, seq: UInt32,
                                      purpose: Fence.Purpose = .retype, origin: Retype.Origin,
                                      decision: Classifier.Decision? = nil, at time: Double,
                                      effects: inout [Effect])
    {
        let layoutBefore = target == layouts.current ? nil : layouts.current
        select(target, effects: &effects)
        effects.append(.retype(Retype(deleteCount: deleteCount ?? word.keys.count, keys: word.keys, target: target,
                                      expected: word.expected, seq: seq, origin: origin, decision: decision)))
        // Long until the retype is posted; `.retypePosted` shortens it.
        fence.raise(seq: seq, awaiting: awaitsLayout ? target : nil, layoutBefore: layoutBefore,
                    deadline: time + settings.postTimeout, purpose: purpose, effects: &effects)
    }
}
