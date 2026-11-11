// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

private func fingerprint(_ text: String) -> UInt64 { ModelFixture.fingerprint(text) }

/// A word that is a word, one swap or one neighbouring key from a word the
/// pair table likes much more after the word before it
/// (docs/classifier.md, «Опечатки-слова»).
@Suite struct RealWordCorrectorTests {
    /// Lifts in eighths of a bit: 72 is nine bits, 56 seven, 40 five.
    static let model = ModelFixture.model(
        withEnglishWords: [("letter", 180), ("form", 150), ("test", 190), ("tests", 190), ("bark", 185), ("nark", 120),
                           ("mark", 185), ("hark", 185)],
        pairs: [
            ("letter", "from", 72), ("a", "form", 72), ("", "from", 72), ("of", "them", 80), ("to", "then", 80),
            ("to", "them", 80), ("run", "test", 80), ("a", "bark", 80), ("a", "mark", 80), ("b", "bark", 80),
            ("b", "mark", 56), ("c", "mark", 40), ("d", "bark", 40), ("e", "hark", 56),
        ])

    static func correct(_ word: String, after previous: String?, realWords: Bool = true, sentenceStart: Bool = false,
                        model: LanguageModel = model, options: TypoCorrector.Options = .init()) -> String?
    {
        let before = previous.map { $0.isEmpty ? ModelFormat.sentenceStart : fingerprint($0) }
        return TypoCorrector(model: model, options: options)
            .correct(Fixture.abc.strokes(word), in: Fixture.abc, sentenceStart: sentenceStart, previous: before,
                     realWords: realWords)?.text
    }

    @Test func theDefaultsAreTheStartingPoint() {
        let options = TypoCorrector.Options()
        #expect(options.realWordLift == 6)
        #expect(options.realWordSlack == 32)
        #expect(options.realWordMargin == 1)
        #expect(!TextCorrections().realWords)
    }

    @Test func twoLettersSwappedMakeAWordTheContextPrefers() {
        #expect(Self.correct("form", after: "letter") == "from")
    }

    @Test func aNeighbouringKeyMakesAWordTheContextPrefers() {
        // "n" sits beside "m".
        #expect(Self.correct("then", after: "of") == "them")
    }

    @Test func offIsTheCorrectorAsBefore() {
        #expect(Self.correct("form", after: "letter", realWords: false) == nil)
        #expect(Self.correct("then", after: "of", realWords: false) == nil)
        // A typo that is no word is fixed either way.
        #expect(Self.correct("wrold", after: "the", realWords: false) == "world")
        #expect(Self.correct("wrold", after: "the") == "world")
    }

    @Test func aPairOfTheTypedWordKeepsIt() {
        // ("to", "then") is in the table: the person meant it.
        #expect(Self.correct("then", after: "to") == nil)
    }

    @Test func withoutTheWordBeforeNothingIsChanged() {
        #expect(Self.correct("form", after: nil) == nil)
    }

    @Test func theStartOfASentenceIsAWordBefore() {
        #expect(Self.correct("form", after: "", sentenceStart: true) == "from")
    }

    @Test func aModelWithoutPairsChangesNothing() {
        #expect(!ModelFixture.model.language("en")!.hasPairTable)
        #expect(Self.correct("then", after: "of", model: ModelFixture.model) == nil)
    }

    @Test func aLiftBelowTheBarChangesNothing() {
        // "d bark": five bits, the bar is six.
        #expect(Self.correct("nark", after: "d") == nil)
        var low = TypoCorrector.Options()
        low.realWordLift = 5
        #expect(Self.correct("nark", after: "d", options: low) == "bark")
        var high = TypoCorrector.Options()
        high.realWordLift = 9.5
        #expect(Self.correct("form", after: "letter", options: high) == nil)
    }

    @Test func aBarOfExactlyTheLiftPasses() {
        var exact = TypoCorrector.Options()
        exact.realWordLift = 9
        #expect(Self.correct("form", after: "letter", options: exact) == "from")
    }

    @Test func aRarerWordThanTheTypedOneIsNotTheAnswer() {
        // "from" (rank 215) typed, "form" (150) liked: 65 below.
        #expect(Self.correct("from", after: "a") == nil)
        var wide = TypoCorrector.Options()
        wide.realWordSlack = 100
        #expect(Self.correct("from", after: "a", options: wide) == "form")
    }

    @Test func aSlackReachesTheRankBelow() {
        // "nark" (120) to "bark" (185) goes up; "bark" to "nark" would need a slack of 65.
        #expect(Self.correct("nark", after: "b") == "bark")
    }

    @Test func twoAnswersOfTheSameLiftChangeNothing() {
        #expect(Self.correct("nark", after: "a") == nil)
    }

    @Test func anAnswerBeatingTheNextByTheMarginWins() {
        // "b bark" 10 bits, "b mark" 7 bits: three bits apart, the margin is one.
        #expect(Self.correct("nark", after: "b") == "bark")
        var wide = TypoCorrector.Options()
        wide.realWordMargin = 4
        #expect(Self.correct("nark", after: "b", options: wide) == nil)
    }

    @Test func theEndingCanBeLeftAlone() {
        var options = TypoCorrector.Options()
        options.realWordEnding = false
        // "then" to "them" is a key at the last letter; "form" to "from" a swap inside.
        #expect(TypoCorrector.Options().realWordEnding)
        #expect(Self.correct("then", after: "of", options: options) == nil)
        #expect(Self.correct("form", after: "letter", options: options) == "from")
        // A swap of the last two letters is an edit of the ending too.
        let swapped = ModelFixture.model(withEnglishWords: [("tets", 190), ("test", 190)], pairs: [("run", "test", 80)])
        #expect(Self.correct("tets", after: "run", model: swapped) == "test")
        #expect(Self.correct("tets", after: "run", model: swapped, options: options) == nil)
    }

    @Test func onlySwapsCanBeAllowed() {
        var options = TypoCorrector.Options()
        options.realWordKeys = false
        #expect(TypoCorrector.Options().realWordKeys)
        #expect(Self.correct("then", after: "of", options: options) == nil)
        #expect(Self.correct("form", after: "letter", options: options) == "from")
    }

    @Test func aMissingOrAnExtraLetterIsNotOfTheClass() {
        // "tests" typed, "test" liked after "run": one letter too many, not a swap or a key.
        #expect(Self.correct("tests", after: "run") == nil)
    }

    @Test func aCapitalIsLeftAlone() {
        let strokes = Fixture.abc.strokes("Form")
        let answer = TypoCorrector(model: Self.model)
            .correct(strokes, in: Fixture.abc, sentenceStart: true, previous: ModelFormat.sentenceStart, realWords: true)
        #expect(answer == nil)
    }

    @Test func shortAndLongWordsAreLeftAlone() {
        #expect(Self.correct("nark", after: "b") == "bark")
        var longer = TypoCorrector.Options()
        longer.minLetters = 5
        #expect(Self.correct("nark", after: "b", options: longer) == nil)
        var strict = TypoCorrector.Options()
        strict.minLetters = 5
        #expect(Self.correct("form", after: "letter", options: strict) == nil)
        var tiny = TypoCorrector.Options()
        tiny.maxLetters = 3
        #expect(Self.correct("form", after: "letter", options: tiny) == nil)
    }

    @Test func aLanguageOutsideTheListIsLeftAlone() {
        var options = TypoCorrector.Options()
        options.languages = ["ru"]
        #expect(Self.correct("form", after: "letter", options: options) == nil)
    }

    @Test func aWordTypedWithAnOptionKeyIsLeftAlone() {
        var strokes = Fixture.abc.strokes("form")
        strokes[1].modifiers.insert(.option)
        let answer = TypoCorrector(model: Self.model)
            .correct(strokes, in: Fixture.abc, sentenceStart: false, previous: fingerprint("letter"), realWords: true)
        #expect(answer == nil)
    }

    @Test func theCandidateMustBeAWordOfTheSameLanguage() {
        // "хорошо" is a Russian word; no pair of the English table speaks for it.
        let strokes = Fixture.russian.strokes("хорошо")
        let answer = TypoCorrector(model: Self.model)
            .correct(strokes, in: Fixture.russian, sentenceStart: false, previous: fingerprint("a"), realWords: true)
        #expect(answer == nil)
    }
}

/// The switch and its path through the machine.
@Suite struct RealWordMachineTests {
    static let classifier = Classifier(model: RealWordCorrectorTests.model)

    static func desk(realWords: Bool = true, typoCorrection: Bool = true, exceptions: Set<String> = []) -> Desk {
        Desk(Settings(exceptions: exceptions, corrections: TextCorrections(realWords: realWords),
                      typoCorrection: typoCorrection),
             classifier: classifier)
    }

    @Test func theWordIsChangedWhenTheSwitchIsOn() {
        var desk = Self.desk()
        desk.type("a letter form ")
        #expect(desk.text == "a letter from ")
        #expect(desk.corrections.map(\.kind) == [.typo])
    }

    @Test func theWordStaysWhenTheSwitchIsOff() {
        var desk = Self.desk(realWords: false)
        desk.type("a letter form ")
        #expect(desk.text == "a letter form ")
        #expect(desk.corrections.isEmpty)
    }

    @Test func theSwitchOffIsTheMachineAsBefore() {
        var plain = Desk(Settings(typoCorrection: true), classifier: Self.classifier)
        var off = Self.desk(realWords: false)
        for text in ["a letter form ", "of then ", "wrold of then ", "form. then, "] {
            plain.type(text)
            off.type(text)
        }
        #expect(plain.text == off.text)
        #expect(plain.corrections.map(\.replacement) == off.corrections.map(\.replacement))
    }

    @Test func withTypoCorrectionOffNothingIsChanged() {
        var desk = Self.desk(typoCorrection: false)
        desk.type("a letter form ")
        #expect(desk.text == "a letter form ")
    }

    @Test func aWordOnTheUserListIsNotTouched() {
        var desk = Self.desk(exceptions: ["form"])
        desk.type("a letter form ")
        #expect(desk.text == "a letter form ")
    }

    @Test func theFirstWordOfAFieldFollowsTheStartOfASentence() {
        var desk = Self.desk()
        desk.type("form ")
        #expect(desk.text == "from ")
    }

    @Test func aSentenceEndMakesTheNextWordTheFirst() {
        var desk = Self.desk()
        desk.type("letter. form ")
        #expect(desk.text == "letter. from ")
    }

    @Test func aFocusChangeForgetsTheWordBefore() {
        var desk = Self.desk()
        desk.type("of ")
        desk.send(.focusChanged(Focus(bundleID: "com.apple.Notes")))
        desk.type("then ")
        // A new field starts a sentence: ("", "them") is no pair and ("", "then") neither; and "of" is forgotten.
        #expect(desk.text == "of then ")
    }

    @Test func aClickForgetsTheWordBefore() {
        var desk = Self.desk()
        desk.type("of ")
        desk.send(.click(time: desk.time))
        desk.type("then ")
        #expect(desk.text == "of then ")
    }

    @Test func theWordIsCorrectedWithTheWordBeforeAlone() {
        var desk = Self.desk()
        desk.type("of then ")
        #expect(desk.text == "of them ")
        #expect(desk.machine.judge.previousForTypo == nil)
    }

    @Test func theCorrectionUndoesLikeAnyTypo() {
        var desk = Self.desk()
        desk.type("a letter form ")
        #expect(desk.text == "a letter from ")
        desk.press(KeyCode.delete)
        #expect(desk.text == "a letter form ")
    }

    @Test func aWordOfOtherLanguageIsNoContext() {
        var desk = Self.desk()
        desk.appLayout = Fixture.russian.id
        desk.send(.layoutChanged(Fixture.russian.id))
        desk.type("привет ", on: Fixture.russian)
        desk.appLayout = Fixture.abc.id
        desk.send(.layoutChanged(Fixture.abc.id))
        desk.type("then ")
        #expect(desk.text == "привет then ")
    }
}

/// The switch in the settings.
@Suite struct RealWordSettingsTests {
    @Test func theSwitchIsOffByDefaultAndDoesNotMakeTheBoundaryLook() {
        #expect(!TextCorrections().realWords)
        // It is a typo correction: it alone starts no dictionary step.
        var only = TextCorrections(phraseRetype: false, doubleCapitals: false)
        #expect(!only.correctsWords)
        only.realWords = true
        #expect(!only.correctsWords)
    }

    @Test func theSwitchSurvivesTheFile() throws {
        let on = TextCorrections(realWords: true)
        let data = try JSONEncoder().encode(on)
        #expect(try JSONDecoder().decode(TextCorrections.self, from: data) == on)
    }

    @Test func aFileWithoutTheKeyGetsTheDefault() throws {
        let old = Data(#"{"phraseRetype":true,"doubleCapitals":true,"capsLock":false,"abbreviations":false,"yo":false,"hyphen":false}"#.utf8)
        let decoded = try JSONDecoder().decode(TextCorrections.self, from: old)
        #expect(!decoded.realWords)
    }
}
