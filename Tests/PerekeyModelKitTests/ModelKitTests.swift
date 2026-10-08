// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyModelKit

@Suite struct HunspellTests {
    static let affix = """
    SET UTF-8
    TRY abc

    PFX U Y 1
    PFX U   0     un         .

    SFX D Y 3
    SFX D   0     d          e
    SFX D   y     ied        [^aeiou]y
    SFX D   0     ed         [^ey]

    SFX S N 1
    SFX S   0     s          .

    SFX Y Y 1
    SFX Y   ый    ого        ый
    """

    @Test func expandsSuffixesPrefixesAndCrossProducts() {
        let hunspell = Hunspell(affix: Self.affix)
        var forms: [String] = []
        hunspell.expand("tie", flags: "DU") { forms.append($0) }
        #expect(forms.sorted() == ["tie", "tied", "untie", "untied"])

        forms = []
        hunspell.expand("try", flags: "D") { forms.append($0) }
        #expect(forms.sorted() == ["tried", "try"])

        forms = []
        hunspell.expand("walk", flags: "DS") { forms.append($0) }
        #expect(forms.sorted() == ["walk", "walked", "walks"])

        // The condition must hold, else the rule does not apply.
        forms = []
        hunspell.expand("obey", flags: "D") { forms.append($0) }
        #expect(forms == ["obey"])

        forms = []
        hunspell.expand("красный", flags: "Y") { forms.append($0) }
        #expect(forms == ["красный", "красного"])
    }

    @Test func readsDictionaryEntries() {
        let entries = Hunspell.entries(dic: "3\nhello/DS\nworld\t po:noun\nЧПУ\n")
        #expect(entries.map(\.stem) == ["hello", "world", "ЧПУ"])
        #expect(entries.map(\.flags) == ["DS", "", ""])
    }
}

@Suite struct WordFreqTests {
    @Test func decodesTheMessagePackLayout() throws {
        // [ {"format": "cB", "version": 1}, [], ["the"], [], ["word", "x"] ]
        var bytes: [UInt8] = [0x95, 0x82]
        bytes += [0xA6] + Array("format".utf8) + [0xA2] + Array("cB".utf8)
        bytes += [0xA7] + Array("version".utf8) + [0x01]
        bytes += [0x90]
        bytes += [0x91, 0xA3] + Array("the".utf8)
        bytes += [0x90]
        bytes += [0x92, 0xA4] + Array("word".utf8)
        bytes += [0xA1] + Array("x".utf8)
        let list = try WordFreq(messagePack: Data(bytes))
        #expect(list.entries.map(\.word) == ["the", "word", "x"])
        #expect(list.entries[0].zipf == 9 - 0.02)
        #expect(list.entries[1].zipf == 9 - 0.04)
        #expect(WordFreq.rank(zipf: 7.7) == 246)
        #expect(WordFreq.rank(zipf: 0) == 1)
        #expect(WordFreq.rank(zipf: 9) == 255)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: (any Error).self) { try WordFreq(messagePack: Data([0x91, 0x80])) }
    }
}

@Suite struct DataListsTests {
    static let directory = Bundle.module.url(forResource: "lists", withExtension: nil, subdirectory: "Fixtures")!.path

    @Test func readsEveryList() throws {
        let lists = try DataLists(directory: "\(Self.directory)/ru")
        #expect(lists.add == ["перекей", "раскладочка"])
        #expect(lists.remove == ["ошибка-словаря"])
        #expect(lists.rank == ["привет": 200, "ок": 180])
        #expect(lists.abbreviations == ["ГОСТ", "МФЦ"])
        #expect(lists.keep == ["ок"])
    }

    @Test func missingFilesAreEmpty() throws {
        let lists = try DataLists(directory: "\(Self.directory)/none")
        #expect(lists.add.isEmpty && lists.remove.isEmpty && lists.rank.isEmpty)
    }

    @Test func badRankFails() {
        #expect(throws: ModelBuild.Failure.self) { try DataLists(directory: "\(Self.directory)/bad") }
    }
}

@Suite struct CorpusTests {
    @Test func wordsGetTheLanguageOfTheirScript() {
        #expect(Corpus.language(of: "привет,") == "ru")
        #expect(Corpus.language(of: "Hello") == "en")
        #expect(Corpus.language(of: "кто-то") == "ru")
        #expect(Corpus.language(of: "привет2") == nil)
        #expect(Corpus.language(of: "café") == nil)
        #expect(Corpus.language(of: "приветhello") == nil)
        #expect(Corpus.language(of: "—") == nil)
    }

    @Test func syntheticStringsAreReproducible() {
        var a = SplitMix64(seed: 7)
        var b = SplitMix64(seed: 7)
        let vocabulary = ["alpha", "beta", "gamma"]
        for _ in 0..<20 {
            #expect(Synthetic.url(vocabulary: vocabulary, random: &a) == Synthetic.url(vocabulary: vocabulary, random: &b))
            #expect(Synthetic.password(vocabulary: vocabulary, random: &a)
                == Synthetic.password(vocabulary: vocabulary, random: &b))
            #expect(Synthetic.captcha(language: "ru", random: &a) == Synthetic.captcha(language: "ru", random: &b))
        }
        var c = SplitMix64(seed: 8)
        #expect(Synthetic.captcha(language: "en", random: &c) != Synthetic.captcha(language: "en", random: &a))
    }

    @Test func corpusFileRoundTrips() throws {
        let items = [
            CorpusItem(category: "prose", language: "ru", previous: nil, text: "Привет,"),
            CorpusItem(category: "prose", language: "en", previous: "ru", text: "world"),
            CorpusItem(category: "url", language: "en", previous: nil, text: "https://a.b/c?d=1"),
            CorpusItem(category: "typos", language: "en", previous: "en", text: "wrold", expected: "world"),
        ]
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("perekey-corpus-\(UUID()).tsv").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Corpus.write(items, to: path)
        #expect(try Corpus.read(path) == items)
    }

    @Test func syntheticTyposAreOneEditAway() {
        var random = SplitMix64(seed: 3)
        var kinds: Set<Int> = []
        for word in ["keyboard", "привет", "hello", "спасибо", "world"] {
            for _ in 0..<40 {
                guard let typo = Synthetic.typo(of: word, language: Corpus.language(of: word)!, random: &random) else {
                    continue
                }
                #expect(typo != word)
                #expect(abs(typo.count - word.count) <= 1)
                // Letters only, from the same keyboard.
                #expect(Corpus.language(of: typo) == Corpus.language(of: word))
                kinds.insert(typo.count - word.count)
            }
        }
        #expect(kinds == [-1, 0, 1], "drops, substitutions and insertions all happen")
        #expect(Synthetic.neighbours(of: "g", language: "en").sorted() == ["b", "f", "h", "t", "v", "y"])
        #expect(Synthetic.typo(of: "abc", language: "en", random: &random) == nil)
    }
}

@Suite struct TypoEvaluationTests {
    /// The letter keys of the ANSI layout, enough for a layout map.
    static func layout(_ id: String, language: String, rows: [String]) -> LayoutMap {
        var table: [KeyStroke: String] = [KeyStroke(49): " "]
        let keys: [[UInt16]] = [
            [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30],
            [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
            [6, 7, 8, 9, 11, 45, 46, 43, 47],
        ]
        for (letters, row) in zip(rows, keys) {
            for (letter, key) in zip(letters, row) {
                table[KeyStroke(key)] = String(letter)
                table[KeyStroke(key, [.shift])] = letter.uppercased()
            }
        }
        return LayoutMap(id: LayoutID(id), language: language, table: table)
    }

    static let abc = layout("test.abc", language: "en", rows: ["qwertyuiop[]", "asdfghjkl;'", "zxcvbnm,./"])
    static let russian = layout("test.ru", language: "ru", rows: ["йцукенгшщзхъ", "фывапролджэ", "ячсмитьбю"])

    static let model: LanguageModel = {
        var builder = ModelBuilder()
        builder.addLanguage("en", alphabet: "abcdefghijklmnopqrstuvwxyz'-")
        builder.addLanguage("ru", alphabet: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-")
        for (word, rank) in [("hello", 200), ("world", 200), ("word", 180), ("then", 200), ("them", 200)] {
            builder.addForm(word, language: "en", rank: UInt8(rank), weight: 100)
        }
        builder.addForm("привет", language: "ru", rank: 200, weight: 100)
        return try! LanguageModel(bytes: builder.build())
    }()

    @Test func countsFixedTyposAndWrongCorrections() {
        let items = [
            CorpusItem(category: "typos", language: "en", previous: "en", text: "wrold", expected: "world"),
            CorpusItem(category: "typos", language: "en", previous: "en", text: "thenm", expected: "them"),
            CorpusItem(category: "prose", language: "en", previous: "en", text: "hello"),
            CorpusItem(category: "prose", language: "en", previous: "en", text: "hwllo"), // a right word the model lacks
            CorpusItem(category: "captcha", language: "en", previous: nil, text: "xkqzp"),
        ]
        let evaluation = Evaluation(model: Self.model, layouts: ["en": Self.abc, "ru": Self.russian])
        let results = evaluation.run(items)
        let typos = results.categories.first { $0.name == "typos" }
        #expect(typos?.typoWords == 2)
        #expect(typos?.typosFixed == 1, "thenm is ambiguous")
        #expect(typos?.wrongCorrections == 0)
        let prose = results.categories.first { $0.name == "prose" }
        #expect(prose?.checkedWords == 2)
        #expect(prose?.wrongCorrections == 1)
        #expect(results.errors.contains { $0.item.text == "hwllo" && $0.correction == "hello" })
        #expect(results.total.fixedShare == 0.5)
        #expect(!results.typoTargetsMet)
        #expect(Evaluation.report(results).contains("typo correction"))
    }
}
