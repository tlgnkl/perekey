// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

@Suite struct ClassifierTests {
    let classifier = Classifier(model: ModelFixture.model)
    let abc = Fixture.abc
    let russian = Fixture.russian

    /// Classifies text typed on the keys of `typed`, with `other` as the alternative.
    func decide(_ text: String, typed: LayoutMap, other: LayoutMap, previous: String? = nil,
                mode: Classifier.Mode = .automatic) -> Classifier.Decision
    {
        classifier.classify(typed.strokes(text), typed: typed, other: other,
                            context: Classifier.Context(previousLanguage: previous, mode: mode))
    }

    @Test(arguments: ["ghbdtn", "vbh", "[jhjij", "ds,jh", "cgfcb,j", "Ghbdtn", "GHBDTN"])
    func russianTypedInEnglishSwitches(typed: String) {
        let decision = decide(typed, typed: abc, other: russian)
        #expect(decision.verdict == .switch(to: russian.id))
        #expect(decision.language == "ru")
        #expect(decision.score > 0)
    }

    @Test(arguments: ["руддщ", "цщкдв", "лунищфкв", "Руддщ"])
    func englishTypedInRussianSwitches(typed: String) {
        let decision = decide(typed, typed: russian, other: abc)
        #expect(decision.verdict == .switch(to: abc.id))
        #expect(decision.language == "en")
    }

    @Test(arguments: ["привет", "хорошо", "спасибо", "Привет", "что-то"])
    func russianStaysRussian(typed: String) {
        let decision = decide(typed, typed: russian, other: abc)
        #expect(decision.verdict == .keep)
        #expect(decision.language == "ru")
    }

    @Test(arguments: ["hello", "world", "keyboard", "Hello", "don't"])
    func englishStaysEnglish(typed: String) {
        let decision = decide(typed, typed: abc, other: russian)
        #expect(decision.verdict == .keep)
        #expect(decision.language == "en")
    }

    @Test(arguments: [
        "https://example.com/path", "www.example.com", "user@mail.ru", "~/Documents/file.txt", "print(x)",
        "x+=1", "a/b", "--flag", "foo_bar", "C:\\Users", "$HOME",
    ])
    func codeAndURLsAreKept(typed: String) {
        let decision = decide(typed, typed: abc, other: russian)
        #expect(decision.verdict == .keep)
        #expect(decision.verdict != .unsure)
    }

    @Test(arguments: ["ghbdtn2024", "k2", "1abc", "привет1"])
    func wordsWithDigitsAreKept(typed: String) {
        let layout = typed.first!.isCyrillic ? russian : abc
        let decision = decide(typed, typed: layout, other: layout == abc ? russian : abc)
        #expect(decision.verdict == .keep)
        #expect(decision.reason == .digits)
    }

    @Test func passwordLikeStringsAreKept() {
        let decision = decide("ghBdtn!x", typed: abc, other: russian)
        #expect(decision.verdict == .keep)
        #expect(decision.reason == .passwordLike)
        // A capital only at the start with trailing punctuation is a sentence, not a password.
        #expect(decide("Ghbdtn!", typed: abc, other: russian).reason != .passwordLike)
    }

    @Test(arguments: ["xkqzp", "qwzxv", "zqxjk"])
    func randomStringsAreKept(typed: String) {
        let decision = decide(typed, typed: abc, other: russian)
        #expect(decision.verdict == .keep)
        #expect(decision.reason == .noise)
    }

    @Test func keepListWins() {
        #expect(decide("iPhone", typed: abc, other: russian).reason == .kept)
        #expect(decide("Wi-Fi", typed: abc, other: russian).reason == .kept)
        #expect(decide("ГОСТ", typed: russian, other: abc).reason == .kept)
        // Not on the list: judged like any word.
        #expect(decide("iphone", typed: abc, other: russian).reason != .kept)
    }

    @Test func oneLetterWordsNeedTheDictionary() {
        // "f" is no English word; "а" is the most common Russian one.
        #expect(decide("f", typed: abc, other: russian, previous: "ru").verdict == .switch(to: russian.id))
        #expect(decide("b", typed: abc, other: russian).verdict == .switch(to: russian.id))
        // "a" and "i" are English words: never switched.
        #expect(decide("a", typed: abc, other: russian, previous: "ru").verdict == .keep)
        #expect(decide("i", typed: abc, other: russian).verdict == .keep)
        // After an English word, a lone "f" is more likely English shorthand.
        #expect(decide("f", typed: abc, other: russian, previous: "en").verdict == .keep)
        // "ш" is no Russian word, "i" is English.
        #expect(decide("ш", typed: russian, other: abc).verdict == .switch(to: abc.id))
    }

    @Test func russianPunctuationKeysBelongToTheWord() {
        // ",eltn" is "будет": the comma key is "б".
        #expect(decide(",eltn", typed: abc, other: russian).verdict == .switch(to: russian.id))
        // "'nj" is "это".
        #expect(decide("'nj", typed: abc, other: russian).verdict == .switch(to: russian.id))
        // Shift+6 is "," in Russian: "ghbdtn^" is "привет," with its comma.
        var strokes = abc.strokes("ghbdtn")
        strokes.append(KeyStroke(22, .shift))
        let decision = classifier.classify(strokes, typed: abc, other: russian)
        #expect(decision.verdict == .switch(to: russian.id))
    }

    @Test func trailingPunctuationIsNotPartOfTheWord() {
        #expect(decide("hello,", typed: abc, other: russian).verdict == .keep)
        #expect(decide("(hello)", typed: abc, other: russian).verdict == .keep)
        #expect(decide("«привет»", typed: russian, other: abc).verdict == .keep)
        // "hello." typed in the Russian layout: the period key is "ю" there.
        let strokes = russian.strokes("руддщ") + [KeyStroke(47)]
        #expect(classifier.classify(strokes, typed: russian, other: abc).verdict == .switch(to: abc.id))
    }

    @Test func trailingSpacesAreIgnored() {
        var strokes = abc.strokes("ghbdtn")
        strokes.append(KeyStroke(KeyCode.space))
        strokes.append(KeyStroke(KeyCode.space))
        #expect(classifier.classify(strokes, typed: abc, other: russian).verdict == .switch(to: russian.id))
        #expect(classifier.classify([KeyStroke(KeyCode.space)], typed: abc, other: russian).reason == .empty)
    }

    @Test func previousWordLanguageTipsTheBalance() {
        let alone = decide("ghbdtn", typed: abc, other: russian)
        let afterRussian = decide("ghbdtn", typed: abc, other: russian, previous: "ru")
        let afterEnglish = decide("ghbdtn", typed: abc, other: russian, previous: "en")
        #expect(afterRussian.score > alone.score)
        #expect(afterEnglish.score < alone.score)
    }

    @Test func manualModeComparesWithoutGuards() {
        // Digits block automatic switching but not an explicit request.
        let decision = decide("ghbdtn1", typed: abc, other: russian, mode: .manual)
        #expect(decision.verdict == .switch(to: russian.id))
        #expect(decide("hello", typed: abc, other: russian, mode: .manual).verdict == .keep)
    }

    @Test func unsupportedLayoutsAreKept() {
        let decision = decide("ghbdtn", typed: abc, other: Fixture.us)
        #expect(decision.reason == .unsupported)
        #expect(classifier.classify(Fixture.ukrainianPC.strokes("привіт"), typed: Fixture.ukrainianPC, other: abc)
            .reason == .unsupported)
    }

    @Test func impossiblePrefixes() {
        #expect(classifier.impossiblePrefix(abc.strokes("ghb"), typed: abc, other: russian))
        #expect(classifier.impossiblePrefix(abc.strokes("ghbd"), typed: abc, other: russian))
        #expect(!classifier.impossiblePrefix(abc.strokes("hel"), typed: abc, other: russian))
        #expect(!classifier.impossiblePrefix(abc.strokes("gh"), typed: abc, other: russian))
        #expect(!classifier.impossiblePrefix(russian.strokes("при"), typed: russian, other: abc))
        #expect(classifier.impossiblePrefix(russian.strokes("рудд"), typed: russian, other: abc))
        // Capitals inside look like an abbreviation: no mid-word switch.
        #expect(!classifier.impossiblePrefix(abc.strokes("GHB"), typed: abc, other: russian))
    }

    @Test func decisionsAreFastAndStable() {
        // Hundreds of classifications of a long word in well under a millisecond each.
        let strokes = abc.strokes("ghbdtn") + abc.strokes("vbh") + abc.strokes("[jhjij") + abc.strokes("ds,jh")
        let first = classifier.classify(strokes, typed: abc, other: russian)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<200 {
                #expect(classifier.classify(strokes, typed: abc, other: russian) == first)
            }
        }
        #expect(elapsed < .milliseconds(200))
    }
}

@Suite struct LanguageModelTests {
    @Test func builderIsDeterministic() {
        #expect(ModelFixture.bytes == ModelFixture.bytes.withUnsafeBufferPointer { Array($0) })
        var builder = ModelBuilder()
        builder.meta = "fixture"
        builder.addLanguage("ru", alphabet: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-")
        builder.addLanguage("en", alphabet: "abcdefghijklmnopqrstuvwxyz'-")
        for (word, rank) in ModelFixture.russian { builder.addForm(word, language: "ru", rank: rank, weight: Double(rank)) }
        for (word, rank) in ModelFixture.english { builder.addForm(word, language: "en", rank: rank, weight: Double(rank)) }
        for word in ["iPhone", "Wi-Fi", "ГОСТ"] { builder.addKeep(word) }
        ModelFixture.addCorrections(to: &builder)
        #expect(builder.build() == ModelFixture.bytes)
    }

    @Test func readerFindsSections() throws {
        let model = ModelFixture.model
        #expect(model.meta == "fixture")
        #expect(model.languages.map(\.code) == ["ru", "en"])
        let russian = try #require(model.language("ru"))
        #expect(russian.rank(of: ModelFormat.Fingerprint.of("привет".unicodeScalars, folded: true)) == 200)
        #expect(russian.rank(of: ModelFormat.Fingerprint.of("ПРИВЕТ".unicodeScalars, folded: true)) == 200)
        #expect(russian.rank(of: ModelFormat.Fingerprint.of("приветик".unicodeScalars, folded: true)) == nil)
        // "ёлка" is also stored as "елка".
        #expect(russian.rank(of: ModelFormat.Fingerprint.of("елка".unicodeScalars, folded: true)) == 150)
        #expect(model.isKept(ModelFormat.Fingerprint.of("iPhone".unicodeScalars, folded: false)))
        #expect(!model.isKept(ModelFormat.Fingerprint.of("iphone".unicodeScalars, folded: false)))
    }

    @Test func everyFormIsFoundWhenBucketsFill() throws {
        // 20 000 forms in 65 536 buckets: many buckets hold several forms, so
        // the order inside a bucket matters.
        var builder = ModelBuilder()
        builder.addLanguage("en", alphabet: "abcdefghijklmnopqrstuvwxyz")
        var words: [String] = []
        for index in 0..<20000 {
            var word = ""
            var value = index
            for _ in 0..<4 {
                word.append(Character(UnicodeScalar(UInt8(97 + value % 26))))
                value /= 26
            }
            words.append(word)
            builder.addForm(word, language: "en", rank: UInt8(index % 256), weight: 1)
        }
        let language = try #require(try LanguageModel(bytes: builder.build()).language("en"))
        for (index, word) in words.enumerated() {
            #expect(language.rank(of: ModelFormat.Fingerprint.of(word.unicodeScalars, folded: true)) == UInt8(index % 256))
        }
        #expect(language.rank(of: ModelFormat.Fingerprint.of("zzzzz".unicodeScalars, folded: true)) == nil)
    }

    @Test func formsOutsideTheAlphabetAreRejected() {
        var builder = ModelBuilder()
        builder.addLanguage("en", alphabet: "abc")
        let inside = builder.addForm("abc", language: "en", rank: 1, weight: 1)
        let outside = builder.addForm("abd", language: "en", rank: 1, weight: 1)
        let empty = builder.addForm("", language: "en", rank: 1, weight: 1)
        #expect(inside && !outside && !empty)
    }

    @Test func corruptionIsDetected() {
        var bytes = ModelFixture.bytes
        bytes[bytes.count / 2] ^= 0xFF
        #expect(throws: LanguageModel.Error.badChecksum) { try LanguageModel(bytes: bytes) }
        #expect(throws: LanguageModel.Error.self) { try LanguageModel(bytes: Array(ModelFixture.bytes.prefix(100))) }
        #expect(throws: LanguageModel.Error.badMagic) { try LanguageModel(bytes: [UInt8](repeating: 0, count: 64)) }
    }
}

extension Character {
    var isCyrillic: Bool {
        unicodeScalars.allSatisfy { (0x400...0x4FF).contains($0.value) }
    }
}
