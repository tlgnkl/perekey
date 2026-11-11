// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A corrupted machine and what the bench must see (docs/eval.md, «Мутанты»).
/// The self-check plays the machine with the corrupted options or preset and
/// compares counts with the ordinary run on the same cases: a mutant that shifts
/// nothing means the bench is blind to that kind of damage.
public struct Mutant: Sendable {
    public enum Count: String, Sendable {
        case harm, missLayout, fixed, silent
    }

    public enum Relation: Sendable {
        /// The count is at least `times` times the ordinary run's (at least `times` when that was 0).
        case grows(times: Double)
        /// The count is at most `times` times the ordinary run's, and the ordinary run had events.
        case shrinks(times: Double)
        /// The count is not above the ordinary run's.
        case notAbove
        /// The ordinary run had events and this one has none.
        case fallsToZero
    }

    public struct Expectation: Sendable {
        /// What the line of the report says: «В в clean.*».
        public var what: String
        /// A suite pattern (`*` stands for any run of characters); the scenario starts with `scenarioPrefix`.
        public var suite: String
        public var scenarioPrefix: String
        /// A slice (`ctx=agree`) of the tokens instead of the whole group.
        public var slice: String?
        public var count: Count
        public var relation: Relation

        func covers(_ score: CaseScore) -> Bool {
            GateMetric.matches(suite, score.suite) && score.scenario.hasPrefix(scenarioPrefix)
        }
    }

    public var name: String
    /// `--options` JSON for the classifier.
    public var options: String?
    /// `--settings` preset.
    public var settings: String?
    public var expectations: [Expectation]
}

/// How one expectation came out.
public struct MutantFinding: Hashable, Sendable {
    public enum Verdict: String, Sendable { case ok, fail, skipped }
    public var verdict: Verdict
    public var line: String
}

public enum Mutants {
    /// The mutants the suites of this repository can show. Each factor is half of the shift measured on
    /// the `ci` level, both parts, six suites, with `perekey-eval selfcheck --mutants` (a margin of two,
    /// plan, section 20, item 8):
    ///
    /// | Mutant | Count | Ordinary → mutant | Shift | Factor |
    /// |---|---|---|---|---|
    /// | threshold: 0 | harm in `clean.*` | 90 → 113 | × 1.26 | × 1.12 |
    /// | threshold: 40 | miss.layout in `slip.*` | 1315 → 2096 | × 1.59 | × 1.29 |
    /// | contextBonus: 0 | miss.layout in `slip.warm` | 1240 → 1200 | × 0.97 | × 0.98 |
    ///
    /// The plan expected a doubling for threshold: 0 and a rise of П for contextBonus: 0; the measure
    /// says otherwise (docs/eval.md, «Мутанты»). Measure again after a change of the cases, of the tier
    /// or of the machine, and write the new numbers here and in docs/eval.md.
    public static let all: [Mutant] = [
        Mutant(name: "threshold: 0", options: #"{"threshold": 0}"#, settings: nil, expectations: [
            .init(what: "В в clean.*", suite: "*", scenarioPrefix: "clean.", slice: nil, count: .harm, relation: .grows(times: 1.12)),
        ]),
        Mutant(name: "threshold: 40", options: #"{"threshold": 40}"#, settings: nil, expectations: [
            .init(what: "П в slip.*", suite: "*", scenarioPrefix: "slip.", slice: nil, count: .missLayout, relation: .grows(times: 1.29)),
        ]),
        Mutant(name: "contextBonus: 0", options: #"{"contextBonus": 0}"#, settings: nil, expectations: [
            .init(what: "П в slip.warm", suite: "*", scenarioPrefix: "slip.warm", slice: nil, count: .missLayout, relation: .shrinks(times: 0.98)),
            .init(what: "В в clean.warm", suite: "*", scenarioPrefix: "clean.warm", slice: nil, count: .harm, relation: .notAbove),
        ]),
        Mutant(name: "preset layout-only", options: nil, settings: "layout-only", expectations: [
            .init(what: "Починено в typos.*", suite: "typos.*", scenarioPrefix: "", slice: nil, count: .fixed, relation: .fallsToZero),
            .init(what: "Т в typos.none", suite: "typos.none", scenarioPrefix: "", slice: nil, count: .silent, relation: .fallsToZero),
        ]),
        Mutant(name: "preset default", options: nil, settings: "default", expectations: [
            .init(what: "Починено в hyphen", suite: "hyphen", scenarioPrefix: "", slice: nil, count: .fixed, relation: .fallsToZero),
            .init(what: "Починено в yo", suite: "yo", scenarioPrefix: "", slice: nil, count: .fixed, relation: .fallsToZero),
        ]),
    ]

    /// The cases a mutant needs: those some expectation covers.
    public static func covers(_ mutant: Mutant, _ item: EvalCase) -> Bool {
        mutant.expectations.contains { GateMetric.matches($0.suite, item.suite) && item.scenario.hasPrefix($0.scenarioPrefix) }
    }

    /// Compares counts of the ordinary run and the mutated one, which played the same cases.
    public static func judge(_ mutant: Mutant, ordinary: [CaseScore], mutated: [CaseScore]) -> [MutantFinding] {
        mutant.expectations.map { expectation in
            let before = ordinary.filter(expectation.covers)
            let after = mutated.filter(expectation.covers)
            guard !before.isEmpty else {
                return MutantFinding(verdict: .skipped,
                                     line: "\(mutant.name): \(expectation.what): пропущен, нет набора \(expectation.suite)")
            }
            let a = count(expectation, before), b = count(expectation, after)
            switch expectation.relation {
            case let .grows(times):
                let needed = times * max(Double(a), 1)
                let ok = Double(b) >= needed
                return MutantFinding(verdict: ok ? .ok : .fail,
                                     line: "\(mutant.name): \(expectation.what): \(a) → \(b), нужно не меньше \(number(needed))"
                                         + (ok ? "" : " — НЕТ СДВИГА"))
            case let .shrinks(times):
                let needed = times * Double(a)
                let ok = a > 0 && Double(b) <= needed
                return MutantFinding(verdict: ok ? .ok : .fail,
                                     line: "\(mutant.name): \(expectation.what): \(a) → \(b), нужно не больше \(number(needed))"
                                         + (ok ? "" : " — НЕТ СДВИГА"))
            case .fallsToZero:
                let ok = a > 0 && b == 0
                return MutantFinding(verdict: ok ? .ok : .fail,
                                     line: "\(mutant.name): \(expectation.what): \(a) → \(b), нужно 0"
                                         + (ok ? "" : " — НЕТ СДВИГА"))
            case .notAbove:
                let ok = b <= a
                return MutantFinding(verdict: ok ? .ok : .fail,
                                     line: "\(mutant.name): \(expectation.what): \(a) → \(b), нужно не больше \(a)"
                                         + (ok ? "" : " — ВЫРОСЛО"))
            }
        }
    }

    private static func count(_ expectation: Mutant.Expectation, _ scores: [CaseScore]) -> Int {
        if let slice = expectation.slice {
            let table = SliceTable(scores)
            let parts = slice.split(separator: "=", maxSplits: 1).map(String.init)
            guard let counters = table.features[parts[0]]?[parts[1]] else { return 0 }
            switch expectation.count {
            case .harm: return counters.harm
            case .missLayout: return counters.missLayout
            case .fixed: return counters.fixed
            case .silent: return counters.silent
            }
        }
        var total = Metrics()
        for score in scores { total.merge(Metrics(score)) }
        switch expectation.count {
        case .harm: return total.harm
        case .missLayout: return total.missLayout
        case .fixed: return total.fixed
        case .silent: return total.silent
        }
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
