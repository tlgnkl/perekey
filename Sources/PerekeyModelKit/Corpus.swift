// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// The held-out corpus: words with the language they are in and the languages
/// of the words before them in the sentence, by category. docs/classifier.md,
/// "Метрика".
///
/// Sources (data/SOURCES.md): Tatoeba sentences, GeoNames cities, Perekey's
/// own sources for code, and seeded synthetic URLs, passwords and captchas.
/// Nothing here is in the training data, which is word lists.
public struct CorpusItem: Hashable, Sendable {
    public var category: String
    /// "ru" or "en": the language the text is in, so the layout it is typed with.
    public var language: String
    /// The languages of the words before it in its sentence, the latest
    /// first, up to `RecentLanguages.capacity`; nil for a word of no language.
    public var recent: [String?]
    public var text: String
    /// For the typos category: the word the user meant.
    public var expected: String?

    /// The language of the word before it.
    public var previous: String? { recent.first ?? nil }

    public init(category: String, language: String, previous: String?, text: String, expected: String? = nil) {
        self.init(category: category, language: language, recent: previous.map { [$0] } ?? [], text: text,
                  expected: expected)
    }

    public init(category: String, language: String, recent: [String?], text: String, expected: String? = nil) {
        self.category = category
        self.language = language
        self.recent = recent
        self.text = text
        self.expected = expected
    }
}

public enum Corpus {
    /// Categories whose words should switch when typed in the wrong layout.
    public static let switchable: Set<String> = ["prose", "chat", "names", "mixed"]
    /// Categories whose strings are typed in the English layout only.
    public static let englishOnly: Set<String> = ["code", "url", "password"]
    public static let categories = ["prose", "chat", "mixed", "names", "code", "url", "password", "captcha", "typos"]

    /// Share of each category in a sample. Typos come on top of the
    /// classifier's categories: the sample of `words` grows by a tenth.
    static let shares: [String: Double] = [
        "prose": 0.30, "chat": 0.25, "mixed": 0.10, "names": 0.10, "code": 0.10, "url": 0.05,
        "password": 0.05, "captcha": 0.05, "typos": 0.10,
    ]

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Builds a corpus of about `words` words.
    /// - Parameters:
    ///   - cache: the data cache of scripts/fetch-data.sh.
    ///   - code: a directory of Swift sources for the code category.
    public static func build(cache: String, code: String, words: Int, seed: UInt64) throws -> [CorpusItem] {
        var random = SplitMix64(seed: seed)
        var items: [CorpusItem] = []
        let quota = { (category: String) in Int(Double(words) * shares[category]!) }

        let russian = try tatoeba("\(cache)/tatoeba/rus_sentences.tsv.bz2", random: &random)
        let english = try tatoeba("\(cache)/tatoeba/eng_sentences.tsv.bz2", random: &random)
        var ru = russian.makeIterator()
        var en = english.makeIterator()

        // Prose: long sentences as written, punctuation and capitals included.
        var count = 0
        while count < quota("prose"), let sentence = random.bool() ? ru.next() : en.next() {
            let tokens = sentence.split(separator: " ")
            guard tokens.count >= 8 else { continue }
            count += add(tokens.map(String.init), category: "prose", to: &items)
        }

        // Chat: short sentences, lower case, no punctuation.
        count = 0
        while count < quota("chat"), let sentence = random.bool() ? ru.next() : en.next() {
            let tokens = chatTokens(sentence)
            guard tokens.count >= 1, tokens.count <= 6 else { continue }
            count += add(tokens, category: "chat", to: &items)
        }

        // Mixed: a Russian and an English sentence interleaved in chunks, so the
        // previous word is often in the other language.
        count = 0
        while count < quota("mixed"), let a = ru.next(), let b = en.next() {
            var tokens: [String] = []
            var left = a.split(separator: " ").map(String.init)
            var right = b.split(separator: " ").map(String.init)
            while !left.isEmpty || !right.isEmpty {
                let chunk = 1 + Int(random.next() % 3)
                tokens += left.prefix(chunk)
                left = Array(left.dropFirst(chunk))
                tokens += right.prefix(chunk)
                right = Array(right.dropFirst(chunk))
            }
            count += add(tokens, category: "mixed", to: &items)
        }

        // Names: city names, Latin and Cyrillic, word by word.
        let names = try geonames("\(cache)/geonames/cities15000.zip")
        count = 0
        for name in names.shuffled(using: &random) where count < quota("names") {
            count += add(name.split(separator: " ").map(String.init), category: "names", to: &items)
        }

        // Code: whitespace tokens of Swift sources, kept as typed. String
        // literals are skipped: the tests and the benchmark spell out words
        // in the wrong layout on purpose.
        var tokens: [String] = []
        for file in try FileManager.default.subpathsOfDirectory(atPath: code).filter({ $0.hasSuffix(".swift") }).sorted() {
            let text = try String(contentsOfFile: "\(code)/\(file)", encoding: .utf8)
            tokens += text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .filter { !$0.contains("\"") }.map(String.init)
        }
        // Code follows code: the previous token was typed in the English layout
        // and read as English, the way the integration will track it.
        for token in tokens.shuffled(using: &random).prefix(quota("code")) {
            items.append(CorpusItem(category: "code", language: "en", recent: ["en"], text: token))
        }

        // Synthetic strings with a fixed seed.
        let vocabulary = english.prefix(2000).flatMap { $0.lowercased().split(separator: " ") }
            .map { String($0.filter(\.isLetter)) }.filter { $0.count >= 3 }
        for _ in 0..<quota("url") {
            items.append(CorpusItem(category: "url", language: "en", previous: nil,
                                    text: Synthetic.url(vocabulary: vocabulary, random: &random)))
        }
        for _ in 0..<quota("password") {
            items.append(CorpusItem(category: "password", language: "en", previous: nil,
                                    text: Synthetic.password(vocabulary: vocabulary, random: &random)))
        }
        for index in 0..<quota("captcha") {
            let language = index % 2 == 0 ? "en" : "ru"
            items.append(CorpusItem(category: "captcha", language: language, previous: nil,
                                    text: Synthetic.captcha(language: language, random: &random)))
        }

        // Typos: one word of a sentence with one key off, lower case, with
        // the word meant and the language of the word before it.
        count = 0
        while count < quota("typos"), let sentence = random.bool() ? ru.next() : en.next() {
            let tokens = sentence.lowercased().split(separator: " ").map { token in
                String(token.filter { $0.isLetter })
            }
            let candidates = tokens.indices.filter { tokens[$0].count >= 4 && language(of: tokens[$0]) != nil }
            guard !candidates.isEmpty else { continue }
            let index = candidates[Int(random.next() % UInt64(candidates.count))]
            let word = tokens[index]
            guard let lang = language(of: word), let typo = Synthetic.typo(of: word, language: lang, random: &random)
            else { continue }
            let recent = tokens[max(0, index - RecentLanguages.capacity)..<index].reversed().map { language(of: $0) }
            items.append(CorpusItem(category: "typos", language: lang, recent: recent, text: typo, expected: word))
            count += 1
        }

        return items
    }

    /// Chat tokens of a sentence: lower case, letters, hyphens and apostrophes.
    private static func chatTokens(_ sentence: String) -> [String] {
        sentence.lowercased().split(separator: " ").map { token in
            String(token.filter { $0.isLetter || $0 == "-" || $0 == "'" })
        }.filter { !$0.isEmpty }
    }

    /// Adds the words of a sentence; each word's language is its script.
    /// Returns how many words were added.
    private static func add(_ tokens: [String], category: String, to items: inout [CorpusItem]) -> Int {
        var recent: [String?] = []
        var added = 0
        for token in tokens {
            let language = language(of: token)
            if let language {
                items.append(CorpusItem(category: category, language: language, recent: recent, text: token))
                added += 1
            }
            recent.insert(language, at: 0)
            if recent.count > RecentLanguages.capacity { recent.removeLast() }
        }
        return added
    }

    /// "ru" for a Cyrillic word, "en" for a Latin one, nil for anything else.
    static func language(of token: String) -> String? {
        var cyrillic = false, latin = false
        for scalar in token.unicodeScalars {
            switch scalar.value {
            case 0x410...0x44F, 0x401, 0x451: cyrillic = true
            case 0x41...0x5A, 0x61...0x7A: latin = true
            case 0x30...0x39: return nil
            default:
                guard scalar.properties.isAlphabetic == false else { return nil }
            }
        }
        if cyrillic != latin { return cyrillic ? "ru" : "en" }
        return nil
    }

    /// Tatoeba sentences of one language, shuffled.
    static func tatoeba(_ path: String, random: inout SplitMix64) throws -> [String] {
        let data = try Archive.bunzip2(path)
        var sentences: [String] = []
        for line in data.lines() {
            let fields = line.split(separator: "\t")
            guard fields.count == 3 else { continue }
            sentences.append(String(fields[2]))
        }
        return sentences.shuffled(using: &random)
    }

    /// City names: the Latin name and the Cyrillic alternatives.
    static func geonames(_ path: String) throws -> [String] {
        let data = try Archive.unzip(path, member: "cities15000.txt")
        var names: Set<String> = []
        for line in data.lines() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count > 3 else { continue }
            names.insert(String(fields[1]))
            for alternative in fields[3].split(separator: ",") where language(of: String(alternative)) == "ru" {
                names.insert(String(alternative))
            }
        }
        return names.sorted()
    }

    /// One word per line: category, language, the languages before it
    /// ("ru,-,en", latest first, "-" for none), the text and the word meant
    /// ("-" for none). Files from before the context, with one language
    /// before and no placeholder for the word meant, still read.
    public static func write(_ items: [CorpusItem], to path: String) throws {
        var text = "# category\tlanguage\trecent\ttext\texpected\n"
        for item in items {
            let recent = item.recent.isEmpty ? "-" : item.recent.map { $0 ?? "-" }.joined(separator: ",")
            text += "\(item.category)\t\(item.language)\t\(recent)\t\(item.text)\t\(item.expected ?? "-")\n"
        }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    public static func read(_ path: String) throws -> [CorpusItem] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var items: [CorpusItem] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard (4...5).contains(fields.count) else { throw Failure(description: "bad corpus line: \(line)") }
            let recent: [String?] = fields[2] == "-" ? [] : fields[2].split(separator: ",").map { $0 == "-" ? nil : String($0) }
            let expected = fields.count >= 5 && fields[4] != "-" ? String(fields[4]) : nil
            items.append(CorpusItem(category: String(fields[0]), language: String(fields[1]), recent: recent,
                                    text: String(fields[3]), expected: expected))
        }
        return items
    }
}

/// Synthetic strings the classifier must leave alone.
enum Synthetic {
    static let tlds = ["com", "ru", "org", "io", "net", "dev", "su", "рф"]
    static let symbols = Array("!@#$%^&*_-+=?")

    static func pick<T>(_ items: [T], _ random: inout SplitMix64) -> T {
        items[Int(random.next() % UInt64(items.count))]
    }

    static func url(vocabulary: [String], random: inout SplitMix64) -> String {
        let host = "\(pick(vocabulary, &random)).\(pick(tlds, &random))"
        switch random.next() % 5 {
        case 0: return "https://\(host)/\(pick(vocabulary, &random))/\(pick(vocabulary, &random))"
        case 1: return "www.\(host)"
        case 2: return "\(pick(vocabulary, &random))@\(host)"
        case 3: return "~/\(pick(vocabulary, &random))/\(pick(vocabulary, &random)).txt"
        default: return "\(host)/\(pick(vocabulary, &random))?id=\(random.next() % 1000)"
        }
    }

    static func password(vocabulary: [String], random: inout SplitMix64) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        switch random.next() % 3 {
        case 0:
            // Random: mixed case, digits, symbols.
            var text = ""
            for index in 0..<(8 + Int(random.next() % 8)) {
                let letter = pick(letters, &random)
                switch random.next() % 4 {
                case 0: text.append(letter.uppercased())
                case 1: text.append(String(random.next() % 10))
                case 2: text.append(index > 0 ? pick(symbols, &random) : letter)
                default: text.append(letter)
                }
            }
            return text
        case 1:
            // A word with a capital inside, a digit and a symbol: "paSsword7!".
            var word = Array(pick(vocabulary, &random))
            let position = 1 + Int(random.next() % UInt64(max(1, word.count - 1)))
            word[min(position, word.count - 1)] = Character(word[min(position, word.count - 1)].uppercased())
            return String(word) + String(random.next() % 100) + String(pick(symbols, &random))
        default:
            // Two words glued CamelCase with a symbol, no digits: "greenHouse#".
            let first = pick(vocabulary, &random)
            let second = pick(vocabulary, &random)
            return first + second.prefix(1).uppercased() + String(second.dropFirst()) + String(pick(symbols, &random))
        }
    }

    /// The letter rows of the two layouts, for the keys next to a letter.
    /// Written out here on purpose: the evaluation must not borrow the
    /// geometry it measures (`KeyboardGeometry`).
    static let letterRows: [String: [(offset: Double, letters: String)]] = [
        "en": [(0, "qwertyuiop"), (0.25, "asdfghjkl"), (0.75, "zxcvbnm")],
        "ru": [(0, "йцукенгшщзхъ"), (0.25, "фывапролджэ"), (0.75, "ячсмитьбю")],
    ]

    /// Letters on the keys around this one: next to it in its row, and the
    /// two keys of each adjacent row that overlap it.
    static func neighbours(of letter: Character, language: String) -> [Character] {
        guard let rows = letterRows[language] else { return [] }
        var position: (row: Int, x: Double)?
        for (row, line) in rows.enumerated() {
            if let index = line.letters.firstIndex(of: letter) {
                position = (row, line.offset + Double(line.letters.distance(from: line.letters.startIndex, to: index)))
            }
        }
        guard let position else { return [] }
        var result: [Character] = []
        for (row, line) in rows.enumerated() {
            for (index, other) in line.letters.enumerated() where other != letter {
                let distance = abs(line.offset + Double(index) - position.x)
                let rowGap = abs(row - position.row)
                if (rowGap == 0 && distance < 1.5) || (rowGap == 1 && distance < 1) { result.append(other) }
            }
        }
        return result
    }

    /// One key off in `word`, the way people miss keys: a neighbouring key
    /// (40 %), two letters swapped (20 %), a letter dropped (20 %), a letter
    /// doubled (10 %), a stray letter (10 %). Nil when the word has no
    /// letter the keyboard rows know at the chosen place.
    static func typo(of word: String, language: String, random: inout SplitMix64) -> String? {
        var letters = Array(word)
        guard letters.count >= 4, let rows = letterRows[language] else { return nil }
        let alphabet = Array(rows.map(\.letters).joined())
        let index = Int(random.next() % UInt64(letters.count))
        switch random.next() % 10 {
        case 0...3:
            let around = neighbours(of: letters[index], language: language)
            guard !around.isEmpty else { return nil }
            letters[index] = pick(around, &random)
        case 4...5:
            let at = min(index, letters.count - 2)
            guard letters[at] != letters[at + 1] else { return nil }
            letters.swapAt(at, at + 1)
        case 6...7:
            letters.remove(at: index)
        case 8:
            letters.insert(letters[index], at: index)
        default:
            letters.insert(pick(alphabet, &random), at: index)
        }
        let typo = String(letters)
        return typo == word ? nil : typo
    }

    static func captcha(language: String, random: inout SplitMix64) -> String {
        let letters = Array(language == "ru" ? "абвгдежзиклмнопрстуфхцчшщыэюя" : "abcdefghijklmnopqrstuvwxyz")
        var text = ""
        for _ in 0..<(4 + Int(random.next() % 5)) {
            let letter = pick(letters, &random)
            text.append(random.next() % 3 == 0 ? Character(letter.uppercased()) : letter)
        }
        return text
    }
}

/// A seeded generator, so corpora and samples are reproducible.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func bool() -> Bool { next() & 1 == 1 }
}
