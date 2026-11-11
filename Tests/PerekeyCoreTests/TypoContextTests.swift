// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private func fingerprint(_ text: String) -> UInt64 { ModelFixture.fingerprint(text) }

/// The word before: how a typed word becomes the `previous` of a pair
/// (docs/corrections.md, «Опечатки с контекстом»).
@Suite struct PreviousWordTests {
    private func previous(_ text: String) -> UInt64? { PreviousWord.fingerprint(of: text.unicodeScalars) }

    @Test func aWordIsItsFoldedFingerprint() {
        #expect(previous("hello") == fingerprint("hello"))
        #expect(previous("Hello") == fingerprint("hello"))
        #expect(previous("привет") == fingerprint("привет"))
        #expect(previous("Ёлка") == fingerprint("ёлка"))
    }

    @Test(arguments: ["hello.", "hello!", "hello?", "hello…", "hello?!", "hello. ", "hello.)"])
    func aSentenceEndMakesTheNextWordTheFirst(text: String) {
        #expect(previous(text) == ModelFormat.sentenceStart)
    }

    @Test(arguments: ["hello,", "hello;", "hello:", "(hello)", "\"hello\"", "«hello»", "hello —"])
    func otherMarksAreNotPartOfTheWord(text: String) {
        #expect(previous(text) == fingerprint("hello"))
    }

    @Test func apostropheAndHyphenStayInsideAndGoAtTheEnds() {
        #expect(previous("don't") == fingerprint("don't"))
        #expect(previous("don’t") == fingerprint("don't"))
        #expect(previous("кто-то") == fingerprint("кто-то"))
        #expect(previous("-hello-") == fingerprint("hello"))
        #expect(previous("'hello'") == fingerprint("hello"))
    }

    @Test func theLastWordOfTheText() {
        #expect(previous("a/b") == fingerprint("b"))
        #expect(previous("said hello") == fingerprint("hello"))
        #expect(previous("hello. said") == fingerprint("said"))
    }

    @Test func digitsMakeWordsAsInTheTrainingText() {
        #expect(previous("mp3") == fingerprint("mp3"))
        #expect(previous("2026") == fingerprint("2026"))
    }

    @Test(arguments: ["", " ", "...", "--", "(!)", ","])
    func textWithoutAWordSaysNothing(text: String) {
        #expect(previous(text) == nil)
    }
}

/// The buffer hands over the keys of the word before the current one.
@Suite struct PreviousWordBufferTests {
    private let en = Fixture.abc.id

    private func typed(_ text: String) -> WordBuffer {
        var buffer = WordBuffer()
        for stroke in Fixture.abc.strokes(text) { buffer.type(stroke, in: en) }
        return buffer
    }

    private func text(_ slice: ArraySlice<WordBuffer.Entry>?) -> String? {
        slice.map { Fixture.abc.type($0.map(\.stroke)) }
    }

    @Test func theWordBeforeWithItsPunctuationAndSpaces() {
        #expect(text(typed("said hello. wrold").previousWord) == "hello. ")
        #expect(text(typed("said wrold").previousWord) == "said ")
    }

    @Test func noWordBeforeTheFirstOne() {
        #expect(typed("wrold").previousWord == nil)
        #expect(typed("").previousWord == nil)
    }

    @Test func historyThatWasClearedSaysNothing() {
        var buffer = typed("said wrold")
        buffer.clear()
        for stroke in Fixture.abc.strokes("wrold") { buffer.type(stroke, in: en) }
        #expect(buffer.previousWord == nil)
    }

    @Test func backspaceIntoTheWordBeforeForgetsIt() {
        var buffer = typed("said ")
        buffer.deleteBackward() // the space
        buffer.deleteBackward() // "d"
        buffer.deleteBackward()
        buffer.deleteBackward()
        buffer.deleteBackward()
        #expect(buffer.previousWord == nil)
    }
}

/// The corrector with the word before it.
@Suite struct TypoContextCorrectorTests {
    static let of = fingerprint("of")
    static let to = fingerprint("to")

    /// "thenm": "then" and "them" are as frequent as each other and one
    /// stray letter away. ("of", "them") and ("to", "then") are the pairs.
    static let model = ModelFixture.model(withEnglishPairs: [
        ("of", "them", 80), ("to", "then", 80), ("", "them", 80), ("keyboard", "layout", 16), ("of", "keyboard", 40),
    ])

    static func corrector(weight: Double, minScore: Int? = nil, model: LanguageModel = model) -> TypoCorrector {
        var options = TypoCorrector.Options()
        options.contextWeight = weight
        if let minScore { options.minScore = minScore }
        return TypoCorrector(model: model, options: options)
    }

    static func correct(_ word: String, previous: UInt64?, weight: Double, sentenceStart: Bool = false,
                        minScore: Int? = nil, model: LanguageModel = model) -> String?
    {
        corrector(weight: weight, minScore: minScore, model: model)
            .correct(Fixture.abc.strokes(word), in: Fixture.abc, sentenceStart: sentenceStart, previous: previous)?.text
    }

    @Test func theWeightIsOffByDefault() {
        #expect(TypoCorrector.Options().contextWeight == 0)
    }

    @Test func aBitIsAboutTenRankUnits() {
        // 32 per unit of Zipf (a factor of ten), one bit a factor of two.
        #expect(abs(TypoCorrector.Options.rankUnitsPerBit - 32 * 0.30103) < 0.001)
    }

    @Test func withWeightZeroTheWordBeforeChangesNothing() {
        for word in ["thenm", "wrold", "keybaord", "hwllo", "wrd", "hello"] {
            let alone = TypoCorrector(model: Self.model)
                .correct(Fixture.abc.strokes(word), in: Fixture.abc, sentenceStart: false)
            for previous in [nil, Self.of, Self.to, ModelFormat.sentenceStart] {
                let with = Self.corrector(weight: 0).correct(Fixture.abc.strokes(word), in: Fixture.abc,
                                                              sentenceStart: false, previous: previous)
                #expect(with == alone, "\(word) after \(String(describing: previous))")
            }
        }
    }

    @Test func withoutTheWordBeforeNothingChanges() {
        #expect(Self.correct("thenm", previous: nil, weight: 1) == nil)
        #expect(Self.correct("wrold", previous: nil, weight: 1) == "world")
    }

    @Test func theWordBeforeBreaksATie() {
        #expect(Self.correct("thenm", previous: nil, weight: 0) == nil)
        #expect(Self.correct("thenm", previous: Self.of, weight: 1) == "them")
        #expect(Self.correct("thenm", previous: Self.to, weight: 1) == "then")
    }

    @Test func aPairOfAnotherWordBreaksNoTie() {
        #expect(Self.correct("thenm", previous: fingerprint("said"), weight: 1) == nil)
    }

    @Test func theStartOfASentenceIsAWordBefore() {
        // ("", "them") is the pair; ("", "then") is not.
        #expect(Self.correct("thenm", previous: ModelFormat.sentenceStart, weight: 1, sentenceStart: true) == "them")
        #expect(Self.correct("thenm", previous: ModelFormat.sentenceStart, weight: 1) == "them")
    }

    @Test func aHalfWeightIsHalfTheBonus() {
        // 80 eighths = 10 bits = 96 rank units at weight 1: the margin of 48 needs half of it.
        #expect(Self.correct("thenm", previous: Self.of, weight: 0.5) == "them")
        #expect(Self.correct("thenm", previous: Self.of, weight: 0.4) == nil)
    }

    @Test func theWordBeforeLiftsAScoreOverTheMinimum() {
        // "keybaord" scores 160 − 22 = 138; ("of", "keyboard") adds 40 eighths = 48 units.
        #expect(Self.correct("keybaord", previous: Self.of, weight: 0, minScore: 150) == nil)
        #expect(Self.correct("keybaord", previous: nil, weight: 1, minScore: 150) == nil)
        #expect(Self.correct("keybaord", previous: Self.of, weight: 1, minScore: 150) == "keyboard")
    }

    @Test func aPairLowersNothing() {
        // The lift is never negative: a word without a pair keeps its score.
        #expect(Self.correct("keybaord", previous: fingerprint("hello"), weight: 1) == "keyboard")
    }

    @Test func aModelWithoutPairsIsUnchanged() {
        let plain = ModelFixture.model
        #expect(!plain.language("en")!.hasPairTable)
        #expect(Self.correct("thenm", previous: Self.of, weight: 1.5, model: plain) == nil)
        #expect(Self.correct("wrold", previous: Self.of, weight: 1.5, model: plain) == "world")
    }

    @Test func aKnownWordIsStillLeftAlone() {
        #expect(Self.correct("them", previous: Self.to, weight: 1.5) == nil)
    }
}

/// The word before, inside the machine.
@Suite struct TypoContextMachineTests {
    static let model = TypoContextCorrectorTests.model

    static func desk(weight: Double, model: LanguageModel = model) -> Desk {
        var classifier = Classifier(model: model)
        classifier.typoContextWeight = weight
        return Desk(Settings(typoCorrection: true), classifier: classifier)
    }

    @Test func theWordBeforeDecidesBetweenTwoWords() {
        var desk = Self.desk(weight: 1)
        desk.type("of thenm ")
        #expect(desk.text == "of them ")
        desk.type("to thenm ")
        #expect(desk.text == "of them to then ")
    }

    @Test func withWeightZeroTheTextIsAsBefore() {
        var desk = Self.desk(weight: 0)
        desk.type("of thenm to thenm ")
        #expect(desk.text == "of thenm to thenm ")
        #expect(desk.corrections.isEmpty)
        var plain = Desk(Settings(typoCorrection: true))
        plain.type("of thenm to thenm ")
        #expect(plain.text == desk.text)
    }

    @Test func aModelWithoutPairsIsAsBefore() {
        var desk = Self.desk(weight: 1, model: ModelFixture.model)
        desk.type("of thenm ")
        #expect(desk.text == "of thenm ")
    }

    @Test func theFirstWordOfTheFieldFollowsTheStartOfASentence() {
        var desk = Self.desk(weight: 1)
        desk.type("thenm ")
        #expect(desk.text == "them ")
    }

    @Test func aSentenceEndAndReturnMakeTheNextWordTheFirst() {
        var desk = Self.desk(weight: 1)
        desk.type("to. thenm ")
        #expect(desk.text == "to. them ")
        var lines = Self.desk(weight: 1)
        lines.type("to")
        lines.press(KeyCode.return)
        lines.type("thenm ")
        #expect(lines.text == "to\nthem ")
    }

    @Test func aFocusChangeForgetsTheWordBefore() {
        var desk = Self.desk(weight: 1)
        desk.type("to ")
        desk.send(.focusChanged(Focus(bundleID: "com.apple.Notes")))
        desk.type("thenm ")
        // A new field starts a sentence: the pair ("", "them") speaks, not ("to", "then").
        #expect(desk.text == "to them ")
    }

    @Test func aWordInAnotherLayoutIsNoContext() {
        var desk = Self.desk(weight: 1)
        desk.appLayout = Fixture.russian.id
        desk.send(.layoutChanged(Fixture.russian.id))
        desk.type("привет ", on: Fixture.russian)
        desk.appLayout = Fixture.abc.id
        desk.send(.layoutChanged(Fixture.abc.id))
        desk.type("thenm ")
        #expect(desk.text == "привет thenm ")
    }

    @Test func aWordInALayoutWithoutALanguageIsStillTheContext() {
        // The typo corrector reads the word before in any layout, as it did before the word context
        // of the classifier: only that context asks for a language.
        let bare = Fixture.abc.withoutLanguage(id: "Bare")
        var classifier = Classifier(model: Self.model)
        classifier.typoContextWeight = 1
        var desk = Desk(Settings(typoCorrection: true), layouts: [Fixture.abc, bare], classifier: classifier)
        desk.appLayout = bare.id
        desk.send(.layoutChanged(bare.id))
        desk.type("to ", on: bare)
        desk.appLayout = Fixture.abc.id
        desk.send(.layoutChanged(Fixture.abc.id))
        desk.type("thenm ")
        // ("to", "then") speaks; without the word before "then" and "them" tie and nothing is fixed.
        #expect(desk.text == "to then ")
    }

    @Test func aClickForgetsTheWordBefore() {
        var desk = Self.desk(weight: 1)
        desk.type("to ")
        desk.send(.click(time: desk.time))
        desk.type("thenm ")
        // Remembered, ("to", "then") would make "then"; forgotten, "then" and "them" tie and nothing is fixed.
        #expect(desk.text == "to thenm ")
    }

    @Test func aClickEmptiesTheHistoryOfTheBuffer() {
        var desk = Self.desk(weight: 1)
        desk.type("of to ")
        #expect(desk.machine.buffer.historyCount > 0)
        desk.send(.click(time: desk.time))
        #expect(desk.machine.buffer.historyCount == 0)
        #expect(desk.machine.buffer.history.isEmpty)
    }

    @Test func aClickOnTheHintForgetsTheWordBeforeToo() {
        var desk = Self.desk(weight: 1)
        desk.type("of to ")
        desk.send(.click(time: desk.time, onHint: true))
        #expect(desk.machine.buffer.historyCount == 0)
    }

    @Test func noWordBeforeStaysBetweenJudgements() {
        var desk = Self.desk(weight: 1)
        desk.type("of thenm ")
        #expect(desk.machine.judge.previousForTypo == nil)
    }

    @Test func forgettingTheContextDropsTheWordBefore() {
        var judge = WordJudge(classifier: Desk.classifier)
        judge.previousForTypo = TypoContextCorrectorTests.of
        judge.forgetContext(newField: false)
        #expect(judge.previousForTypo == nil)
    }
}
