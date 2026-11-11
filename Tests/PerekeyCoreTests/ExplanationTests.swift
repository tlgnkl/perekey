// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
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
        inside.decision = Classifier.Decision(verdict: .keep, score: 0, reason: .compared, language: nil,
                                              typedLanguage: "en")
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

    @Test func theReportSummaryHasNamesAndNumbersOnly() {
        let ru = LayoutID("ru")
        let won = decision(.compared, verdict: .switch(to: ru), score: 38.24)
        #expect(FalseSwitchReport.summary(of: won) == "reason=compared score=38.2 threshold=10 typed=unknown other=known")
        let none = decision(.codeLike, score: -.infinity, margin: 0)
        #expect(FalseSwitchReport.summary(of: none) == "reason=codeLike typed=unknown other=known")

        var correction = Correction(seq: 1, original: "ghbdtn", replacement: "привет", source: LayoutID("en"),
                                    target: ru)
        #expect(FalseSwitchReport.summary(of: correction) == "kind=layout")
        correction.decision = won
        #expect(FalseSwitchReport.summary(of: correction).hasPrefix("reason=compared"))
        correction.insideWord = true
        #expect(FalseSwitchReport.summary(of: correction) == "kind=layout inside-word")
        // The word itself is never in it.
        #expect(!FalseSwitchReport.summary(of: correction).contains("ghbdtn"))
    }

    @Test func theReportCarriesTheReason() throws {
        let report = FalseSwitchReport(typed: "ghbdtn", reason: "reason=compared score=38.2 threshold=10")
        #expect(report.fields.first { $0.id == "reason" }?.value == "reason=compared score=38.2 threshold=10")
        #expect(report.url.absoluteString.contains("reason=reason%3Dcompared"))
        #expect(FalseSwitchReport(typed: "a").fields.allSatisfy { $0.id != "reason" })
    }

    @Test func theLogKeepsWhyForEveryEntry() {
        var log = CorrectionLog()
        var correction = Correction(seq: 7, original: "прривет", replacement: "привет", source: LayoutID("ru"),
                                    target: LayoutID("ru"), kind: .typo)
        correction.typoChange = .delete
        log.record(correction)
        #expect(log.entries[0].explanation.statements == [.typo(.delete)])
        #expect(log.entries[0].summary == "kind=typo typo=delete")
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

    // MARK: The personal lexicon (plan 7.2, item 4)

    /// "lfirf" judged with «дашка» in the lexicon, explained.
    private func explainedPersonal(typedPersonal: Bool = false) -> Classifier.Decision {
        let classifier = Classifier(model: ModelFixture.model)
        let (typed, other, text) = typedPersonal
            ? (Fixture.russian, Fixture.abc, "дашка") : (Fixture.abc, Fixture.russian, "lfirf")
        return classifier.classify(typed.strokes(text), typed: typed, other: other,
                                   context: Classifier.Context(recent: RecentLanguages(),
                                                               personal: personalLexicon([("дашка", "ru")])),
                                   explaining: true)
    }

    @Test func aPersonalReadingIsNamedInTheFacts() {
        let switched = explainedPersonal()
        #expect(switched.otherPersonal && !switched.typedPersonal)
        let explanation = Explanation(decision: switched, typed: "lfirf", other: "дашка")
        #expect(explanation.statements.contains(.personal(text: "дашка")))
        #expect(!explanation.statements.contains { if case .reading(text: "дашка", _, _) = $0 { true } else { false } })
        // The typed reading can be the personal one too.
        let kept = explainedPersonal(typedPersonal: true)
        #expect(kept.typedPersonal)
        #expect(Explanation(decision: kept, typed: "дашка", other: "lfirf").statements.first == .personal(text: "дашка"))
    }

    /// The text of the reason in both languages: the app turns `.personal` into
    /// the line that `Support/*.lproj/Localizable.strings` has for its key
    /// (`ExplanationText`, checked in the app by `scripts/check-strings.sh`).
    @Test func theReasonHasATextInRussianAndEnglish() throws {
        let key = "“%@” is a word you often type"
        func value(of language: String) throws -> String {
            let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Support/\(language).lproj/Localizable.strings")
            let strings = try #require(NSDictionary(contentsOf: file) as? [String: String])
            return try #require(strings[key])
        }
        let english = try value(of: "en")
        let russian = try value(of: "ru")
        #expect(english == key)
        #expect(russian == "«%@» — слово, которое вы часто пишете")
        for text in [english, russian] { #expect(String(format: text, "дашка").contains("дашка")) }
    }
}
