// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

/// A model of a file per language (docs/classifier.md, «Файл на язык»).
@Suite struct ModelFilesTests {
    static let russianAlphabet = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-"
    static let englishAlphabet = "abcdefghijklmnopqrstuvwxyz'-"

    /// A one-language file with its own keep and cased entries and the mixed list.
    static func file(_ language: String, _ words: [String], keep: [String] = [],
                     cased: [(String, Bool)] = []) -> LanguageModel
    {
        var builder = ModelBuilder()
        builder.meta = language
        builder.addLanguage(language, alphabet: language == "ru" ? russianAlphabet : englishAlphabet)
        for word in words { builder.addForm(word, language: language, rank: 200, weight: 100) }
        for word in keep + ["iPhone"] { builder.addKeep(word) }
        for (word, corrects) in cased + [("iPhone", false)] { builder.addCasedForm(word, corrects: corrects) }
        return try! LanguageModel(bytes: builder.build())
    }

    static let russian = file("ru", ["привет", "мир"], keep: ["ГОСТ"], cased: [("МВД", true)])
    static let english = file("en", ["hello", "world"], keep: ["NASA"], cased: [("NASA", true), ("IT", true)])

    private func fingerprint(_ text: String, folded: Bool = false) -> UInt64 {
        ModelFormat.Fingerprint.of(text.unicodeScalars, folded: folded)
    }

    @Test func combinedFilesActAsOneModel() throws {
        let model = LanguageModel(combining: [Self.russian, Self.english])
        #expect(model.languages.map(\.code) == ["ru", "en"])
        #expect(model.codes == ["ru", "en"])
        #expect(model.meta == "ru\n\nen")
        #expect(model.byteCount == Self.russian.byteCount + Self.english.byteCount)
        for kept in ["ГОСТ", "NASA", "iPhone"] { #expect(model.isKept(fingerprint(kept))) }
        #expect(!model.isKept(fingerprint("гост")))
        #expect(model.casedForm(of: fingerprint("мвд", folded: true))?.form == "МВД")
        #expect(model.casedForm(of: fingerprint("nasa", folded: true))?.form == "NASA")
        let english = try #require(model.language("en"))
        #expect(english.rank(of: fingerprint("hello", folded: true)) == 200)
    }

    @Test func combinedModelClassifiesLikeOneFile() {
        var builder = ModelBuilder()
        builder.addLanguage("ru", alphabet: Self.russianAlphabet)
        builder.addLanguage("en", alphabet: Self.englishAlphabet)
        for word in ["привет", "мир"] { builder.addForm(word, language: "ru", rank: 200, weight: 100) }
        for word in ["hello", "world"] { builder.addForm(word, language: "en", rank: 200, weight: 100) }
        let one = Classifier(model: try! LanguageModel(bytes: builder.build()))
        let two = Classifier(model: LanguageModel(combining: [Self.russian, Self.english]))
        for word in ["ghbdtn", "hello", "vbh", "руддщ"] {
            let typed = word.first!.isASCII ? Fixture.abc : Fixture.russian
            let other = typed.id == Fixture.abc.id ? Fixture.russian : Fixture.abc
            let strokes = typed.strokes(word)
            #expect(one.classify(strokes, typed: typed, other: other) == two.classify(strokes, typed: typed, other: other))
        }
    }

    @Test func aCasedFormInTwoFilesFollowsTheBuilderRule() {
        let quiet = Self.file("en", ["hello"], cased: [("Abc", false)])
        let loud = Self.file("ru", ["мир"], cased: [("ABC", true)])
        for order in [[quiet, loud], [loud, quiet]] {
            let model = LanguageModel(combining: order)
            #expect(model.casedForm(of: fingerprint("abc", folded: true))?.form == "ABC", "a correcting form wins")
        }
    }

    @Test func keepingDropsTheFilesOfOtherLanguages() throws {
        let model = LanguageModel(combining: [Self.russian, Self.english])
        let english = try #require(model.keeping(languages: ["en", "uk"]))
        #expect(english.codes == ["en"])
        #expect(english.byteCount == Self.english.byteCount, "the Russian file is not held")
        #expect(!english.isKept(fingerprint("ГОСТ")))
        #expect(english.isKept(fingerprint("iPhone")), "the mixed list is in every file")
        #expect(model.keeping(languages: ["uk"]) == nil)
    }

    @Test func ukrainianApostropheReadsAsTheJoiner() {
        #expect(ModelFormat.fold(0x2BC) == 0x27)
        #expect(ModelFormat.fold(0x2019) == 0x2019, "’ is typed with ⌥ only; English text keeps it as a symbol")
        #expect(ModelFormat.Fingerprint.of("пʼять".unicodeScalars, folded: true)
            == ModelFormat.Fingerprint.of("п'ять".unicodeScalars, folded: true))
    }
}
