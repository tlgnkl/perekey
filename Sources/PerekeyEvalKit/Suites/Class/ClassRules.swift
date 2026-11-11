// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyModelKit

/// What a rule returns: the items it derived, and the seeds, each with the
/// key the rule also found it by (the proof that the rule covers the seed).
struct RuleOutput {
    var derived: [ClassItem] = []
    var seeds: [ClassItem] = []
    /// The cache files read and their SHA-256.
    var files: [String: String] = [:]
}

/// The rules of the class suites (docs/eval.md, «Наборы классов»). Each takes
/// words from a lexicon, a corpus or a generator; the seed list only starts it.
struct ClassRules {
    /// Numbers of the rules. A first guess, not a measurement; each says where it comes from.
    struct Options {
        /// The least Zipf of a word the lexicon rules take: plan, 8.4 («Zipf ≥ 3»).
        var minZipf = 3.0
        /// The Zipf of a word the lexicon lacks, for its weight: 2 is the least the lexicon keeps (plan, 9.4).
        var unknownZipf = 2.0
        /// The longest and the shortest word a generator takes from the vocabulary, in letters.
        var vocabularyLetters = 3...10
        /// How many of the most frequent words give the vocabulary of a generator.
        var vocabularySize = 2000
        /// The share of generated passwords that are a Russian word typed on Latin keys: plan, 8.4 («Ghbdtn123!»).
        var passwordRussianShare = 0.4
        /// The least Zipf at which a word counts as known when the language has no spelling dictionary (`oov` for
        /// Ukrainian): the least the bench's lexicon keeps (plan, 9.4).
        var knownZipf = 2.0
        /// The platforms of tldr-pages whose pages give the examples: the ones a Mac user types.
        var tldrPlatforms = ["common", "linux", "osx"]
        /// The longest token of a source file, in characters: a longer one is a string or a hash, not code.
        var codeTokenLetters = 40

        init() {}
    }

    let manifest: SuiteManifest
    let spec: ClassSpec
    let context: ClassContext
    let library: LayoutLibrary
    let sets: [LayoutSet]
    let tier: SuiteManifest.Tier
    let options: Options

    init(manifest: SuiteManifest, spec: ClassSpec, context: ClassContext, library: LayoutLibrary, sets: [LayoutSet],
         tier: SuiteManifest.Tier, options: Options = Options())
    {
        self.manifest = manifest
        self.spec = spec
        self.context = context
        self.library = library
        self.sets = sets
        self.tier = tier
        self.options = options
    }

    var cap: Int { manifest.tiers.tokens(tier) }
    var minZipf: Double { spec.minZipf ?? options.minZipf }

    func run() throws -> RuleOutput {
        var output = RuleOutput()
        switch spec.rule {
        case .short: output.derived = try short()
        case .collision: output.derived = try collision()
        case .frequent: output.derived = try frequent()
        case .punct: output.derived = try punct()
        case .caps: (output.derived, output.files) = try caps()
        case .translit: output.derived = try translit()
        case .oov: (output.derived, output.files) = try oov()
        case .brands: (output.derived, output.files) = try brands()
        case .names: (output.derived, output.files) = try names()
        case .cli: (output.derived, output.files) = try cli()
        case .code: (output.derived, output.files) = try code()
        case .url, .password, .captcha, .numbers: output.derived = try generated()
        }
        output.seeds = try seedItems(derived: output.derived)
        return output
    }

    // MARK: - Languages and words

    /// The Cyrillic language of the layout sets, nil when they differ.
    var cyrillicLanguage: String? {
        let codes = Set(sets.map(\.language))
        return codes.count == 1 ? codes.first : nil
    }

    func script(of language: String) -> Lexicon.Script { Lexicon.scripts[language] ?? .cyrillic }

    /// Letters of the language's script only, nothing else.
    static func isWord(_ word: String, script: Lexicon.Script) -> Bool {
        guard !word.isEmpty else { return false }
        return word.unicodeScalars.allSatisfy { scalar in
            switch script {
            case .latin: (0x61...0x7A).contains(scalar.value) || (0x41...0x5A).contains(scalar.value)
            case .cyrillic: (0x400...0x4FF).contains(scalar.value) && scalar.properties.isAlphabetic
            }
        }
    }

    /// The words of the language with Zipf from `minimum`, the most frequent first, a word of the language's spelling
    /// dictionary where the cache has one and `requireDictionary` is not off.
    func lexiconWords(_ language: String, minimum: Double? = nil) throws -> [(word: String, zipf: Double)] {
        guard Lexicon.scripts[language] != nil else { throw EvalError.input("\(manifest.suite): no language \(language)") }
        let script = script(of: language)
        let dictionary = (spec.requireDictionary ?? true) ? try context.dictionary(language) : nil
        let floor = minimum ?? minZipf
        var words: [(word: String, zipf: Double)] = []
        for entry in try context.lexiconWords(language) where entry.zipf >= floor && Self.isWord(entry.word, script: script) {
            if let dictionary, !dictionary.contains(Lexicon.key(entry.word)) { continue }
            words.append(entry)
        }
        words.sort { $0.zipf != $1.zipf ? $0.zipf > $1.zipf : $0.word.utf8.lexicographicallyPrecedes($1.word.utf8) }
        return words
    }

    func item(_ text: String, zipf: Double, tags: [String]) -> ClassItem {
        ClassItem(text: text, weight: classWeight(zipf: zipf), tags: tags)
    }

    func title(_ word: String) -> String { word.prefix(1).uppercased() + word.dropFirst() }

    static func choice(_ key: String, salt: String, count: Int) -> Int {
        Int(FNV1a.hash64(key + "\u{1F}" + salt) % UInt64(count))
    }

    // MARK: - short, collision, frequent

    /// Every word of one or two letters with Zipf from 3 (plan, 8.4).
    func short() throws -> [ClassItem] {
        var items: [ClassItem] = []
        for language in spec.languages {
            for entry in try lexiconWords(language) where entry.word.count <= (spec.maxLetters ?? 2) {
                items.append(item(entry.word, zipf: entry.zipf, tags: ["short", "len\(entry.word.count)"]))
            }
        }
        return items
    }

    /// Words whose keys, pressed on the other layout of the pair, type a word as frequent (plan, 8.4: «vs» — «мы»).
    func collision() throws -> [ClassItem] {
        var items: [ClassItem] = []
        for set in sets {
            guard let latin = library[set.latin], let cyrillic = library[set.cyrillic] else { continue }
            for language in spec.languages {
                let other = spec.languages.first { $0 != language } ?? language
                let isLatin = script(of: language) == .latin
                let (source, target) = isLatin ? (latin, cyrillic) : (cyrillic, latin)
                let partners = try context.zipfs(other)
                let partnerDictionary = (spec.requireDictionary ?? true) ? try context.dictionary(other) : nil
                for entry in try lexiconWords(language) {
                    let typed = target.convert(entry.word, from: source)
                    guard typed != entry.word, Self.isWord(typed, script: script(of: other)),
                          let zipf = partners[Lexicon.key(typed)], zipf >= minZipf,
                          partnerDictionary?.contains(Lexicon.key(typed)) ?? true
                    else { continue }
                    items.append(item(entry.word, zipf: entry.zipf, tags: ["collision"]))
                }
            }
        }
        return items
    }

    /// The most frequent words of each language (plan, 8.4: 5000).
    func frequent() throws -> [ClassItem] {
        var items: [ClassItem] = []
        for language in spec.languages {
            for entry in try lexiconWords(language, minimum: spec.minZipf ?? 0).prefix(spec.top ?? 5000) {
                items.append(item(entry.word, zipf: entry.zipf, tags: ["frequent"]))
            }
        }
        return items
    }

    // MARK: - punct, caps

    /// A decoration of a word: the marks in front of it and behind it.
    struct Decoration {
        var name: String
        var before: String
        var after: String
    }

    /// Marks that open a word, close it, or both; the quote, the bracket, the
    /// ellipsis. Typed without ⌥ on ABC, Russian and RussianWin (plan, 8.4).
    static let decorations: [Decoration] = [
        .init(name: "lead", before: "\"", after: ""), .init(name: "lead", before: "(", after: ""),
        .init(name: "lead", before: "[", after: ""), .init(name: "lead", before: "'", after: ""),
        .init(name: "trail", before: "", after: "."), .init(name: "trail", before: "", after: ","),
        .init(name: "trail", before: "", after: "!"), .init(name: "trail", before: "", after: "?"),
        .init(name: "trail", before: "", after: ";"), .init(name: "trail", before: "", after: ":"),
        .init(name: "trail", before: "", after: "..."), .init(name: "trail", before: "", after: ")"),
        .init(name: "trail", before: "", after: "]"), .init(name: "trail", before: "", after: "\""),
        .init(name: "trail", before: "", after: "'"), .init(name: "trail", before: "", after: "!!"),
        .init(name: "both", before: "\"", after: "\""), .init(name: "both", before: "(", after: ")"),
        .init(name: "both", before: "'", after: "'"), .init(name: "both", before: "[", after: "]"),
        .init(name: "both", before: "\"", after: "\","), .init(name: "both", before: "(", after: ")."),
        .init(name: "both", before: "\"", after: "\"."), .init(name: "both", before: "(", after: "),"),
        .init(name: "both", before: "\"", after: "\"!"), .init(name: "both", before: "(", after: ")?"),
        .init(name: "hyphen", before: "", after: ""),
    ]

    /// The decorations a person can type on the layouts of the sets: a Cyrillic word takes only the marks that
    /// every Cyrillic layout has a key for (`'`, `[` and `]` are letters there).
    func decorations(for language: String) -> [Decoration] {
        guard script(of: language) == .cyrillic else { return Self.decorations }
        let maps = sets.compactMap { library[$0.cyrillic] }
        return Self.decorations.filter { decoration in
            (decoration.before + decoration.after).allSatisfy { mark in
                maps.allSatisfy { LayoutLibrary.printableStroke(mark, in: $0) != nil }
            }
        }
    }

    /// The most frequent words, each with one decoration the word's hash picks (plan, 8.4).
    func punct() throws -> [ClassItem] {
        var items: [ClassItem] = []
        for language in spec.languages {
            let words = Array(try lexiconWords(language).prefix(spec.top ?? 1500))
            let available = decorations(for: language)
            for entry in words {
                let decoration = available[Self.choice(entry.word, salt: "punct", count: available.count)]
                var text = decoration.before + entry.word + decoration.after
                if decoration.name == "hyphen", let partner = words.isEmpty ? nil
                    : words[Self.choice(entry.word, salt: "partner", count: words.count)].word, partner != entry.word
                {
                    text = entry.word + "-" + partner
                }
                items.append(item(text, zipf: entry.zipf, tags: ["punct", "punct:\(decoration.name)"]))
            }
        }
        return items
    }

    /// Words with a capital at the start, in capitals, in CamelCase; and the acronyms a corpus has (plan, 8.4).
    func caps() throws -> ([ClassItem], [String: String]) {
        var items: [ClassItem] = []
        var files: [String: String] = [:]
        for language in spec.languages {
            let words = Array(try lexiconWords(language).prefix(spec.top ?? 1500))
            let latin = script(of: language) == .latin
            let forms = latin ? ["title", "upper", "camel", "pascal"] : ["title", "upper"]
            for entry in words {
                let form = forms[Self.choice(entry.word, salt: "caps", count: forms.count)]
                var text: String
                switch form {
                case "title": text = title(entry.word)
                case "upper": text = entry.word.uppercased()
                default:
                    let partner = words[Self.choice(entry.word, salt: "camel", count: words.count)].word
                    text = (form == "camel" ? entry.word : title(entry.word)) + title(partner)
                }
                items.append(item(text, zipf: entry.zipf, tags: ["caps", "caps:\(form)"]))
            }
        }
        if !spec.corpusFiles.isEmpty {
            let stats = try context.corpus(files: spec.corpusFiles)
            files = stats.files
            let allowed = Set(spec.languages.map(script(of:)))
            for (word, count) in stats.capitals where stats.perMillion(count) >= (spec.minPerMillion ?? 0) {
                let kind = word.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) } ? Lexicon.Script.cyrillic : .latin
                guard allowed.contains(kind) else { continue }
                items.append(ClassItem(text: word, weight: stats.perMillion(count), tags: ["caps", "caps:acronym"]))
            }
        }
        return (items, files)
    }

    // MARK: - translit

    /// GOST 7.79 system B without the marks: the digraphs for ж ч ш щ ю я, «j» for й, «cz» for ц, «x» for х; the
    /// letters ъ and ь, which system B writes as marks, are dropped (plan, 8.4: «без диакритики»).
    static let translitTable: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "zh", "з": "z", "и": "i", "й": "j",
        "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f",
        "х": "x", "ц": "cz", "ч": "ch", "ш": "sh", "щ": "shh", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu",
        "я": "ya",
    ]

    static func transliterate(_ word: String) -> String {
        word.lowercased().map { translitTable[$0] ?? String($0) }.joined()
    }

    /// The most frequent Russian words, written in Latin letters by one scheme, typed on ABC: they must stay.
    func translit() throws -> [ClassItem] {
        var items: [ClassItem] = []
        for entry in try lexiconWords("ru", minimum: spec.minZipf ?? 0).prefix(spec.top ?? 2000) {
            let text = Self.transliterate(entry.word)
            guard !text.isEmpty else { continue }
            items.append(item(text, zipf: entry.zipf, tags: ["translit"]))
        }
        return items
    }

    // MARK: - Seeds

    /// The seed list as items. A seed the rule found keeps the rule's weight; any other has the Zipf of the lexicon,
    /// or `unknownZipf`.
    func seedItems(derived: [ClassItem]) throws -> [ClassItem] {
        let list = try context.seeds(spec.seeds)
        let found = Dictionary(derived.map { ($0.key, $0.weight) }, uniquingKeysWith: max)
        var items: [ClassItem] = []
        for entry in list.entries {
            var weight = found[ClassItem.key(entry.word)]
            if weight == nil {
                let language = entry.word.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
                    ? (cyrillicLanguage ?? "ru") : "en"
                let zipf = try context.zipfs(language)[Lexicon.key(entry.word)] ?? options.unknownZipf
                weight = classWeight(zipf: zipf)
            }
            var tags = ["seed"]
            if let group = entry.group { tags.append("seed:\(group)") }
            items.append(ClassItem(text: entry.word, weight: weight ?? 1, tags: tags))
        }
        return items
    }
}
