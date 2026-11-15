// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyModelKit

/// Builds the cases of a correction suite (docs/eval.md, «Наборы правок
/// слова»): sentences of a corpus in which the person's fingers make one kind
/// of slip, the slip the corrections of Perekey are there for.
///
/// Like `SuiteBuilder`, two passes. The first reads the source once and keeps,
/// for each scenario, the sentences that come first in the seeded order and
/// can give a case (`CorrectionEdits.prefilter`). The second parses them in
/// that order, makes the slip and builds the case until the scenario has the
/// tokens its tier asks for.
///
/// One layout throughout: the person aims at the layout of the sentence and
/// does not slip on it. The only mistake of a case is the slip, so Null gets
/// wrong exactly the tokens the slip touched, and `err` comes from Null as
/// in the layout scenarios.
public struct CorrectionBuilder {
    /// Numbers of the sampling. A first guess, not a measurement.
    public struct Options: Hashable, Sendable {
        /// Sentences kept for each scenario, as a multiple of the tier's
        /// tokens. A sentence is at least a token, and many give no case
        /// (no word with a slip in it).
        public var poolFactor = 6

        public init() {}
    }

    public let manifest: SuiteManifest
    public let library: LayoutLibrary
    public let options: Options
    let correction: SuiteManifest.Correction
    let scorer: Scorer
    let typist = Typist()

    public init(manifest: SuiteManifest, library: LayoutLibrary, options: Options = Options()) throws {
        guard let correction = manifest.correction else {
            throw EvalError.input("\(manifest.suite): not a correction suite")
        }
        self.manifest = manifest
        self.library = library
        self.options = options
        self.correction = correction
        scorer = Scorer(library: library)
    }

    /// The token error a kind of correction puts in.
    static func error(of kind: SuiteManifest.Correction.Kind) -> TokenError {
        switch kind {
        case .typoSynth, .typoReal: .typo
        case .yo: .yo
        case .hyphen: .hyphen
        case .doublecap: .doublecap
        case .capslock: .caps
        case .abbrev: .abbrev
        }
    }

    public func build(tier: SuiteManifest.Tier, cache: String) throws -> SuiteBuilder.Output {
        var cases: [EvalCase] = []
        let report = try build(tier: tier, cache: cache) { cases.append($0) }
        return SuiteBuilder.Output(cases: cases, report: report)
    }

    /// The same, one case at a time to `emit`.
    public func build(tier: SuiteManifest.Tier, cache: String, emit: (EvalCase) throws -> Void) throws -> BuildReport {
        let sets = try manifest.layoutSets.map { try LayoutSet(names: $0, library: library) }
        let budget = manifest.tiers.tokens(tier)
        var report = BuildReport(suite: manifest.suite, tier: tier.rawValue, epoch: manifest.epoch, seed: manifest.seed)
        let ordered: [String: [Candidate]]
        switch correction.kind {
        case .typoReal: ordered = try pairCandidates(budget: budget, cache: cache, report: &report)
        default: ordered = try sentenceCandidates(budget: budget, cache: cache, report: &report)
        }
        report.pooled = ordered.values.map(\.count).max() ?? 0

        var seen = Set<UInt64>()
        var built = Set<String>()
        for scenario in manifest.scenarios {
            var remaining = budget
            for candidate in ordered[scenario] ?? [] {
                if remaining <= 0 { break }
                report.examined += 1
                let set = sets[Int(FNV1a.hash64(candidate.ref) % UInt64(sets.count))]
                switch try makeCase(candidate, scenario: scenario, set: set) {
                case let .failure(drop):
                    report.scenarios[scenario, default: .init()].drops[drop.rawValue, default: 0] += 1
                case let .success(item):
                    guard seen.insert(FNV1a.hash64(scenario + "\u{1F}" + item.want + "\u{1F}" + candidate.typedKey)).inserted
                    else {
                        report.scenarios[scenario, default: .init()].drops[Drop.duplicate.rawValue, default: 0] += 1
                        continue
                    }
                    built.insert(candidate.ref)
                    let count = item.tokens?.count ?? 0
                    remaining -= count
                    try emit(item)
                    var stats = report.scenarios[scenario, default: .init()]
                    stats.cases += 1
                    stats.tokens += count
                    stats.layoutErrors += item.tokens?.filter { $0.err == .layout }.count ?? 0
                    stats.errors = (stats.errors ?? 0) + (item.tokens?.filter { $0.err != .none }.count ?? 0)
                    if item.split == .dev { stats.dev += 1 } else { stats.test += 1 }
                    report.scenarios[scenario] = stats
                }
            }
            var stats = report.scenarios[scenario] ?? .init()
            stats.shortfall = max(remaining, 0)
            report.scenarios[scenario] = stats
        }
        report.built = built.count
        return report
    }

    // MARK: - Candidates

    /// A unit that may become a case: the sentence as meant, and the slip when
    /// it is given by the source (the pairs of real typos).
    struct Candidate {
        var rank: UInt64
        var ref: String
        var text: String
        var slip: Slip = .made

        /// What tells two candidates with one sentence apart.
        var typedKey: String {
            switch slip {
            case .made: ""
            case let .replace(word, with): "\(word)>\(with)"
            case let .typed(text): text
            }
        }
    }

    enum Slip {
        /// The edit of the kind makes it.
        case made
        /// The first token with this word (case folded) is typed as the other word.
        case replace(word: String, with: String)
        /// The sentence as typed, given by the source.
        case typed(String)
    }

    /// The sentences of a Tatoeba or Stack Exchange source, by scenario, in the order of the draw.
    func sentenceCandidates(budget: Int, cache: String, report: inout BuildReport) throws -> [String: [Candidate]] {
        let capacity = budget * options.poolFactor
        var pools: [String: [BoundedPool<SuiteBuilder.Pooled>]] = [:]
        for scenario in manifest.scenarios {
            pools[scenario] = manifest.sources.map { _ in BoundedPool<SuiteBuilder.Pooled>(capacity: capacity) }
        }
        var units = 0
        try SourceReader.forEachUnit(manifest, cache: cache) { source, refHash, pending in
            units += 1
            let rank = SuiteBuilder.rank(refHash: refHash, seed: manifest.seed, epoch: manifest.epoch)
            var unit: SourceUnit?
            for scenario in manifest.scenarios {
                if let worst = pools[scenario]?[source].worstKept, rank > worst.rank { continue }
                let made = unit ?? pending.make()
                unit = made
                guard CorrectionEdits.prefilter(correction.kind, scenario: scenario, text: made.text) else { continue }
                pools[scenario]?[source].insert(SuiteBuilder.Pooled(rank: rank, ref: made.ref, text: made.text),
                                                by: SuiteBuilder.order)
            }
        }
        report.units = units
        var result: [String: [Candidate]] = [:]
        for scenario in manifest.scenarios {
            var lists = (pools[scenario] ?? []).map { $0.sorted(by: SuiteBuilder.order) }
            if manifest.effectiveBalance, let smallest = lists.map(\.count).min() {
                lists = lists.map { Array($0.prefix(smallest)) }
            }
            result[scenario] = SuiteBuilder.interleaved(lists).map { Candidate(rank: $0.rank, ref: $0.ref, text: $0.text) }
        }
        return result
    }

    // MARK: - Cases

    func makeCase(_ candidate: Candidate, scenario: String, set: LayoutSet) throws -> Result<EvalCase, Drop> {
        let parsed: ParsedUnit
        switch UnitParser.parse(candidate.text, manifest: manifest, set: set, library: library) {
        case let .failure(drop): return .failure(drop)
        case let .success(unit): parsed = unit
        }
        guard parsed.scripts.count == 1, let script = parsed.firstScript, let layout = set.layout(for: script) else {
            return .failure(.mixedScript)
        }
        let language = set.code(for: script)
        var random = SplitMix64(seed: FNV1a.hash64(candidate.ref + "\u{1F}slip")
            ^ (UInt64(truncatingIfNeeded: manifest.seed + manifest.epoch) &* 0x9E37_79B9_7F4A_7C15))
        let edited: Edited
        switch candidate.slip {
        case .made:
            switch CorrectionEdits.apply(correction.kind, scenario: scenario, tokens: parsed.tokens, language: language,
                                         weights: correction.weights, random: &random)
            {
            case let .failure(drop): return .failure(drop)
            case let .success(value): edited = value
            }
        case let .replace(word, with):
            switch PairEdits.replace(word: word, with: with, tokens: parsed.tokens) {
            case let .failure(drop): return .failure(drop)
            case let .success(value): edited = value
            }
        case let .typed(text):
            switch PairEdits.typed(text, meant: parsed, manifest: manifest, set: set, library: library) {
            case let .failure(drop): return .failure(drop)
            case let .success(value): edited = value
            }
        }

        guard let map = library[layout] else { return .failure(.unprintable) }
        let trailer = manifest.effectiveEnd == .space ? " " : ""
        let typedText = edited.text + trailer
        for character in typedText where LayoutLibrary.printableStroke(character, in: map) == nil {
            return .failure(.unprintable)
        }
        var steps: [Step] = []
        if correction.kind == .capslock { steps.append(.capsLock(true)) }
        steps.append(.type(typedText, on: layout))
        if manifest.effectiveEnd == .return { steps.append(.key(.return, n: nil, mods: nil)) }

        var tokens: [TokenSpec] = []
        for (index, token) in parsed.tokens.enumerated() {
            var tags = edited.tags[index]
            if token.code { tags.append("code") }
            tokens.append(TokenSpec(t: token.text, lang: set.code(for: token.scripts.first), err: .none,
                                    tags: tags.isEmpty ? nil : tags))
        }
        var caseTags = manifest.tags ?? []
        if candidate.slip.isStandalone(tokens: parsed.tokens.count) { caseTags.append("alone") }
        var env: Env?
        if manifest.effectiveSettings != EvalSettings.defaultPreset { env = Env(settings: manifest.effectiveSettings) }
        var item = EvalCase(
            suite: manifest.suite, scenario: scenario,
            split: ScenarioBuilder.split(suite: manifest.suite, key: candidate.ref, dev: manifest.split.dev),
            epoch: manifest.epoch, layouts: set.names, start: layout, env: env, script: steps,
            want: tokens.map(\.t).joined(separator: " "), tokens: tokens,
            fold: manifest.fold?.compactMap(EvalCase.Fold.init(rawValue:)),
            tags: caseTags.isEmpty ? nil : caseTags,
            meta: ["ref": .string(candidate.ref), "source": .string(ScenarioBuilder.sourceName(manifest))]
        )
        if item.fold?.isEmpty == true { item.fold = nil }
        item = try item.identified()
        // `err` comes from Null: it is wrong where the slip is.
        let events = try typist.events(for: item, layouts: library)
        let setup = try CaseSetup(item: item, library: library, classifier: nil)
        let null = try SystemName.null.play(setup, events: events)
        let wrong = ScenarioBuilder.wrongTokens(item, null: null, scorer: scorer)
        if scenario == "keep" {
            if !wrong.isEmpty { return .failure(.nullWrongInClean) }
        } else {
            if wrong.isEmpty { return .failure(.nullRight) }
            let error = Self.error(of: correction.kind)
            for index in wrong { item.tokens?[index].err = error }
        }
        return .success(item)
    }
}

extension CorrectionBuilder.Slip {
    /// A single word given by a pair, with no sentence around it.
    func isStandalone(tokens: Int) -> Bool {
        if case .made = self { return false }
        return tokens == 1
    }
}
