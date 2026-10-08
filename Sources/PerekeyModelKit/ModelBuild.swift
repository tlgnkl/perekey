// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// Builds the language model from the data cache and the lists in `data/`.
/// Sources and licences: data/SOURCES.md. Steps: docs/classifier.md.
public struct ModelBuild {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public struct Report {
        public var notes: [String] = []
        public var bytes: [UInt8] = []
    }

    /// Letters of each language in model order: the alphabet plus joiners.
    public static let alphabets: [String: String] = [
        "ru": "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-",
        "en": "abcdefghijklmnopqrstuvwxyz'-",
    ]

    public let cache: String
    public let data: String

    public init(cache: String, data: String) {
        self.cache = cache
        self.data = data
    }

    public func run() throws -> Report {
        var report = Report()
        var builder = ModelBuilder()
        var sources: [String] = []

        for language in ["ru", "en"] {
            builder.addLanguage(language, alphabet: Self.alphabets[language]!)
            let lists = try DataLists(directory: "\(data)/\(language)")
            var forms = 0, rejected = 0

            // 1. Frequencies and extra forms from wordfreq. Weighted n-gram
            // statistics come from here: weight = sqrt(frequency per billion).
            let frequencies = try WordFreq(gzipPath: "\(cache)/wordfreq/large_\(language).msgpack.gz")
            sources.append("wordfreq 3.2 large_\(language): \(frequencies.entries.count) words")
            var ranks: [String: UInt8] = [:]
            for entry in frequencies.entries {
                guard !lists.remove.contains(entry.word) else { continue }
                let rank = lists.rank[entry.word] ?? WordFreq.rank(zipf: entry.zipf)
                let weight = pow(10, entry.zipf / 2)
                if builder.addForm(entry.word, language: language, rank: rank, weight: weight,
                                   prefixes: entry.zipf >= 2.5)
                {
                    ranks[entry.word] = rank
                    forms += 1
                } else {
                    rejected += 1
                }
            }

            // 2. Word forms from the spelling dictionary, expanded by its affix
            // rules. Forms unknown to wordfreq get rank 0 and a small weight.
            let (dic, aff, name) = try spellingDictionary(language)
            let hunspell = Hunspell(affix: aff)
            var seen: Set<String> = []
            var expanded = 0
            for entry in Hunspell.entries(dic: dic) {
                hunspell.expand(entry.stem, flags: entry.flags) { form in
                    let word = form.lowercased()
                    guard seen.insert(word).inserted, !lists.remove.contains(word) else { return }
                    expanded += 1
                    if ranks[word] != nil { return }
                    let rank = lists.rank[word] ?? 0
                    if builder.addForm(word, language: language, rank: rank, weight: 1) {
                        forms += 1
                    } else {
                        rejected += 1
                    }
                }
            }
            sources.append("\(name): \(expanded) forms after affix expansion")

            // 3. Hand-maintained lists.
            for word in lists.add where ranks[word] == nil {
                _ = builder.addForm(word, language: language, rank: lists.rank[word] ?? 96, weight: 1)
            }
            for word in lists.abbreviations {
                _ = builder.addForm(word, language: language, rank: lists.rank[word.lowercased()] ?? 96, weight: 0,
                                    prefixes: false)
                builder.addKeep(word)
            }
            for word in lists.keep { builder.addKeep(word) }
            report.notes.append("\(language): \(forms) forms, \(rejected) rejected (outside the alphabet)")
        }
        let mixed = try DataLists(directory: "\(data)/mixed")
        for word in mixed.keep { builder.addKeep(word) }

        let manifest = (try? String(contentsOfFile: "\(cache)/MANIFEST.sha256", encoding: .utf8)) ?? ""
        builder.meta = """
        Perekey language model. Licence: CC BY-SA 4.0 (data/SOURCES.md).
        Sources: \(sources.joined(separator: "; ")).
        wordfreq data by Robyn Speer, CC BY-SA 4.0. Russian word forms: modified from the
        dictionary by Alexander I. Lebedev (BSD-like licence). English word forms: SCOWL / ESDB.
        Inputs:
        \(manifest.split(separator: "\n").filter { $0.contains("wordfreq/") || $0.contains("hunspell-ru/") || $0.contains("esdb/") }.joined(separator: "\n"))
        """
        report.bytes = builder.build()
        return report
    }

    private func spellingDictionary(_ language: String) throws -> (dic: String, aff: String, name: String) {
        switch language {
        case "ru":
            let dic = try String(contentsOfFile: "\(cache)/hunspell-ru/ru_RU.dic", encoding: .utf8)
            let aff = try String(contentsOfFile: "\(cache)/hunspell-ru/ru_RU.aff", encoding: .utf8)
            return (dic, aff, "Hunspell ru_RU")
        case "en":
            let archives = try FileManager.default.contentsOfDirectory(atPath: "\(cache)/esdb")
                .filter { $0.hasPrefix("hunspell-en_US-large-") && $0.hasSuffix(".zip") }.sorted()
            guard let archive = archives.last else { throw Failure(description: "no SCOWL archive in \(cache)/esdb") }
            let path = "\(cache)/esdb/\(archive)"
            let dic = String(decoding: try Archive.unzip(path, member: "en_US-large.dic"), as: UTF8.self)
            let aff = String(decoding: try Archive.unzip(path, member: "en_US-large.aff"), as: UTF8.self)
            return (dic, aff, "SCOWL \(archive)")
        default:
            throw Failure(description: "no spelling dictionary for \(language)")
        }
    }
}

/// The hand-maintained lists of one directory under `data/`: format in data/README.md.
public struct DataLists {
    public var add: [String] = []
    public var remove: Set<String> = []
    public var rank: [String: UInt8] = [:]
    public var abbreviations: [String] = []
    public var keep: [String] = []

    public init() {}

    public init(directory: String) throws {
        add = try Self.read("\(directory)/add.txt").map(\.word)
        remove = Set(try Self.read("\(directory)/remove.txt").map(\.word))
        for entry in try Self.read("\(directory)/rank.txt") {
            guard let field = entry.field, let value = UInt8(field) else {
                throw ModelBuild.Failure(description: "\(directory)/rank.txt: bad rank for \(entry.word)")
            }
            rank[entry.word] = value
        }
        abbreviations = try Self.read("\(directory)/abbrev.txt").map(\.word)
        keep = try Self.read("\(directory)/keep.txt").map(\.word)
    }

    /// Entries of one list: the word and the field after a tab, if any.
    /// A missing file is an empty list.
    static func read(_ path: String) throws -> [(word: String, field: String?)] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var entries: [(String, String?)] = []
        for line in text.split(separator: "\n") {
            let content = line.prefix { $0 != "#" }
            let fields = content.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let word = fields.first, !word.isEmpty else { continue }
            entries.append((word, fields.count > 1 ? fields[1] : nil))
        }
        return entries
    }
}
