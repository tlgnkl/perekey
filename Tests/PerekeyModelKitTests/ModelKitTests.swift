// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
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
        ]
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("perekey-corpus-\(UUID()).tsv").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Corpus.write(items, to: path)
        #expect(try Corpus.read(path) == items)
    }
}
