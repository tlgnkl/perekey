// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

/// macOS raises the first letter of a sentence right after Perekey typed the
/// word ("привет " becomes "Привет "). The retype and the Backspace undo
/// that follow must still find the word, and never leave garbage when they do not.
@Suite struct AutocapitalizationTests {
    @Test func matchTakesARaisedFirstLetter() {
        #expect(CaretText.match(expected: "привет ", actual: "привет ") == .exact)
        #expect(CaretText.match(expected: "привет ", actual: "Привет ") == .firstLetterRaised)
        #expect(CaretText.match(expected: "привет ", actual: "Привет\u{00A0}") == .firstLetterRaised)
        #expect(CaretText.match(expected: "привет ", actual: "привет\u{00A0}") == .exact)
    }

    @Test func anyOtherDifferenceIsAMismatch() {
        #expect(CaretText.match(expected: "привет ", actual: "Првиет ") == nil)
        #expect(CaretText.match(expected: "привет ", actual: "ПРивет ") == nil, "two capitals are not one raised letter")
        #expect(CaretText.match(expected: "привет ", actual: "Привет") == nil, "shorter")
        #expect(CaretText.match(expected: "Привет ", actual: "привет ") == nil, "lowered is not what the system does")
        #expect(CaretText.match(expected: "[x", actual: "{x") == nil)
        #expect(CaretText.match(expected: "", actual: "a") == nil)
    }

    @Test func aRetypeRaisesItsFirstLetter() throws {
        let key = Retype.Key(stroke: KeyStroke(5), text: "g")
        let retype = Retype(deleteCount: 7, keys: [key, Retype.Key(stroke: KeyStroke(4), text: "h")], target: Fixture.abc.id,
                            expected: "привет ", seq: 1, viaAccessibility: false, origin: .manual(.convertLastWord))
        #expect(retype.raisingFirstLetter().text == "Gh")
        #expect(retype.raisingFirstLetter().deleteCount == 7)
        let empty = Retype(deleteCount: 0, keys: [], target: Fixture.abc.id, expected: "", seq: 1, viaAccessibility: false, origin: .manual(.convertLastWord))
        #expect(empty.raisingFirstLetter() == empty)
    }

    /// Case 1б of the live notes: "ghbdtn " becomes "привет ", macOS makes it "Привет ",
    /// Option has to bring "ghbdtn " back, not do nothing.
    @Test func optionAfterTheSystemRaisedAnAutomaticCorrection() {
        var desk = Desk()
        desk.autocapitalizes = true
        desk.type("ghbdtn ")
        #expect(desk.text == "Привет ")
        desk.tapOption()
        #expect(desk.text == "Ghbdtn ", "the word comes back raised, as the user saw it")
        #expect(desk.history.count == 2)
    }

    /// 1в: Backspace right after the correction puts the word back; before the fix the
    /// check failed, the Backspace went through and ate the space ("Привет").
    @Test func backspaceAfterTheSystemRaisedAnAutomaticCorrection() {
        var desk = Desk()
        desk.autocapitalizes = true
        desk.type("ghbdtn ")
        desk.press(KeyCode.delete)
        #expect(desk.text == "Ghbdtn ")
        #expect(desk.undone.count == 1)
    }

    /// 1а: a manual retype, then a second one within 400 ms. Never "Hellhello".
    @Test func twoManualRetypesOfTheFirstWord() {
        var desk = Desk()
        desk.autocapitalizes = true
        desk.type("hello")
        desk.tapOption()
        #expect(desk.text == "Руддщ")
        desk.tapOption()
        #expect(desk.text == "Hello")
        desk.tapOption()
        #expect(desk.text == "Руддщ")
    }

    @Test func withoutTheSystemRaisingNothingChanges() {
        var desk = Desk()
        desk.type("ghbdtn ")
        desk.tapOption()
        #expect(desk.text == "ghbdtn ")
        var second = Desk()
        second.autocapitalizes = true
        second.type("ghbdtn ")
        second.type("ghbdtn ")
        #expect(second.text == "Привет привет ", "only the first word of a sentence is raised")
        second.tapOption()
        #expect(second.text == "Привет ghbdtn ")
    }

    /// The field is not what the machine thinks: nothing is erased.
    @Test func aChangedWordIsRefusedNotMangled() {
        var desk = Desk()
        desk.type("hello")
        desk.text = "Hellx"
        desk.tapOption()
        #expect(desk.text == "Hellx")
    }
}

/// The retype of a word macOS raised reports "привет " as the original and
/// "Ghbdtn " as the text. What learning and the undo count must be the same as
/// for the word the app did not raise.
@Suite struct RaisedUndoAccountingTests {
    static func undoReports(autocapitalizes: Bool, _ undo: (inout Desk) -> Void) -> [UndoReport] {
        var desk = Desk()
        desk.autocapitalizes = autocapitalizes
        desk.type("ghbdtn ")
        undo(&desk)
        return desk.undoReports
    }

    @Test func backspaceUndoCountsTheSameWord() {
        let raised = Self.undoReports(autocapitalizes: true) { $0.press(KeyCode.delete) }
        let plain = Self.undoReports(autocapitalizes: false) { $0.press(KeyCode.delete) }
        #expect(raised.map(\.word) == plain.map(\.word))
        #expect(raised.map(\.channel) == plain.map(\.channel))
    }

    @Test func shortcutUndoCountsTheSameWord() {
        let raised = Self.undoReports(autocapitalizes: true) { $0.tapOption() }
        let plain = Self.undoReports(autocapitalizes: false) { $0.tapOption() }
        #expect(raised.map(\.word) == plain.map(\.word))
        #expect(raised.map(\.channel) == plain.map(\.channel))
        #expect(raised.map(\.word) == ["ghbdtn"], "the word the user typed, not \"Ghbdtn \" or \"привет \"")
    }

    /// `InputController` unlearns with the event's two strings: the word the machine expected in the
    /// field ("jrtq ") and what the retype typed, which macOS raised in the field ("Окей ").
    @Test func aRetypedWordIsUnlearnedWhateverTheCaseOfTheText() {
        func rules() -> WordRules {
            WordRules(learned: [LearnedWord(word: "jrtq", learnedAt: 1), LearnedWord(word: "ytn", learnedAt: 1)])
        }
        var plain = rules(), raised = rules()
        let expected = plain.unlearn(typed: "jrtq ", retyped: "окей ", app: nil)
        #expect(expected == Unlearned(word: "jrtq", app: nil))
        #expect(raised.unlearn(typed: "jrtq ", retyped: "Окей ", app: nil) == expected)
        #expect(raised.learned == plain.learned)
    }
}
