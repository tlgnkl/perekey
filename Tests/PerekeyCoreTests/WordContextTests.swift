// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

/// The word before as a context of the classifier (docs/classifier.md,
/// «Слова в контексте»): short words and the band of doubt.
@Suite struct WordContextTests {
    let abc = Fixture.abc
    let russian = Fixture.russian

    /// "yf" is English here and "на" on the Russian keys, both of rank 230;
    /// "yj" is English of rank 235 and "но" on the Russian keys (rank 205).
    static let english: [(String, UInt8)] = [("yf", 230), ("yj", 235)]

    private func ref(_ word: String, _ language: String) -> Classifier.PreviousWordRef {
        Classifier.PreviousWordRef(language: language, fingerprint: ModelFixture.fingerprint(word))
    }

    private func classifier(limit: Double, russianPairs: [(String, String, UInt8)] = [],
                            englishPairs: [(String, String, UInt8)] = [],
                            russianWords: [(String, UInt8)] = []) -> Classifier
    {
        var classifier = Classifier(model: ModelFixture.model(withEnglishWords: Self.english,
                                                              englishPairs: englishPairs,
                                                              russianWords: russianWords,
                                                              russianPairs: russianPairs))
        classifier.options.wordContextLimit = limit
        return classifier
    }

    private func decide(_ classifier: Classifier, _ text: String, previous: Classifier.PreviousWordRef?,
                        language: String? = "ru") -> Classifier.Decision
    {
        classifier.classify(abc.strokes(text), typed: abc, other: russian,
                            context: Classifier.Context(recent: RecentLanguages(language.map { [$0] } ?? []),
                                                        previousWord: previous))
    }

    @Test func aShortWordTheRankKeepsIsSwitchedWhenThePairLikesTheOtherReading() {
        let pairs: [(String, String, UInt8)] = [("привет", "на", 40)]
        let with = classifier(limit: 8, russianPairs: pairs)
        // Same rank in both languages after a Russian word: no switch without the pair.
        #expect(decide(classifier(limit: 0, russianPairs: pairs), "yf", previous: ref("привет", "ru")).verdict == .keep)
        #expect(decide(with, "yf", previous: nil).verdict == .keep)
        #expect(decide(with, "yf", previous: ref("привет", "ru")).verdict == .switch(to: russian.id))
        // A pair of another word, or of a word of another language, says nothing.
        #expect(decide(with, "yf", previous: ref("мир", "ru")).verdict == .keep)
        #expect(decide(with, "yf", previous: ref("привет", "en")).verdict == .keep)
    }

    @Test func theLimitCapsWhatThePairGives() {
        // "yf" ties with "на" at 230: half a bit, 5 units of rank, is enough.
        let tie = classifier(limit: 0.5, russianPairs: [("привет", "на", 255)])
        #expect(decide(tie, "yf", previous: ref("привет", "ru")).verdict == .switch(to: russian.id))
        // "yj" is 30 units ahead of "но" (205). The pair has 31.9 bits, but the limit of one bit
        // is 10 units: the typed word stays.
        let capped = classifier(limit: 1, russianPairs: [("привет", "но", 255)])
        #expect(decide(capped, "yj", previous: ref("привет", "ru")).verdict == .keep)
    }

    @Test func thePairOfTheTypedReadingHoldsASwitchBack() {
        // After an English word "yf" is a word of the typed reading, mixed sentence or not:
        // the Russian pair is of no use, the English pair cannot make it switch.
        let with = classifier(limit: 8, russianPairs: [("привет", "на", 255)], englishPairs: [("see", "yf", 60)])
        #expect(decide(with, "yf", previous: ref("see", "en"), language: "en").verdict == .keep)
    }

    /// English words of the fixture whose Russian reading (the same keys on
    /// the Russian layout) is added to the model as a word of a rank that
    /// differs from word to word: the readings compete on every score from
    /// a clear switch to a clear keep, the band of doubt in between.
    private var spread: [(english: String, russian: String, rank: UInt8)] {
        let words = ModelFixture.english.map(\.0).filter { $0.count >= 3 && $0.allSatisfy { $0.isASCII && $0.isLetter } }
        return words.enumerated().map { index, word in
            (word, abc.strokes(word).compactMap { russian.text(for: $0) }.joined(), UInt8(80 + (index * 7) % 160))
        }
    }

    private var spreadWords: [(String, UInt8)] { spread.map { ($0.russian, $0.rank) } }

    /// A strong pair after "привет" for every Russian reading, and after "see" for every English word.
    private var spreadClassifier: Classifier {
        classifier(limit: 100, russianPairs: spread.map { ("привет", $0.russian, 255) },
                   englishPairs: spread.flatMap { [("see", $0.english, 255), ("привет", $0.english, 255)] },
                   russianWords: spreadWords)
    }

    @Test func aPairTipsADecisionOfTheBandOfDoubtAndNothingElse() {
        let plain = classifier(limit: 0, russianWords: spreadWords)
        let with = spreadClassifier
        let margin = plain.options.threshold
        var band = 0
        for entry in spread {
            let before = decide(plain, entry.english, previous: ref("привет", "ru"))
            guard before.reason == .compared, before.verdict == .unsure else { continue }
            band += 1
            #expect(before.score > 0 && before.score < margin + plain.options.unknownWordExtra)
            let after = decide(with, entry.english, previous: ref("привет", "ru"))
            // 31.9 bits move any score of the band over its bar.
            #expect(after.verdict == .switch(to: russian.id), "\(entry.english)")
            #expect(after.score == before.score)
        }
        // The fixture has doubt to resolve; otherwise this test proves nothing.
        #expect(band > 0)
    }

    @Test func aPairOfTheTypedReadingTurnsADoubtIntoAKeep() {
        let plain = classifier(limit: 0, russianWords: spreadWords)
        let with = spreadClassifier
        var band = 0
        for entry in spread {
            let before = decide(plain, entry.english, previous: ref("see", "en"), language: "en")
            guard before.reason == .compared, before.verdict == .unsure else { continue }
            band += 1
            // The previous word is English: the pair of the typed reading counts against the switch.
            let after = decide(with, entry.english, previous: ref("see", "en"), language: "en")
            #expect(after.verdict == .keep, "\(entry.english)")
        }
        #expect(band > 0)
    }

    @Test func aConfidentDecisionIsNeverMoved() {
        let plain = classifier(limit: 0, russianWords: spreadWords)
        let with = spreadClassifier
        for entry in spread {
            let word = entry.english
            let before = decide(plain, word, previous: ref("привет", "ru"))
            guard before.reason == .compared, before.verdict != .unsure else { continue }
            let after = decide(with, word, previous: ref("привет", "ru"))
            #expect(after.verdict == before.verdict, "\(word)")
        }
    }

    @Test func aLimitOfZeroLooksNothingUp() {
        let pairs: [(String, String, UInt8)] = [("привет", "на", 255), ("привет", "мир", 255)]
        let off = classifier(limit: 0, russianPairs: pairs)
        let plain = Classifier(model: ModelFixture.model(withEnglishWords: Self.english, pairs: []))
        for word in ["yf", "yj", "hello", "ghbdtn", "vbh", "b", "f"] {
            let left = decide(off, word, previous: ref("привет", "ru"))
            let right = decide(plain, word, previous: nil)
            #expect(left == right, "\(word)")
        }
    }

    @Test func manualModeIgnoresTheWordBefore() {
        let with = classifier(limit: 8, russianPairs: [("привет", "на", 255)])
        let context = Classifier.Context(recent: RecentLanguages(["ru"]), mode: .manual,
                                         previousWord: ref("привет", "ru"))
        let bare = Classifier.Context(recent: RecentLanguages(["ru"]), mode: .manual)
        #expect(with.classify(abc.strokes("yf"), typed: abc, other: russian, context: context)
            == with.classify(abc.strokes("yf"), typed: abc, other: russian, context: bare))
    }
}

/// The word before, inside the machine: the judge reads it from the buffer
/// with the language of the layout it was typed in.
@Suite struct WordContextMachineTests {
    static let model = ModelFixture.model(withEnglishWords: [("yf", 230)],
                                          russianPairs: [("привет", "на", 40)])

    static func desk(limit: Double) -> Desk {
        var options = Classifier.Options()
        options.personalNoiseCost = .infinity
        options.wordContextLimit = limit
        return Desk(Settings(), classifier: Classifier(model: model, options: options))
    }

    /// "привет" on the Russian layout, then "yf" on ABC: "на" and "yf" tie on rank.
    static func typeAfterRussianWord(limit: Double, before: String = "привет ") -> String {
        var desk = Self.desk(limit: limit)
        desk.appLayout = Fixture.russian.id
        desk.send(.layoutChanged(Fixture.russian.id))
        desk.type(before, on: Fixture.russian)
        desk.appLayout = Fixture.abc.id
        desk.send(.layoutChanged(Fixture.abc.id))
        desk.type("yf ")
        return desk.text
    }

    @Test func thePairOfTheWordBeforeSwitchesAShortWord() {
        #expect(Self.typeAfterRussianWord(limit: 8) == "привет на ")
    }

    @Test func withLimitZeroTheTextIsAsBefore() {
        #expect(Self.typeAfterRussianWord(limit: 0) == "привет yf ")
    }

    @Test func aWordWithoutThePairChangesNothing() {
        #expect(Self.typeAfterRussianWord(limit: 8, before: "мир ") == "мир yf ")
    }

    @Test func theFirstWordOfTheFieldHasNoWordBefore() {
        var desk = Self.desk(limit: 8)
        desk.type("yf ")
        #expect(desk.text == "yf ")
    }
}
