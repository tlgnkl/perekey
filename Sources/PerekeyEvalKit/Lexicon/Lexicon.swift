// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import PerekeyCore
import PerekeyModelKit

/// The bench's lexicon (docs/eval.md, «Лексикон»): the word forms of a
/// language and their frequency, to answer «is this a real word», which is
/// another question than «has the model seen it» (`known`).
///
/// Built from the same cache files the model reads, with the bench's own
/// code over the readers of `PerekeyModelKit`: the forms of the spelling
/// dictionary (Hunspell, SCOWL) and the words of wordfreq with Zipf from 2.
/// A word is kept by a 64-bit hash of its lower-case letters, «ё» as «е».
public struct Lexicon: Sendable {
    /// The least Zipf a wordfreq word needs to join: the plan, 9.4.
    public static let minimumZipf = 2.0

    /// Languages by the script they are written in, for the label `silent`.
    public static let scripts: [String: Script] = ["ru": .cyrillic, "uk": .cyrillic, "be": .cyrillic,
                                                   "kk": .cyrillic, "en": .latin]

    public enum Script: String, Sendable { case cyrillic, latin }

    /// Languages wordfreq has no list for: the model counts them from
    /// Wikipedia (`ModelBuild.wikipediaFrequencies`, which is not public).
    static let wikipediaFrequencies: Set = ["be", "kk"]

    /// Word → Zipf, by language. A form of the dictionary wordfreq lacks has Zipf 0.
    private var tables: [String: [UInt64: Float]]

    public init(tables: [String: [UInt64: Float]] = [:]) {
        self.tables = tables
    }

    /// A lexicon of the given words, for tests.
    public init(words: [String: [(String, Double)]]) {
        tables = words.mapValues { list in
            Dictionary(list.map { (Self.key($0.0), Float($0.1)) }, uniquingKeysWith: max)
        }
    }

    public var languages: [String] { tables.keys.sorted() }

    /// The Zipf of the word in the language, nil when the lexicon lacks it
    /// (or the language).
    public func zipf(of word: String, language: String) -> Double? {
        tables[language]?[Self.key(word)].map(Double.init)
    }

    public func contains(_ word: String, language: String) -> Bool {
        tables[language]?[Self.key(word)] != nil
    }

    /// Whether the lexicon holds this language at all.
    public func has(language: String) -> Bool { tables[language] != nil }

    // MARK: - Words

    /// The hash of a word: lower case, «ё» as «е», the Ukrainian apostrophe `ʼ` as `'`.
    public static func key(_ word: String) -> UInt64 {
        var fingerprint = ModelFormat.Fingerprint()
        for scalar in word.lowercased().unicodeScalars {
            let value = ModelFormat.fold(scalar.value)
            fingerprint.add(value == 0x451 ? 0x435 : value)
        }
        return fingerprint.value
    }

    /// The word of a token: without the marks at both ends, lower case.
    /// «"привет,"» is «привет»; «во-первых» keeps its hyphen.
    public static func core(_ token: String) -> String {
        var characters = Substring(token)
        while let first = characters.first, !first.isLetter, !first.isNumber { characters.removeFirst() }
        while let last = characters.last, !last.isLetter, !last.isNumber { characters.removeLast() }
        return characters.lowercased()
    }

    /// The script of a word's letters, nil when it has none or mixes them.
    public static func script(of word: String) -> Script? {
        var found: Script?
        for scalar in word.unicodeScalars where scalar.properties.isAlphabetic {
            let script: Script = (0x400...0x52F).contains(scalar.value) ? .cyrillic
                : (scalar.value < 0x250 ? .latin : .cyrillic)
            if let known = found, known != script { return nil }
            found = script
        }
        return found
    }

    // MARK: - Files

    /// `lexicon-<language>.tsv`: word, Zipf with two decimals, words in byte order.
    public static func fileName(_ language: String) -> String { "lexicon-\(language).tsv" }

    /// The lexicon of the languages: from the TSV files of `directory` where
    /// they exist, built from the data cache and written there where not.
    public static func load(languages: [String], directory: String, cache: String?) throws -> Lexicon {
        var tables: [String: [UInt64: Float]] = [:]
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for language in languages {
            let path = (directory as NSString).appendingPathComponent(fileName(language))
            if !FileManager.default.fileExists(atPath: path) {
                guard let cache else {
                    throw EvalError.input("no \(path) and no --cache <data cache> to build it from")
                }
                let words = try build(language: language, cache: cache)
                let text = words.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
                    .map { "\($0.key)\t\(String(format: "%.2f", $0.value))" }.joined(separator: "\n") + "\n"
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            }
            tables[language] = try read(path)
        }
        return Lexicon(tables: tables)
    }

    static func read(_ path: String) throws -> [UInt64: Float] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var table: [UInt64: Float] = [:]
        table.reserveCapacity(text.utf8.count / 14)
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let zipf = Float(line[line.index(after: tab)...]) else {
                throw EvalError.input("\(path): bad line \(line.debugDescription)")
            }
            table[key(String(line[..<tab]))] = zipf
        }
        return table
    }

    /// SHA-256 of the lexicon file of the language, for run.json.
    public static func hash(language: String, directory: String) throws -> String {
        try Runner.sha256(file: (directory as NSString).appendingPathComponent(fileName(language)))
    }

    // MARK: - Building

    /// The words of a language with their Zipf from the cache files that the
    /// model reads (`ModelBuild`): wordfreq or the Wikipedia counts, and the
    /// spelling dictionary expanded by its affix rules.
    static func build(language: String, cache: String) throws -> [String: Double] {
        let frequencyPath = wikipediaFrequencies.contains(language)
            ? "\(cache)/wikifreq/large_\(language).msgpack.gz" : "\(cache)/wordfreq/large_\(language).msgpack.gz"
        guard FileManager.default.fileExists(atPath: frequencyPath) else {
            throw EvalError.input("no frequency list \(frequencyPath): scripts/fetch-data.sh lexicon")
        }
        var frequency: [String: Double] = [:]
        for entry in try WordFreq(gzipPath: frequencyPath).entries {
            let word = entry.word.lowercased()
            frequency[word] = max(frequency[word] ?? 0, entry.zipf)
        }
        var words = frequency.filter { $0.value >= minimumZipf }
        if let (dic, aff) = try spellingDictionary(language, cache: cache) {
            let hunspell = Hunspell(affix: aff)
            for entry in Hunspell.entries(dic: dic) {
                hunspell.expand(entry.stem, flags: entry.flags) { form in
                    let word = form.lowercased()
                    if words[word] == nil { words[word] = frequency[word] ?? 0 }
                }
            }
        }
        return words
    }

    private static func spellingDictionary(_ language: String, cache: String) throws -> (dic: String, aff: String)? {
        switch language {
        case "ru":
            return try (String(contentsOfFile: "\(cache)/hunspell-ru/ru_RU.dic", encoding: .utf8),
                        String(contentsOfFile: "\(cache)/hunspell-ru/ru_RU.aff", encoding: .utf8))
        case "be":
            return try (String(contentsOfFile: "\(cache)/hunspell-be/be-official.dic", encoding: .utf8),
                        String(contentsOfFile: "\(cache)/hunspell-be/be-official.aff", encoding: .utf8))
        case "en":
            let archives = try FileManager.default.contentsOfDirectory(atPath: "\(cache)/esdb")
                .filter { $0.hasPrefix("hunspell-en_US-large-") && $0.hasSuffix(".zip") }.sorted()
            guard let archive = archives.last else { throw EvalError.input("no SCOWL archive in \(cache)/esdb") }
            let path = "\(cache)/esdb/\(archive)"
            return try (String(decoding: Archive.unzip(path, member: "en_US-large.dic"), as: UTF8.self),
                        String(decoding: Archive.unzip(path, member: "en_US-large.aff"), as: UTF8.self))
        default:
            return nil
        }
    }
}

/// The words of the lists under `data/` (`data/<language>/*.txt`,
/// `data/mixed/*.txt`), for the feature `seen`: a gain on them may come from
/// the word added to a list, not from a rule (plan, 9.3).
public struct SeenWords: Sendable {
    private var keys: Set<UInt64>

    public init(words: [String]) {
        keys = Set(words.map(Lexicon.key))
    }

    /// Every list file of every subdirectory of `data`.
    public init(directory: String) throws {
        var keys: Set<UInt64> = []
        let manager = FileManager.default
        for sub in try manager.contentsOfDirectory(atPath: directory).sorted() {
            let path = (directory as NSString).appendingPathComponent(sub)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            for name in try manager.contentsOfDirectory(atPath: path).sorted() where name.hasSuffix(".txt") {
                let text = try String(contentsOfFile: (path as NSString).appendingPathComponent(name), encoding: .utf8)
                for line in text.split(separator: "\n") {
                    let record = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    let word = record.split(separator: "\t").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    if !word.isEmpty { keys.insert(Lexicon.key(word)) }
                }
            }
        }
        self.keys = keys
    }

    public func contains(_ word: String) -> Bool { keys.contains(Lexicon.key(word)) }

    public var count: Int { keys.count }

    /// SHA-256 of the sorted keys, for run.json: the lists changed or not.
    public var hash: String {
        var data = Data()
        for key in keys.sorted() { withUnsafeBytes(of: key.bigEndian) { data.append(contentsOf: $0) } }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
