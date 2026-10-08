// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let us = Fixture.us.id
private let ru = Fixture.russian.id
private let uk = Fixture.ukrainianPC.id

/// A few Ukrainian words next to the ru and en fixture: enough to tell the
/// readings of one word apart.
enum UkrainianFixture {
    static let words: [(String, UInt8)] = [
        ("привіт", 200), ("дякую", 190), ("будь", 180), ("ласка", 180), ("добре", 190), ("що", 230), ("як", 230),
        ("так", 230), ("ні", 220), ("вона", 210), ("мене", 210), ("його", 210), ("їжак", 140), ("європа", 160),
        ("п'ять", 190), ("сьогодні", 190), ("дуже", 200), ("місто", 180), ("її", 210), ("україна", 180),
    ]

    static let model: LanguageModel = {
        var builder = ModelBuilder()
        builder.addLanguage("uk", alphabet: "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'-")
        for (word, rank) in words { builder.addForm(word, language: "uk", rank: rank, weight: Double(rank)) }
        return LanguageModel(combining: [ModelFixture.model, try! LanguageModel(bytes: builder.build())])
    }()

    static let classifier = Classifier(model: model)
}

@Suite struct LayoutCandidatesTests {
    @Test func oneCandidatePerLanguageTheSourcesNever() {
        let layouts = LayoutState([Fixture.abc, Fixture.us, Fixture.russian, Fixture.ukrainianPC], current: en)
        #expect(layouts.candidates(of: en) == [ru, uk], "US types the same letters as ABC: it never competes")
        #expect(layouts.candidates(of: ru) == [en, uk])
        #expect(layouts.counterpart(of: en) == ru)
    }

    @Test func theLayoutSwitchedToComesFirst() {
        var layouts = LayoutState([Fixture.abc, Fixture.russian, Fixture.ukrainianPC], current: en)
        layouts.makeCurrent(uk)
        #expect(layouts.candidates(of: en) == [uk, ru])
        #expect(layouts.candidates(of: uk) == [en, ru], "then the one used before")
        // A layout of the source's language switched to stands back.
        layouts = LayoutState([Fixture.abc, Fixture.us, Fixture.russian], current: en)
        layouts.makeCurrent(us)
        #expect(layouts.candidates(of: en) == [ru])
        #expect(layouts.counterpart(of: en) == ru)
    }

    @Test func onlyLayoutsOfOneLanguageStillHaveACounterpart() {
        let layouts = LayoutState([Fixture.abc, Fixture.us], current: en)
        #expect(layouts.candidates(of: en).isEmpty)
        #expect(layouts.counterpart(of: en) == us)
        #expect(layouts.automaticCandidates.isEmpty)
    }

    @Test func automaticSwitchingGoesBetweenScriptsOnly() {
        var layouts = LayoutState([Fixture.abc, Fixture.russian, Fixture.ukrainianPC], current: en)
        #expect(layouts.automaticCandidates.map(\.id) == [ru, uk])
        layouts.makeCurrent(ru)
        #expect(layouts.automaticCandidates.map(\.id) == [en], "ru ↔ uk is never automatic")
        layouts.makeCurrent(uk)
        #expect(layouts.automaticCandidates.map(\.id) == [en])
        layouts = LayoutState([Fixture.russian, Fixture.ukrainianPC], current: ru)
        #expect(layouts.automaticCandidates.isEmpty)
        #expect(layouts.counterpart(of: ru) == uk, "by hand, yes")
    }

    @Test func theRuleOfScripts() {
        #expect(Classifier.switchesAutomatically(from: "en", to: "ru"))
        #expect(Classifier.switchesAutomatically(from: "uk", to: "en"))
        #expect(!Classifier.switchesAutomatically(from: "ru", to: "uk"))
        #expect(!Classifier.switchesAutomatically(from: "uk", to: "ru"))
        #expect(!Classifier.switchesAutomatically(from: "en", to: "de"))
        #expect(!Classifier.switchesAutomatically(from: "en", to: "xx"), "an unknown script never switches")
    }
}

@Suite struct ClassifierCandidatesTests {
    let classifier = UkrainianFixture.classifier

    @Test func theBestReadingWins() {
        let toUkrainian = classifier.classify(Fixture.abc.strokes("ghbdsn"), typed: Fixture.abc,
                                              candidates: [Fixture.russian, Fixture.ukrainianPC])
        #expect(toUkrainian.verdict == .switch(to: uk))
        #expect(toUkrainian.language == "uk")
        let toRussian = classifier.classify(Fixture.abc.strokes("ghbdtn"), typed: Fixture.abc,
                                            candidates: [Fixture.ukrainianPC, Fixture.russian])
        #expect(toRussian.verdict == .switch(to: ru))
        let english = classifier.classify(Fixture.abc.strokes("hello"), typed: Fixture.abc,
                                          candidates: [Fixture.russian, Fixture.ukrainianPC])
        #expect(english.verdict == .keep)
    }

    @Test func oneCandidateIsThePair() {
        for word in ["ghbdtn", "hello", "f", "xkqzp"] {
            let strokes = Fixture.abc.strokes(word)
            #expect(classifier.classify(strokes, typed: Fixture.abc, candidates: [Fixture.russian])
                == classifier.classify(strokes, typed: Fixture.abc, other: Fixture.russian))
        }
    }

    @Test func ruAndUkNeverSwitchAutomaticallyButCompareByHand() {
        let strokes = Fixture.russian.strokes("привыт") // "привіт" on Ukrainian-PC keys
        let automatic = classifier.classify(strokes, typed: Fixture.russian, candidates: [Fixture.ukrainianPC])
        #expect(automatic.verdict == .keep)
        #expect(automatic.reason == .unsupported)
        let none = classifier.classify(strokes, typed: Fixture.russian, candidates: [Fixture.ukrainianPC, Fixture.abc])
        #expect(none.verdict != .switch(to: uk))
        let manual = classifier.classify(strokes, typed: Fixture.russian, candidates: [Fixture.ukrainianPC],
                                         context: Classifier.Context(mode: .manual))
        #expect(manual.verdict == .switch(to: uk))
    }

    @Test func aReadingWithoutAModelDoesNotCompete() {
        let decision = ModelFixture.classifierWithoutUkrainian.classify(
            Fixture.abc.strokes("ghbdsn"), typed: Fixture.abc, candidates: [Fixture.ukrainianPC, Fixture.russian])
        #expect(decision.verdict != .switch(to: uk))
    }

    @Test func rankedByPlausibility() {
        let ranked = classifier.ranked(Fixture.russian.strokes("привыт"), typed: Fixture.russian,
                                       candidates: [Fixture.abc, Fixture.ukrainianPC])
        #expect(ranked.map(\.id) == [uk, en])
    }

    @Test func ukrainianApostrophesReadAsTheJoiner() {
        // Ukrainian-PC types ʼ (U+02BC) on the \ key; Ukrainian types ' on `.
        for layout in [Fixture.ukrainianPC, Fixture.ukrainian] {
            let apostrophe: Character = layout.id == uk ? "\u{2BC}" : "'"
            let strokes = layout.strokes("п\(apostrophe)ять")
            let decision = classifier.classify(strokes, typed: Fixture.abc, candidates: [Fixture.russian, layout])
            #expect(decision.verdict == .switch(to: layout.id), "\(layout.id)")
        }
    }
}

extension ModelFixture {
    static let classifierWithoutUkrainian = Classifier(model: model)
}

@Suite struct ThreeLayoutsTests {
    private func desk(_ settings: Settings = Settings(), _ layouts: [LayoutMap] = [Fixture.abc, Fixture.russian,
                                                                                    Fixture.ukrainianPC],
                      current: LayoutID = en) -> Desk
    {
        Desk(settings, layouts: layouts, current: current, classifier: UkrainianFixture.classifier)
    }

    @Test func aWordSwitchesToTheLanguageItReadsIn() {
        var desk = desk()
        desk.type("ghbdsn ")
        #expect(desk.text == "привіт ")
        #expect(desk.appLayout == uk)
        desk = self.desk()
        desk.type("ghbdtn ")
        #expect(desk.text == "привет ")
        #expect(desk.appLayout == ru)
    }

    @Test func noEarlySwitchWhenTwoLanguagesCanStartTheWord() {
        var desk = desk()
        desk.type("ghb")
        #expect(desk.text == "ghb", "при- starts words of ru and of uk: the end decides")
        desk.type("dsn ")
        #expect(desk.text == "привіт ")
    }

    @Test func ruNeverGoesToUkByItself() {
        var desk = desk(current: ru)
        desk.type("привыт ", on: Fixture.russian)
        #expect(desk.text == "привыт ")
        #expect(desk.corrections.isEmpty)
    }

    @Test func layoutsOfOneLanguageDoNotCompete() {
        var desk = desk(Settings(), [Fixture.abc, Fixture.us, Fixture.russian])
        desk.type("ghbdtn ")
        #expect(desk.text == "привет ")
    }

    @Test func manualRetypeWalksTheReadingsThenPutsTheWordBack() {
        var settings = Settings()
        settings.corrections.phraseRetype = false
        var desk = desk(settings, current: ru)
        desk.type("привыт", on: Fixture.russian)
        desk.tapOption()
        #expect(desk.text == "привіт", "the most plausible reading first")
        desk.tapOption()
        #expect(desk.text == "ghbdsn")
        desk.tapOption()
        #expect(desk.text == "привыт")
        desk.tapOption()
        #expect(desk.text == "привіт", "and round again")
    }

    @Test func withPhrasesTheWalkComesBeforeTheSecondWord() {
        var desk = desk(current: ru)
        desk.type("ьшк привыт", on: Fixture.russian) // "mir" on Russian keys
        desk.tapOption()
        #expect(desk.text == "ьшк привіт")
        desk.tapOption()
        #expect(desk.text == "ьшк ghbdsn")
        desk.tapOption()
        #expect(desk.text == "ьшк привыт")
        desk.tapOption()
        #expect(desk.text == Fixture.ukrainianPC.type(Fixture.russian.strokes("ьшк привыт")),
                "two words, into the first reading")
    }
}

@Suite struct UkrainianTyposTests {
    @Test func typosAreCorrectedOnlyInLanguagesThatPassedTheGate() {
        #expect(TypoCorrector.Options().languages == ["ru", "en"])
        // "сьогодні" with two letters swapped: one edit from a known uk form.
        let typo = Fixture.ukrainianPC.strokes("сього" + "нді")
        let corrector = TypoCorrector(model: UkrainianFixture.model)
        #expect(corrector.correct(typo, in: Fixture.ukrainianPC, sentenceStart: false) == nil)
        var options = TypoCorrector.Options()
        options.languages.insert("uk")
        let measured = TypoCorrector(model: UkrainianFixture.model, options: options)
        #expect(measured.correct(typo, in: Fixture.ukrainianPC, sentenceStart: false)?.text == "сьогодні",
                "the corrector itself handles uk once the language is allowed")
    }
}
