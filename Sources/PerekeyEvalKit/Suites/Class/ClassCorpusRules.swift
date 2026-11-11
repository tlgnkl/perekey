// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyModelKit

/// The rules that read text: words the dictionary lacks, names set among
/// Russian text, names of people and cities, commands, source code.
extension ClassRules {
    /// The corpus files of the tier: the ones the manifest names, and at `full` the optional ones the cache has.
    func corpusFiles() -> [String] {
        var files = spec.corpusFiles
        if tier == .full {
            files += spec.corpusFullFiles.filter {
                FileManager.default.fileExists(atPath: (context.cache as NSString).appendingPathComponent($0))
            }
        }
        return files
    }

    /// The posts to read of a dump: all at `full`, `ciPosts` at `ci`.
    var corpusPosts: Int? { tier == .ci ? spec.ciPosts : nil }

    // MARK: - oov

    /// Cyrillic words that a corpus uses from `minPerMillion` times in a million tokens and the language's
    /// dictionary lacks: slang and jargon, found by the rule (plan, 8.4). A language with no dictionary
    /// (Ukrainian) counts as known a word the lexicon has from Zipf 2.
    func oov() throws -> ([ClassItem], [String: String]) {
        guard let language = spec.languages.first(where: { script(of: $0) == .cyrillic }) else {
            throw EvalError.input("\(manifest.suite): oov needs a Cyrillic language")
        }
        let stats = try context.corpus(files: corpusFiles(), posts: corpusPosts)
        let dictionary = try context.dictionary(language)
        let zipfs = dictionary == nil ? try context.zipfs(language) : [:]
        var items: [ClassItem] = []
        for (word, count) in stats.cyrillic where word.count >= options.corpusWordLetters && stats.perMillion(count) >= (spec.minPerMillion ?? options.minPerMillion) {
            let known = dictionary.map { $0.contains(Lexicon.key(word)) } ?? ((zipfs[Lexicon.key(word)] ?? 0) >= options.knownZipf)
            if !known { items.append(ClassItem(text: word, weight: stats.perMillion(count), tags: ["oov"])) }
        }
        return (items, stats.files)
    }

    // MARK: - brands

    /// Latin words among Russian text that have a capital or are not English words: names of products and
    /// companies (plan, 8.4). A lower-case English word is text, not a name.
    func brands() throws -> ([ClassItem], [String: String]) {
        let stats = try context.corpus(files: corpusFiles(), posts: corpusPosts)
        let english = try context.dictionary("en")
        var items: [ClassItem] = []
        for (word, count) in stats.latinAmongCyrillic where word.count >= options.corpusWordLetters && stats.perMillion(count) >= (spec.minPerMillion ?? options.minPerMillion) {
            let capital = word != word.lowercased()
            if !capital, english?.contains(Lexicon.key(word)) ?? false { continue }
            items.append(ClassItem(text: word, weight: stats.perMillion(count), tags: ["brand"]))
        }
        return (items, stats.files)
    }

    // MARK: - names

    /// The names of the cities of GeoNames (`cities15000`: the Latin name; the Cyrillic alternatives of each
    /// Cyrillic language of the manifest) and the given names of the Wikidata snapshot in `eval/classes/`.
    /// One word each, with a capital. A Cyrillic alternative counts as a name of the language only if the language
    /// knows it: its dictionary has it, or its lexicon has it from `unknownZipf` (GeoNames does not say which
    /// language an alternative is in, and «Одеса» is not Russian).
    func names() throws -> ([ClassItem], [String: String]) {
        var items: [ClassItem] = []
        var files: [String: String] = [:]
        var zipfs: [String: [UInt64: Double]] = [:]
        func zipf(_ name: String, language: String) throws -> Double? {
            if zipfs[language] == nil { zipfs[language] = try context.zipfs(language) }
            return zipfs[language]?[Lexicon.key(name)]
        }
        func known(_ name: String, language: String) throws -> Bool {
            if let dictionary = try context.dictionary(language), dictionary.contains(Lexicon.key(name)) { return true }
            return (try zipf(name, language: language) ?? 0) >= options.unknownZipf
        }
        func weight(_ name: String, language: String) throws -> Double {
            classWeight(zipf: try zipf(name, language: language) ?? options.unknownZipf)
        }
        for file in corpusFiles() {
            let path = (context.cache as NSString).appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: path) else { throw EvalError.input("no source file \(path)") }
            files[file] = try Runner.sha256(file: path)
            for line in String(decoding: try Archive.unzip(path, member: "cities15000.txt"), as: UTF8.self)
                .split(separator: "\n")
            {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count > 3 else { continue }
                if spec.languages.contains("en"), Self.isWord(String(fields[2]), script: .latin) {
                    items.append(ClassItem(text: String(fields[2]), weight: try weight(String(fields[2]), language: "en"),
                                           tags: ["name", "name:city"]))
                }
                for language in spec.languages where script(of: language) == .cyrillic {
                    for alternative in fields[3].split(separator: ",") where Self.isWord(String(alternative), script: .cyrillic) {
                        let name = title(String(alternative).lowercased())
                        guard try known(name, language: language) else { continue }
                        items.append(ClassItem(text: name, weight: try weight(name, language: language),
                                               tags: ["name", "name:city"]))
                    }
                }
            }
        }
        if let snapshot = spec.snapshot {
            let path = (context.classesDirectory as NSString).appendingPathComponent(snapshot)
            for label in try Self.snapshotLabels(path: path) where spec.languages.contains(label.language) {
                guard Self.isWord(label.name, script: script(of: label.language)) else { continue }
                items.append(ClassItem(text: title(label.name.lowercased()),
                                       weight: try weight(label.name.lowercased(), language: label.language),
                                       tags: ["name", "name:given"]))
            }
        }
        return (items, files)
    }

    /// The labels of a names snapshot (`eval/classes/names.wikidata.tsv`): `#` lines are comments, the first other
    /// line names the columns (`ru`, `en`, `uk`, `links`), an empty cell is a name the language lacks.
    static func snapshotLabels(path: String) throws -> [(language: String, name: String)] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw EvalError.input("no snapshot \(path)") }
        var header: [String]?
        var labels: [(language: String, name: String)] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let columns = header else {
                header = cells
                continue
            }
            for (index, column) in columns.enumerated() where ["ru", "en", "uk"].contains(column) && index < cells.count && !cells[index].isEmpty {
                labels.append((column, cells[index]))
            }
        }
        guard header != nil else { throw EvalError.input("\(path) has no header line") }
        return labels
    }

    // MARK: - cli

    /// The commands, flags and paths of the `tldr-pages` examples, token by token (plan, 8.4).
    func cli() throws -> ([ClassItem], [String: String]) {
        var counts: [String: (count: Int, kind: String)] = [:]
        var total = 0
        var files: [String: String] = [:]
        for file in spec.corpusFiles {
            let path = (context.cache as NSString).appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: path) else {
                throw EvalError.input("no source file \(path); run scripts/fetch-data.sh bench")
            }
            files[file] = try Runner.sha256(file: path)
            var listed: [String] = []
            try LineStream.read(tool: "/usr/bin/unzip", arguments: ["-Z1", path]) { name in
                listed.append(String(decoding: name, as: UTF8.self))
                return true
            }
            let platforms = options.tldrPlatforms.filter { platform in listed.contains { $0.hasPrefix(platform + "/") } }
            try LineStream.read(tool: "/usr/bin/unzip", arguments: ["-p", path] + platforms.map { $0 + "/*" }) { line in
                let text = String(decoding: line, as: UTF8.self)
                if text.hasPrefix("# ") {
                    let name = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !name.contains(" ") {
                        counts[name, default: (0, "command")].count += 1
                        total += 1
                    }
                } else if let example = Self.tldrExample(text) {
                    for (token, kind) in Self.tldrTokens(example) {
                        counts[token, default: (0, kind)].count += 1
                        total += 1
                    }
                }
                return true
            }
        }
        let items = counts.map { token, entry in
            ClassItem(text: token, weight: total > 0 ? Double(entry.count) * 1_000_000 / Double(total) : 0,
                      tags: ["cli", "cli:\(entry.kind)"])
        }
        return (items, files)
    }

    /// The command of an example line `` `git add {{path}}` ``, nil for any other line.
    static func tldrExample(_ line: String) -> String? {
        guard line.hasPrefix("`"), line.hasSuffix("`"), line.count > 2 else { return nil }
        return String(line.dropFirst().dropLast())
    }

    /// The tokens of an example with their kind: the command (the first word, and after `|`, `&&`, `;`), flags,
    /// paths, other words. A `{{placeholder}}` is a value to fill in and is dropped, except the options inside
    /// `{{[-v|--verbose]}}`, which are flags.
    static func tldrTokens(_ example: String) -> [(String, String)] {
        var text = example
        var flags: [String] = []
        while let open = text.range(of: "{{") {
            guard let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) else { break }
            let inside = String(text[open.upperBound..<close.lowerBound])
            if inside.hasPrefix("["), inside.hasSuffix("]") {
                flags += inside.dropFirst().dropLast().split(separator: "|").map(String.init)
            }
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: "\u{0}")
        }
        var result: [(String, String)] = flags.filter { $0.hasPrefix("-") && $0.count > 1 }.map { ($0, "flag") }
        var expectCommand = true
        for piece in text.split(whereSeparator: { $0 == " " }) {
            var token = String(piece)
            if ["|", "&&", ";", "||"].contains(token) {
                expectCommand = true
                continue
            }
            let hadPlaceholder = token.contains("\u{0}")
            token = token.replacingOccurrences(of: "\u{0}", with: "")
            guard !token.isEmpty, token.contains(where: \.isLetter), !hadPlaceholder || token.hasPrefix("-") else {
                expectCommand = false
                continue
            }
            let kind: String
            if expectCommand {
                kind = "command"
            } else if token.hasPrefix("-") {
                kind = "flag"
            } else if token.contains("/") || token.hasPrefix("~") || token.hasPrefix(".") {
                kind = "path"
            } else {
                kind = "word"
            }
            expectCommand = false
            result.append((token, kind))
        }
        return result
    }

    // MARK: - code

    /// Comment openers by language of a code file: a line that starts with one is prose, not code.
    static let commentOpeners: [String: [String]] = [
        "swift": ["//", "/*", "*"], "go": ["//", "/*", "*"], "js": ["//", "/*", "*"],
        "python": ["#"], "sh": ["#"], "sql": ["--", "/*", "*"],
    ]
    static let codeGlobs: [String: String] = [
        "swift": "*.swift", "go": "*.go", "js": "*.js", "python": "*.py", "sh": "*.sh", "sql": "*.sql",
    ]

    /// The tokens of source files from pinned revisions of free repositories (plan, 8.4): split at spaces, comment
    /// lines left out. A file `code/<language>-<repository>.tar.gz` of the cache holds the files of one repository.
    func code() throws -> ([ClassItem], [String: String]) {
        var counts: [String: (count: Int, languages: Set<String>)] = [:]
        var total = 0
        var files: [String: String] = [:]
        for file in corpusFiles() {
            let path = (context.cache as NSString).appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: path) else {
                throw EvalError.input("no source file \(path); run scripts/fetch-data.sh bench")
            }
            files[file] = try Runner.sha256(file: path)
            let name = (file as NSString).lastPathComponent
            guard let language = name.split(separator: "-").first.map(String.init), let glob = Self.codeGlobs[language],
                  let openers = Self.commentOpeners[language]
            else { throw EvalError.input("\(file): the name must start with swift-, go-, js-, python-, sh- or sql-") }
            try LineStream.read(tool: "/usr/bin/tar", arguments: ["-xzOf", path, "--include", glob]) { line in
                let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, !openers.contains(where: text.hasPrefix) else { return true }
                for piece in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    total += 1
                    let token = String(piece)
                    guard token.count <= options.codeTokenLetters, token.contains(where: \.isLetter),
                          token.unicodeScalars.allSatisfy({ $0.isASCII })
                    else { continue }
                    counts[token, default: (0, [])].count += 1
                    counts[token]?.languages.insert(language)
                }
                return true
            }
        }
        var items: [ClassItem] = []
        for (token, entry) in counts {
            let perMillion = total > 0 ? Double(entry.count) * 1_000_000 / Double(total) : 0
            guard perMillion >= (spec.minPerMillion ?? options.minPerMillion) else { continue }
            items.append(ClassItem(text: token, weight: perMillion,
                                   tags: ["code"] + entry.languages.sorted().map { "code:\($0)" }))
        }
        return (items, files)
    }
}
