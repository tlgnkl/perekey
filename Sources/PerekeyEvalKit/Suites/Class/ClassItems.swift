// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyModelKit

/// One unit of a class suite: a word (or a short run of tokens) that a rule picked, the weight it counts with
/// and the classes it belongs to.
struct ClassItem: Hashable {
    /// The text the fingers type, tokens apart by one space.
    var text: String
    /// `10^(Zipf − 3)` (docs/eval.md, «Наборы классов»); for an item taken from a corpus, its occurrences per million.
    var weight: Double
    /// Classes of every token: `seed`, `probe:slang`, `caps:title`, …
    var tags: [String] = []
    /// Where the fingers aim a token with no letter in it (`15:30`).
    var aim: Aim = .latin

    enum Aim: String, Hashable { case latin, cyrillic }

    /// The key of the unit: lower case, «ё» as «е» (plan, 9.1).
    var key: String { Self.key(text) }

    static func key(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}

/// Weight of a Zipf value: `10^(Zipf − 3)`, so that «где» counts more than a rare word (plan, 8.4).
func classWeight(zipf: Double) -> Double { pow(10, zipf - 3) }

/// A seed list of `eval/classes/`: one word a line, `#` starts a comment, an optional second column after a tab
/// names the group (`slang`) the word came from.
struct SeedList {
    struct Entry: Hashable {
        var word: String
        var group: String?
    }

    var entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
    }

    init(text: String) {
        var entries: [Entry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let record = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let columns = record.split(separator: "\t", omittingEmptySubsequences: false)
            let word = columns[0].trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            let group = columns.count > 1 ? columns[1].trimmingCharacters(in: .whitespaces) : ""
            entries.append(Entry(word: word, group: group.isEmpty ? nil : group))
        }
        self.entries = entries
    }

    init(path: String) throws {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw EvalError.input("no seed list \(path)")
        }
        self.init(text: text)
    }
}

/// Counts of a corpus: tokens by kind, for the rules that read text (`oov`, `brands`, `caps`, `code`).
struct CorpusStats {
    var total = 0
    /// Lower-case words made of Cyrillic letters only.
    var cyrillic: [String: Int] = [:]
    /// Lower-case words made of Latin letters only.
    var latin: [String: Int] = [:]
    /// Latin words as written, from sentences with more Cyrillic letters than Latin: names set among Russian text.
    var latinAmongCyrillic: [String: Int] = [:]
    /// Words of capitals only, two to six letters, either script.
    var capitals: [String: Int] = [:]
    /// The cache files read and their SHA-256, for the build report.
    var files: [String: String] = [:]

    /// The sum of two counts.
    mutating func merge(_ other: CorpusStats) {
        total += other.total
        cyrillic.merge(other.cyrillic, uniquingKeysWith: +)
        latin.merge(other.latin, uniquingKeysWith: +)
        latinAmongCyrillic.merge(other.latinAmongCyrillic, uniquingKeysWith: +)
        capitals.merge(other.capitals, uniquingKeysWith: +)
        files.merge(other.files) { first, _ in first }
    }

    func perMillion(_ count: Int) -> Double { total > 0 ? Double(count) * 1_000_000 / Double(total) : 0 }

    /// Adds the tokens of one sentence.
    mutating func add(sentence tokens: [ParsedToken]) {
        var cyrillicLetters = 0, latinLetters = 0
        for token in tokens {
            for character in token.text {
                switch LetterScript.of(character) {
                case .cyrillic?: cyrillicLetters += 1
                case .latin?: latinLetters += 1
                default: break
                }
            }
        }
        let russian = cyrillicLetters > latinLetters
        for token in tokens {
            total += 1
            guard !token.code else { continue }
            let core = Self.core(token.text)
            guard !core.isEmpty else { continue }
            let scripts = core.compactMap(LetterScript.of)
            guard scripts.count == core.count, let script = scripts.first, scripts.allSatisfy({ $0 == script }) else { continue }
            let lower = core.lowercased()
            switch script {
            case .cyrillic: cyrillic[lower, default: 0] += 1
            case .latin:
                latin[lower, default: 0] += 1
                if russian { latinAmongCyrillic[core, default: 0] += 1 }
            case .other: break
            }
            if (2...6).contains(core.count), core == core.uppercased(), core != lower { capitals[core, default: 0] += 1 }
        }
    }

    /// The token without the marks at both ends, case kept.
    static func core(_ token: String) -> String {
        var characters = Substring(token)
        while let first = characters.first, !first.isLetter { characters.removeFirst() }
        while let last = characters.last, !last.isLetter { characters.removeLast() }
        return String(characters)
    }
}

/// What the rules of a build share: the lexicon's words, the dictionaries, the corpora already read and the
/// sentences to warm up with. One per build, so that twenty class suites read each file once.
final class ClassContext {
    let cache: String
    let lexiconDirectory: String
    let classesDirectory: String
    private var words: [String: [(word: String, zipf: Double)]] = [:]
    private var dictionaries: [String: Set<UInt64>?] = [:]
    private var corpora: [String: CorpusStats] = [:]
    private var zipfTables: [String: [UInt64: Double]] = [:]
    var warmups: [String: [LetterScript: [SuiteBuilder.Pooled]]] = [:]

    init(cache: String, lexiconDirectory: String, classesDirectory: String) {
        self.cache = cache
        self.lexiconDirectory = lexiconDirectory
        self.classesDirectory = classesDirectory
    }

    /// The words of the language's lexicon file, built from the cache when it is not there yet.
    func lexiconWords(_ language: String) throws -> [(word: String, zipf: Double)] {
        if let known = words[language] { return known }
        _ = try Lexicon.load(languages: [language], directory: lexiconDirectory, cache: cache)
        let path = (lexiconDirectory as NSString).appendingPathComponent(Lexicon.fileName(language))
        let entries = try Lexicon.entries(path)
        words[language] = entries
        return entries
    }

    /// The Zipf of every word of the language, by `Lexicon.key`.
    func zipfs(_ language: String) throws -> [UInt64: Double] {
        if let known = zipfTables[language] { return known }
        var table: [UInt64: Double] = [:]
        for entry in try lexiconWords(language) {
            let key = Lexicon.key(entry.word)
            table[key] = max(table[key] ?? 0, entry.zipf)
        }
        zipfTables[language] = table
        return table
    }

    /// The spelling dictionary of the language, nil when the cache has none (Ukrainian).
    func dictionary(_ language: String) throws -> Set<UInt64>? {
        if let known = dictionaries[language] { return known }
        let keys = try Lexicon.dictionaryKeys(language: language, cache: cache)
        dictionaries[language] = .some(keys)
        return keys
    }

    /// Sets the dictionary of a language by hand, so that a test needs no Hunspell files.
    func setDictionary(_ keys: Set<UInt64>?, for language: String) {
        dictionaries[language] = .some(keys)
    }

    /// Sets the counts of a corpus by hand, so that a test needs no dump.
    func setCorpus(_ stats: CorpusStats, file: String) {
        corpora[file] = stats
    }

    func seeds(_ name: String?) throws -> SeedList {
        guard let name else { return SeedList(entries: []) }
        return try SeedList(path: (classesDirectory as NSString).appendingPathComponent(name))
    }

    /// Reads Stack Exchange dumps of the cache once each and counts their tokens; the counts of several files add up.
    func corpus(files: [String]) throws -> CorpusStats {
        var sum = CorpusStats()
        for file in files {
            if let known = corpora[file] {
                sum.merge(known)
                continue
            }
            let path = (cache as NSString).appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: path) else {
                throw EvalError.input("no source file \(path); run scripts/fetch-data.sh heldout")
            }
            var stats = CorpusStats()
            try StackExchangeReader.forEachUnit(path: path) { unit in
                stats.add(sentence: UnitParser.tokens(of: unit.text))
            }
            stats.files[file] = try Runner.sha256(file: path)
            corpora[file] = stats
            sum.merge(stats)
        }
        return sum
    }
}
