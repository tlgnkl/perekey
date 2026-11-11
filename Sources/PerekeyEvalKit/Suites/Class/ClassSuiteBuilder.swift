// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyModelKit

/// Builds the cases of a class suite (docs/eval.md, «Наборы классов»): the
/// units are words that a rule picks out, each typed in every scenario of
/// the manifest, one word to a case. The same scenarios, parts and `err`
/// as a corpus suite, because the same `ScenarioBuilder` makes them.
struct ClassSuiteBuilder {
    let manifest: SuiteManifest
    let library: LayoutLibrary
    let context: ClassContext
    let rules: ClassRules.Options

    init(manifest: SuiteManifest, library: LayoutLibrary, context: ClassContext, rules: ClassRules.Options = .init()) {
        self.manifest = manifest
        self.library = library
        self.context = context
        self.rules = rules
    }

    func build(tier: SuiteManifest.Tier) throws -> SuiteBuilder.Output {
        guard let spec = manifest.classSpec else { throw EvalError.input("\(manifest.suite): no class rule") }
        let sets = try manifest.layoutSets.map { try LayoutSet(names: $0, library: library) }
        for language in spec.languages where language != "en" {
            let known = sets.map(\.language)
            guard known.contains(language) else {
                throw EvalError.input("\(manifest.suite): language \(language) is in no layout set of the manifest")
            }
        }
        var report = BuildReport(suite: manifest.suite, tier: tier.rawValue, epoch: manifest.epoch, seed: manifest.seed)
        let produced = try ClassRules(manifest: manifest, spec: spec, context: context, library: library, sets: sets,
                                      tier: tier, options: rules).run()

        // Merge by text, as written («if» and «If» are two items, one part): the weight is the greatest, the classes add up.
        var merged: [String: ClassItem] = [:]
        for item in produced.derived + produced.seeds {
            if var known = merged[item.text] {
                known.weight = max(known.weight, item.weight)
                known.tags = Set(known.tags + item.tags).sorted()  // a Set has no stable order between runs
                merged[item.text] = known
            } else {
                var first = item
                first.tags = Set(item.tags).sorted()
                merged[item.text] = first
            }
        }
        let derivedKeys = Set(produced.derived.map(\.key))
        let seedKeys = Set(produced.seeds.map(\.key))
        // The most frequent first; the draw of the seed and the epoch decides between equals, then the text. Seeds stay
        // whatever the cap.
        let order = { (a: ClassItem, b: ClassItem) -> Bool in
            if a.weight != b.weight { return a.weight > b.weight }
            let (x, y) = (SuiteBuilder.rank(ref: a.key, seed: manifest.seed, epoch: manifest.epoch),
                          SuiteBuilder.rank(ref: b.key, seed: manifest.seed, epoch: manifest.epoch))
            return x != y ? x < y : a.text < b.text
        }
        let sorted = merged.values.sorted(by: order)
        let budget = manifest.tiers.tokens(tier)
        var taken = 0
        var chosen: [ClassItem] = []
        for item in sorted {
            if item.tags.contains("seed") {
                chosen.append(item)
            } else if taken < budget {
                taken += 1
                chosen.append(item)
            }
        }
        report.units = sorted.count
        report.pooled = chosen.count
        report.classes = ClassReport(rule: spec.rule.rawValue, derived: derivedKeys.count, seeds: seedKeys.count,
                                     seedsFound: seedKeys.intersection(derivedKeys).count,
                                     cut: sorted.count - chosen.count, files: produced.files)
        var tagCounts: [String: Int] = [:]
        for item in chosen { for tag in item.tags { tagCounts[tag, default: 0] += 1 } }
        report.classes?.tags = tagCounts

        let wantsWarmup = manifest.scenarios.contains { $0.hasSuffix(".warm") }
        let warmups = wantsWarmup ? try warmupPool(sets: sets) : [:]
        report.warmupPool = ["cyrillic": warmups[.cyrillic]?.count ?? 0, "latin": warmups[.latin]?.count ?? 0]
        let filter = SuiteManifest.Filter(minTokens: SuiteBuilder.Options().warmupMinTokens,
                                          maxTokens: SuiteBuilder.Options().warmupMaxTokens)

        let builder = ScenarioBuilder(manifest: manifest, library: library)
        var cases: [EvalCase] = []
        for entry in chosen {
            report.examined += 1
            let key = entry.key
            let set = sets[Int(FNV1a.hash64(key) % UInt64(sets.count))]
            let parsed: ParsedUnit
            switch UnitParser.parse(entry.text, manifest: manifest, set: set, library: library,
                                    aim: entry.aim == .cyrillic ? set.cyrillic : set.latin, lettersOptional: true)
            {
            case let .failure(drop):
                report.drops[drop.rawValue, default: 0] += 1
                if drop == .unprintable {
                    for character in Set(UnitParser.unprintableCharacters(entry.text, manifest: manifest, set: set,
                                                                          library: library))
                    {
                        report.unprintable[SuiteBuilder.describe(character), default: 0] += 1
                    }
                }
                continue
            case let .success(unit):
                parsed = unit
            }
            report.built += 1
            let warmup = SuiteBuilder.warmup(for: parsed, ref: key, pool: warmups, manifest: manifest, library: library,
                                             filter: filter)
            for scenario in manifest.scenarios {
                switch try builder.build(ref: key, unit: parsed, scenario: scenario, warmup: warmup) {
                case let .failure(drop):
                    report.scenarios[scenario, default: .init()].drops[drop.rawValue, default: 0] += 1
                case var .success(item):
                    for index in item.tokens?.indices ?? 0..<0 {
                        item.tokens?[index].w = (entry.weight * 1_000_000).rounded() / 1_000_000
                        let tags = (item.tokens?[index].tags ?? []) + entry.tags
                        item.tokens?[index].tags = tags
                    }
                    cases.append(item)
                    let count = item.tokens?.count ?? 0
                    var stats = report.scenarios[scenario, default: .init()]
                    stats.cases += 1
                    stats.tokens += count
                    stats.layoutErrors += item.tokens?.filter { $0.err == .layout }.count ?? 0
                    if item.split == .dev { stats.dev += 1 } else { stats.test += 1 }
                    report.scenarios[scenario] = stats
                }
            }
        }
        for scenario in manifest.scenarios { report.scenarios[scenario, default: .init()] = report.scenarios[scenario] ?? .init() }
        return SuiteBuilder.Output(cases: cases, report: report)
    }

    /// The sentences to warm up with, read once for all the suites that name the same files.
    func warmupPool(sets: [LayoutSet]) throws -> [LetterScript: [SuiteBuilder.Pooled]] {
        let key = ([manifest.source, String(manifest.seed + manifest.epoch)] + sets.map { $0.names.joined(separator: "+") })
            .joined(separator: "|")
        if let known = context.warmups[key] { return known }
        // The first 20 000 units of the draw are many times the 2000 sentences a pool keeps.
        var pools = manifest.sources.map { _ in BoundedPool<SuiteBuilder.Pooled>(capacity: 20_000) }
        try SourceReader.forEachUnit(manifest, cache: context.cache) { source, refHash, pending in
            let rank = SuiteBuilder.rank(refHash: refHash, seed: manifest.seed, epoch: manifest.epoch)
            if let worst = pools[source].worstKept, rank > worst.rank { return }
            let unit = pending.make()
            pools[source].insert(SuiteBuilder.Pooled(rank: rank, ref: unit.ref, text: unit.text), by: SuiteBuilder.order)
        }
        let lists = pools.map { $0.sorted(by: SuiteBuilder.order) }
        let ordered = SuiteBuilder.interleaved(lists)
        let filter = SuiteManifest.Filter(minTokens: SuiteBuilder.Options().warmupMinTokens,
                                          maxTokens: SuiteBuilder.Options().warmupMaxTokens)
        let found = SuiteBuilder(manifest: manifest, library: library).warmupSentences(in: ordered, sets: sets, filter: filter)
        context.warmups[key] = found
        return found
    }
}

/// What a class build says about its rule: counts only, no words.
public struct ClassReport: Hashable, Sendable, Codable {
    public var rule: String
    /// Items the rule derived.
    public var derived: Int
    /// Items of the seed list, and the ones the rule found as well.
    public var seeds: Int
    public var seedsFound: Int
    /// Derived items left out by the tier's cap.
    public var cut: Int
    /// The cache files the rule read and their SHA-256.
    public var files: [String: String]
    /// Items by class.
    public var tags: [String: Int] = [:]

    init(rule: String, derived: Int, seeds: Int, seedsFound: Int, cut: Int, files: [String: String]) {
        self.rule = rule
        self.derived = derived
        self.seeds = seeds
        self.seedsFound = seedsFound
        self.cut = cut
        self.files = files
    }
}
