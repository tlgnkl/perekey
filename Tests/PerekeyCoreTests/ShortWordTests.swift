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
    /// "d" one of rank 100, a frequent word; "z" is no word, and "в" and "я" are far ahead of them.
    static let model = ModelFixture.model(withEnglishWords: [("yt", 220), ("d", 100)], russianPairs: [])

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
        // "Hello. z": "я" is far more frequent than the no-word "z", as without context.
        #expect(decide(on, "z", after: "en", startsSentence: true) == .switch(to: russian.id))
        // In the middle of a sentence the English word before keeps it.
        #expect(decide(on, "z", after: "en", startsSentence: false) == .keep)
        // Off, the sentence before keeps it at its start too.
        #expect(decide(classifier(sentenceStart: false), "z", after: "en", startsSentence: true) == .keep)
    }

    @Test func aFrequentWordOfTheSentenceBeforeIsNotTakenForAMistake() {
        // "Hello there. d": "d" is a frequent English word (rank 100, Zipf 3): after a sentence in English it is
        // kept, as on main, whatever "в" is. After a Russian sentence it is the "в" of a wrong layout.
        let on = classifier(sentenceStart: true)
        #expect(decide(on, "d", after: "en", startsSentence: true) == .keep)
        #expect(decide(on, "d", after: "ru", startsSentence: true) == .switch(to: russian.id))
        // A no-word, "ytn" or "z", is no such word.
        #expect(decide(on, "z", after: "en", startsSentence: true) == .switch(to: russian.id))
    }

    @Test func theKeepRankIsTheBoundaryOfTheGuard() {
        // "d" one rank below the bar goes to "в" after an English sentence, one at it stays: the fixtures of 60 and
        // 100 are far from the bar, these two are next to it.
        func model(rank: Int) -> LanguageModel {
            ModelFixture.model(withEnglishWords: [("d", UInt8(rank))], russianPairs: [])
        }
        var options = Classifier.Options()
        options.shortWordSentenceStart = true
        let bar = Classifier.sentenceStartKeepRank
        let below = Classifier(model: model(rank: bar - 1), options: options)
        let at = Classifier(model: model(rank: bar), options: options)
        #expect(decide(below, "d", after: "en", startsSentence: true) == .switch(to: russian.id))
        #expect(decide(at, "d", after: "en", startsSentence: true) == .keep)
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

    @Test func theOptionsOfTheRulesAreAlwaysCoded() throws {
        var options = Classifier.Options()
        options.shortWordSentenceStart.toggle()
        options.shortWordsCarried = 1
        let read = try JSONDecoder().decode(Classifier.Options.self, from: JSONEncoder().encode(options))
        #expect(read == options)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        #expect(json["shortWordSentenceStart"] != nil && json["shortWordsCarried"] != nil)
        // The default ones too: a record of a session says which rules it ran with.
        let defaults = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Classifier.Options()))
            as? [String: Any])
        #expect(defaults["shortWordSentenceStart"] as? Bool == true && defaults["shortWordsCarried"] as? Int == 2)
    }
}

/// The rules inside the machine: what the text becomes, and one undo for a
/// carried switch.
@Suite struct ShortWordMachineTests {
    /// "d" and "z" English words of rank 60 here (below `Classifier.sentenceStartKeepRank`), so the language of the
    /// sentence goes on through them, and "vbh" a possible start of an
    /// English word ("vbhs"): "vbh" switches at its end, "ghbdtn" inside.
    static let model = ModelFixture.model(withEnglishWords: [("d", 60), ("z", 60), ("vbhs", 50)], russianPairs: [])

    static func desk(sentenceStart: Bool = true, carried: Int = 2, settings: Settings = Settings()) -> Desk {
        var options = Classifier.Options()
        options.personalNoiseCost = .infinity
        options.shortWordSentenceStart = sentenceStart
        options.shortWordsCarried = carried
        return Desk(settings, classifier: Classifier(model: Self.model, options: options))
    }

    /// The same machine with no focus event: the focus is unknown.
    static func deskWithoutFocus() -> Desk {
        var options = Classifier.Options()
        options.personalNoiseCost = .infinity
        return Desk(Settings(), classifier: Classifier(model: Self.model, options: options), focus: nil)
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

    @Test func theMarksGivenBackAtTheWordsEndKeepTheCarriedWords() throws {
        // "ytn" goes to Russian inside the word and carries "d"; the comma typed next is "б" there,
        // and the end of the word gives it back: one correction for all of it.
        var desk = Self.desk()
        desk.type("hello d ytn, ")
        #expect(desk.text == "hello в нет, ")
        let correction = try #require(desk.corrections.last)
        #expect(correction.original == "d ytn," && correction.replacement == "в нет,")
        #expect(correction.carried == 1)
        desk.press(KeyCode.delete)
        #expect(desk.text == "hello d ytn, ")
        #expect(desk.undone.count == 1)
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

/// What the retype erases: how many keys, and the text the caret check compares.
@Suite struct ShortWordErasureTests {
    /// The retypes the desk asked for, the text typed on the layout it stood in.
    private func retypes(_ text: String, focus: Focus? = Desk.textEdit, carried: Int = 2) -> [Retype] {
        var desk = ShortWordMachineTests.desk(carried: carried)
        if let focus { desk.send(.focusChanged(focus)) }
        desk.type(text)
        return desk.history
    }

    @Test func aSwitchAtTheWordsEndErasesTheShortWordToo() throws {
        let retype = try #require(retypes("hello d vbh ").last)
        #expect(retype.expected == "d vbh")
        #expect(retype.deleteCount == "d vbh".count)
        #expect(retype.text == "в мир")
        let two = try #require(retypes("hello z d vbh ").last)
        #expect(two.expected == "z d vbh")
        #expect(two.deleteCount == "z d vbh".count)
        #expect(two.text == "я в мир")
    }

    @Test func aSwitchInsideTheWordErasesTheShortWordAndWhatIsTypedOfTheWord() throws {
        let all = retypes("hello d ghbdtn ")
        let first = try #require(all.first)
        // The text before the caret is "d " and the keys of the word typed so far, all in ABC.
        #expect(first.expected.hasPrefix("d g") && "d ghbdtn".hasPrefix(first.expected))
        #expect(first.deleteCount == first.expected.count)
        #expect(first.text.hasPrefix("в "))
        // The end of the word, a space, retypes nothing again: the rest of the word is typed in Russian.
        #expect(all.count == 1)
    }

    @Test func theMarksGivenBackEraseTheCarriedWordOnce() throws {
        let all = retypes("hello d ytn, ")
        let last = try #require(all.last)
        // "в нет" and the comma that the Russian layout types as "б": one retype for the word with its mark,
        // without "в" again.
        #expect(last.expected == "в нетб")
        #expect(last.deleteCount == "в нетб".count)
        #expect(last.text == "в нет,")
        #expect(all.count == 2)
    }

    @Test func aCarriedWordIsNotCarriedAgain() {
        // After the switch inside the word the layout is Russian: the rest of the word, the space and the words
        // typed next ask for no second retype, so nothing is erased twice.
        var desk = ShortWordMachineTests.desk()
        desk.type("hello d ghbdtn ")
        desk.type("z yt vbh ")
        #expect(desk.text == "hello в привет я не мир ")
        #expect(desk.history.count == 1)
    }

    @Test func whereTheCaretCannotBeReadOnlyTheWordIsRetyped() throws {
        let blind = Focus(bundleID: "com.example.electron", caretReadable: false)
        var end = ShortWordMachineTests.desk()
        end.send(.focusChanged(blind))
        end.type("hello d vbh ")
        #expect(end.text == "hello d мир ")
        let last = try #require(end.history.last)
        #expect(last.expected == "vbh" && last.deleteCount == 3)
        var inside = ShortWordMachineTests.desk()
        inside.send(.focusChanged(blind))
        inside.type("hello d ghbdtn ")
        #expect(inside.text == "hello d привет ")
        #expect(inside.corrections.allSatisfy { $0.carried == 0 })
    }

    @Test func anUnknownFocusCarriesNothingAndAKnownOneKeepsTheCarry() throws {
        // No focus at all: the machine does not switch on its own, and so carries nothing (the guard in
        // `carryShortWords` is the second wall, should a caller get past the first).
        var none = ShortWordMachineTests.deskWithoutFocus()
        none.type("hello d vbh ")
        #expect(none.text == "hello d vbh " && none.history.isEmpty)
        // Where the focus is known and readable (TextEdit, Safari) the product carries as before.
        for bundle in ["com.apple.TextEdit", "com.apple.Safari"] {
            var desk = ShortWordMachineTests.desk()
            desk.send(.focusChanged(Focus(bundleID: bundle)))
            desk.type("hello d vbh ")
            #expect(desk.text == "hello в мир ", "\(bundle)")
            #expect(try #require(desk.history.last).expected == "d vbh", "\(bundle)")
        }
    }

    @Test func theFocusOfASessionWithoutTheFlagReadsAsReadable() throws {
        let old = Data(#"{"bundleID":"a.b","isSecureField":false,"isKnown":true}"#.utf8)
        #expect(try JSONDecoder().decode(Focus.self, from: old) == Focus(bundleID: "a.b"))
        // Written only when false: a recorded readable focus is the file of before.
        let readable = try JSONEncoder().encode(Focus(bundleID: "a.b"))
        #expect(!String(decoding: readable, as: UTF8.self).contains("caretReadable"))
        let blind = Focus(bundleID: "a.b", caretReadable: false)
        #expect(try JSONDecoder().decode(Focus.self, from: JSONEncoder().encode(blind)) == blind)
    }
}

@Suite struct ShortWordPartsTests {
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
