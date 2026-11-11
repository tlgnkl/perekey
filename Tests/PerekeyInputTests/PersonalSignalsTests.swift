// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import Testing
@testable import PerekeyInput

struct PersonalSignalsTests {
    private let en = LayoutID("en"), ru = LayoutID("ru")

    /// "Lfirf" → "Дашка", switched because the lexicon has the word.
    private func personalSwitch(seq: UInt32 = 1) -> Correction {
        var correction = Correction(seq: seq, original: "Lfirf", replacement: "Дашка,", source: en, target: ru)
        var decision = Classifier.Decision(verdict: .switch(to: ru), score: 30, reason: .compared, language: "ru",
                                           margin: 10, typedForm: .unknown, otherForm: .known, typedLanguage: "en",
                                           otherLanguage: "ru")
        decision.otherPersonal = true
        correction.decision = decision
        return correction
    }

    private func report(_ channel: UndoChannel, _ followUp: UndoFollowUp) -> UndoReport {
        UndoReport(word: "lfirf", app: nil, channel: channel, followUp: followUp, threshold: 2,
                   facts: UndoFacts(kind: .layout, decision: nil))
    }

    @Test func aSwitchToAPersonalWordIsRemembered() throws {
        let word = try #require(PersonalWordRef(switchedTo: personalSwitch()))
        #expect(word == PersonalWordRef(text: "Дашка,", language: "ru"))
    }

    @Test func aSwitchToAnyOtherWordIsNot() {
        var plain = personalSwitch()
        var decision = try! #require(plain.decision)
        decision.otherPersonal = false
        plain.decision = decision
        #expect(PersonalWordRef(switchedTo: plain) == nil)
        var none = personalSwitch()
        none.decision = nil
        #expect(PersonalWordRef(switchedTo: none) == nil)
        var noLanguage = personalSwitch()
        var noCode = try! #require(noLanguage.decision)
        noCode.otherLanguage = nil
        noLanguage.decision = noCode
        #expect(PersonalWordRef(switchedTo: noLanguage) == nil)
        var longCode = personalSwitch()
        var odd = try! #require(longCode.decision)
        odd.otherLanguage = "ruu"
        longCode.decision = odd
        #expect(PersonalWordRef(switchedTo: longCode) == nil)
    }

    @Test func theButtonsUndoDropsTheWord() {
        var signals = PersonalSignals()
        signals.corrected(personalSwitch())
        signals.undone(seq: 1)
        #expect(signals.settled(report(.button, .none)) == PersonalWordRef(text: "Дашка,", language: "ru"))
    }

    @Test func theShortcutsUndoDropsTheWord() {
        var signals = PersonalSignals()
        signals.corrected(personalSwitch())
        signals.undone(seq: 1)
        #expect(signals.settled(report(.shortcut, .none)) != nil)
    }

    @Test func aBackspaceThatKeptTheWordAsTypedDropsIt() {
        var signals = PersonalSignals()
        signals.corrected(personalSwitch())
        signals.undone(seq: 1)
        #expect(signals.settled(report(.backspace, .continued)) != nil)
    }

    @Test func aBackspaceThatWasForSomethingElseDoesNot() {
        for followUp in [UndoFollowUp.punctuation, .retyped, .edited, .unknown] {
            var signals = PersonalSignals()
            signals.corrected(personalSwitch())
            signals.undone(seq: 1)
            #expect(signals.settled(report(.backspace, followUp)) == nil, "\(followUp)")
        }
    }

    @Test func theUndoOfAnotherSwitchDoesNot() {
        var signals = PersonalSignals()
        signals.corrected(personalSwitch(seq: 1))
        signals.undone(seq: 9)
        #expect(signals.settled(report(.button, .none)) == nil)
        // The word of seq 1 is still there for its own undo.
        signals.undone(seq: 1)
        #expect(signals.settled(report(.button, .none)) != nil)
    }

    @Test func anUndoNobodySettledDoesNotLeakIntoTheNext() {
        var signals = PersonalSignals()
        signals.corrected(personalSwitch(seq: 1))
        signals.undone(seq: 1)
        // No report came for it. A later undo of a switch that is not personal must not drop the word.
        signals.undone(seq: 2)
        #expect(signals.settled(report(.button, .none)) == nil)
    }

    @Test func aSettledReportIsUsedOnce() {
        var signals = PersonalSignals()
        signals.corrected(personalSwitch())
        signals.undone(seq: 1)
        #expect(signals.settled(report(.button, .none)) != nil)
        #expect(signals.settled(report(.button, .none)) == nil)
    }

    @Test func onlyTheLatestSwitchesAreRemembered() {
        var signals = PersonalSignals()
        for seq in 1...UInt32(PersonalSignals.remembered + 3) { signals.corrected(personalSwitch(seq: seq)) }
        signals.undone(seq: 1)
        #expect(signals.settled(report(.button, .none)) == nil, "the oldest are gone")
        signals.undone(seq: UInt32(PersonalSignals.remembered + 3))
        #expect(signals.settled(report(.button, .none)) != nil)
    }

    @Test func aRetypeByHandOfAPersonalWordNamesTheWordAsTyped() throws {
        var decision = Classifier.Decision(verdict: .keep, score: -10, reason: .compared, language: "en",
                                           typedForm: .known, otherForm: .unknown, typedLanguage: "en",
                                           otherLanguage: "ru")
        #expect(PersonalWordRef(retyped: "dashka", decision: decision) == nil, "an ordinary word")
        decision.typedPersonal = true
        #expect(PersonalWordRef(retyped: "dashka", decision: decision) == PersonalWordRef(text: "dashka", language: "en"))
        #expect(PersonalWordRef(retyped: "dashka", decision: nil) == nil)
    }
}
