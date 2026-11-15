// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyModelKit

/// Builds the cases of a corpus suite from its source (docs/eval.md,
/// «Сборщик наборов»). Two passes over the source's units: the first reads
/// all of them, drops what cannot be a case and keeps the units that come
/// first in the seeded order, and the sentences to warm up with; the second
/// builds the scenarios of the kept units, in that order, until every
/// scenario has the tokens its tier asks for.
public struct SuiteBuilder {
    /// Numbers of the sampling. A first guess, not a measurement.
    public struct Options: Hashable, Sendable {
        /// The longest sentence to warm up with, in tokens. A short one keeps
        /// the case about the measured part.
        public var warmupMaxTokens = 8
        public var warmupMinTokens = 3
        /// How many warm-up sentences to keep for each script.
        public var warmupPool = 2000
        /// Units kept for the draw, as a multiple of the tier's tokens: a
        /// sentence is at least a token, and many drop or give no case in
        /// `stuck` and `clean.toggle`. Memory: a full tier keeps this many
        /// sentences of the source at once.
        public var poolFactor = 4

        public init() {}
    }

    public let manifest: SuiteManifest
    public let library: LayoutLibrary
    public let options: Options

    public init(manifest: SuiteManifest, library: LayoutLibrary, options: Options = Options()) {
        self.manifest = manifest
        self.library = library
        self.options = options
    }

    /// The cases of one suite and what happened to the units.
    public struct Output: Sendable {
        public var cases: [EvalCase]
        public var report: BuildReport
    }

    struct Pooled: Hashable {
        var rank: UInt64
        var ref: String
        var text: String
    }

    /// The place of a unit in the order of the draw: `SplitMix64` seeded by
    /// the manifest's seed plus the epoch, and the unit's reference.
    public static func rank(ref: String, seed: Int, epoch: Int) -> UInt64 {
        rank(refHash: FNV1a.hash64(ref), seed: seed, epoch: epoch)
    }

    static func rank(refHash: UInt64, seed: Int, epoch: Int) -> UInt64 {
        var generator = SplitMix64(seed: refHash ^ (UInt64(truncatingIfNeeded: seed + epoch) &* 0x9E37_79B9_7F4A_7C15))
        return generator.next()
    }

    /// Reads the source from `cache` and builds the cases of `tier`.
    public func build(tier: SuiteManifest.Tier, cache: String) throws -> Output {
        var cases: [EvalCase] = []
        let report = try build(tier: tier, cache: cache) { cases.append($0) }
        return Output(cases: cases, report: report)
    }

    /// The same, one case at a time to `emit`: a suite of a gigabyte is not held whole.
    public func build(tier: SuiteManifest.Tier, cache: String, emit: (EvalCase) throws -> Void) throws -> BuildReport {
        let sets = try manifest.layoutSets.map { try LayoutSet(names: $0, library: library) }
        let budget = manifest.tiers.tokens(tier)
        var report = BuildReport(suite: manifest.suite, tier: tier.rawValue, epoch: manifest.epoch, seed: manifest.seed)

        // Pass one: the units that come first in the seeded order. Nothing is
        // parsed here, so the kept units are a draw from the whole source and
        // the reasons counted in pass two describe the source.
        // One pool for each source file, so that Russian and English sentences
        // of a Tatoeba suite weigh the same; the files are taken in turn.
        let capacity = budget * options.poolFactor
        var pools = manifest.sources.map { _ in BoundedPool<Pooled>(capacity: capacity) }
        try SourceReader.forEachUnit(manifest, cache: cache) { source, refHash, pending in
            report.units += 1
            let rank = Self.rank(refHash: refHash, seed: manifest.seed, epoch: manifest.epoch)
            if let worst = pools[source].worstKept, rank > worst.rank { return }
            let unit = pending.make()
            pools[source].insert(Pooled(rank: rank, ref: unit.ref, text: unit.text), by: Self.order)
        }
        var lists = pools.map { $0.sorted(by: Self.order) }
        if manifest.effectiveBalance, let smallest = lists.map(\.count).min() {
            lists = lists.map { Array($0.prefix(smallest)) }
        }
        let ordered = Self.interleaved(lists)
        report.pooled = ordered.count

        // Pass two: parse in that order, build until every scenario has its tokens.
        let filter = SuiteManifest.Filter(minTokens: options.warmupMinTokens, maxTokens: options.warmupMaxTokens)
        let wantsWarmup = manifest.scenarios.contains { $0.hasSuffix(".warm") }
        let warmups = wantsWarmup ? warmupSentences(in: ordered, sets: sets, filter: filter) : [:]
        report.warmupPool = ["cyrillic": warmups[.cyrillic]?.count ?? 0, "latin": warmups[.latin]?.count ?? 0]

        let builder = ScenarioBuilder(manifest: manifest, library: library)
        var remaining = Dictionary(uniqueKeysWithValues: manifest.scenarios.map { ($0, budget) })
        var texts = Set<UInt64>()
        for entry in ordered {
            if remaining.values.allSatisfy({ $0 <= 0 }) { break }
            report.examined += 1
            let set = sets[Int(FNV1a.hash64(entry.ref) % UInt64(sets.count))]
            let parsed: ParsedUnit
            switch UnitParser.parse(entry.text, manifest: manifest, set: set, library: library) {
            case let .failure(drop):
                report.drops[drop.rawValue, default: 0] += 1
                if drop == .unprintable {
                    for character in Set(UnitParser.unprintableCharacters(entry.text, manifest: manifest, set: set,
                                                                          library: library))
                    {
                        report.unprintable[Self.describe(character), default: 0] += 1
                    }
                }
                continue
            case let .success(unit):
                guard texts.insert(FNV1a.hash64(unit.tokens.map(\.text).joined(separator: " "))).inserted else {
                    report.drops[Drop.duplicate.rawValue, default: 0] += 1
                    continue
                }
                parsed = unit
            }
            report.built += 1
            let warmup = Self.warmup(for: parsed, ref: entry.ref, pool: warmups, manifest: manifest, library: library,
                                     filter: filter)
            for scenario in manifest.scenarios where remaining[scenario, default: 0] > 0 {
                switch try builder.build(ref: entry.ref, unit: parsed, scenario: scenario, warmup: warmup) {
                case let .failure(drop):
                    report.scenarios[scenario, default: .init()].drops[drop.rawValue, default: 0] += 1
                case let .success(item):
                    let count = item.tokens?.count ?? 0
                    remaining[scenario, default: 0] -= count
                    try emit(item)
                    var stats = report.scenarios[scenario, default: .init()]
                    stats.cases += 1
                    stats.tokens += count
                    stats.layoutErrors += item.tokens?.filter { $0.err == .layout }.count ?? 0
                    if item.split == .dev { stats.dev += 1 } else { stats.test += 1 }
                    report.scenarios[scenario] = stats
                }
            }
        }
        for scenario in manifest.scenarios {
            var stats = report.scenarios[scenario] ?? .init()
            stats.shortfall = max(remaining[scenario, default: 0], 0)
            report.scenarios[scenario] = stats
        }
        return report
    }

    /// Short sentences in one script that every set can type, the first
    /// `warmupPool` of each script in the order of the draw.
    func warmupSentences(in ordered: [Pooled], sets: [LayoutSet], filter: SuiteManifest.Filter)
        -> [LetterScript: [Pooled]]
    {
        var found: [LetterScript: [Pooled]] = [.latin: [], .cyrillic: []]
        for entry in ordered {
            if found.values.allSatisfy({ $0.count >= options.warmupPool }) { break }
            var script: LetterScript?
            var typeable = true
            for set in sets {
                guard case let .success(parsed) = UnitParser.parse(entry.text, manifest: manifest, set: set,
                                                                   library: library, filter: filter),
                    parsed.scripts.count == 1
                else {
                    typeable = false
                    break
                }
                script = parsed.firstScript
            }
            if typeable, let script, found[script, default: []].count < options.warmupPool {
                found[script, default: []].append(entry)
            }
        }
        return found
    }

    /// The first of each list, then the second of each, and so on; a list
    /// that ends drops out.
    static func interleaved<T>(_ lists: [[T]]) -> [T] {
        var result: [T] = []
        var index = 0
        while result.count < lists.reduce(0, { $0 + $1.count }) {
            for list in lists where index < list.count { result.append(list[index]) }
            index += 1
        }
        return result
    }

    /// A character for the report: itself and its code point, `"ʼ U+02BC"`.
    static func describe(_ character: Character) -> String {
        "\(character) " + character.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }

    static func order(_ a: Pooled, _ b: Pooled) -> Bool {
        a.rank != b.rank ? a.rank < b.rank : a.ref < b.ref
    }

    /// The sentence to warm up with: of the script the unit does not start
    /// in, picked by the hash of the unit's reference.
    static func warmup(for unit: ParsedUnit, ref: String, pool: [LetterScript: [Pooled]], manifest: SuiteManifest,
                       library: LayoutLibrary, filter: SuiteManifest.Filter) -> Warmup?
    {
        guard let first = unit.firstScript else { return nil }
        let script: LetterScript = first == .latin ? .cyrillic : .latin
        guard let candidates = pool[script], !candidates.isEmpty else { return nil }
        let pick = candidates[Int(FNV1a.hash64(ref + "\u{1F}warmup") % UInt64(candidates.count))]
        guard case let .success(parsed) = UnitParser.parse(pick.text, manifest: manifest, set: unit.set, library: library,
                                                           filter: filter)
        else { return nil }
        return Warmup(unit: parsed, script: script)
    }
}

/// The best `capacity` items by an order, kept as they come: the buffer is
/// cut back to `capacity` whenever it holds twice that.
struct BoundedPool<Element> {
    let capacity: Int
    private var items: [Element] = []

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    var count: Int { min(items.count, capacity) }

    /// The last item kept at the latest cut: anything that orders after it
    /// cannot enter. Nil before the first cut.
    private(set) var worstKept: Element?

    mutating func insert(_ item: Element, by order: (Element, Element) -> Bool) {
        items.append(item)
        if items.count >= capacity * 2 {
            items.sort(by: order)
            items.removeSubrange(capacity...)
            worstKept = items.last
        }
    }

    func sorted(by order: (Element, Element) -> Bool) -> [Element] {
        Array(items.sorted(by: order).prefix(capacity))
    }
}

/// What happened in a build of one suite: counts only, no words.
public struct BuildReport: Hashable, Sendable, Codable {
    public var suite: String
    public var tier: String
    public var epoch: Int
    public var seed: Int
    /// Units read from the source.
    public var units = 0
    /// Why examined units were dropped, `Drop` raw values.
    public var drops: [String: Int] = [:]
    /// Units kept for the draw.
    public var pooled = 0
    /// Pooled units parsed, and the ones that became a unit of cases.
    public var examined = 0
    public var built = 0
    /// Sentences to warm up with, by script.
    public var warmupPool: [String: Int] = [:]
    /// The characters behind `unprintable`: each with the number of examined units that have it.
    public var unprintable: [String: Int] = [:]
    public var scenarios: [String: ScenarioStats] = [:]
    /// What the rule of a class suite did; absent for a corpus suite.
    public var classes: ClassReport?

    public struct ScenarioStats: Hashable, Sendable, Codable {
        public var cases = 0
        public var tokens = 0
        public var dev = 0
        public var test = 0
        /// Tokens `err: layout` of the cases built.
        public var layoutErrors = 0
        /// Why a unit gave no case in this scenario.
        public var drops: [String: Int] = [:]
        /// Tokens short of the tier: the source ran out.
        public var shortfall = 0
        /// Tokens with a slip put in (`err` other than none), in the correction suites; absent in the others.
        public var errors: Int?

        public init() {}
    }

    public init(suite: String, tier: String, epoch: Int, seed: Int) {
        self.suite = suite
        self.tier = tier
        self.epoch = epoch
        self.seed = seed
    }
}
