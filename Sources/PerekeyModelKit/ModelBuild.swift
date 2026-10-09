// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// Builds the language model files, one per language, from the data cache
/// and the lists in `data/`. Sources and licences: data/SOURCES.md. Steps:
/// docs/classifier.md.
///
/// Every file carries its language's sections and the lists that are not
/// per language: its own `keep` and `case` entries plus `data/mixed`
/// ("iPhone"). The mixed list is tiny and copied into each file, so any
/// subset of files the app maps keeps it whole (docs/classifier.md, «Файл на язык»).
public struct ModelBuild {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public struct Report {
        public var notes: [String] = []
        /// The model file of each language, in the order asked for.
        public var files: [(language: String, bytes: [UInt8])] = []
    }

    /// Letters of each language in model order: the alphabet plus joiners.
    /// The order of ru and en is fixed: it is in the bytes of their files.
    public static let alphabets: [String: String] = [
        "ru": "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-",
        "en": "abcdefghijklmnopqrstuvwxyz'-",
        // The apostrophe is a letter of the word ("п'ять"): `'`, and `ʼ`
        // through `ModelFormat.fold`; the builder reads `’` as `'` too.
        "uk": "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'-",
        // The apostrophe is a letter here too ("аб'ём").
        "be": "абвгдеёжзійклмнопрстуўфхцчшыьэюя'-",
        "kk": "абвгғдеёжзийкқлмнңоөпрстуұүфхһцчшщъыіьэюяә-",
    ]

    /// The languages `perekey-model` builds by default.
    public static let languages = ["ru", "en", "uk", "be"]

    /// Languages wordfreq has no list for: the frequencies are counted from
    /// the Wikipedia snapshot by scripts/wiki-freq.py.
    static let wikipediaFrequencies: Set = ["be", "kk"]

    public let cache: String
    public let data: String

    public init(cache: String, data: String) {
        self.cache = cache
        self.data = data
    }

    public func run(languages: [String] = ModelBuild.languages) throws -> Report {
        var report = Report()
        let mixed = try DataLists(directory: "\(data)/mixed")
        let manifest = (try? String(contentsOfFile: "\(cache)/MANIFEST.sha256", encoding: .utf8)) ?? ""
        for language in languages {
            guard Self.alphabets[language] != nil else { throw Failure(description: "no alphabet for \(language)") }
            var builder = ModelBuilder()
            var sources: [String] = []
            builder.addLanguage(language, alphabet: Self.alphabets[language]!)
            let lists = try DataLists(directory: "\(data)/\(language)")
            var forms = 0, rejected = 0

            // 1. Frequencies and extra forms from wordfreq. Weighted n-gram
            // statistics come from here: weight = sqrt(frequency per billion),
            // from Zipf 2.5 up; the long tail is typos and foreign words.
            let fromWikipedia = Self.wikipediaFrequencies.contains(language)
            let frequencies = try WordFreq(gzipPath: fromWikipedia
                ? "\(cache)/wikifreq/large_\(language).msgpack.gz"
                : "\(cache)/wordfreq/large_\(language).msgpack.gz")
            sources.append(fromWikipedia
                ? "Wikipedia \(language) 20231101, words counted by scripts/wiki-freq.py: \(frequencies.entries.count) words"
                : "wordfreq 3.2 large_\(language): \(frequencies.entries.count) words")
            var ranks: [String: UInt8] = [:]
            for entry in frequencies.entries {
                guard !lists.remove.contains(entry.word) else { continue }
                // `ʼ` folds to `'`: it is the Ukrainian apostrophe, in other lists a foreign token.
                let word = language == "uk" ? Self.apostrophes(entry.word) : entry.word
                guard language == "uk" || !word.unicodeScalars.contains("\u{2BC}") else {
                    rejected += 1
                    continue
                }
                let rank = lists.rank[word] ?? WordFreq.rank(zipf: entry.zipf)
                let weight = entry.zipf >= 2.5 ? pow(10, entry.zipf / 2) : 0
                if builder.addForm(word, language: language, rank: rank, weight: weight,
                                   prefixes: entry.zipf >= 2.5)
                {
                    ranks[word] = rank
                    forms += 1
                } else {
                    rejected += 1
                }
            }

            // 2. Word forms from the spelling dictionary, expanded by its affix
            // rules. Forms unknown to wordfreq get rank 0 and a small weight.
            // Ukrainian has none with a compatible licence (data/SOURCES.md):
            // wordfreq alone, the n-grams cover the rare forms.
            if let (dic, aff, name) = try spellingDictionary(language) {
                let hunspell = Hunspell(affix: aff)
                var seen: Set<String> = []
                var expanded = 0
                let entries = Hunspell.entries(dic: dic)
                // Words with "ё" are derived from the dictionary as it is expanded.
                var yo = language == "ru" ? YoTable(entries: entries) : nil
                // An abbreviation Perekey corrects must not be an ordinary word: "it" ≠ "IT".
                let corrected = Set(lists.correctedAbbreviations.map { $0.lowercased() })
                var ordinary: Set<String> = []
                for (index, entry) in entries.enumerated() {
                    let lowercaseStem = entry.stem.first?.isLowercase == true
                    hunspell.expand(entry.stem, flags: entry.flags) { form in
                        let word = form.lowercased()
                        if lists.remove.contains(word) { return }
                        yo?.add(word, entry: index)
                        if lowercaseStem, corrected.contains(word) { ordinary.insert(word) }
                        guard seen.insert(word).inserted else { return }
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
                if !ordinary.isEmpty {
                    throw Failure(description: "data/\(language)/abbreviations.txt: ordinary words in \(name): "
                        + ordinary.sorted().joined(separator: ", "))
                }
                if var table = yo {
                    for word in lists.add + lists.noYo { table.block(word) }
                    var added = 0
                    let yoForms = table.forms { ranks[$0] }
                    for form in yoForms where builder.addYo(form, language: language) { added += 1 }
                    report.notes.append("\(language): \(added) forms take \"ё\" unambiguously")
                }
            }

            // 3. Hand-maintained lists.
            for word in lists.add where ranks[word] == nil {
                _ = builder.addForm(word, language: language, rank: lists.rank[word] ?? 96, weight: 1)
            }
            for word in lists.abbreviations {
                _ = builder.addForm(word, language: language, rank: lists.rank[word.lowercased()] ?? 96, weight: 0,
                                    prefixes: false)
                builder.addKeep(word)
            }
            for word in lists.correctedAbbreviations {
                guard word.contains(where: \.isUppercase) else {
                    throw Failure(description: "data/\(language)/abbreviations.txt: \(word) has no capital to restore")
                }
                // Words with digits ("MP3") are outside the alphabet: no form, still corrected.
                _ = builder.addForm(word, language: language, rank: lists.rank[word.lowercased()] ?? 96, weight: 0,
                                    prefixes: false)
                builder.addKeep(word)
                builder.addCasedForm(word, corrects: true)
            }
            for word in lists.abbreviations { builder.addCasedForm(word, corrects: false) }
            for word in lists.keep { builder.addKeep(word) }
            report.notes.append("\(language): \(forms) forms, \(rejected) rejected (outside the alphabet)")
            for word in mixed.keep {
                builder.addKeep(word)
                builder.addCasedForm(word, corrects: false)
            }

            // The inputs of this language only: a new source for another
            // language leaves this file's bytes and hash alone.
            let inputs: [String] = switch language {
            case "ru": ["wordfreq/large_ru.", "hunspell-ru/"]
            case "en": ["wordfreq/large_en.", "esdb/"]
            case "be": ["wikipedia/be/", "hunspell-be/"]
            case "kk": ["wikipedia/kk/"]
            default: ["wordfreq/large_\(language)."]
            }
            let formsNote = switch language {
            case "ru": "Word forms: modified from the dictionary by Alexander I. Lebedev (BSD-like licence)."
            case "en": "Word forms: SCOWL / ESDB."
            case "be": "Word forms: Hunspell be-official from the Belarusian Grammar Database (bnkorpus.info), CC BY-SA 4.0."
            default: "No word-form dictionary."
            }
            let frequencyNote = fromWikipedia
                ? "Frequencies counted from Wikipedia (CC BY-SA 4.0 + GFDL)."
                : "wordfreq data by Robyn Speer, CC BY-SA 4.0."
            builder.meta = """
            Perekey language model, \(language). Licence: CC BY-SA 4.0 (data/SOURCES.md).
            Sources: \(sources.joined(separator: "; ")).
            \(frequencyNote) \(formsNote)
            Inputs:
            \(manifest.split(separator: "\n").filter { line in inputs.contains { line.contains($0) } }.joined(separator: "\n"))
            """
            report.files.append((language, builder.build()))
        }
        return report
    }

    /// The Ukrainian apostrophes `’` and `ʼ` as `'`.
    static func apostrophes(_ word: String) -> String {
        guard word.unicodeScalars.contains(where: { $0 == "\u{2019}" || $0 == "\u{2BC}" }) else { return word }
        return String(String.UnicodeScalarView(word.unicodeScalars.map { $0 == "\u{2019}" || $0 == "\u{2BC}" ? "'" : $0 }))
    }

    private func spellingDictionary(_ language: String) throws -> (dic: String, aff: String, name: String)? {
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
        case "be":
            let dic = try String(contentsOfFile: "\(cache)/hunspell-be/be-official.dic", encoding: .utf8)
            let aff = try String(contentsOfFile: "\(cache)/hunspell-be/be-official.aff", encoding: .utf8)
            return (dic, aff, "Hunspell be-official")
        default:
            return nil
        }
    }
}

/// The hand-maintained lists of one directory under `data/`: format in data/README.md.
public struct DataLists {
    public var add: [String] = []
    public var remove: Set<String> = []
    public var rank: [String: UInt8] = [:]
    /// `abbrev.txt`: abbreviations never switched, in their case.
    public var abbreviations: [String] = []
    /// `abbreviations.txt`: abbreviations Perekey also writes in their case
    /// when typed in another ("мвд" → "МВД"). None may be an ordinary word.
    public var correctedAbbreviations: [String] = []
    /// `noyo.txt`: "е" spellings that are words of their own though the
    /// dictionary lists them as spellings of a form with "ё" ("все").
    public var noYo: [String] = []
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
        correctedAbbreviations = try Self.read("\(directory)/abbreviations.txt").map(\.word)
        noYo = try Self.read("\(directory)/noyo.txt").map(\.word)
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
