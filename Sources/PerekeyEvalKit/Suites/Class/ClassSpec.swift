// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The rule of a class suite, the `class` object of its manifest
/// (docs/eval.md, «Наборы классов»). A class is a rule over a lexicon, a
/// corpus or a generator; a seed list in `eval/classes/` only starts it
/// and checks it (memory `fix-by-class-not-list`).
public struct ClassSpec: Hashable, Sendable {
    public var rule: Rule
    /// Language codes whose words the rule takes: `en` and the Cyrillic one of the layout set.
    public var languages: [String]
    /// The least Zipf of a word for the rule; the rule's own default when absent.
    public var minZipf: Double?
    /// The most letters of a word (`short`).
    public var maxLetters: Int?
    /// How many of the most frequent words (`frequent`, `punct`, `caps`, `translit`).
    public var top: Int?
    /// The least occurrences per million tokens of the corpus.
    public var minPerMillion: Double?
    /// Files of the data cache, comma-separated, that the rule reads: Stack
    /// Exchange dumps, `geonames/cities15000.zip`, `tldr/tldr-pages.en.zip`,
    /// archives of source code.
    public var corpus: String?
    /// More files, read at tier `full` when they are in the cache.
    public var corpusFull: String?
    /// The seed list, a file of `eval/classes/`.
    public var seeds: String?
    /// A snapshot of open data kept in the repository, a file of `eval/classes/` (`names.wikidata.tsv`).
    public var snapshot: String?
    /// At tier `ci` the corpus is read only up to this many posts of a Stack Exchange dump, from the start of the
    /// file; `full` reads all. The limit lets the 1 GB dump of ru.stackoverflow serve the quick tier.
    public var ciPosts: Int?
    /// A word must be in the language's spelling dictionary (Hunspell, SCOWL) when it has one.
    public var requireDictionary: Bool?

    public enum Rule: String, Hashable, Sendable, Codable, CaseIterable {
        case short, collision, frequent, oov, names, brands, translit, cli, code
        case url, password, captcha, numbers
        case punct, caps
    }

    public init(rule: Rule, languages: [String] = [], minZipf: Double? = nil, maxLetters: Int? = nil, top: Int? = nil,
                minPerMillion: Double? = nil, corpus: String? = nil, corpusFull: String? = nil, seeds: String? = nil,
                snapshot: String? = nil, ciPosts: Int? = nil, requireDictionary: Bool? = nil)
    {
        self.rule = rule
        self.languages = languages
        self.minZipf = minZipf
        self.maxLetters = maxLetters
        self.top = top
        self.minPerMillion = minPerMillion
        self.corpus = corpus
        self.corpusFull = corpusFull
        self.seeds = seeds
        self.snapshot = snapshot
        self.ciPosts = ciPosts
        self.requireDictionary = requireDictionary
    }

    public var corpusFiles: [String] { Self.files(corpus) }
    public var corpusFullFiles: [String] { Self.files(corpusFull) }

    static func files(_ list: String?) -> [String] {
        (list ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Problems of the values the decoder cannot see.
    func problems(scenarios: [String]) -> [String] {
        var problems: [String] = []
        let needsLanguages: Set<Rule> = [.short, .collision, .frequent, .punct, .caps, .oov, .names, .url, .password, .captcha,
                                         .numbers]
        if needsLanguages.contains(rule), languages.isEmpty { problems.append("class.languages is empty") }
        if rule == .collision, languages.count != 2 { problems.append("class.languages of collision: the two languages of the pair") }
        switch rule {
        case .short where (maxLetters ?? 0) < 1: problems.append("class.maxLetters of short must be at least 1")
        case .frequent, .punct, .caps, .translit:
            if (top ?? 0) < 1 { problems.append("class.top of \(rule.rawValue) must be at least 1") }
        case .oov, .brands:
            if corpusFiles.isEmpty { problems.append("class.corpus of \(rule.rawValue) is empty") }
            if (minPerMillion ?? 0) <= 0 { problems.append("class.minPerMillion of \(rule.rawValue) must be positive") }
        case .cli, .code, .names:
            if corpusFiles.isEmpty { problems.append("class.corpus of \(rule.rawValue) is empty") }
        default:
            break
        }
        if rule == .caps, !corpusFiles.isEmpty, (minPerMillion ?? 0) <= 0 {
            problems.append("class.minPerMillion of caps must be positive when it reads a corpus")
        }
        for name in scenarios where !["clean.cold", "clean.warm", "slip.cold", "slip.warm"].contains(name) {
            problems.append("a class suite has no scenario \(name)")
        }
        return problems
    }
}

extension ClassSpec: Codable {
    private static let fields: Set<String> = [
        "rule", "languages", "minZipf", "maxLetters", "top", "minPerMillion", "corpus", "corpusFull", "seeds",
        "snapshot", "ciPosts", "requireDictionary",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try c.onlyKeys(Self.fields, in: "class")
        rule = try c.required(Rule.self, "rule")
        languages = try c.optional([String].self, "languages") ?? []
        minZipf = try c.optional(Double.self, "minZipf")
        maxLetters = try c.optional(Int.self, "maxLetters")
        top = try c.optional(Int.self, "top")
        minPerMillion = try c.optional(Double.self, "minPerMillion")
        corpus = try c.optional(String.self, "corpus")
        corpusFull = try c.optional(String.self, "corpusFull")
        seeds = try c.optional(String.self, "seeds")
        snapshot = try c.optional(String.self, "snapshot")
        ciPosts = try c.optional(Int.self, "ciPosts")
        requireDictionary = try c.optional(Bool.self, "requireDictionary")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(rule, forKey: AnyKey("rule"))
        if !languages.isEmpty { try c.encode(languages, forKey: AnyKey("languages")) }
        try c.encodeIfPresent(minZipf, forKey: AnyKey("minZipf"))
        try c.encodeIfPresent(maxLetters, forKey: AnyKey("maxLetters"))
        try c.encodeIfPresent(top, forKey: AnyKey("top"))
        try c.encodeIfPresent(minPerMillion, forKey: AnyKey("minPerMillion"))
        try c.encodeIfPresent(corpus, forKey: AnyKey("corpus"))
        try c.encodeIfPresent(corpusFull, forKey: AnyKey("corpusFull"))
        try c.encodeIfPresent(seeds, forKey: AnyKey("seeds"))
        try c.encodeIfPresent(snapshot, forKey: AnyKey("snapshot"))
        try c.encodeIfPresent(ciPosts, forKey: AnyKey("ciPosts"))
        try c.encodeIfPresent(requireDictionary, forKey: AnyKey("requireDictionary"))
    }
}
