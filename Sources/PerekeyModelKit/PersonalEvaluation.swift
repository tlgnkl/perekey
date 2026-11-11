// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// The personal lexicon on a corpus (docs/classifier.md, «Личный словарь»;
/// plan 7.2, item 9): `perekey-eval personal`.
///
/// The "user" is a seeded group of GeoNames names the model does not know,
/// half Cyrillic, half Latin: the names category of the corpus, the class
/// the model knows least. Phase 1: each name is typed in its own layout and
/// kept on a schedule of days, and what the classifier observes goes to a
/// real `PersonalLexiconModel`. Phase 2: the same names are judged in their
/// own layout and in the other one, with the typo corrector, as
/// `Evaluation` judges the corpus, with the lexicon empty and full.
///
/// Poison: strings the lexicon must never accept, each typed ten times over
/// five days and observed whatever the classifier decided, so only the
/// conditions of the observation keep them out: (a) common words typed in
/// the other layout and left there ("ghbdtn"); (b) random strings of the
/// alphabet; (c) typos of known words.
public struct PersonalEvaluation {
    /// One string typed on one day.
    struct Typing {
        var day: Int
        var strokes: [KeyStroke]
        /// The layout the string stays in.
        var result: LayoutMap
        var rivals: [LayoutMap]
        /// Observed only when the classifier keeps it, as the word judge
        /// does; poison is observed regardless.
        var decided: Bool
    }

    public struct Poison: Sendable {
        public var name: String
        /// Distinct strings typed.
        public var strings: Int
        public var accepted: Int
        /// Of those accepted, the rare forms of the model: the typo corrector
        /// leaves a form it knows alone, however rare.
        public var rare: Int
    }

    /// The names judged with one lexicon.
    public struct Judged: Sendable {
        public var all: Evaluation.Category
        /// The names the lexicon accepted.
        public var accepted: Evaluation.Category
    }

    public struct Results: Sendable {
        public var personalRank: UInt8
        public var names: Int
        public var accepted: Int
        public var empty: Judged
        public var full: Judged
        public var poisons: [Poison]
        /// The poison typed over and over: printed, not gated.
        public var limits: [Poison]
        /// The corpus judged with the lexicon empty and full, when given.
        public var corpus: (empty: Evaluation.Results, full: Evaluation.Results)?

        /// Of the names typed in the other layout, the share switched back.
        public var recall: Double { full.all.recall }

        /// What `perekey-eval personal` fails on: a false switch of a
        /// personal word, a correction of one, poison accepted, a category
        /// of the corpus that got worse. Recall is a target, not a gate.
        public var failures: [String] {
            var failures: [String] = []
            if full.all.falseSwitches > 0 { failures.append("\(full.all.falseSwitches) false switches of personal words") }
            if full.accepted.wrongCorrections > 0 {
                failures.append("\(full.accepted.wrongCorrections) corrections of accepted words")
            }
            for poison in poisons where poison.accepted > 0 {
                failures.append("\(poison.accepted) of \(poison.name) accepted")
            }
            if let corpus { failures += PersonalEvaluation.worse(corpus.full, than: corpus.empty) }
            return failures
        }
    }

    public let model: LanguageModel
    /// One layout per language: "ru" and "en".
    public let layouts: [String: LayoutMap]
    public var options: Classifier.Options
    public var personalOptions = PersonalOptions()
    let key: PersonalKey

    public init(model: LanguageModel, layouts: [String: LayoutMap], options: Classifier.Options = .init(),
                seed: UInt64 = 1)
    {
        self.model = model
        self.layouts = layouts
        self.options = options
        var random = SplitMix64(seed: seed ^ 0x5045_5253_4F4E_414C)
        key = PersonalKey(k0: random.next(), k1: random.next())
    }

    /// The days a name is typed on: five times over three days, the least
    /// that accepts it (`PersonalOptions.promoteCount`, `promoteDays`).
    static let nameDays = [0, 0, 2, 4, 4]
    /// The days a poison string is typed on: ten times over five days.
    static let poisonDays = [0, 0, 1, 1, 2, 2, 3, 3, 4, 4]

    // MARK: - The strings

    /// GeoNames names of one word, letters only, capitalized, 3 to 24
    /// letters, unknown to the model in their language: `count` of them, half
    /// Cyrillic, half Latin, picked with `seed`.
    public static func names(cache: String, model: LanguageModel, options: Classifier.Options = .init(),
                             count: Int, seed: UInt64) throws -> [CorpusItem]
    {
        var random = SplitMix64(seed: seed)
        var seen: Set<String> = []
        var byLanguage: [String: [String]] = [:]
        for name in try Corpus.geonames("\(cache)/geonames/cities15000.zip") {
            for token in name.split(separator: " ").map(String.init) {
                guard let language = Corpus.language(of: token), token.allSatisfy(\.isLetter),
                      (3...24).contains(token.count), let first = token.first, first.isUppercase,
                      token.dropFirst().allSatisfy(\.isLowercase), seen.insert(token.lowercased()).inserted,
                      !isKnown(token, language: language, model: model, options: options)
                else { continue }
                byLanguage[language, default: []].append(token)
            }
        }
        var items: [CorpusItem] = []
        for language in ["ru", "en"] {
            let picked = (byLanguage[language] ?? []).sorted().shuffled(using: &random).prefix(count / 2)
            items += picked.map { CorpusItem(category: "personal", language: language, recent: [], text: $0) }
        }
        return items
    }

    /// Known to the model as the classifier counts it (`Classifier.isKnown`).
    static func isKnown(_ word: String, language: String, model: LanguageModel, options: Classifier.Options) -> Bool {
        guard let rank = model.language(language)?.rank(of: ModelFormat.Fingerprint.of(word.unicodeScalars,
                                                                                         folded: true))
        else { return false }
        return rank == 0 || rank >= options.knownRank
    }

    /// Words of Tatoeba the model knows, the most frequent first: `count`
    /// per language, 4 letters or more.
    static func commonWords(cache: String, model: LanguageModel, options: Classifier.Options,
                            count: Int) throws -> [String: [String]]
    {
        var words: [String: [String]] = [:]
        for (language, file) in [("ru", "rus"), ("en", "eng")] {
            var random = SplitMix64(seed: 1)
            var counts: [String: Int] = [:]
            for sentence in try Corpus.tatoeba("\(cache)/tatoeba/\(file)_sentences.tsv.bz2", random: &random)
                .prefix(200_000)
            {
                for token in sentence.lowercased().split(separator: " ") {
                    let word = String(token.filter(\.isLetter))
                    guard word.count >= 4, Corpus.language(of: word) == language else { continue }
                    counts[word, default: 0] += 1
                }
            }
            words[language] = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map(\.key).filter { isKnown($0, language: language, model: model, options: options) }
                .prefix(count).map { $0 }
        }
        return words
    }

    // MARK: - Running

    /// Phase 1 and 2, and the corpus when given.
    public func run(names: [CorpusItem], cache: String, corpus: [CorpusItem]?, poisonCount: Int = 100) throws -> Results {
        let classifier = Classifier(model: model, options: options)

        // Phase 1: the names typed and kept on their days.
        var typings: [Typing] = []
        for (index, item) in names.enumerated() {
            guard let own = layouts[item.language], let other = otherLayout(item.language),
                  let strokes = strokes(item.text, in: own)
            else { continue }
            for day in Self.nameDays {
                typings.append(Typing(day: index % 7 + day, strokes: strokes, result: own, rivals: [other],
                                      decided: true))
            }
        }
        let lexicon = learn(typings, classifier: classifier).snapshot(key: key)
        let acceptedNames = names.filter { item in
            lexicon.containsWord(key.fingerprint(ofWord: item.text, language: item.language))
        }

        // Phase 2: judged as the corpus is, with the lexicon empty and full.
        var evaluation = Evaluation(model: model, layouts: layouts, options: options)
        let empty = judge(names, acceptedNames, evaluation)
        evaluation.personal = lexicon
        let full = judge(names, acceptedNames, evaluation)

        var corpusResults: (Evaluation.Results, Evaluation.Results)?
        if let corpus {
            var plain = evaluation
            plain.personal = .off
            corpusResults = (plain.run(corpus, maxErrors: 0), evaluation.run(corpus, maxErrors: 0))
        }

        let poison = try poisons(cache: cache, count: poisonCount, classifier: classifier)
        return Results(personalRank: options.personalRank, names: names.count, accepted: acceptedNames.count,
                       empty: empty, full: full, poisons: poison.gated, limits: poison.limits,
                       corpus: corpusResults)
    }

    /// Phase 1 with every rank of `ranks`.
    public func sweep(ranks: [UInt8], names: [CorpusItem], cache: String, corpus: [CorpusItem]?) throws -> [Results] {
        try ranks.map { rank in
            var evaluation = self
            evaluation.options.personalRank = rank
            return try evaluation.run(names: names, cache: cache, corpus: corpus)
        }
    }

    private func otherLayout(_ language: String) -> LayoutMap? {
        layouts.first { $0.key != language }?.value
    }

    private func strokes(_ text: String, in layout: LayoutMap) -> [KeyStroke]? {
        var strokes: [KeyStroke] = []
        for character in text {
            guard let stroke = layout.stroke(for: character) else { return nil }
            strokes.append(stroke)
        }
        return strokes
    }

    private func judge(_ names: [CorpusItem], _ accepted: [CorpusItem], _ evaluation: Evaluation) -> Judged {
        func category(_ items: [CorpusItem]) -> Evaluation.Category {
            evaluation.run(items, maxErrors: 0).categories.first ?? Evaluation.Category(name: "personal")
        }
        return Judged(all: category(names), accepted: category(accepted))
    }

    /// The model after the typings, day by day: what each day observes goes
    /// in one batch, judged with the lexicon as it was that morning.
    func learn(_ typings: [Typing], classifier: Classifier) -> PersonalLexiconModel {
        let corrector = TypoCorrector(model: model)
        var counted = PersonalLexiconModel(options: personalOptions)
        var lexicon = counted.snapshot(key: key)
        let days = Dictionary(grouping: typings, by: \.day)
        for day in days.keys.sorted() {
            var observations: [PersonalObservation] = []
            for typing in days[day] ?? [] {
                if typing.decided, let rival = typing.rivals.first {
                    let decision = classifier.classify(typing.strokes, typed: typing.result, other: rival,
                                                       context: Classifier.Context(recent: RecentLanguages(),
                                                                                   personal: lexicon))
                    guard decision.verdict == .keep else { continue }
                }
                if let observation = classifier.personalObservation(
                    typing.strokes, in: typing.result, rivals: typing.rivals, personal: lexicon, corrector: corrector,
                    sentenceStart: false
                ) {
                    observations.append(observation)
                }
            }
            if counted.record(PersonalTally(observations: observations, generation: counted.generation), day: day) {
                lexicon = counted.snapshot(key: key)
            }
        }
        return counted
    }

    /// The poison, `count` strings per language of each kind. Gated (plan
    /// 7.2, item 9, gives a frequency for (a) only): (a) common words left in
    /// the other layout, each ten times over five days; (b) random strings
    /// and (c) typos of known words as they come, a stream of strings each
    /// typed once over 30 days. The known limit, printed and not gated: (b)
    /// and (c) each typed ten times over five days too.
    func poisons(cache: String, count: Int, classifier: Classifier) throws -> (gated: [Poison], limits: [Poison]) {
        var random = SplitMix64(seed: 7)
        let common = try Self.commonWords(cache: cache, model: model, options: options, count: count)
        var words: [(String, String)] = []
        var strings: [(String, String)] = []
        var typos: [(String, String)] = []
        var streamStrings: [(String, String)] = []
        var streamTypos: [(String, String)] = []
        for language in ["ru", "en"] {
            let known = common[language] ?? []
            words += known.map { ($0, language) }
            let alphabet = Array(Synthetic.letterRows[language]!.map(\.letters).joined())
            func randomString() -> String {
                String((0..<(5 + Int(random.next() % 6))).map { _ in Synthetic.pick(alphabet, &random) })
            }
            strings += (0..<count).map { _ in (randomString(), language) }
            streamStrings += (0..<count * 10).map { _ in (randomString(), language) }
            func typo() -> String? {
                guard !known.isEmpty else { return nil }
                let word = known[Int(random.next() % UInt64(known.count))]
                guard let typo = Synthetic.typo(of: word, language: language, random: &random),
                      !Self.isKnown(typo, language: language, model: model, options: options)
                else { return nil }
                return typo
            }
            var distinct: Set<String> = []
            var attempts = 0
            while distinct.count < count, attempts < count * 20 {
                attempts += 1
                if let typo = typo() { distinct.insert(typo) }
            }
            typos += distinct.sorted().map { ($0, language) }
            // As typos come: a frequent word's typo may come again.
            attempts = 0
            var stream: [(String, String)] = []
            while stream.count < count * 10, attempts < count * 200 {
                attempts += 1
                if let typo = typo() { stream.append((typo, language)) }
            }
            streamTypos += stream
        }
        let streamDays = { (index: Int, total: Int) in index * 30 / max(total, 1) }
        let gated = [
            poison("(a) common words left in the other layout, 10 times over 5 days", words, wrongLayout: true,
                   days: { _ in Self.poisonDays }, classifier: classifier),
            poison("(b) random strings, each once over 30 days", streamStrings, wrongLayout: false,
                   days: { [streamDays($0, streamStrings.count)] }, classifier: classifier),
            poison("(c) typos of known words, each as it comes over 30 days", streamTypos, wrongLayout: false,
                   days: { [streamDays($0, streamTypos.count)] }, classifier: classifier),
        ]
        let limits = [
            poison("(b) random strings, 10 times over 5 days", strings, wrongLayout: false,
                   days: { _ in Self.poisonDays }, classifier: classifier),
            poison("(c) typos of known words, 10 times over 5 days", typos, wrongLayout: false,
                   days: { _ in Self.poisonDays }, classifier: classifier),
        ]
        return (gated, limits)
    }

    /// How many distinct `strings` the lexicon accepts after they are typed
    /// on `days(index)`, observed whatever the classifier decides. A common
    /// word is typed on its own keys in the other layout and left there;
    /// the rest stay in their own one. `rare`: of those accepted, how many
    /// the model has as rare forms (rank under `knownRank`).
    private func poison(_ name: String, _ strings: [(String, String)], wrongLayout: Bool, days: (Int) -> [Int],
                        classifier: Classifier) -> Poison
    {
        var typings: [Typing] = []
        var accepted: [String: (fingerprint: UInt64, rare: Bool)] = [:]
        for (index, (text, language)) in strings.enumerated() {
            guard let own = layouts[language], let other = otherLayout(language),
                  let strokes = strokes(text, in: own)
            else { continue }
            let result = wrongLayout ? other : own
            let rival = wrongLayout ? own : other
            for day in days(index) {
                typings.append(Typing(day: day, strokes: strokes, result: result, rivals: [rival], decided: false))
            }
            let typed = strokes.compactMap { result.text(for: $0) }.joined()
            let rank = model.language(result.language ?? "")?.rank(of: ModelFormat.Fingerprint.of(typed.unicodeScalars,
                                                                                                   folded: true))
            accepted[typed] = (key.fingerprint(ofWord: typed, language: result.language ?? ""), rank != nil)
        }
        let lexicon = learn(typings, classifier: classifier).snapshot(key: key)
        let found = accepted.values.filter { lexicon.containsWord($0.fingerprint) }
        return Poison(name: name, strings: accepted.count, accepted: found.count, rare: found.filter(\.rare).count)
    }

    /// The categories of `full` that are worse than in `empty`: more false
    /// switches or wrong corrections, fewer switches back or typos fixed.
    static func worse(_ full: Evaluation.Results, than empty: Evaluation.Results) -> [String] {
        var found: [String] = []
        for category in full.categories {
            guard let before = empty.categories.first(where: { $0.name == category.name }) else { continue }
            if category.falseSwitches > before.falseSwitches {
                found.append("\(category.name): false switches \(before.falseSwitches) → \(category.falseSwitches)")
            }
            if category.switches < before.switches {
                found.append("\(category.name): switched back \(before.switches) → \(category.switches)")
            }
            if category.wrongCorrections > before.wrongCorrections {
                found.append("\(category.name): wrong corrections \(before.wrongCorrections) → \(category.wrongCorrections)")
            }
            if category.typosFixed < before.typosFixed {
                found.append("\(category.name): typos fixed \(before.typosFixed) → \(category.typosFixed)")
            }
        }
        return found
    }

    // MARK: - Report

    public static func report(_ results: Results) -> String {
        func line(_ label: String, _ category: Evaluation.Category) -> String {
            String(format: "  %-16@ %5d names  recall %6.2f%% (%d of %d)  false switches %d of %d  wrong corrections %d of %d\n",
                   label as NSString, category.switchWords, category.recall * 100, category.switches,
                   category.switchWords, category.falseSwitches, category.keepWords, category.wrongCorrections,
                   category.checkedWords)
        }
        var text = String(format: "personal rank %d: %d names unknown to the model, %d accepted (%.1f%%)\n",
                          Int(results.personalRank), results.names, results.accepted,
                          results.names > 0 ? Double(results.accepted) / Double(results.names) * 100 : 0)
        text += line("lexicon empty", results.empty.all)
        text += line("lexicon full", results.full.all)
        text += line("accepted, empty", results.empty.accepted)
        text += line("accepted, full", results.full.accepted)
        text += "poison, observed whatever the classifier decided:\n"
        for poison in results.poisons {
            text += String(format: "  %-62@ %4d accepted of %d\n", poison.name as NSString, poison.accepted,
                           poison.strings)
        }
        text += "known limit, not gated (docs/classifier.md, «Личный словарь»):\n"
        for poison in results.limits {
            text += String(format: "  %-62@ %4d accepted of %d, %d of them rare forms of the model\n",
                           poison.name as NSString, poison.accepted, poison.strings, poison.rare)
        }
        if let corpus = results.corpus {
            text += "corpus with the lexicon empty → full:\n"
            text += "  category   false switches    switched back    wrong corrections    typos fixed\n"
            for category in corpus.full.categories + [corpus.full.total] {
                let before = category.name == "all" ? corpus.empty.total
                    : corpus.empty.categories.first { $0.name == category.name } ?? category
                text += String(format: "  %-9@ %7d → %-7d %7d → %-7d %9d → %-7d %7d → %-7d\n", category.name as NSString,
                               before.falseSwitches, category.falseSwitches, before.switches, category.switches,
                               before.wrongCorrections, category.wrongCorrections, before.typosFixed,
                               category.typosFixed)
            }
        }
        let failures = results.failures
        text += failures.isEmpty ? "no false switch, no correction of a personal word, no poison, no category worse\n"
            : "FAIL: " + failures.joined(separator: "; ") + "\n"
        if results.recall < 0.9 {
            text += String(format: "recall of personal words %.2f%% is under the target of 90%%\n", results.recall * 100)
        }
        return text
    }

    public static func json(_ results: Results) -> [String: Any] {
        func category(_ category: Evaluation.Category) -> [String: Any] {
            ["keepWords": category.keepWords, "falseSwitches": category.falseSwitches,
             "switchWords": category.switchWords, "switches": category.switches,
             "checkedWords": category.checkedWords, "wrongCorrections": category.wrongCorrections]
        }
        var json: [String: Any] = [
            "personalRank": Int(results.personalRank), "names": results.names, "accepted": results.accepted,
            "empty": category(results.empty.all), "full": category(results.full.all),
            "acceptedEmpty": category(results.empty.accepted), "acceptedFull": category(results.full.accepted),
            "poisons": results.poisons.map { ["name": $0.name, "strings": $0.strings, "accepted": $0.accepted] },
            "limits": results.limits.map {
                ["name": $0.name, "strings": $0.strings, "accepted": $0.accepted, "rare": $0.rare]
            },
            "failures": results.failures,
        ]
        if let corpus = results.corpus {
            json["corpus"] = corpus.full.categories.map { full -> [String: Any] in
                let empty = corpus.empty.categories.first { $0.name == full.name } ?? full
                return ["name": full.name, "empty": category(empty), "full": category(full)]
            }
        }
        return json
    }
}
