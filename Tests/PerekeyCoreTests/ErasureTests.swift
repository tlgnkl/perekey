// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

/// A retype never types its new word over a field the Backspaces left in a state
/// nobody expected: the word is replaced, the field is as it was, or nothing is
/// typed and the outcome says why.
@Suite struct ErasureTests {
    static let snapshot = Erasure.Snapshot(start: 3, lead: "ab ", word: "hello")

    static func reading(_ location: Int, lead: String = "ab ", remaining: String = "") -> Erasure.Reading {
        Erasure.Reading(location: location, lead: lead, remaining: remaining)
    }

    // MARK: - judge

    @Test func judgesTheField() {
        let snapshot = Self.snapshot
        #expect(Erasure.judge(snapshot, Self.reading(3)) == .done)
        #expect(Erasure.judge(snapshot, Self.reading(3, lead: "ab\u{00A0}")) == .done, "no-break space")
        #expect(Erasure.judge(snapshot, Self.reading(5, remaining: "he")) == .pending(remaining: "he"))
        #expect(Erasure.judge(snapshot, Self.reading(5, remaining: "He")) == .pending(remaining: "He"), "raised")
        #expect(Erasure.judge(snapshot, Self.reading(8, remaining: "hello")) == .pending(remaining: "hello"))
        #expect(Erasure.judge(snapshot, Self.reading(2, lead: "ab")) == .overErased)
        #expect(Erasure.judge(snapshot, Self.reading(3, lead: "ax ")) == .changed, "the text before the word changed")
        #expect(Erasure.judge(snapshot, Self.reading(5, remaining: "wo")) == .changed, "not the start of the word")
        #expect(Erasure.judge(snapshot, Self.reading(5, remaining: "")) == .changed, "the field was not read")
        #expect(Erasure.judge(snapshot, Erasure.Reading(location: 3, selectionLength: 1, lead: "ab ")) == .changed)
        #expect(Erasure.judge(snapshot, nil) == .unreadable)
    }

    @Test func whatIsLeftBeforeTheWordIsCheckedWhenMoreIsGone() {
        let snapshot = Erasure.Snapshot(start: 7, lead: "xyz ab ", word: "hello")
        #expect(Erasure.judge(snapshot, Self.reading(4, lead: "xyz ")) == .overErased)
        #expect(Erasure.judge(snapshot, Self.reading(4, lead: "Xyz ")) == .changed, "the app changed what is left")
        #expect(Erasure.judge(snapshot, Self.reading(0, lead: "")) == .overErased)
    }

    @Test func onlyPlainTextIsTypedBack() {
        #expect(Erasure.isSafeToType("ab hello"))
        #expect(Erasure.isSafeToType("ёж 😀"))
        for unsafe in ["a\nb", "a\rb", "a\tb", "a\r\nb", "a\u{2028}b", "a\u{0}b", "\u{FFFD}b"] {
            #expect(!Erasure.isSafeToType(unsafe), "\(unsafe.unicodeScalars.map(\.value))")
        }
    }

    // MARK: - confirm, on a field

    /// Every outcome says what the field holds once all keys are handled,
    /// late ones too: the word gone and the rest as before, exactly the
    /// snapshot, or a refusal with nothing typed back over a field that moved.
    static func expectHonest(_ outcome: Erasure.Outcome, _ field: AppField, was before: String, word: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        field.drain()
        let lead = String(before.dropLast(word.count))
        switch outcome {
        case .erased:
            #expect(field.text == lead, "the word gone, nothing else", sourceLocation: sourceLocation)
        case .restored:
            #expect(field.text == before, "typed back means as before", sourceLocation: sourceLocation)
        case .stopped(.restoreFailed):
            break
        case .stopped:
            #expect(field.typedBack.isEmpty, "a refusal types nothing", sourceLocation: sourceLocation)
        }
    }

    @Test func theWordErasedIsConfirmed() {
        let field = AppField("ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.postBackspaces(5)
        #expect(field.confirm(snapshot) == .erased)
        #expect(field.text == "ab ")
        #expect(field.typedBack.isEmpty)
    }

    @Test func aLetterRaisedAfterTheCheckChangesNothing() {
        let field = AppField("ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.text = "ab Hello"
        field.postBackspaces(5)
        #expect(field.confirm(snapshot) == .erased)
        #expect(field.text == "ab ")
    }

    @Test func aBackspaceTheAppAteLeavesTheWordHalfErasedAndTypesNothingBack() {
        let field = AppField("ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.postBackspaces(5, eaten: [0])
        #expect(field.confirm(snapshot) == .stopped(.stalled))
        #expect(field.typedBack.isEmpty)
        #expect(field.text == "ab h")
    }

    /// A Backspace the app is late with comes before any text typed back:
    /// typing back a half-erased word would leave "ab ello".
    @Test func aLateBackspaceNeverMixesWithTextTypedBack() {
        let field = AppField("ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.postBackspaces(5, late: [4: 0.3])
        let outcome = field.confirm(snapshot)
        #expect(outcome == .stopped(.stalled))
        #expect(field.typedBack.isEmpty)
        Self.expectHonest(outcome, field, was: "ab hello", word: "hello")
        #expect(field.text == "ab ", "the late Backspace erased the rest; no letter of the word typed in between")
    }

    @Test func aWordTheAppReplacedIsNotTypedOver() {
        let field = AppField("ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.text = "ab worldly"
        field.postBackspaces(5)
        #expect(field.confirm(snapshot) == .stopped(.changed))
        #expect(field.typedBack.isEmpty)
    }

    /// The app made the word shorter after the check; the Backspaces took
    /// "ab " too. The text before it and the word go back: the field is as
    /// the check saw it, not "ab " with the word lost.
    @Test func anOverErasedFieldIsPutBackWhole() {
        let field = AppField("ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.text = "ab hi"
        field.postBackspaces(5)
        let outcome = field.confirm(snapshot)
        #expect(outcome == .restored)
        #expect(field.typedBack == ["ab hello"])
        Self.expectHonest(outcome, field, was: "ab hello", word: "hello")
        #expect(field.text == "ab hello")
    }

    @Test func anOverErasedFieldWithTheTextBeforeChangedIsNotTypedBack() {
        let field = AppField("xyz ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.text = "Xyz ab hi"
        field.postBackspaces(5)
        let outcome = field.confirm(snapshot)
        #expect(outcome == .stopped(.changed))
        #expect(field.typedBack.isEmpty, "never \"Xyz ab \" put together from two versions")
        #expect(field.text == "Xyz ")
    }

    @Test func anOverErasedFieldChangedWhileItStandsStillIsNotTypedBack() {
        let field = AppField("xyz ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.text = "xyz ab hi"
        field.postBackspaces(5)
        // The app raises the first letter while the check waits for the caret to stand still.
        field.schedule(at: 0.1) { $0 = "X" + $0.dropFirst() }
        let outcome = field.confirm(snapshot)
        #expect(outcome == .stopped(.changed))
        #expect(field.typedBack.isEmpty)
    }

    @Test(arguments: ["\n", "\r", "\t", "\r\n"])
    func aLineBreakOrTabIsNeverTypedBack(_ separator: String) {
        let field = AppField("a\(separator)hello")
        let snapshot = field.snapshot(word: "hello")
        field.text = "a\(separator)hi"
        field.postBackspaces(5)
        let outcome = field.confirm(snapshot)
        #expect(outcome == .stopped(.unsafeText))
        #expect(field.typedBack.isEmpty, "a messenger sends on Return")
        Self.expectHonest(outcome, field, was: "a\(separator)hello", word: "hello")
    }

    /// The 8 units before the word began in the middle of an emoji: what was
    /// read of it is U+FFFD, and typing that back is a wrong character.
    @Test func halfASurrogatePairIsNeverTypedBack() {
        let field = AppField("\u{FFFD}b hi")
        let snapshot = Erasure.Snapshot(start: 3, lead: "\u{FFFD}b ", word: "hello")
        field.postBackspaces(5)
        #expect(field.confirm(snapshot) == .stopped(.unsafeText))
        #expect(field.typedBack.isEmpty)
    }

    @Test func aCaretInsideASurrogatePairIsNeverTypedBackFrom() {
        var clock = 0.0
        let snapshot = Erasure.Snapshot(start: 3, lead: "😀 ", word: "hello")
        let outcome = Erasure.confirm(
            snapshot, deadline: 2, now: { clock }, pause: { clock += 0.01 },
            read: { Erasure.Reading(location: 1, lead: String(decoding: "😀".utf16.prefix(1), as: UTF16.self)) },
            restore: { _ in Issue.record("half an emoji typed back") })
        #expect(outcome == .stopped(.unsafeText))
    }

    /// A Backspace later than the wait for the caret to stand still lands
    /// before the text typed back. The field is not as before, and the
    /// outcome says so: it never claims `.restored`.
    @Test func aBackspaceLateAfterTheTypingBackIsReported() {
        let field = AppField("ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.text = "ab hi"
        field.postBackspaces(5, late: [4: 0.25])
        let outcome = field.confirm(snapshot)
        #expect(outcome == .stopped(.restoreFailed))
        Self.expectHonest(outcome, field, was: "ab hello", word: "hello")
        #expect(field.text != "ab hello")
    }

    @Test func aBackspaceLateWithinTheWaitIsWaitedFor() {
        let field = AppField("ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.text = "ab hi"
        field.postBackspaces(5, late: [4: 0.1])
        let outcome = field.confirm(snapshot)
        #expect(outcome == .restored)
        Self.expectHonest(outcome, field, was: "ab hello", word: "hello")
    }

    @Test func noBackspaceWorkingTypesNothingAndPutsNothingBack() {
        let field = AppField("ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.postBackspaces(5, eaten: Set(0..<5))
        #expect(field.confirm(snapshot) == .stopped(.idle))
        #expect(field.text == "ab hello")
        #expect(field.typedBack.isEmpty)
    }

    @Test func aFieldThatCannotBeReadTypesNothing() {
        var clock = 0.0
        let outcome = Erasure.confirm(Self.snapshot, deadline: 2, now: { clock }, pause: { clock += 0.01 },
                                      read: { nil }, restore: { _ in Issue.record("nothing to put back") })
        #expect(outcome == .stopped(.unreadable))
    }

    // MARK: - the fence's deadline

    /// The caret moves all the time and never shows the word gone: the check
    /// still ends before the fence lets the user's keys go, a read included.
    @Test func aFieldThatNeverSettlesEndsBeforeTheDeadline() {
        let field = AppField("ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.readTime = 0.1
        // Two or three changes between reads, four states: never the same twice in a row.
        let states = ["ab h", "ab he", "ab hel", "ab hell"]
        for tick in 0..<1000 {
            field.schedule(at: Double(tick) * 0.05) { $0 = states[tick % states.count] }
        }
        let outcome = field.confirm(snapshot, deadline: 2)
        #expect(outcome == .stopped(.late))
        #expect(field.clock < 2, "ended at \(field.clock)")
        #expect(field.typedBack.isEmpty)
    }

    @Test func noTypingBackThatCannotEndBeforeTheDeadline() {
        let field = AppField("ab hello")
        let snapshot = field.snapshot(word: "hello")
        field.text = "ab hi"
        field.postBackspaces(5)
        // The field stands still at 0.16; typing back and its check need 0.7 more.
        let outcome = field.confirm(snapshot, deadline: 0.6)
        #expect(outcome == .stopped(.overErased))
        #expect(field.typedBack.isEmpty)
        #expect(field.clock < 0.6)
    }

    @Test func noBackspacesWithoutTimeForTheCheck() {
        let timing = Erasure.Timing()
        #expect(Erasure.hasTime(at: 0, deadline: 2))
        #expect(!Erasure.hasTime(at: 2 - timing.least, deadline: 2))
        #expect(timing.least == 0.7)
    }

    // MARK: - the machine and a field that changes meanwhile

    /// Types "hello" in the English layout; Option retypes it as "Руддщ".
    static func desk(_ interference: Desk.Interference?) -> Desk {
        var desk = Desk()
        desk.autocapitalizes = true
        desk.type("hello")
        desk.interference = interference
        desk.tapOption()
        return desk
    }

    @Test func aRetypeAfterNothingHappenedTypesTheWord() {
        let desk = Self.desk(nil)
        #expect(desk.text == "Руддщ")
        #expect(desk.erasures == [.erased])
    }

    @Test func aLetterRaisedBetweenTheCheckAndTheBackspacesGivesTheRightWord() {
        let desk = Self.desk(.raisesLetter)
        #expect(desk.text == "Руддщ")
        #expect(desk.erasures == [.erased])
    }

    @Test func aBackspaceEatenLeavesTheRestOfTheWordAndNothingElse() {
        let desk = Self.desk(.eatsBackspaces(count: 1))
        #expect(desk.text == "h", "never \"hРуддщ\", never a letter typed back after a late Backspace")
        #expect(desk.erasures == [.stopped(.stalled)])
    }

    @Test func aWordTheAppMadeShorterIsPutBack() {
        var desk = Desk()
        desk.type("ab hello")
        desk.interference = .replacesWord("hi")
        desk.tapOption()
        #expect(desk.text == "ab hello")
        #expect(desk.erasures == [.restored])
    }

    @Test func allBackspacesEatenLeavesTheFieldAsItWas() {
        let desk = Self.desk(.eatsBackspaces(count: 5))
        #expect(desk.text == "hello")
        #expect(desk.erasures == [.stopped(.idle)])
    }

    @Test func aWordReplacedMeanwhileIsNotMixedWithTheNewOne() {
        let desk = Self.desk(.replacesWord("worldly"))
        #expect(!desk.text.contains("Руддщ"))
        #expect(desk.erasures == [.stopped(.changed)])
    }

    @Test func theMachineGoesOnAfterAStoppedRetype() {
        var desk = Self.desk(.eatsBackspaces(count: 1))
        desk.interference = nil
        desk.type(" ok")
        #expect(desk.text == "h ok", "the fence was let go: typing reaches the field")
        #expect(desk.machine.pendingRetypeSeq == nil)
    }

    // MARK: - the fence and the check after the Backspaces

    /// Until `.retypePosted` the fence holds for `postTimeout` (2 s) from the
    /// Option, not `fenceTimeout` (0.3 s): that one starts at the posting.
    @Test func theFenceHoldsForPostTimeoutUntilTheRetypeIsPosted() {
        var desk = Desk()
        desk.type("hello")
        desk.time += 0.3
        desk.send(.flagsChanged(keyCode: ModifierKey.leftOption.keyCode, flags: Keyboard.leftOption, origin: .user,
                                time: desk.time))
        desk.time += 0.08
        let released = desk.time
        desk.send(.flagsChanged(keyCode: ModifierKey.leftOption.keyCode, flags: 0, origin: .user, time: released))
        let seq = desk.machine.pendingRetypeSeq
        #expect(seq != nil)
        #expect(desk.machine.fenceDeadline == released + Settings().postTimeout)
        #expect(Settings().postTimeout == 2)
        desk.send(.deadline(time: released + 1.9))
        #expect(desk.machine.pendingRetypeSeq == seq, "still held 1.9 s in")
        desk.send(.retypePosted(seq: seq!, time: released + 1.95))
        #expect(desk.machine.fenceDeadline == released + 1.95 + Settings().fenceTimeout)
    }

    /// Every wait of the check together: a busy app handles a Backspace every
    /// 0.14 s, just under `stall`, so each one starts the wait again. 15 of
    /// them would take 2.1 s, past the fence; the check stops before it, while
    /// the fence still holds the user's keys.
    @Test func theCheckEndsWhileTheFenceStillHolds() {
        var desk = Desk()
        desk.type("abcdefghijklmno")
        desk.interference = .slowBackspaces(every: 0.14)
        desk.tapOption()
        #expect(desk.erasures == [.stopped(.late)])
        let end = try! #require(desk.erasureEnds.first)
        #expect(end.ended < end.fenceDeadline, "ended \(end.ended), fence until \(end.fenceDeadline)")
        #expect(end.holding, "the fence still held when the check ended")
    }

    @Test func aQuickBusyAppIsWaitedFor() {
        let desk = Self.desk(.slowBackspaces(every: 0.1))
        #expect(desk.text == "Руддщ")
        #expect(desk.erasures == [.erased])
        #expect(desk.erasureEnds.allSatisfy { $0.holding })
    }

    /// What the test above caught the code doing: the retype before the check after the Backspaces.
    @Test func withoutTheCheckTheSameFieldGetsAMix() {
        var desk = Desk()
        desk.autocapitalizes = true
        desk.confirmsErasure = false
        desk.type("hello")
        desk.interference = .eatsBackspaces(count: 1)
        desk.tapOption()
        #expect(desk.text == "hруддщ", "the first Backspace eaten: the old letter stays in the new word")
    }
}
