// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyModelKit

/// The statistics of the report (docs/eval.md, «Статистика»): intervals for
/// shares, the bootstrap over cases, and the paired test of two runs.
public enum Stats {
    /// A confidence interval, in the unit of the statistic it belongs to.
    public struct Interval: Hashable, Sendable, Codable {
        public var low: Double
        public var high: Double
    }

    /// The numbers of the plan, 10.3. Every one with where it comes from.
    public struct Options: Sendable {
        /// The normal quantile of a 95 % interval: 1.96 (z of 0.975).
        public var z = 1.96
        /// Resamples of the bootstrap: the plan, 10.3 («1000 выборок»).
        public var resamples = 1000
        /// The seed of the bootstrap: the plan, 10.3 («зерно 1»).
        public var seed: UInt64 = 1
        /// The percentiles of the bootstrap interval: 2.5 and 97.5 (plan, 10.3).
        public var lowPercentile = 2.5
        public var highPercentile = 97.5

        public init() {}
    }

    /// The Wilson interval of `successes` of `trials`, 95 % by default.
    /// Check: 5 of 10 gives 0.2366…0.7634; 37 of 119 804 gives 0.00022…0.00043.
    public static func wilson(_ successes: Int, of trials: Int, options: Options = Options()) -> Interval? {
        guard trials > 0, successes >= 0, successes <= trials else { return nil }
        let n = Double(trials), p = Double(successes) / n, z = options.z
        let denominator = 1 + z * z / n
        let center = (p + z * z / (2 * n)) / denominator
        let half = z * (p * (1 - p) / n + z * z / (4 * n * n)).squareRoot() / denominator
        return Interval(low: max(0, center - half), high: min(1, center + half))
    }

    /// The upper bound for zero events of `trials`: 3 / n, the rule of three
    /// (plan, 10.3: «Ноль событий из n слов печатается с верхней границей 3/n»).
    public static func ruleOfThree(of trials: Int) -> Double? {
        trials > 0 ? 3 / Double(trials) : nil
    }

    /// The cases of one stratum, each with the same number of channels of counts:
    /// `data` holds them one after another.
    public struct Sample: Sendable {
        public let channels: Int
        public private(set) var data: [Double] = []

        public init(channels: Int) {
            self.channels = channels
        }

        public var count: Int { data.count / max(1, channels) }

        public mutating func append(_ values: [Double]) {
            precondition(values.count == channels)
            data += values
        }
    }

    /// The bootstrap over cases, which are clusters (plan, 10.3).
    ///
    /// A resample draws from each stratum as many cases as it has, with
    /// replacement, and sums their channels. `statistics` turns the sums of all
    /// strata (a row of channels per stratum) into the numbers to report, a nil
    /// for one that has no value (an empty denominator). The result has the
    /// interval of each number, from the percentiles of the resamples.
    public static func bootstrap(strata: [Sample], statistics: Int, options: Options = Options(),
                                 statistic: ([[Double]]) -> [Double?]) -> [Interval?]
    {
        guard strata.contains(where: { $0.count > 0 }) else { return Array(repeating: nil, count: statistics) }
        var random = SplitMix64(seed: options.seed)
        var values = Array(repeating: [Double](), count: statistics)
        var sums = strata.map { [Double](repeating: 0, count: $0.channels) }
        for _ in 0..<options.resamples {
            for (index, stratum) in strata.enumerated() {
                let channels = stratum.channels
                for channel in 0..<channels { sums[index][channel] = 0 }
                let count = stratum.count
                guard count > 0 else { continue }
                stratum.data.withUnsafeBufferPointer { data in
                    for _ in 0..<count {
                        let base = Int(random.next() % UInt64(count)) * channels
                        for channel in 0..<channels { sums[index][channel] += data[base + channel] }
                    }
                }
            }
            for (number, value) in statistic(sums).enumerated() {
                if let value { values[number].append(value) }
            }
        }
        return values.map { list in
            guard !list.isEmpty else { return nil }
            let sorted = list.sorted()
            return Interval(low: percentile(sorted, options.lowPercentile), high: percentile(sorted, options.highPercentile))
        }
    }

    /// The bootstrap interval of one ratio: the sum of numerators over the sum
    /// of denominators of cases, given as `(numerator, denominator)` pairs.
    public static func bootstrapRatio(_ cases: [(Double, Double)], options: Options = Options()) -> Interval? {
        var sample = Sample(channels: 2)
        for pair in cases { sample.append([pair.0, pair.1]) }
        return bootstrap(strata: [sample], statistics: 1, options: options) { sums in
            [sums[0][1] > 0 ? sums[0][0] / sums[0][1] : nil]
        }[0]
    }

    /// The `p`-th percentile (0…100) of sorted values, linear between ranks.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard sorted.count > 1 else { return sorted[0] }
        let position = p / 100 * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = min(sorted.count - 1, lower + 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// The exact two-sided McNemar test: `better` and `worse` are the cases
    /// that changed one way and the other; under no difference each is half
    /// of the changed. Check: 9 and 3 give 0.146; 131 and 17 give < 0.001.
    public static func mcNemar(better: Int, worse: Int) -> Double {
        let changed = better + worse
        guard changed > 0 else { return 1 }
        let smaller = min(better, worse)
        var tail = 0.0
        for k in 0...smaller {
            tail += exp(lgamma(Double(changed + 1)) - lgamma(Double(k + 1)) - lgamma(Double(changed - k + 1))
                - Double(changed) * log(2))
        }
        return min(1, 2 * tail)
    }
}
