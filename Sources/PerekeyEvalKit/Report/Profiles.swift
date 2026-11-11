// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `eval/profiles.json`: a profile is a weighted mix of corpus suites that
/// looks like a person; its metric is the weighted mean of the suites' metrics
/// (plan, 10.2). Class suites do not belong to profiles: they explain, they do not weigh.
public struct ProfileFile: Hashable, Sendable, Codable {
    public static let version = 1

    public var version: Int
    /// Profile → suite → weight.
    public var profiles: [String: [String: Double]]
    /// Profile → a line the report prints large under the profile table: what the profile lacks.
    public var caveats: [String: String]?
    /// Profile → why the weights are what they are; for readers of the file, the report ignores it.
    public var notes: [String: String]?

    public init(version: Int = ProfileFile.version, profiles: [String: [String: Double]],
                caveats: [String: String]? = nil, notes: [String: String]? = nil)
    {
        self.version = version
        self.profiles = profiles
        self.caveats = caveats
        self.notes = notes
    }

    public static func read(_ path: String) throws -> ProfileFile {
        guard let data = FileManager.default.contents(atPath: path) else { throw EvalError.input("no such file: \(path)") }
        do {
            let file = try JSONDecoder().decode(ProfileFile.self, from: data)
            guard file.version == Self.version else { throw EvalError.input("\(path): version \(file.version)") }
            for (name, weights) in file.profiles where weights.isEmpty || weights.values.contains(where: { $0 <= 0 }) {
                throw EvalError.input("\(path): profile \(name) needs positive weights")
            }
            return file
        } catch let error as EvalError {
            throw error
        } catch {
            throw EvalError.input("\(path): \(error)")
        }
    }
}

/// A profile of a run: the three numbers of the report's header, and the rest.
public struct ProfileRow: Hashable, Sendable, Codable {
    public var name: String
    /// Suites of the profile the run lacks; the weights of the others are renormalized.
    public var missing: [String]
    /// From the file's `caveats`.
    public var caveat: String?
    public var harm: Estimate
    public var rest: Estimate
    public var restNull: Estimate
    public var silent: Estimate
    public var exact: Estimate
}

enum ProfileEstimator {
    /// The scenarios the numbers come from. Harm is read in `clean.*`; the rest
    /// (О and О₀) where the person does not think of the layout, `stuck`, and in
    /// `slip.*` for a suite that has no `stuck`; Т and «чисто» over all scenarios (plan, 7.3, 10.1).
    struct Options {
        var harmPrefixes = ["clean."]
        var restScenarios: Set<String> = ["stuck"]
        var restFallbackPrefixes = ["slip."]
    }

    static func row(_ name: String, weights: [String: Double], rows: [RunData.Row], options: Options = Options(),
                    stats: Stats.Options = Stats.Options()) -> ProfileRow
    {
        let suites = weights.keys.sorted()
        let present = suites.filter { suite in rows.contains { $0.suite == suite } }
        func estimate(_ measure: Measure, _ pick: (String, [RunData.Row]) -> [RunData.Row]) -> Estimate {
            var strata: [Stats.Sample] = []
            var weightList: [Double] = []
            var totals: [Metrics] = []
            for suite in present {
                let chosen = pick(suite, rows.filter { $0.suite == suite })
                var sample = Stats.Sample(channels: Measure.channelCount)
                var total = Metrics()
                for row in chosen {
                    sample.append(row.metrics.channelValues)
                    total.merge(row.metrics)
                }
                strata.append(sample)
                totals.append(total)
                weightList.append(weights[suite]!)
            }
            let (n, d) = measure.channelPair
            func mean(_ sums: [[Double]]) -> Double? {
                var weighted = 0.0, weight = 0.0
                for (index, sum) in sums.enumerated() where sum[d] > 0 {
                    weighted += weightList[index] * sum[n] / sum[d]
                    weight += weightList[index]
                }
                return weight > 0 ? weighted / weight : nil
            }
            let intervals = Stats.bootstrap(strata: strata, statistics: 1, options: stats) { [mean($0)] }
            var weighted = 0.0, weight = 0.0, events = 0, of = 0
            for (index, total) in totals.enumerated() {
                let (e, o) = total.count(measure)
                events += e
                of += o
                if let ratio = total.ratio(measure) {
                    weighted += weightList[index] * ratio
                    weight += weightList[index]
                }
            }
            return Estimate(value: weight > 0 ? weighted / weight : nil, low: intervals[0]?.low, high: intervals[0]?.high,
                            events: events, of: of, upperIfNone: events == 0 && measure != .exact ? Stats.ruleOfThree(of: of) : nil)
        }
        let all: (String, [RunData.Row]) -> [RunData.Row] = { $1 }
        return ProfileRow(
            name: name, missing: suites.filter { !present.contains($0) }, caveat: nil,
            harm: estimate(.harm) { _, list in list.filter { row in options.harmPrefixes.contains { row.scenario.hasPrefix($0) } } },
            rest: estimate(.rest) { _, list in restRows(list, options) },
            restNull: estimate(.restNull) { _, list in restRows(list, options) },
            silent: estimate(.silent, all), exact: estimate(.exact, all)
        )
    }

    private static func restRows(_ list: [RunData.Row], _ options: Options) -> [RunData.Row] {
        let stuck = list.filter { options.restScenarios.contains($0.scenario) }
        if !stuck.isEmpty { return stuck }
        return list.filter { row in options.restFallbackPrefixes.contains { row.scenario.hasPrefix($0) } }
    }
}
