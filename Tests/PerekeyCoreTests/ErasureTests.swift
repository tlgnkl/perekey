// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

/// A retype never types its new word over a field the Backspaces left in a state
/// nobody expected: the word is replaced, or the field is as it was.
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

    // MARK: - confirm, on a field

    /// A field with a caret at its end and Backspaces that work one by one.
    final class Field {
        var text: String
        var queue = 0
        var clock = 0.0
        var typed: [String] = []
        let snapshot: Erasure.Snapshot

        init(_ text: String, word: String) {
            self.text = text
            let start = text.utf16.count - word.utf16.count
            snapshot = Erasure.Snapshot(start: start, lead: Field.slice(text, max(0, start - 8)..<start), word: word)
        }

        static func slice(_ text: String, _ range: Range<Int>) -> String {
            guard range.lowerBound < range.upperBound else { return "" }
            let units = Array(text.utf16)
            return String(decoding: units[range.lowerBound..<min(range.upperBound, units.count)], as: UTF16.self)
        }

        func read() -> Erasure.Reading? {
            let location = text.utf16.count
            let gap = location - snapshot.start
            return Erasure.Reading(
                location: location, lead: Self.slice(text, max(0, snapshot.start - 8)..<snapshot.start),
                remaining: gap > 0 && gap <= snapshot.word.utf16.count ? Self.slice(text, snapshot.start..<location) : "")
        }

        func confirm(backspaces: Int, dropped: Int = 0) -> Erasure.Outcome {
            queue = backspaces - dropped
            return Erasure.confirm(
                snapshot, now: { self.clock },
                pause: {
                    self.clock += 0.002
                    if self.queue > 0, !self.text.isEmpty { self.text.removeLast(); self.queue -= 1 }
                },
                read: { self.read() },
                restore: { self.typed.append($0); self.text += $0 })
        }
    }

    @Test func theWordErasedIsConfirmed() {
        let field = Field("ab hello", word: "hello")
        #expect(field.confirm(backspaces: 5) == .erased)
        #expect(field.text == "ab ")
        #expect(field.typed.isEmpty)
    }

    @Test func aLetterRaisedAfterTheCheckChangesNothing() {
        let field = Field("ab hello", word: "hello")
        field.text = "ab Hello"
        #expect(field.confirm(backspaces: 5) == .erased)
        #expect(field.text == "ab ")
    }

    @Test func aBackspaceTheAppAteIsPutBack() {
        let field = Field("ab hello", word: "hello")
        #expect(field.confirm(backspaces: 5, dropped: 1) == .restored)
        #expect(field.text == "ab hello", "the field is as it was")
        #expect(field.typed == ["ello"])
    }

    @Test func aWordTheAppReplacedIsNotTypedOver() {
        let field = Field("ab hello", word: "hello")
        field.text = "ab worldly"
        let outcome = field.confirm(backspaces: 5)
        #expect(outcome == .stopped(.changed))
        #expect(field.typed.isEmpty)
    }

    @Test func aShorterWordTheAppPutInTakesTheTextBeforeItAndItIsPutBack() {
        let field = Field("ab hello", word: "hello")
        field.text = "ab hi"
        #expect(field.confirm(backspaces: 5) == .restored)
        #expect(field.text == "ab ", "the text before the word is back; the app's own \"hi\" went with the Backspaces")
        #expect(field.typed == ["ab "])
    }

    @Test func noBackspaceWorkingTypesNothingAndPutsNothingBack() {
        let field = Field("ab hello", word: "hello")
        #expect(field.confirm(backspaces: 5, dropped: 5) == .stopped(.idle))
        #expect(field.text == "ab hello")
        #expect(field.typed.isEmpty)
    }

    @Test func aFieldThatCannotBeReadTypesNothing() {
        var clock = 0.0
        let outcome = Erasure.confirm(Self.snapshot, now: { clock }, pause: { clock += 0.01 },
                                      read: { nil }, restore: { _ in Issue.record("nothing to put back") })
        #expect(outcome == .stopped(.unreadable))
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

    @Test func aBackspaceEatenLeavesTheFieldAsItWas() {
        let desk = Self.desk(.eatsBackspaces(count: 1))
        #expect(desk.text == "hello", "never \"hРуддщ\"")
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
        #expect(desk.text == "hello ok", "the fence was let go: typing reaches the field")
        #expect(desk.machine.pendingRetypeSeq == nil)
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
