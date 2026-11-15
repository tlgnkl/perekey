// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

/// The rules of short words (docs/classifier.md, «Короткие слова»): a short
/// word at a sentence start is judged without the sentence before
/// (`Classifier.Options.shortWordSentenceStart`), and the short words kept
/// before a word that switches go with it (`shortWordsCarried`).
@Suite struct ShortWordRuleTests {
    let abc = Fixture.abc
    let russian = Fixture.russian

    /// "yt" an English word of rank 220 here: "не" (235) is ahead, but by less than a unit of Zipf.
    static let model = ModelFixture.model(withEnglishWords: [("yt", 220)], russianPairs: [])

    private func classifier(sentenceStart: Bool) -> Classifier {
        var options = Classifier.Options()
        options.shortWordSentenceStart = sentenceStart
        return Classifier(model: Self.model, options: options)
    }

    private func decide(_ classifier: Classifier, _ text: String, after language: String,
                        startsSentence: Bool) -> Classifier.Verdict
    {
        var context = Classifier.Context(previousLanguage: language)
        context.startsSentence = startsSentence
        return classifier.classify(abc.strokes(text), typed: abc, other: russian, context: context).verdict
    }

    @Test func aShortWordAtASentenceStartIsJudgedWithoutTheSentenceBefore() {
        let on = classifier(sentenceStart: true)
        // "Hello. d": "в" is far more frequent than "d", as without context.
        #expect(decide(on, "d", after: "en", startsSentence: true) == .switch(to: russian.id))
        // In the middle of a sentence the English word before keeps it.
        #expect(decide(on, "d", after: "en", startsSentence: false) == .keep)
        // Off, the sentence before keeps it at its start too.
        #expect(decide(classifier(sentenceStart: false), "d", after: "en", startsSentence: true) == .keep)
    }

    @Test func atASentenceStartTheOtherLanguageNoLongerLowersTheBar() {
        // After a Russian word "yt" goes to "не" by the rank alone; at a sentence start it needs a unit of Zipf.
        #expect(decide(classifier(sentenceStart: true), "yt", after: "ru", startsSentence: false)
            == .switch(to: russian.id))
        #expect(decide(classifier(sentenceStart: true), "yt", after: "ru", startsSentence: true) == .keep)
        #expect(decide(classifier(sentenceStart: false), "yt", after: "ru", startsSentence: true)
            == .switch(to: russian.id))
    }

    @Test func aShortWordIsCarriedByTheRuleWithoutContext() {
        let classifier = classifier(sentenceStart: true)
        #expect(classifier.carriesShortWord(abc.strokes("d"), typed: abc, other: russian))
        #expect(classifier.carriesShortWord(abc.strokes("z"), typed: abc, other: russian))
        // "не" is ahead of "yt" by less than a unit of Zipf: no context would switch it.
        #expect(!classifier.carriesShortWord(abc.strokes("yt"), typed: abc, other: russian))
        // "i" is a frequent English word, "ш" no Russian one.
        #expect(!classifier.carriesShortWord(abc.strokes("i"), typed: abc, other: russian))
        // A mark at the end is a boundary, not a letter: "d," stays.
        #expect(!classifier.carriesShortWord(abc.strokes("d,"), typed: abc, other: russian))
    }

    @Test func theOptionsOfTheRulesAreCodedOnlyWhenNotTheDefault() throws {
        var options = Classifier.Options()
        options.shortWordSentenceStart.toggle()
        options.shortWordsCarried = 1
        let read = try JSONDecoder().decode(Classifier.Options.self, from: JSONEncoder().encode(options))
        #expect(read == options)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        #expect(json["shortWordSentenceStart"] != nil && json["shortWordsCarried"] != nil)
    }
}

/// The rules inside the machine: what the text becomes, and one undo for a
/// carried switch.
@Suite struct ShortWordMachineTests {
    /// "d" and "z" English words of rank 100 here, so the language of the
    /// sentence goes on through them, and "vbh" a possible start of an
    /// English word ("vbhs"): "vbh" switches at its end, "ghbdtn" inside.
    static let model = ModelFixture.model(withEnglishWords: [("d", 100), ("z", 100), ("vbhs", 50)], russianPairs: [])

    static func desk(sentenceStart: Bool = true, carried: Int = 2, settings: Settings = Settings()) -> Desk {
        var options = Classifier.Options()
        options.personalNoiseCost = .infinity
        options.shortWordSentenceStart = sentenceStart
        options.shortWordsCarried = carried
        return Desk(settings, classifier: Classifier(model: Self.model, options: options))
    }

    static func typed(_ text: String, sentenceStart: Bool = true, carried: Int = 2) -> String {
        var desk = Self.desk(sentenceStart: sentenceStart, carried: carried)
        desk.type(text)
        return desk.text
    }

    @Test func aSentenceTypedOnTheWrongLayoutStartsWithItsShortWord() {
        #expect(Self.typed("hello. d ") == "hello. в ")
        #expect(Self.typed("hello. d ", sentenceStart: false) == "hello. d ")
        // One letter and a period is an initial, no sentence end: "J. R." stays.
        #expect(Self.typed("hello i. d ") == "hello i. d ")
    }

    @Test func theShortWordsBeforeASwitchedWordGoWithIt() {
        #expect(Self.typed("hello d ghbdtn ") == "hello в привет ")
        #expect(Self.typed("hello z yt ghbdtn ") == "hello я не привет ")
        // One word back at most.
        #expect(Self.typed("hello z yt ghbdtn ", carried: 1) == "hello z не привет ")
        #expect(Self.typed("hello d ghbdtn ", carried: 0) == "hello d привет ")
        // A word kept for another reason than the rule of short words stays: "hello" is no short word.
        #expect(Self.typed("hello ghbdtn ") == "hello привет ")
    }

    @Test func aSwitchAtTheWordsEndCarriesTooAsOneCorrection() throws {
        var desk = Self.desk()
        desk.type("hello d vbh ")
        #expect(desk.text == "hello в мир ")
        let correction = try #require(desk.corrections.last)
        #expect(correction.original == "d vbh" && correction.replacement == "в мир")
        #expect(correction.carried == 1 && !correction.insideWord)
        #expect(desk.corrections.count == 1)
    }

    @Test func noCarryOverASentenceEndAClickOrALayoutTheUserChose() {
        // The short word ends a sentence.
        #expect(Self.typed("hello d. ghbdtn ") == "hello d. привет ")
        var click = Self.desk()
        click.type("hello d ")
        click.send(.click(time: click.time))
        click.type("ghbdtn ")
        #expect(click.text == "hello d привет ")
        var chosen = Self.desk()
        chosen.type("hello d ")
        chosen.send(.layoutChanged(Fixture.russian.id))
        chosen.send(.layoutChanged(Fixture.abc.id))
        chosen.type("ghbdtn ")
        #expect(chosen.text == "hello d привет ")
        // A Backspace into the short word: the buffer no longer knows it as typed.
        var back = Self.desk()
        back.type("hello dd")
        back.press(KeyCode.delete)
        back.type(" ghbdtn ")
        #expect(back.text == "hello в привет ", "a Backspace inside the short word keeps it a word")
        var into = Self.desk()
        into.type("hello d g")
        for _ in 0..<2 { into.press(KeyCode.delete) }
        into.type(" ghbdtn ")
        #expect(into.text == "hello d привет ")
    }

    @Test func aShortWordOnTheUsersListStays() {
        var desk = Self.desk(settings: Settings(exceptions: ["d"]))
        desk.type("hello d ghbdtn ")
        #expect(desk.text == "hello d привет ")
    }

    @Test func oneUndoPutsBackAllTheWordsAndLearnsTheSwitchedOneOnly() {
        var desk = Self.desk()
        desk.type("hello d vbh ")
        #expect(desk.text == "hello в мир ")
        desk.press(KeyCode.delete)
        #expect(desk.text == "hello d vbh ")
        desk.type("x")
        #expect(desk.undone.count == 1)
        #expect(desk.learned == ["vbh"])
    }

    @Test func oneUndoOfASwitchInsideTheWordPutsBackAllTheWords() {
        var desk = Self.desk()
        desk.type("hello d ghbdtn ")
        #expect(desk.text == "hello в привет ")
        desk.press(KeyCode.delete)
        #expect(desk.text == "hello d ghbdtn ")
        desk.type("vbh")
        #expect(desk.undone.count == 1)
        #expect(desk.learned == ["ghbdtn"])
    }
}

@Suite struct ShortWordPartsTests {
    @Test func theWordsBackAreSlicesOfTheHistory() {
        var buffer = WordBuffer()
        for stroke in Fixture.abc.strokes("ab cd e") { buffer.type(stroke, in: Fixture.abc.id) }
        #expect(buffer.word(back: 1).map { $0.map(\.stroke) } == Fixture.abc.strokes("cd "))
        #expect(buffer.word(back: 2).map { $0.map(\.stroke) } == Fixture.abc.strokes("ab "))
        #expect(buffer.word(back: 3) == nil)
        buffer.relabel(words: 2, to: Fixture.russian.id)
        #expect(buffer.entries.allSatisfy { $0.layout == Fixture.russian.id })
        #expect(buffer.word(back: 1)?.allSatisfy { $0.layout == Fixture.russian.id } == true)
        #expect(buffer.word(back: 2)?.allSatisfy { $0.layout == Fixture.abc.id } == true)
    }

    @Test func theExplanationTellsTheCarriedWordsApart() {
        var correction = Correction(seq: 1, original: "d ghbdtn", replacement: "в привет", source: Fixture.abc.id,
                                    target: Fixture.russian.id)
        correction.carried = 1
        var decision = Classifier.Decision(verdict: .switch(to: Fixture.russian.id), score: 30, reason: .compared,
                                           language: "ru", margin: 10, typedForm: .unknown, otherForm: .known,
                                           typedLanguage: "en", otherLanguage: "ru")
        decision.margin = 10
        correction.decision = decision
        let statements = Explanation(correction: correction).statements
        #expect(statements.first == .reading(text: "ghbdtn", form: .unknown, language: "en"))
        #expect(statements.last == .carried(typed: "d", other: "в"))
        correction.insideWord = true
        #expect(Explanation(correction: correction).statements
            == [.impossibleStart(text: "ghbdtn", language: "en"), .carried(typed: "d", other: "в")])
    }

    @Test func theUndoOfACarriedSwitchLearnsTheLastWord() {
        #expect(CorrectionUndo.lastWord("d ghbdtn") == "ghbdtn")
        #expect(CorrectionUndo.lastWord("ghbdtn") == "ghbdtn")
    }
}
