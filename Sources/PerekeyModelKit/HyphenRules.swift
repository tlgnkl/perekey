// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// Words that take a hyphen by rule, derived from the spelling dictionary
/// into the "hyph" table next to `data/ru/hyphen.txt` (docs/corrections.md,
/// «Дефис»). The part of speech comes from the shape of the Hunspell
/// entries: a stem in -ый, -ий, -ой with flags is an adjective, flag B
/// gives the imperative and L the past of a verb, a stem without flags
/// does not inflect (adverbs, pronoun forms, particles).
///
/// Every word keeps the condition of the hand list, stricter: its merged
/// spelling is no word (`maxMergedRank`), and each part is a form of the
/// dictionary. The prefixes (вице-мэр) need no list: `HyphenStep` checks them.
public enum HyphenRules {
    public enum Rule: String, CaseIterable, Sendable {
        /// по- before an adverb ending: по-новому, по-прежнему, по-русски, по-лисьи.
        case po
        /// -то, -либо, -нибудь after a word that does not inflect: вообще-то,
        /// наконец-то; -то after an adverb of an adjective too: просто-то.
        case particle
        /// -ка after an imperative and after ну: дай-ка, смотри-ка, ну-ка.
        case ka
        /// -таки after a word that does not inflect or an adverb: опять-таки, прямо-таки.
        case taki
        /// A word that does not inflect or an adverb, twice: тихо-тихо, что-что.
        case doubling
    }

    /// The particles of `Rule.particle`.
    static let particles = ["то", "либо", "нибудь"]

    /// The prepositions of three letters or more: no word before a particle
    /// ("прото" is not "про-то"). The dictionary does not mark them.
    static let prepositions: Set = [
        "без", "безо", "близ", "вдоль", "вместо", "вне", "внутри", "внутрь", "возле", "вокруг", "для", "изо",
        "кроме", "между", "мимо", "над", "около", "ото", "перед", "передо", "под", "подо", "после", "пред",
        "при", "про", "против", "ради", "сквозь", "среди", "через", "чрез", "благодаря", "согласно", "вопреки",
        "вследствие", "ввиду", "поверх", "позади", "посреди", "сверх", "спустя", "вблизи", "наряду",
    ]

    /// A derived word's merged spelling is rarer than Zipf 3, below the hand
    /// list's bar (`HyphenList.maxMergedRank`): typos of the rules sit near
    /// 2.5 ("вообщето" 2.56, "дайка" 2.55), names above ("Като" 3.12, "Коко" 3.41).
    public static let maxMergedRank = WordFreq.rank(zipf: 3)
    /// A word before -то, -либо, -нибудь, -таки or twice is frequent, Zipf 4 and up,
    /// three letters or more: pronouns and adverbs ("так", "вообще"), not
    /// "ка", "со", "амба" or the odd form of a noun ("окон").
    static let minimumBaseRank = WordFreq.rank(zipf: 4)
    static let minimumBaseLength = 3
    /// An imperative before -ка is frequent, Zipf 4 and up: "дай", "смотри", not "грузи", "тай", "знай".
    static let minimumImperativeRank = WordFreq.rank(zipf: 4)

    /// The words with a hyphen the rules derive, each with its rule. A
    /// merged spelling two rules split differently gives none.
    /// - Parameters:
    ///   - entries: the stems and flags of the spelling dictionary.
    ///   - isWord: the word is a form of the spelling dictionary or of a hand list.
    ///   - rank: the wordfreq rank of a word, `nil` if wordfreq does not know it.
    public static func derive(_ entries: [(stem: String, flags: Substring)], hunspell: Hunspell,
                              isWord: (String) -> Bool, rank: (String) -> UInt8?) -> [String: Rule]
    {
        var candidates: [String: (form: String, rule: Rule)] = [:]
        var ambiguous: Set<String> = []
        func add(_ first: String, _ second: String, _ rule: Rule) {
            let merged = first + second
            guard !ambiguous.contains(merged), !isWord(merged), !isWord(YoTable.plain(merged)),
                  (rank(merged) ?? 0) < maxMergedRank, (rank(YoTable.plain(merged)) ?? 0) < maxMergedRank
            else { return }
            let form = "\(first)-\(second)"
            if let known = candidates[merged] {
                guard known.form != form else { return }
                candidates[merged] = nil
                ambiguous.insert(merged)
                return
            }
            candidates[merged] = (form, rule)
        }

        func isBase(_ word: String) -> Bool {
            word.count >= minimumBaseLength && (rank(word) ?? 0) >= minimumBaseRank
        }
        var imperatives: Set<String> = []
        var invariable: Set<String> = []
        var others: [(stem: String, flags: Substring)] = []
        var verbs: [(stem: String, flags: Substring)] = []
        var particleBases: Set<String> = []
        for entry in entries {
            let stem = entry.stem
            guard stem.first?.isLowercase == true, stem.allSatisfy(\.isLetter) else { continue }
            if entry.flags.isEmpty {
                invariable.insert(stem)
                // Adverbs, pronoun forms, particles, and the odd form of an
                // irregular word; the frequent ones are pronouns and adverbs.
                if isBase(stem) {
                    particleBases.insert(stem)
                    add(stem, "таки", .taki)
                    add(stem, stem, .doubling)
                }
                continue
            }
            if entry.flags.contains("B") {
                // Flag B gives the imperative: "дать" → "дай", "дайте";
                // irregular imperatives are entries of their own ("иди/B").
                hunspell.expand(stem, flags: "B") { form in
                    if form != stem || !isInfinitive(stem), (rank(form) ?? 0) >= minimumImperativeRank {
                        imperatives.insert(form)
                    }
                }
            }
            if entry.flags.contains("B") || entry.flags.contains("L") {
                verbs.append(entry)
                continue
            }
            others.append(entry)
            guard stem.hasSuffix("ый") || stem.hasSuffix("ий") || stem.hasSuffix("ой") else { continue }
            // An adjective: по- with -ски, -цки from -ский, -цкий (по-русски),
            // with the dative of the others (по-новому), with -ьи from -ий
            // (по-лисьи); its adverb takes -то, -таки and doubles.
            let ski = stem.hasSuffix("ский") || stem.hasSuffix("цкий")
            if ski { add("по", String(stem.dropLast(2)) + "и", .po) }
            var adverbs: Set<String> = []
            hunspell.expand(stem, flags: entry.flags) { form in
                if !ski, form.hasSuffix("ому") || form.hasSuffix("ему") || stem.hasSuffix("ий") && form.hasSuffix("ьи") {
                    add("по", form, .po)
                }
                // The short neuter in -о is the adverb: "прямо", "довольно" (not "-ого", "-ое").
                if form.hasSuffix("о"), !form.hasSuffix("ого"), !form.hasSuffix("ое") { adverbs.insert(form) }
            }
            if entry.flags.contains("Z") {
                hunspell.expand(stem, flags: "Z") { if $0 != stem { adverbs.insert($0) } }
            }
            for adverb in adverbs.sorted() where isBase(adverb) {
                add(adverb, "то", .particle)
                add(adverb, "таки", .taki)
                add(adverb, adverb, .doubling)
            }
        }
        // An imperative that is also another word is read as that: a form of
        // a noun ("печаль", "вой"; "печалька" is a word), a word that does not inflect.
        imperatives.subtract(invariable)
        for entry in others {
            hunspell.expand(entry.stem, flags: entry.flags) {
                imperatives.remove($0)
                particleBases.remove($0)
            }
        }
        // A particle follows a pronoun, an adverb, a conjunction, not a noun
        // or a verb ("окон", "идти") and not a preposition: "Оконто" is a name.
        for entry in verbs {
            hunspell.expand(entry.stem, flags: entry.flags) { particleBases.remove($0) }
        }
        for base in particleBases.subtracting(prepositions).sorted() where !isGenitivePlural(base) {
            for particle in particles { add(base, particle, .particle) }
        }
        for imperative in imperatives { add(imperative, "ка", .ka) }
        add("ну", "ка", .ka)

        var words: [String: Rule] = [:]
        for candidate in candidates.values { words[candidate.form] = candidate.rule }
        return words
    }

    /// A noun form the dictionary lists without flags: the genitive plural
    /// in -ов, -ев, -ей ("денег" and "окон" it cannot tell): "беженцев",
    /// "детей". Not "ней".
    static func isGenitivePlural(_ word: String) -> Bool {
        word != "ней" && ["ов", "ев", "ей"].contains(where: word.hasSuffix)
    }

    /// An infinitive: "дать", "идти", "лечь", "мыться".
    static func isInfinitive(_ stem: String) -> Bool {
        ["ть", "ти", "чь", "ться", "тись", "чься"].contains(where: stem.hasSuffix)
    }
}
