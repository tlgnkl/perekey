// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyModelKit

/// Words and sentences of the training text, and the pair counts built on them.
@Suite struct PairTextTests {
    static func fingerprint(_ text: String) -> UInt64 {
        ModelFormat.Fingerprint.of(text.unicodeScalars, folded: true)
    }

    static func events(_ text: String) -> [PairText.Event] {
        var events: [PairText.Event] = []
        PairText.scan(text) { events.append($0) }
        return events
    }

    static func word(_ text: String) -> PairText.Event { .word(fingerprint(text)) }

    @Test func wordsComeFoldedAndSentencesEndAtTheirMarks() {
        #expect(Self.events("Привет, мир! Как дела?") == [
            Self.word("привет"), Self.word("мир"), .sentenceEnd, Self.word("как"), Self.word("дела"), .sentenceEnd,
        ])
        // The comma, the dash, the quotes and the brackets end no sentence.
        #expect(Self.events("«Привет» — (мир)") == [Self.word("привет"), Self.word("мир"), .sentenceEnd])
    }

    @Test func aWordIsWhatCoverageCallsOne() {
        let sentences = ["кто-то сказал «да-да» и ушёл", "don’t say -what- or a--b", "'quoted' word- -word ok",
                         "Ёлка и ёж", "x2 3d 1990 года", "Perekey, iPhone & NASA", "п'ять п’ять пʼять"]
        for sentence in sentences {
            let words = Coverage.words(of: Substring(sentence)).map { token in
                Self.fingerprint(String(String.UnicodeScalarView(token.unicodeScalars.map { $0 == "\u{2019}" ? "'" : $0 })))
            }
            #expect(Self.events(sentence) == words.map { .word($0) } + [.sentenceEnd], "\(sentence)")
        }
    }

    @Test func theApostrophesOfTheLayoutsAreOneJoiner() {
        #expect(Self.events("don’t") == Self.events("don't"))
        #expect(Self.events("п'ять") == Self.events("пʼять"))
        #expect(Self.events("п'ять") == [Self.word("п'ять"), .sentenceEnd])
    }

    @Test func sentencesEndAtDotsParagraphsAndLines() {
        #expect(Self.events("т.е. да") == [Self.word("т"), .sentenceEnd, Self.word("е"), .sentenceEnd, Self.word("да"),
                                           .sentenceEnd])
        #expect(Self.events("3.5 раза") == [Self.word("3"), .sentenceEnd, Self.word("5"), Self.word("раза"), .sentenceEnd])
        #expect(Self.events("один\tдва\nтри…четыре") == [Self.word("один"), .sentenceEnd, Self.word("два"), .sentenceEnd,
                                                        Self.word("три"), .sentenceEnd, Self.word("четыре"), .sentenceEnd])
    }

    @Test func aSentenceWithNoWordSendsNoEnd() {
        #expect(Self.events("").isEmpty)
        #expect(Self.events("... !? \t\n —") .isEmpty)
        #expect(Self.events("да... нет") == [Self.word("да"), .sentenceEnd, Self.word("нет"), .sentenceEnd])
    }

    @Test func aMarkStaysInTheWordAndMakesItAnotherWord() {
        #expect(Self.events("уда\u{301}р") != Self.events("удар"))
        #expect(Self.events("уда\u{301}р").count == 2)
    }

    @Test func damagedUTF8IsASeparatorAndNeverStopsTheScan() {
        let bytes: [UInt8] = Array("да".utf8) + [0xFF] + Array("нет".utf8) + [0xD0] + Array("ок".utf8) + [0xE2, 0x82]
        var events: [PairText.Event] = []
        bytes.withUnsafeBytes { PairText.scan($0) { events.append($0) } }
        #expect(events == [Self.word("да"), Self.word("нет"), Self.word("ок"), .sentenceEnd])
    }
}

@Suite struct PairTableTests {
    static let known = ["привет", "мир", "как", "дела"].map(PairTextTests.fingerprint)

    /// 8 sentences: "привет мир" ×3, "как дела" ×3, "привет дела", "привет ёж" (ёж is not known).
    /// 16 words. привет is followed 5 times, occurs 5; мир occurs 3; как 3; дела 4; 8 sentences.
    static let text = "привет мир. привет мир. привет мир. как дела. как дела. как дела. привет дела. привет, ёж."

    static func count(_ text: String = text, options: PairTable.Options = PairTable.Options()) throws -> PairTable {
        try PairTable.count(language: "ru", sources: ["abc  wikipedia-pairs/ru/x.parquet"], knownForms: known,
                            options: options) { line in
            var text = text
            text.withUTF8 { line(UnsafeRawBufferPointer($0)) }
        }
    }

    private func key(_ previous: String, _ word: String) -> [UInt64] {
        [previous.isEmpty ? ModelFormat.sentenceStart : PairTextTests.fingerprint(previous), PairTextTests.fingerprint(word)]
    }

    @Test func pairsCarryTheirCountsAndTheTotalsOfTheirWords() throws {
        var options = PairTable.Options()
        options.minCount = 1
        options.minLift = -1000
        let table = try Self.count(options: options)
        #expect(table.tokens == 16)
        func entry(_ previous: String, _ word: String) -> PairTable.Entry? {
            let ids = key(previous, word)
            return table.entries.first { $0.previous == ids[0] && $0.word == ids[1] }
        }
        #expect(entry("привет", "мир") == .init(previous: key("привет", "мир")[0], word: key("привет", "мир")[1],
                                                 count: 3, previousTotal: 5, wordTotal: 3))
        #expect(entry("как", "дела")?.count == 3)
        #expect(entry("привет", "дела")?.count == 1)
        #expect(entry("", "привет")?.count == 5)
        #expect(entry("", "привет")?.previousTotal == 8) // eight sentences
        #expect(entry("", "как")?.count == 3)
        // The word before an unknown word and the word after it make no pair; the unknown word still counts as a word.
        #expect(entry("привет", "ёж") == nil)
        #expect(table.entries.count == 5)
    }

    @Test func aPairNeedsItsCountAndOneBitOfLift() throws {
        let table = try Self.count()
        // "привет мир": (3 − 0.75) / 5 over 3 / 16 is 2.4 times, 10 eighths of a bit. "как дела": 3 times, 13.
        // "привет" at the start of a sentence: 6 eighths, under a bit; "как" there: 5.
        #expect(Set(table.entries.map { [$0.count, $0.previousTotal, $0.wordTotal] }) == [[3, 5, 3], [3, 3, 4]])
        #expect(table.chosen().map(\.lift).sorted() == [10, 13])
        var options = PairTable.Options()
        options.minCount = 4
        #expect(try Self.count(options: options).entries.isEmpty)
    }

    @Test func theSketchChangesNoCount() throws {
        var small = PairTable.Options(), large = PairTable.Options()
        small.sketchBits = 4 // every pair shares a counter with others
        large.sketchBits = 20
        small.minCount = 1
        large.minCount = 1
        small.minLift = -1000
        large.minLift = -1000
        #expect(try Self.count(options: small).entries == Self.count(options: large).entries)
        // And with the default minimum a tiny sketch lets strangers through that the count then drops.
        small.minCount = 3
        large.minCount = 3
        small.minLift = 8
        large.minLift = 8
        #expect(try Self.count(options: small).entries == Self.count(options: large).entries)
    }

    @Test func theEntriesAreSortedAndTwoCountsGiveOneTable() throws {
        let a = try Self.count(), b = try Self.count()
        #expect(a.tsv() == b.tsv())
        var options = PairTable.Options()
        options.minCount = 1
        options.minLift = -1000
        let entries = try Self.count(options: options).entries
        #expect(entries.map { [$0.previous, $0.word] } == entries.map { [$0.previous, $0.word] }.sorted {
            ($0[0], $0[1]) < ($1[0], $1[1])
        })
    }

    @Test func theFileHoldsFingerprintsAndNumbersButNoWord() throws {
        var options = PairTable.Options()
        options.minCount = 1
        options.minLift = -1000
        let text = try Self.count(options: options).tsv()
        for word in ["привет", "мир", "как", "дела", "ёж"] { #expect(!text.contains(word), "\(word)") }
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(!body.isEmpty)
        for line in body {
            #expect(line.range(of: #"^[0-9a-f]{16}\t[0-9a-f]{16}\t\d+\t\d+\t\d+$"#, options: .regularExpression) != nil,
                    "\(line)")
        }
        // The comments say what the file is for and where it came from, in numbers and file names.
        let header = text.split(separator: "\n").filter { $0.hasPrefix("#") }
        #expect(header.contains("# language ru") && header.contains("# tokens 16"))
    }

    @Test func theFileRoundTripsAndRefusesWhatItIsNot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pairs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let table = try Self.count()
        let path = directory.appendingPathComponent("ru.tsv").path
        try table.tsv().write(toFile: path, atomically: true, encoding: .utf8)
        let read = try PairTable.read(path)
        #expect(read.entries == table.entries && read.tokens == 16 && read.language == "ru")
        #expect(read.known == PairTable.known(Self.known.sorted()))
        #expect(read.sources == table.sources)

        let other = directory.appendingPathComponent("other.tsv").path
        try "# perekey pairs 2\n# language ru\n# tokens 5\n# known 1:2\n".write(toFile: other, atomically: true, encoding: .utf8)
        #expect(throws: PairTable.Failure.self) { try PairTable.read(other) }
        try (table.tsv() + "not a line\n").write(toFile: other, atomically: true, encoding: .utf8)
        #expect(throws: PairTable.Failure.self) { try PairTable.read(other) }
    }

    @Test func aCutFileIsAnErrorAndNotAShorterTable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pairs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = PairTable.Options()
        options.minCount = 1
        options.minLift = -1000
        let table = try Self.count(options: options)
        #expect(table.entries.count > 2)
        let text = table.tsv()
        #expect(text.contains("# entries \(table.entries.count)\n"))
        let path = directory.appendingPathComponent("cut.tsv").path

        // Cut at a line end, the way a full disk or a killed process leaves a file: every line is whole.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        try (lines.dropLast().joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: PairTable.Failure.self) { try PairTable.read(path) }
        // Longer than it says is as wrong.
        try (text + lines.last! + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: PairTable.Failure.self) { try PairTable.read(path) }
        // A file with no count line is not of this format.
        try text.replacingOccurrences(of: "# entries \(table.entries.count)\n", with: "")
            .write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: PairTable.Failure.self) { try PairTable.read(path) }
        // And the whole file reads.
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(try PairTable.read(path).entries == table.entries)
    }

    @Test func writingTakesTheFileOverWhetherOrNotOneIsThere() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pairs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let table = try Self.count()
        let path = directory.appendingPathComponent("ru.tsv").path

        // No tsv yet: the first run in a cache.
        try table.write(to: path)
        #expect(try PairTable.read(path).entries == table.entries)
        // A tsv from an earlier run is replaced.
        try "old\n".write(toFile: path, atomically: true, encoding: .utf8)
        try table.write(to: path)
        #expect(try PairTable.read(path).entries == table.entries)
        // The partial file does not stay.
        #expect(!FileManager.default.fileExists(atPath: path + ".part"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["ru.tsv"])
    }

    @Test func aChangedDictionaryChangesTheStamp() {
        #expect(PairTable.known([1, 2, 3]) == PairTable.known([1, 2, 3]))
        #expect(PairTable.known([1, 2, 3]) != PairTable.known([1, 2, 4]))
        #expect(PairTable.known([1, 2, 3]).hasPrefix("3:"))
    }

    // MARK: Choosing

    /// 40 pairs of rising strength, all with at least a bit of lift.
    static func strong() -> PairTable {
        var entries: [PairTable.Entry] = []
        for index in 0..<40 {
            entries.append(.init(previous: UInt64(index), word: UInt64(1000 + index), count: 3 + index,
                                 previousTotal: 20 + index, wordTotal: 50 + index))
        }
        return PairTable(language: "ru", tokens: 1_000_000, known: "0:0", sources: [], entries: entries)
    }

    @Test func everyPairWithItsCountAndLiftIsChosenWhenTheSectionFits() {
        let table = Self.strong()
        let all = table.chosen()
        #expect(all.count == 40)
        #expect(all.map(\.entry.previous) == all.map(\.entry.previous).sorted())
        #expect(all.allSatisfy { $0.lift >= 8 })
    }

    @Test func aSectionThatDoesNotFitKeepsTheBestPairsByLiftTimesLogCount() {
        let table = Self.strong()
        let all = table.chosen()
        let budget = ModelBuilder.pairSectionSize(count: 25)
        let cut = table.chosen(budget: budget)
        // The most entries that fit.
        #expect(cut.count >= 25 && ModelBuilder.pairSectionSize(count: cut.count) <= budget)
        #expect(ModelBuilder.pairSectionSize(count: cut.count + 1) > budget)
        // They are the best: nothing left out scores more than the weakest kept.
        let kept = Set(cut.map(\.entry.previous))
        let weakest = cut.map { ModelBuilder.pairScore(lift: $0.lift, count: $0.entry.count) }.min()!
        for pair in all where !kept.contains(pair.entry.previous) {
            #expect(ModelBuilder.pairScore(lift: pair.lift, count: pair.entry.count) <= weakest)
        }
        #expect(cut.map(\.entry.previous) == cut.map(\.entry.previous).sorted())
        #expect(table.chosen(budget: budget) == cut)
    }

    @Test func theLiftIsAtMost255() {
        let table = PairTable(language: "ru", tokens: 10_000_000_000_000, known: "0:0", sources: [], entries: [
            .init(previous: 1, word: 2, count: 500, previousTotal: 500, wordTotal: 500),
        ])
        #expect(table.chosen().map(\.lift) == [255])
    }
}

/// The lists of `scripts/fetch-data.sh`: training and held-out text apart.
@Suite struct PairSourcesTests {
    static let script = """
    SOURCES="
    lexicon|wordfreq/large_ru.msgpack.gz|$GH_RAW/rspeer/large_ru.msgpack.gz|aaaa
    text|wikipedia/ru/train-00007-of-00021.parquet|$HF_WIKI.ru/train-00007-of-00021.parquet|bbbb
    pairs|wikipedia-pairs/ru/train-00010-of-00021.parquet|$HF_WIKI.ru/train-00010-of-00021.parquet|cccc
    pairs|wikipedia-pairs/en/train-00022-of-00041.parquet|$HF_WIKI.en/train-00022-of-00041.parquet|dddd
    wikifreq|wikipedia/be/train-00000-of-00002.parquet|$HF_WIKI.be/train-00000-of-00002.parquet|eeee
    heldout|tatoeba/rus_sentences.tsv.bz2|https://downloads.tatoeba.org/rus.tsv.bz2|-
    "
    """

    @Test func theRowsAreTheLinesOfTheSourcesBlock() {
        let rows = PairSources.rows(of: Self.script)
        #expect(rows.map(\.group) == ["lexicon", "text", "pairs", "pairs", "wikifreq", "heldout"])
        #expect(rows[2].path == "wikipedia-pairs/ru/train-00010-of-00021.parquet" && rows[2].sha256 == "cccc")
    }

    @Test func apartListsPass() throws {
        #expect(PairSources.problems(in: Self.script).isEmpty)
        try PairSources.check(script: Self.script, cachedFiles: ["wikipedia-pairs/ru/train-00010-of-00021.parquet"])
    }

    @Test func aFileInTheTrainingAndTheHeldOutListIsAProblem() {
        // The same file as the one the hyphen step is measured on.
        let sameName = Self.script + "\npairs|wikipedia-pairs/ru/train-00007-of-00021.parquet|$HF_WIKI.ru/other|ffff\n"
        #expect(!PairSources.problems(in: sameName).isEmpty)
        let sameURL = Self.script + "\npairs|wikipedia-pairs/ru/other.parquet|$HF_WIKI.ru/train-00007-of-00021.parquet|ffff\n"
        #expect(!PairSources.problems(in: sameURL).isEmpty)
        let sameHash = Self.script + "\npairs|wikipedia-pairs/ru/other.parquet|$HF_WIKI.ru/other|bbbb\n"
        #expect(!PairSources.problems(in: sameHash).isEmpty)
        let belarusian = Self.script + "\npairs|wikipedia-pairs/be/train-00000-of-00002.parquet|$HF_WIKI.be/x|ffff\n"
        #expect(!PairSources.problems(in: belarusian).isEmpty)
    }

    @Test func trainingFilesLiveWhereTheTextScriptReadsThem() {
        let elsewhere = Self.script + "\npairs|wikipedia/ru/train-00011-of-00021.parquet|$HF_WIKI.ru/train-00011-of-00021.parquet|ffff\n"
        #expect(PairSources.problems(in: elsewhere).contains { $0.contains("wikipedia-pairs/") })
        #expect(!PairSources.problems(in: "SOURCES=\"\nlexicon|a|b|c\n\"").isEmpty) // no training file at all
    }

    @Test func aFileOfTheCacheThatTheScriptDoesNotListIsAProblem() {
        #expect(throws: PairSources.Failure.self) {
            try PairSources.check(script: Self.script, cachedFiles: ["wikipedia-pairs/ru/train-00012-of-00021.parquet"])
        }
    }

    @Test func theScriptOfTheRepository() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/fetch-data.sh"), encoding: .utf8)
        #expect(PairSources.problems(in: script).isEmpty)
        let training = PairSources.rows(of: script).filter { $0.group == "pairs" }
        #expect(training.count >= 4)
        // Two or more files of each language, each pinned by a SHA-256.
        for language in ["ru", "en"] {
            let files = training.filter { $0.path.hasPrefix("wikipedia-pairs/\(language)/") }
            #expect(files.count >= 2, "\(language)")
            #expect(files.allSatisfy { $0.sha256.count == 64 })
        }
        // The held-out Wikipedia files stay where they were: the hyphen step reads them.
        let held = PairSources.rows(of: script).filter { $0.group == "text" }.map(\.path)
        #expect(held.contains("wikipedia/ru/train-00007-of-00021.parquet"))
    }

    @Test func trainingFilesOfOneLanguageAreTheirLinesInTheManifest() {
        let manifest = """
        11  wikipedia-pairs/en/b.parquet
        22  wikipedia-pairs/ru/a.parquet
        33  wikipedia/ru/held.parquet
        44  wikipedia-pairs/ru/c.parquet
        """
        #expect(ModelBuild.trainingFiles(manifest, language: "ru") == ["22  wikipedia-pairs/ru/a.parquet",
                                                                        "44  wikipedia-pairs/ru/c.parquet"])
        #expect(ModelBuild.trainingFiles("", language: "en").isEmpty)
    }
}

@Suite struct TextLinesTests {
    @Test func linesComeWholeAcrossTheBlocksOfTheReader() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("lines-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Lines of 3 MB: no block of 4 MB ends on a line end.
        let long = String(repeating: "я", count: 1_500_000)
        try (["один", long, "три", long + "!"].joined(separator: "\n")).write(toFile: path, atomically: true, encoding: .utf8)
        var lengths: [Int] = []
        try TextLines.forEach(path: path) { lengths.append($0.count) }
        #expect(lengths == [8, 3_000_000, 6, 3_000_001])
    }

    @Test func aMissingFileIsAnError() {
        #expect(throws: PairTable.Failure.self) { try TextLines.forEach(path: "/nonexistent/pairs.txt") { _ in } }
    }
}
