// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the report asks of a run.
public struct ReportOptions: Sendable {
    /// The profiles to show; nil shows all of the file.
    public var profiles: [String]?
    public var profilesFile: String?
    /// How many words of the list; nil: the plan's 200 (plan, 10.4).
    public var words: Int?
    /// The table of every feature (`--slices`).
    public var slices = false
    /// Words of the test part (`--reveal-test`, rule 2.8).
    public var revealTest = false
    /// A slice needs this many words to rank among the worst: plan, 10.4.
    public var support = 200
    /// How many worst slices to print: plan, 10.4.
    public var worstCount = 20
    /// The default length of the word list: plan, 10.4.
    public var defaultWords = 200
    public var stats = Stats.Options()

    public init() {}
}

/// A group of cases: suite × scenario.
public struct GroupRow: Hashable, Sendable, Codable {
    public var suite: String
    public var scenario: String
    public var cases: Int
    public var words: Int
    /// Measure → estimate (`Measure.rawValue`).
    public var estimates: [String: Estimate]
    public var harmEvents: Int
    /// В and П with the weights of the tokens, for class suites; nil where all weights are 1.
    public var harmWeighted: Double?
    public var missLayoutWeighted: Double?
    /// Mean lag in tokens over the cases that have one.
    public var lag: Double?
    public var checksFailed: Int
}

/// A slice of the worst list.
public struct SliceLine: Hashable, Sendable, Codable {
    public var name: String
    public var counters: SliceCounters
    /// (share in the slice − share in the run) × words of the slice.
    public var extra: Double
    public var wrongShare: Double?
    public var harmShare: Double?
    public var missLayoutShare: Double?
}

/// A word type of the list: occurrences, errors, weight.
public struct WordLine: Hashable, Sendable, Codable {
    public var word: String
    public var split: String
    public var occurrences: Int
    public var harm: Int
    public var miss: Int
    public var botched: Int
    public var weight: Double
}

/// Values of a feature, for `--slices`.
public struct FeatureTable: Hashable, Sendable, Codable {
    public struct Line: Hashable, Sendable, Codable {
        public var value: String
        public var counters: SliceCounters
        /// The Wilson interval of the share of wrong tokens among the words.
        public var wrong: Stats.Interval?
        public var harm: Stats.Interval?
    }

    public var feature: String
    public var lines: [Line]
}

/// The report as data: the text, Markdown and HTML renderers draw it, and
/// `--format json` writes it as it is.
public struct ReportData: Hashable, Sendable, Codable {
    public static let schema = 1

    public var schema = ReportData.schema
    public var system: String
    public var commit: String
    public var models: [String: String]
    public var tier: String?
    public var epochs: [Int]
    public var settings: String?
    public var options: String?
    public var scorer: Int
    /// Whether the words of the test part are in this report.
    public var testRevealed: Bool
    public var profiles: [ProfileRow]
    public var groups: [GroupRow]
    public var total: GroupRow
    public var worst: [SliceLine]
    public var words: [WordLine]
    public var seen: [String: SliceCounters]
    public var reasons: [String: SliceCounters]
    public var margins: [String: SliceCounters]
    public var features: [FeatureTable]
    public var incidents: Summary.Incidents
    /// Harm in the protective suites (`protect.*`): (harm, words); nil without them.
    public var protective: Estimate?
    public var notes: [String]
}

public enum ReportBuilder {
    /// Suites whose harm must be zero (plan, 11.3 «Защитные наборы»).
    static let protectivePrefix = "protect."

    public static func build(_ run: RunData, options: ReportOptions = ReportOptions()) throws -> ReportData {
        var notes: [String] = []
        let reveal = options.revealTest
        if reveal { notes.append(run.info.testRevealed ? "тест раскрыт" : "тест раскрыт флагом, но прогон сыгран без --reveal-test: слова части test в нём скрыты") }
        else if run.info.testRevealed { notes.append("прогон сыгран с --reveal-test; в этом отчёте слова части test скрыты") }

        let key = { (row: RunData.Row) in [row.suite, row.scenario] }
        var order: [[String]] = []
        var grouped: [[String]: [RunData.Row]] = [:]
        for row in run.rows {
            if grouped[key(row)] == nil { order.append(key(row)) }
            grouped[key(row), default: []].append(row)
        }
        let groups = order.sorted { $0.lexicographicallyPrecedes($1) }.map { name in
            groupRow(name[0], name[1], grouped[name]!, options.stats)
        }
        let total = groupRow("итого", "", run.rows, options.stats)

        var profiles: [ProfileRow] = []
        if let path = options.profilesFile {
            let file = try ProfileFile.read(path)
            let wanted = options.profiles ?? file.profiles.keys.sorted()
            for name in wanted {
                guard let weights = file.profiles[name] else { throw EvalError.input("\(path): no profile \(name)") }
                var row = ProfileEstimator.row(name, weights: weights, rows: run.rows, stats: options.stats)
                row.caveat = file.caveats?[name]
                if !row.missing.isEmpty {
                    notes.append("профиль \(name) неполный: нет наборов \(row.missing.joined(separator: ", ")); веса остальных пересчитаны")
                }
                profiles.append(row)
            }
        }

        let slices = run.slices
        let all = slices.total
        let worst = worstSlices(slices, total: all, options: options)
        let wordCount = options.words ?? options.defaultWords
        let shown = run.words.filter { $0.split == "dev" || (reveal && run.info.testRevealed) }
            .filter { $0.harm + $0.miss + $0.botched > 0 }
            .sorted { ($1.errorWeight, $1.harm + $1.miss + $1.botched, $0.word) < ($0.errorWeight, $0.harm + $0.miss + $0.botched, $1.word) }
            .prefix(wordCount)
            .map { WordLine(word: $0.word, split: $0.split, occurrences: $0.occurrences, harm: $0.harm, miss: $0.miss,
                            botched: $0.botched, weight: $0.errorWeight) }

        let protectedRows = run.rows.filter { $0.suite.hasPrefix(protectivePrefix) }
        var protective: Estimate?
        if !protectedRows.isEmpty {
            protective = Estimator.estimates(of: protectedRows, options: options.stats)[.harm]
        }
        if run.info.lexicon == nil {
            notes.append("прогон без лексикона: нет признаков known, zipf, collision, seen и исхода «спорно»")
        }

        var features: [FeatureTable] = []
        if options.slices {
            for name in SliceTable.featureNames {
                guard let values = slices.features[name] else { continue }
                let lines = values.keys.sorted().map { value -> FeatureTable.Line in
                    let c = values[value]!
                    return .init(value: value, counters: c, wrong: Stats.wilson(c.wrong, of: c.words),
                                 harm: Stats.wilson(c.harm, of: c.words))
                }
                features.append(FeatureTable(feature: name, lines: lines))
            }
        }
        return ReportData(
            system: run.info.system, commit: run.info.commit, models: run.info.models, tier: run.info.tier,
            epochs: Array(Set(run.rows.map(\.epoch))).sorted(), settings: run.info.settings, options: run.info.options,
            scorer: run.scorer, testRevealed: reveal && run.info.testRevealed, profiles: profiles, groups: groups,
            total: total, worst: worst, words: Array(shown), seen: slices.features["seen"] ?? [:],
            reasons: slices.features["reason"] ?? [:], margins: slices.features["margin"] ?? [:], features: features,
            incidents: run.incidents, protective: protective, notes: notes
        )
    }

    static func groupRow(_ suite: String, _ scenario: String, _ rows: [RunData.Row], _ stats: Stats.Options) -> GroupRow {
        var total = Metrics()
        var lagSum = 0, lagCount = 0
        for row in rows {
            total.merge(row.metrics)
            if let lag = row.lag {
                lagSum += lag
                lagCount += 1
            }
        }
        total.computeRates()
        var estimates = Estimator.estimates(of: rows, options: stats)
        // Cases scored as a whole have words but no token outcome: only «чисто» means something.
        if total.tokens == 0 {
            for measure in Measure.allCases where measure != .exact { estimates[measure] = Estimate.none }
        }
        return GroupRow(
            suite: suite, scenario: scenario, cases: total.cases, words: total.words,
            estimates: Dictionary(uniqueKeysWithValues: estimates.map { ($0.key.rawValue, $0.value) }),
            harmEvents: total.harmEvents, harmWeighted: total.rates.harmWeighted.map { $0 / 1000 },
            missLayoutWeighted: total.rates.missLayoutWeighted.map { $0 / 1000 },
            lag: lagCount > 0 ? Double(lagSum) / Double(lagCount) : nil, checksFailed: total.checksFailed
        )
    }

    /// The worst slices (plan, 10.4.2): every value of a feature and every pair
    /// of values of two features with enough words, by the extra errors.
    static func worstSlices(_ table: SliceTable, total: SliceCounters, options: ReportOptions) -> [SliceLine] {
        guard total.words > 0 else { return [] }
        let baseWrong = Double(total.wrong) / Double(total.words)
        var candidates: [(String, SliceCounters)] = []
        for (feature, values) in table.features {
            for (value, counters) in values { candidates.append(("\(feature)=\(value)", counters)) }
        }
        candidates += table.pairs.map { ($0.key, $0.value) }
        let lines = candidates.compactMap { name, c -> SliceLine? in
            guard c.words >= options.support else { return nil }
            let share = Double(c.wrong) / Double(c.words)
            let extra = (share - baseWrong) * Double(c.words)
            guard extra > 0 else { return nil }
            return SliceLine(name: name, counters: c, extra: extra, wrongShare: share,
                             harmShare: Double(c.harm) / Double(c.words),
                             missLayoutShare: c.layoutErrors > 0 ? Double(c.missLayout) / Double(c.layoutErrors) : nil)
        }
        return Array(lines.sorted { ($1.extra, $0.name) < ($0.extra, $1.name) }.prefix(options.worstCount))
    }
}
