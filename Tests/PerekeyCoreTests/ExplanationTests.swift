// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

@Suite struct ExplanationTests {
    private func decision(_ reason: Classifier.Reason, verdict: Classifier.Verdict = .keep, score: Double = 4,
                          margin: Double = 10) -> Classifier.Decision
    {
        Classifier.Decision(verdict: verdict, score: score, reason: reason, language: nil, margin: margin,
                            typedForm: .unknown, otherForm: .known, typedLanguage: "en", otherLanguage: "ru")
    }

    @Test func everyReasonHasFacts() {
        for reason in Classifier.Reason.allCases {
            let explanation = Explanation(decision: decision(reason), typed: "ghbdtn", other: "привет")
            #expect(!explanation.statements.isEmpty, "\(reason) says nothing")
        }
    }

    @Test func guardsAreNotComparisons() {
        for reason in [Classifier.Reason.empty, .unsupported, .tooLong, .digits, .kept, .passwordLike] {
            let explanation = Explanation(decision: decision(reason), typed: "a", other: "b")
            #expect(explanation.statements == [.note(reason)])
        }
    }

    @Test func doubtfulWordsShowBothReadingsAndTheReason() {
        for reason in [Classifier.Reason.codeLike, .noise, .mixedCase, .bothPlausible, .shortWord] {
            let explanation = Explanation(decision: decision(reason), typed: "ghbdtn", other: "привет")
            #expect(explanation.statements.count == 3)
            #expect(explanation.statements.last == .note(reason))
        }
    }

    @Test func aComparisonShowsTheEdgeAndTheThreshold() {
        let won = Explanation(decision: decision(.compared, verdict: .switch(to: LayoutID("ru")), score: 38),
                              typed: "ghbdtn", other: "привет")
        #expect(won.switched)
        #expect(won.statements == [
            .reading(text: "ghbdtn", form: .unknown, language: "en"),
            .reading(text: "привет", form: .known, language: "ru"),
            .edge(score: 38, needed: 10, switched: true),
        ])
        let close = Explanation(decision: decision(.compared, verdict: .unsure, score: 4), typed: "a", other: "b")
        #expect(!close.switched)
        #expect(close.statements.last == .edge(score: 4, needed: 10, switched: false))
    }

    @Test func anOtherReadingThatIsNoWordHasNoEdge() {
        let explanation = Explanation(decision: decision(.compared, score: -.infinity), typed: "x", other: "y")
        #expect(explanation.statements == [.reading(text: "y", form: .known, language: "ru")])
    }

    @Test func correctionsExplainThemselves() {
        let ru = LayoutID("ru")
        func correction(_ kind: Correction.Kind) -> Correction {
            Correction(seq: 1, original: "ghbdtn", replacement: "привет", source: LayoutID("en"), target: ru, kind: kind)
        }
        var layout = correction(.layout)
        layout.decision = decision(.compared, verdict: .switch(to: ru), score: 38)
        #expect(Explanation(correction: layout).statements.count == 3)

        var inside = correction(.layout)
        inside.insideWord = true
        inside.sourceLanguage = "en"
        #expect(Explanation(correction: inside).statements == [.impossibleStart(text: "ghbdtn", language: "en")])

        for change in TypoCorrector.Change.allCases {
            var typo = correction(.typo)
            typo.typoChange = change
            #expect(Explanation(correction: typo).statements == [.typo(change)])
        }
        for kind in [Correction.Kind.capsLock, .doubleCapitals, .abbreviation, .yo] {
            #expect(Explanation(correction: correction(kind)).statements == [.rule(kind)])
        }
    }

    @Test func aLayoutSwitchWithATypoShowsBoth() {
        let ru = LayoutID("ru")
        var both = Correction(seq: 1, original: "ghbdtn", replacement: "привет", source: LayoutID("en"), target: ru,
                              kind: .typo)
        both.decision = decision(.compared, verdict: .switch(to: ru), score: 38)
        both.typoChange = .substitute
        let statements = Explanation(correction: both).statements
        #expect(statements.count == 4)
        #expect(statements.last == .typo(.substitute))
    }
}
