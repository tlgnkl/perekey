// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

/// The values `InputMachine` routes to, each on its own. The machine as a
/// whole is tested on event sequences elsewhere.

private let en = Fixture.abc.id
private let ru = Fixture.russian.id
private let ukrainian = Fixture.ukrainianPC.id

private func key(_ keyCode: UInt16, _ phase: KeyEvent.Phase = .down, origin: EventOrigin = .user) -> KeyEvent {
    KeyEvent(phase, keyCode: keyCode, origin: origin)
}

/// A buffer with `text` typed on the ABC keys, labelled with `layout`.
private func buffer(_ text: String, in layout: LayoutID = en) -> WordBuffer {
    var buffer = WordBuffer()
    for stroke in Fixture.abc.strokes(text) { buffer.type(stroke, in: layout) }
    return buffer
}

@Suite struct FenceValueTests {
    @Test func releasesOnceTheLastOwnEventAndTheLayoutAreBoth() {
        var fence = Fence(confirmedLayout: en)
        var effects: [Effect] = []
        fence.raise(seq: 1, awaiting: ru, deadline: 10, effects: &effects)
        #expect(effects == [.scheduleDeadline(at: 10)])
        #expect(fence.isHolding)
        fence.ownEvent(seq: 1, last: true, effects: &effects)
        #expect(fence.isHolding)
        fence.selected(ru)
        let ours = fence.confirmed(ru, effects: &effects)
        #expect(ours)
        #expect(!fence.isHolding)
        #expect(effects.last == .releaseHeld)
    }

    @Test func aConfirmedTargetIsNotAwaited() {
        var fence = Fence(confirmedLayout: en)
        var effects: [Effect] = []
        fence.raise(seq: 1, awaiting: en, deadline: 10, effects: &effects)
        fence.ownEvent(seq: 2, last: true, effects: &effects)
        #expect(fence.isHolding)
        fence.ownEvent(seq: 1, last: true, effects: &effects)
        #expect(!fence.isHolding)
    }

    @Test func aLateConfirmationKeepsTheLaterSelection() {
        var fence = Fence(confirmedLayout: en)
        var effects: [Effect] = []
        fence.selected(ru)
        fence.selected(en)
        let ours1 = fence.confirmed(ru, effects: &effects)
        #expect(ours1)
        let ours2 = fence.confirmed(en, effects: &effects)
        #expect(ours2)
        // Nothing pending now: this one came from someone else.
        let ours3 = fence.confirmed(ru, effects: &effects)
        #expect(!ours3)
    }

    @Test func expiresAtTheDeadline() {
        var fence = Fence(confirmedLayout: en)
        var effects: [Effect] = []
        fence.raise(seq: 1, awaiting: ru, deadline: 10, effects: &effects)
        let expired1 = fence.expire(at: 9.9, effects: &effects)
        #expect(!expired1)
        let expired2 = fence.expire(at: 10, effects: &effects)
        #expect(expired2)
        #expect(!fence.isHolding)
        let expired3 = fence.expire(at: 11, effects: &effects)
        #expect(!expired3)
    }

    @Test func postedHandsThePurposeOverOnce() {
        var fence = Fence(confirmedLayout: en)
        var effects: [Effect] = []
        let pending = CorrectionUndo.Pending(correction: Correction(seq: 1, original: "", replacement: "", source: en,
                                                                    target: ru),
                                             strokes: [], wordLength: 0, isOpen: false)
        fence.raise(seq: 1, awaiting: ru, deadline: 10, purpose: .correction(pending), effects: &effects)
        let purpose = fence.posted(seq: 2, deadline: 11, effects: &effects)
        #expect(purpose == nil)
        guard case .correction = fence.posted(seq: 1, deadline: 11, effects: &effects) else {
            Issue.record("expected the correction")
            return
        }
        #expect(effects.last == .scheduleDeadline(at: 11))
        guard case .retype = fence.posted(seq: 1, deadline: 12, effects: &effects) else {
            Issue.record("the correction is reported once")
            return
        }
    }

    @Test func aSelectionIsReadBeforeItCanBePosted() {
        var fence = Fence(confirmedLayout: en)
        var effects: [Effect] = []
        fence.raise(seq: 3, awaiting: nil, deadline: 10, purpose: .readingSelection(.changeCase), effects: &effects)
        fence.ownEvent(seq: 3, last: true, effects: &effects)
        #expect(fence.isHolding)
        let purpose = fence.posted(seq: 3, deadline: 11, effects: &effects)
        #expect(purpose == nil)
        let action1 = fence.selectionRead(seq: 2)
        #expect(action1 == nil)
        let action2 = fence.selectionRead(seq: 3)
        #expect(action2 == .changeCase)
        let action3 = fence.selectionRead(seq: 3)
        #expect(action3 == nil)
        fence.retypesSelection(into: en, layoutBefore: nil, viaAccessibility: true)
        _ = fence.posted(seq: 3, deadline: 11, effects: &effects)
        fence.finishPosted(effects: &effects)
        #expect(!fence.isHolding)
    }

    @Test func theUndoKeyIsDroppedOnlyWhenItComesBackFirst() {
        var fence = Fence(confirmedLayout: en)
        fence.undoPosted(heldKey: true)
        let dropped1 = fence.takeUndoKey(key(KeyCode.delete, .up, origin: .replayed))
        #expect(!dropped1)
        let dropped2 = fence.takeUndoKey(key(KeyCode.delete, origin: .replayed))
        #expect(dropped2)
        let dropped3 = fence.takeUndoKey(key(KeyCode.delete, origin: .replayed))
        #expect(!dropped3)

        // Any other key down ends the wait.
        fence.undoPosted(heldKey: true)
        let dropped4 = fence.takeUndoKey(key(KeyCode.space, origin: .replayed))
        #expect(!dropped4)
        let dropped5 = fence.takeUndoKey(key(KeyCode.delete, origin: .replayed))
        #expect(!dropped5)
    }

    @Test func theHeldBoundaryComesBackOnce() {
        var fence = Fence(confirmedLayout: en)
        fence.holdsBoundary(.boundary(keyCode: KeyCode.space, endsWord: true))
        // An undo posted without a held key leaves the boundary waiting.
        fence.undoPosted(heldKey: false)
        let dropped = fence.takeUndoKey(key(KeyCode.space, origin: .replayed))
        #expect(!dropped)
        let back = fence.takeBoundary(key(KeyCode.space, origin: .replayed))
        #expect(back?.isHeldKey == true)
        #expect(back?.endsWord == true)
        let again = fence.takeBoundary(key(KeyCode.space, origin: .replayed))
        #expect(again == nil)

        fence.holdsBoundary(.boundary(keyCode: KeyCode.space, endsWord: true))
        let typedByUser = fence.takeBoundary(key(KeyCode.space))
        #expect(typedByUser?.isHeldKey == false)

        fence.holdsBoundary(.boundary(keyCode: KeyCode.space, endsWord: false))
        fence.forgetBoundary()
        #expect(fence.returning == .nothing)
        fence.undoPosted(heldKey: true)
        fence.forgetBoundary()
        #expect(fence.returning == .undoKey)
    }

    @Test func sequenceNumbersCount() {
        var fence = Fence(confirmedLayout: nil)
        let seq1 = fence.takeSeq()
        #expect(seq1 == 1)
        let seq2 = fence.takeSeq()
        #expect(seq2 == 2)
    }
}

@Suite struct LayoutStateTests {
    @Test func theCounterpartOfTwoIsTheOther() {
        let layouts = LayoutState([Fixture.abc, Fixture.russian], current: en)
        #expect(layouts.counterpart(of: en) == ru)
        #expect(layouts.counterpart(of: ru) == en)
    }

    @Test func withMoreTheCurrentThenThePreviousThenAnotherLanguage() {
        var layouts = LayoutState([Fixture.abc, Fixture.us, Fixture.russian, Fixture.ukrainianPC], current: en)
        // Nothing chosen yet: another language.
        #expect(layouts.counterpart(of: en) == ru)
        layouts.makeCurrent(ukrainian)
        #expect(layouts.counterpart(of: en) == ukrainian)
        // The word is in the current layout: the one before it.
        #expect(layouts.counterpart(of: ukrainian) == en)
    }

    @Test func makeCurrentReportsAChange() {
        var layouts = LayoutState([Fixture.abc, Fixture.russian], current: en)
        let changed1 = layouts.makeCurrent(en)
        #expect(!changed1)
        let changed2 = layouts.makeCurrent(ru)
        #expect(changed2)
        #expect(layouts.current == ru)
        #expect(layouts.currentMap?.id == ru)
        #expect(layouts.next == en)
        #expect(layouts.first(language: "ru") == ru)
    }

    @Test func retypeKeysRefuseOptionKeys() {
        let layouts = LayoutState([Fixture.abc, Fixture.russian], current: en)
        let entries = [WordBuffer.Entry(KeyStroke(0, [.option]), in: en)]
        guard case .refused(.unconvertibleWord) = layouts.retypeKeys(for: entries, into: Fixture.russian) else {
            Issue.record("expected a refusal")
            return
        }
        guard case let .keys(word) = layouts.retypeKeys(for: buffer("ghb").entries, into: Fixture.russian) else {
            Issue.record("expected keys")
            return
        }
        #expect(word.expected == "ghb")
        #expect(word.keys.map(\.text).joined() == "при")
    }
}

@Suite struct WordJudgeTests {
    let layouts = LayoutState([Fixture.abc, Fixture.russian], current: en)
    let focus: Focus? = Desk.textEdit

    func judge(_ judge: inout WordJudge, _ word: WordBuffer, endedBy keyCode: UInt16 = KeyCode.space)
        -> WordJudge.Ruling
    {
        judge.judge(endedBy: key(keyCode), held: 0, buffer: word, layouts: layouts, settings: Settings(),
                    focus: focus, secureInput: false)
    }

    @Test func aWrongLayoutWordIsRetypedWithTheDecision() throws {
        var wordJudge = WordJudge(classifier: Desk.classifier)
        guard case let .retype(retype) = judge(&wordJudge, buffer("ghbdtn")) else {
            Issue.record("expected a retype")
            return
        }
        #expect(retype.target == ru)
        #expect(retype.expected == "ghbdtn")
        #expect(retype.keys.map(\.text).joined() == "привет")
        #expect(retype.pending.correction.original == "ghbdtn")
        #expect(retype.pending.correction.replacement == "привет")
        #expect(retype.pending.correction.seq == 0)
        #expect(retype.held == .boundary(keyCode: KeyCode.space, endsWord: true))
        #expect(!retype.dropsLastKey)
        let decision = try #require(retype.decision)
        #expect(decision.verdict == .switch(to: ru))
        #expect(wordJudge.judged)
        #expect(wordJudge.previousLanguage == "ru")
        // Judged once: the next boundary key lets it be.
        guard case .keep = judge(&wordJudge, buffer("ghbdtn")) else {
            Issue.record("judged twice")
            return
        }
    }

    @Test func aWordInItsLayoutIsKept() {
        var wordJudge = WordJudge(classifier: Desk.classifier)
        guard case .keep = judge(&wordJudge, buffer("hello")) else {
            Issue.record("expected keep")
            return
        }
        #expect(wordJudge.previousLanguage == "en")
    }

    @Test func nothingWithoutAKnownFocus() {
        var wordJudge = WordJudge(classifier: Desk.classifier)
        let ruling = wordJudge.judge(endedBy: key(KeyCode.space), held: 0, buffer: buffer("ghbdtn"),
                                     layouts: layouts, settings: Settings(), focus: .unknown(bundleID: nil),
                                     secureInput: false)
        guard case .keep = ruling else {
            Issue.record("expected keep")
            return
        }
        #expect(!wordJudge.judged)
    }

    @Test func aSuppressedWordIsLeftAloneUntilTheNextOne() {
        var wordJudge = WordJudge(classifier: Desk.classifier)
        wordJudge.leaveWordAlone()
        guard case .keep = judge(&wordJudge, buffer("ghbdtn")) else {
            Issue.record("expected keep")
            return
        }
        // Its language still counts for the next word.
        #expect(wordJudge.previousLanguage == "en")
        wordJudge.typed(startsWord: false)
        #expect(wordJudge.switching == .suppressed)
        wordJudge.typed(startsWord: true)
        #expect(wordJudge.switching == .allowed)
        #expect(!wordJudge.judged)
    }

    @Test func anUndoneSwitchInsideTheWordIsLearnedAtItsEnd() {
        var wordJudge = WordJudge(classifier: Desk.classifier)
        wordJudge.wordUndone()
        wordJudge.undoPosted(language: "en")
        #expect(wordJudge.judged)
        wordJudge.learnAtWordEnd()
        wordJudge.typed(startsWord: false)
        guard case let .learn(word) = judge(&wordJudge, buffer("ghbdtn")) else {
            Issue.record("expected the word to learn")
            return
        }
        #expect(word == "ghbdtn")
        #expect(wordJudge.switching == .suppressed)
    }

    @Test func anImpossiblePrefixSwitchesInsideTheWord() {
        var wordJudge = WordJudge(classifier: Desk.classifier)
        let retype = wordJudge.insideWord(buffer: buffer("ghb"), layouts: layouts, settings: Settings(),
                                          focus: focus, secureInput: false)
        #expect(retype?.dropsLastKey == true)
        #expect(retype?.keys.map(\.text).joined() == "пр")
        #expect(retype?.pending.isOpen == true)
        #expect(retype?.pending.correction.replacement == "при")
        #expect(retype?.held == .boundary(keyCode: Fixture.abc.strokes("b")[0].keyCode, endsWord: false))
        #expect(wordJudge.switching == .suppressed)
    }

    @Test func wordEnds() {
        let comma = Fixture.abc.strokes(",")[0]
        let bang = Fixture.abc.strokes("!")[0]
        #expect(!WordJudge.endsWord(comma, typed: Fixture.abc, other: Fixture.russian))
        #expect(WordJudge.endsWord(bang, typed: Fixture.abc, other: Fixture.russian))
        #expect(WordJudge.endsSentence(bang, in: Fixture.abc))
        #expect(WordJudge.exceptionKey("(Hello!)") == "hello")
    }
}

@Suite struct CorrectionUndoTests {
    let layouts = LayoutState([Fixture.abc, Fixture.russian], current: ru)

    func pending(_ word: String, isOpen: Bool = false) -> CorrectionUndo.Pending {
        var pending = CorrectionUndo.Pending(
            correction: Correction(seq: 7, original: "", replacement: "", source: en, target: ru),
            strokes: Fixture.abc.strokes(word), wordLength: word.count, isOpen: isOpen
        )
        CorrectionUndo.describe(&pending, layouts: layouts)
        return pending
    }

    @Test func postedReportsAClosedCorrection() {
        var undo = CorrectionUndo()
        var effects: [Effect] = []
        undo.posted(pending("ghbdtn"), effects: &effects)
        #expect(effects == [.corrected(Correction(seq: 7, original: "ghbdtn", replacement: "привет", source: en,
                                                  target: ru))])
        #expect(undo.isLast(seq: 7))
        #expect(undo.last?.reported == true)
    }

    @Test func aClickDuringTheRetypeMakesItFinal() {
        var undo = CorrectionUndo()
        var effects: [Effect] = []
        var clicked = pending("ghbdtn")
        clicked.clicked = true
        undo.posted(clicked, effects: &effects)
        guard case let .corrected(correction) = effects.first else {
            Issue.record("expected the correction")
            return
        }
        #expect(!correction.undoable)
        #expect(undo.last == nil)
    }

    @Test func backspaceUndoesAndOtherKeysEnd() {
        var undo = CorrectionUndo()
        var effects: [Effect] = []
        undo.posted(pending("ghbdtn"), effects: &effects)
        let role1 = undo.keyDown(KeyCode.delete, held: 0)
        #expect(role1 == .undoes)
        let role2 = undo.keyDown(KeyCode.space, held: 0)
        #expect(role2 == .ends)
        #expect(undo.last == nil)
        let role3 = undo.keyDown(KeyCode.delete, held: 0)
        #expect(role3 == .ends)
    }

    @Test func lettersExtendAnOpenCorrection() {
        var undo = CorrectionUndo()
        var effects: [Effect] = []
        undo.posted(pending("ghb", isOpen: true), effects: &effects)
        #expect(effects.isEmpty)
        let d = Fixture.abc.strokes("d")[0]
        let role1 = undo.keyDown(d.keyCode, held: 0)
        #expect(role1 == .extends)
        var word = buffer("ghb", in: ru)
        word.type(d, in: ru)
        undo.extend(with: key(d.keyCode), buffer: word, layouts: layouts, alwaysFix: [:], effects: &effects)
        #expect(undo.last?.correction.replacement == "прив")
        #expect(undo.last?.extended == true)
        // Backspace fixes a typo in the word now.
        let role2 = undo.keyDown(KeyCode.delete, held: 0)
        #expect(role2 == .ends)
    }

    @Test func takeBackPutsTheWordBackOnce() throws {
        var undo = CorrectionUndo()
        var effects: [Effect] = []
        undo.posted(pending("ghbdtn"), effects: &effects)
        let undone1 = undo.takeBack(layouts: layouts, learnFromUndos: true, heldKey: true)
        let plan = try #require(undone1)
        #expect(plan.source == en)
        #expect(plan.expected == "привет")
        #expect(plan.deleteCount == 6)
        #expect(plan.keys.map(\.text).joined() == "ghbdtn")
        #expect(plan.language == "en")
        #expect(plan.inFlight.seq == 7)
        #expect(plan.inFlight.learn == "ghbdtn")
        #expect(plan.inFlight.heldKey)
        let undone2 = undo.takeBack(layouts: layouts, learnFromUndos: true, heldKey: true)
        #expect(undone2 == nil)
    }

    @Test func aCapsLockFixTeachesNothing() throws {
        var undo = CorrectionUndo()
        var effects: [Effect] = []
        var caps = pending("ghbdtn")
        caps.correction.kind = .capsLock
        undo.posted(caps, effects: &effects)
        let undone = undo.takeBack(layouts: layouts, learnFromUndos: true, heldKey: false)
        let plan = try #require(undone)
        #expect(plan.inFlight.learn == nil)
    }
}

@Suite struct ManualActionsTests {
    let layouts = LayoutState([Fixture.abc, Fixture.russian], current: en)

    @Test func retypeWordThenPutItBack() {
        var actions = ManualActions()
        var word = buffer("ghbdtn")
        guard case let .retype(first) = actions.retypeWord(buffer: word, layouts: layouts, phrases: true,
                                                           isSecureField: false)
        else {
            Issue.record("expected a retype")
            return
        }
        #expect(first.target == ru)
        #expect(first.changesLayout)
        #expect(first.word.keys.map(\.text).joined() == "привет")
        word.relabel(to: ru)
        guard case let .retype(second) = actions.retypeWord(buffer: word, layouts: layouts, phrases: true,
                                                            isSecureField: false)
        else {
            Issue.record("expected the word back")
            return
        }
        #expect(second.target == en)
        #expect(second.word.expected == "привет")
        guard case .relabelPhrase = second.edit else {
            Issue.record("a second press goes on with the phrase")
            return
        }
    }

    @Test func refusalsAndTheSelection() {
        var actions = ManualActions()
        guard case .refuse(.secureField) = actions.retypeWord(buffer: buffer("ghbdtn"), layouts: layouts,
                                                              phrases: true, isSecureField: true)
        else {
            Issue.record("expected a refusal")
            return
        }
        guard case .readSelection(.convertLayout) = actions.retypeWord(buffer: WordBuffer(), layouts: layouts,
                                                                       phrases: true, isSecureField: false)
        else {
            Issue.record("expected a selection read")
            return
        }
        guard case .refuse(.unsupportedLayout) = ManualActions.changeCase(buffer: buffer("hello", in: ru),
                                                                         layouts: layouts, isSecureField: false)
        else {
            Issue.record("expected a refusal")
            return
        }
    }

    @Test func changeCaseKeepsTheLayout() {
        guard case let .retype(retype) = ManualActions.changeCase(buffer: buffer("hello"), layouts: layouts,
                                                                  isSecureField: false)
        else {
            Issue.record("expected a retype")
            return
        }
        #expect(retype.target == en)
        #expect(!retype.changesLayout)
        #expect(retype.word.expected == "hello")
        #expect(retype.word.keys.map(\.text).joined() == "Hello")
    }

    @Test func aSelectionIsConverted() {
        guard case let .retype(target, keys) = ManualActions.selectionRead("ghbdtn", action: .convertLayout,
                                                                           layouts: layouts)
        else {
            Issue.record("expected a retype")
            return
        }
        #expect(target == ru)
        #expect(keys.map(\.text).joined() == "привет")
        guard case .refuse(.nothingSelected) = ManualActions.selectionRead("", action: .transliterate,
                                                                          layouts: layouts)
        else {
            Issue.record("expected a refusal")
            return
        }
    }
}

@Suite struct ShortcutsTests {
    @Test func aKeyTriggerRunsAndSwallowsItsKeyUp() {
        var shortcuts = Shortcuts([HotkeyBinding(.key(keyCode: KeyCode.f18, modifiers: []), action: .switchLayout)])
        guard case .runs(.switchLayout) = shortcuts.keyDown(key(KeyCode.f18), held: 0, at: 1) else {
            Issue.record("expected the action")
            return
        }
        var repeated = key(KeyCode.f18)
        repeated.isRepeat = true
        guard case .swallowed = shortcuts.keyDown(repeated, held: 0, at: 1.1) else {
            Issue.record("a repeat runs nothing")
            return
        }
        let swallowed1 = shortcuts.keyUp(KeyCode.f18)
        #expect(swallowed1)
        let swallowed2 = shortcuts.keyUp(KeyCode.f18)
        #expect(!swallowed2)
        guard case .typing = shortcuts.keyDown(key(KeyCode.space), held: 0, at: 2) else {
            Issue.record("expected typing")
            return
        }
    }

    @Test func capsLockIsNoChord() {
        var shortcuts = Shortcuts(Settings().hotkeys)
        let action = shortcuts.modifiersChanged(keyCode: KeyCode.capsLock, flags: EventFlags.capsLock, at: 1)
        #expect(action == nil)
    }
}
