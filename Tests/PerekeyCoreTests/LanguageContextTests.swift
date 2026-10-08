// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

/// The context of a word: the languages of the words before it in the sentence.

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

@Suite struct RecentLanguagesTests {
    @Test func keepsTheLastThreeLatestFirst() {
        var recent = RecentLanguages()
        for language in ["en", "ru", nil, "ru"] { recent.push(language) }
        #expect(recent.count == 3)
        #expect(recent.latest == "ru")
        #expect(recent[1] == nil)
        #expect(recent[2] == "ru")
        #expect(recent[3] == nil)
        #expect(recent == RecentLanguages(["ru", nil, "ru", "en"]))
    }

    @Test func aSentenceEndKeepsTheLastWord() {
        var recent = RecentLanguages(["en", "ru", "ru"])
        recent.keepLatest()
        #expect(recent == RecentLanguages(["en"]))
        recent.replaceLatest("ru")
        #expect(recent == RecentLanguages(["ru"]))
        recent.removeAll()
        #expect(recent.count == 0)
        recent.replaceLatest("en")
        #expect(recent == RecentLanguages(["en"]))
    }
}

@Suite struct ClassifierContextTests {
    let classifier = Classifier(model: ModelFixture.model)

    func decide(_ text: String, typed: LayoutMap, other: LayoutMap, recent: [String?]) -> Classifier.Decision {
        classifier.classify(typed.strokes(text), typed: typed, other: other,
                            context: Classifier.Context(recent: RecentLanguages(recent)))
    }

    @Test func agreeingWordsAddUp() {
        let one = decide("руддщ", typed: Fixture.russian, other: Fixture.abc, recent: ["en"])
        let three = decide("руддщ", typed: Fixture.russian, other: Fixture.abc, recent: ["en", "en", "en"])
        let options = Classifier.Options()
        let earlier = options.contextBonus * (options.contextDecay + options.contextDecay * options.contextDecay)
        #expect(three.score - one.score == earlier)
        let against = decide("руддщ", typed: Fixture.russian, other: Fixture.abc, recent: ["ru", "ru", "ru"])
        #expect(one.score - against.score == 2 * options.contextBonus + earlier)
    }

    @Test func inAMixedSentenceOnlyThePreviousWordCounts() {
        let one = decide("руддщ", typed: Fixture.russian, other: Fixture.abc, recent: ["en"])
        let mixed = decide("руддщ", typed: Fixture.russian, other: Fixture.abc, recent: ["en", "ru", "en"])
        #expect(mixed.score == one.score)
    }

    @Test func aShortWordSwitchesAfterItsOwnLanguageOnlyInAMixedSentence() {
        // "i" typed on the Russian keys is "ш". After a Russian word it stays,
        // unless the sentence has English in it too.
        let plain = decide("ш", typed: Fixture.russian, other: Fixture.abc, recent: ["ru", "ru"])
        #expect(plain.verdict == .keep)
        let mixed = decide("ш", typed: Fixture.russian, other: Fixture.abc, recent: ["ru", "en"])
        #expect(mixed.verdict == .switch(to: en))
    }
}

@Suite struct WordJudgeContextTests {
    let layouts = LayoutState([Fixture.abc, Fixture.russian], current: en)

    func judge(_ judge: inout WordJudge, _ text: String, endedBy keyCode: UInt16 = KeyCode.space) {
        var buffer = WordBuffer()
        for stroke in Fixture.abc.strokes(text) { buffer.type(stroke, in: en) }
        judge.typed(startsWord: true)
        _ = judge.judge(endedBy: KeyEvent(.down, keyCode: keyCode), held: 0, buffer: buffer, layouts: layouts,
                        settings: Settings(), focus: Desk.textEdit, secureInput: false)
    }

    @Test func aSentenceEndLeavesItsLastWord() {
        var wordJudge = WordJudge(classifier: Desk.classifier)
        judge(&wordJudge, "hello")
        judge(&wordJudge, "world")
        #expect(wordJudge.recent.count == 2)
        judge(&wordJudge, "today", endedBy: KeyCode.return)
        #expect(wordJudge.recent == RecentLanguages(["en"]))
        wordJudge.forgetContext(newField: false)
        #expect(wordJudge.recent.count == 0)
    }
}
