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
        ("п'ять", 190), ("м'ясо", 170), ("сьогодні", 190), ("дуже", 200), ("місто", 180), ("її", 210), ("україна", 180),
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

    @Test func aReadingOfAnotherTextWinsByAClearMargin() {
        // "ghbdsn": "привыт" in Russian is noise, "привіт" in Ukrainian a word.
        let toUkrainian = classifier.classify(Fixture.abc.strokes("ghbdsn"), typed: Fixture.abc,
                                              candidates: [Fixture.russian, Fixture.ukrainianPC])
        #expect(toUkrainian.verdict == .switch(to: uk))
        #expect(toUkrainian.language == "uk")
        // Even after Russian words: the text is not Russian.
        let afterRussian = classifier.classify(Fixture.abc.strokes("ghbdsn"), typed: Fixture.abc,
                                               candidates: [Fixture.russian, Fixture.ukrainianPC],
                                               context: Classifier.Context(previousLanguage: "ru"))
        #expect(afterRussian.verdict == .switch(to: uk))
        let english = classifier.classify(Fixture.abc.strokes("hello"), typed: Fixture.abc,
                                          candidates: [Fixture.russian, Fixture.ukrainianPC])
        #expect(english.verdict == .keep)
    }

    @Test func theSameTextIsATieTheContextDecides() {
        // "ghbdtn" is "привет" on Russian and on Ukrainian-PC keys alike: the
        // model must not choose, a wrong pick would stick (ru ↔ uk is manual).
        let strokes = Fixture.abc.strokes("ghbdtn")
        let candidates = [Fixture.ukrainianPC, Fixture.russian]
        let afterRussian = classifier.classify(strokes, typed: Fixture.abc, candidates: candidates,
                                               context: Classifier.Context(recent: RecentLanguages(["en", "ru"])))
        #expect(afterRussian.verdict == .switch(to: ru), "the latest word of a candidate language")
        let russianApp = classifier.classify(strokes, typed: Fixture.abc, candidates: candidates,
                                             context: Classifier.Context(recent: RecentLanguages(),
                                                                         prior: LanguagePrior(counts: ["ru": 5000])))
        #expect(russianApp.verdict == .switch(to: ru), "then the app's prior")
        let none = classifier.classify(strokes, typed: Fixture.abc, candidates: candidates)
        #expect(none.verdict != .switch(to: ru), "then the first candidate, the layout used last")
        let reversed = classifier.classify(strokes, typed: Fixture.abc, candidates: [Fixture.russian, Fixture.ukrainianPC])
        #expect(reversed.verdict == .switch(to: ru))
    }

    @Test func theCyrillicLayoutUsedLastComesFirst() {
        var layouts = LayoutState([Fixture.abc, Fixture.russian, Fixture.ukrainianPC], current: en)
        #expect(layouts.automaticCandidates.map(\.id) == [ru, uk])
        layouts.makeCurrent(uk)
        layouts.makeCurrent(ru)
        layouts.makeCurrent(en)
        #expect(layouts.automaticCandidates.map(\.id) == [ru, uk])
        layouts.makeCurrent(uk)
        layouts.makeCurrent(en)
        #expect(layouts.automaticCandidates.map(\.id) == [uk, ru])
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

    @Test func aReadingOfTheSameTextIsNoPress() {
        // "ghbdtn" types "привет" on Russian and on Ukrainian-PC: one reading.
        var settings = Settings()
        settings.corrections.phraseRetype = false
        var desk = desk(settings)
        desk.type("ghbdtn")
        desk.tapOption()
        #expect(desk.text == "привет")
        desk.tapOption()
        #expect(desk.text == "ghbdtn", "not «привет» again in the other layout")
    }

    @Test func aLoneWordKeepsTheWholeWalkWithPhrases() {
        var desk = desk(current: ru)
        desk.type("привыт", on: Fixture.russian)
        for expected in ["привіт", "ghbdsn", "привыт", "привіт", "ghbdsn", "привыт"] {
            desk.tapOption()
            #expect(desk.text == expected)
        }
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
    @Test func theLayoutsKnowWhichLanguagesHaveTypoCorrection() {
        let layouts = LayoutState([Fixture.abc, Fixture.russian, Fixture.ukrainianPC], current: en)
        #expect(layouts.correctsTypos(en) && layouts.correctsTypos(ru))
        #expect(!layouts.correctsTypos(uk))
    }

    @Test func aUkrainianTypoStaysAsTyped() {
        var desk = Desk(Settings(autoswitch: false, typoCorrection: true),
                        layouts: [Fixture.abc, Fixture.russian, Fixture.ukrainianPC], current: uk,
                        classifier: UkrainianFixture.classifier)
        let typo = "сього" + "нді "
        desk.type(typo, on: Fixture.ukrainianPC)
        #expect(desk.text == typo)
        #expect(desk.corrections.isEmpty)
    }

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

/// «Почему не исправил?» with three layouts: the facts of the reading the user chose.
@Suite struct ThreeLayoutsExplanationTests {
    private func keyboard(current: LayoutID) -> Keyboard {
        let settings = Settings(hotkeys: [HotkeyBinding(.modifiers(.option, taps: .single), action: .convertLastWord)])
        var kb = Keyboard(settings)
        kb.machine = InputMachine(settings: settings, layouts: [Fixture.abc, Fixture.russian, Fixture.ukrainianPC],
                                  currentLayout: current, classifier: UkrainianFixture.classifier)
        kb.send(.focusChanged(Desk.textEdit))
        return kb
    }

    @Test func theCandidatesExplainTheReadingThatWon() {
        let decision = UkrainianFixture.classifier.classify(
            Fixture.abc.strokes("ghbdsn"), typed: Fixture.abc, candidates: [Fixture.russian, Fixture.ukrainianPC],
            explaining: true)
        #expect(decision.verdict == .switch(to: uk))
        #expect(decision.typedLanguage == "en" && decision.otherLanguage == "uk")
        #expect(decision.otherForm == .known)
    }

    @Test func aManualRetypeExplainsTheReadingItWentTo() throws {
        var kb = keyboard(current: en)
        kb.type("ghbdsn", in: Fixture.abc)
        let retype = try #require(kb.tapOption().retype)
        #expect(retype.target == uk)
        let decision = try #require(retype.decision)
        #expect(decision.otherLanguage == "uk", "the reading chosen, not the first candidate (Russian)")
    }

    @Test func ruToUkByHandHasNothingToExplain() throws {
        var kb = keyboard(current: ru)
        kb.type("привыт", in: Fixture.russian)
        let retype = try #require(kb.tapOption().retype)
        #expect(retype.target == uk)
        #expect(retype.decision == nil, "automatic switching never weighs ru against uk")
    }
}

/// The three-word context and the app's language prior with N candidates.
@Suite struct ThreeLayoutsContextTests {
    let classifier = UkrainianFixture.classifier

    @Test func eachReadingGetsTheLeanOfItsOwnLanguage() {
        let ukrainian = LanguagePrior(counts: ["uk": 100_000, "en": 10, "ru": 10])
        let context = Classifier.Context(recent: RecentLanguages(["uk"]), prior: ukrainian)
        for word in ["ghbdsn", "ghbdtn", "hello"] {
            let strokes = Fixture.abc.strokes(word)
            let best = classifier.classify(strokes, typed: Fixture.abc,
                                           candidates: [Fixture.russian, Fixture.ukrainianPC], context: context)
            // The winner is the pair of its own reading, with that reading's lean.
            let pairs = [Fixture.russian, Fixture.ukrainianPC].map {
                classifier.classify(strokes, typed: Fixture.abc, other: $0, context: context)
            }
            #expect(pairs.contains(best), "\(word)")
        }
        let toUkrainian = classifier.classify(Fixture.abc.strokes("ghbdsn"), typed: Fixture.abc,
                                              candidates: [Fixture.russian, Fixture.ukrainianPC], context: context)
        let alone = classifier.classify(Fixture.abc.strokes("ghbdsn"), typed: Fixture.abc, other: Fixture.ukrainianPC)
        #expect(toUkrainian.score > alone.score, "a Ukrainian app and Ukrainian words before lean toward uk")
    }

    @Test func noPriorMakesRuToUkAutomatic() {
        let ukrainian = LanguagePrior(counts: ["uk": 1_000_000, "ru": 1])
        let context = Classifier.Context(recent: RecentLanguages(["uk", "uk", "uk"]), prior: ukrainian)
        let strokes = Fixture.russian.strokes("привыт")
        for candidates in [[Fixture.ukrainianPC], [Fixture.ukrainianPC, Fixture.abc]] {
            let decision = classifier.classify(strokes, typed: Fixture.russian, candidates: candidates, context: context)
            #expect(decision.verdict != .switch(to: uk))
        }
    }
}

/// The word lists read the Ukrainian apostrophe as the model does.
@Suite struct UkrainianApostropheListTests {
    @Test func theListsFoldTheUkrainianApostrophe() {
        #expect(WordRules.normalize("Мʼясо") == "м'ясо")
        #expect(WordRules.matchKey("мʼясо") == WordRules.matchKey("м’ясо"))
        let words = WordRules(mine: ["м'ясо"])
        #expect(words.contains("мʼясо"))
        #expect(WordJudge.exceptionKey("«мʼясо»") == "м'ясо")
    }

    @Test func aListedWordTypedOnUkrainianPCMatches() {
        let layouts = [Fixture.abc, Fixture.ukrainianPC]
        let typed = Fixture.ukrainianPC.strokes("мʼясо")
        let text = Fixture.abc.type(typed) + " "
        var plain = Desk(Settings(), layouts: layouts, classifier: UkrainianFixture.classifier)
        plain.type(text)
        #expect(plain.text == "мʼясо ", "without a list it switches")
        var kept = Desk(Settings(exceptions: ["м'ясо"]), layouts: layouts, classifier: UkrainianFixture.classifier)
        kept.type(text)
        #expect(kept.text == text, "«м'ясо» on the list keeps «мʼясо»")
    }
}

@Suite struct ThreeLayoutsSelectionTests {
    @Test func aSelectionGoesWhereItReadsNotWhereTheLayoutWasBefore() {
        var layouts = LayoutState([Fixture.abc, Fixture.russian, Fixture.ukrainianPC], current: en)
        layouts.makeCurrent(ru)
        layouts.makeCurrent(uk)
        // "руддщ" reads the same in Ukrainian and Russian: Russian was the
        // layout before, but only English makes it another text.
        for classifier in [UkrainianFixture.classifier, nil] {
            let plan = ManualActions.selectionRead("руддщ", action: .convertLayout, layouts: layouts,
                                                   classifier: classifier)
            guard case let .retype(target, keys) = plan else {
                Issue.record("refused: \(plan)")
                continue
            }
            #expect(target == en)
            #expect(keys.map(\.text).joined() == "hello")
        }
    }
}
