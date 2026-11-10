// SPDX-License-Identifier: GPL-3.0-or-later

@testable import PerekeyEvalKit
import Testing

/// The intervals and the paired test against values worked out by hand.
@Suite struct StatsTests {
    @Test func wilsonMatchesKnownValues() throws {
        let half = try #require(Stats.wilson(5, of: 10))
        #expect(abs(half.low - 0.2366) < 0.0001)
        #expect(abs(half.high - 0.7634) < 0.0001)
        let none = try #require(Stats.wilson(0, of: 10))
        #expect(none.low == 0)
        #expect(abs(none.high - 0.2775) < 0.0001)
        let all = try #require(Stats.wilson(10, of: 10))
        #expect(all.high == 1)
        #expect(abs(all.low - 0.7225) < 0.0001)
    }

    @Test func wilsonOfThePlanExample() throws {
        // «В 0,31 ‰ (37 из 119 804), 95 % 0,22–0,43» (plan, 11.3).
        let interval = try #require(Stats.wilson(37, of: 119_804))
        #expect(abs(interval.low * 1000 - 0.224) < 0.001)
        #expect(abs(interval.high * 1000 - 0.426) < 0.001)
    }

    @Test func wilsonWithoutTrialsHasNoValue() {
        #expect(Stats.wilson(0, of: 0) == nil)
        #expect(Stats.wilson(3, of: 2) == nil)
    }

    @Test func ruleOfThree() {
        #expect(Stats.ruleOfThree(of: 1000) == 0.003)
        #expect(Stats.ruleOfThree(of: 0) == nil)
    }

    @Test func mcNemarMatchesTheWorkedValues() {
        // 9 better, 3 worse: 2 · P(X ≤ 3 | n = 12) = 2 · 299 / 4096 = 0.146 (plan, 11.3).
        #expect(abs(Stats.mcNemar(better: 9, worse: 3) - 0.14599609375) < 1e-9)
        #expect(abs(Stats.mcNemar(better: 3, worse: 9) - 0.14599609375) < 1e-9)
        #expect(Stats.mcNemar(better: 5, worse: 5) == 1)
        #expect(Stats.mcNemar(better: 0, worse: 0) == 1)
        // 0 and 6: 2 · (1/64) = 0.03125.
        #expect(abs(Stats.mcNemar(better: 0, worse: 6) - 0.03125) < 1e-12)
        #expect(Stats.mcNemar(better: 131, worse: 17) < 0.001)
    }

    @Test func bootstrapOfTwoCasesSpansTheirExtremes() throws {
        // Cases 1/1 and 0/1: a resample of two is 0, 0.5 or 1 with chances ¼, ½, ¼;
        // 1000 resamples reach both ends, so the 2.5 and 97.5 percentiles are 0 and 1.
        let interval = try #require(Stats.bootstrapRatio([(1, 1), (0, 1)]))
        #expect(interval.low == 0)
        #expect(interval.high == 1)
    }

    @Test func bootstrapOfEqualCasesIsAPoint() throws {
        let interval = try #require(Stats.bootstrapRatio(Array(repeating: (1.0, 4.0), count: 50)))
        #expect(interval.low == 0.25)
        #expect(interval.high == 0.25)
    }

    @Test func bootstrapIsDeterministicAndNarrowsWithMoreCases() throws {
        func cases(_ count: Int) -> [(Double, Double)] { (0..<count).map { ($0 % 10 == 0 ? 1 : 0, 1) } }
        let small = try #require(Stats.bootstrapRatio(cases(100)))
        #expect(small == Stats.bootstrapRatio(cases(100)))
        let large = try #require(Stats.bootstrapRatio(cases(10_000)))
        #expect(large.high - large.low < small.high - small.low)
        #expect(small.low < 0.1 && 0.1 < small.high)
    }

    @Test func bootstrapWithoutDenominatorHasNoValue() {
        #expect(Stats.bootstrapRatio([(0, 0), (0, 0)]) == nil)
        #expect(Stats.bootstrapRatio([]) == nil)
    }

    @Test func bootstrapOfStrataCombinesThem() throws {
        // Two strata, each constant: the statistic is their weighted mean, a point.
        var first = Stats.Sample(channels: 2), second = Stats.Sample(channels: 2)
        for _ in 0..<5 {
            first.append([1, 2])
            second.append([1, 1])
        }
        let intervals = Stats.bootstrap(strata: [first, second], statistics: 2) { sums in
            [(sums[0][0] / sums[0][1]) * 0.5 + (sums[1][0] / sums[1][1]) * 0.5, sums[1][0] / sums[1][1]]
        }
        #expect(intervals[0] == Stats.Interval(low: 0.75, high: 0.75))
        #expect(intervals[1] == Stats.Interval(low: 1, high: 1))
    }

    @Test func percentileInterpolates() {
        #expect(Stats.percentile([1, 2, 3, 4, 5], 50) == 3)
        #expect(Stats.percentile([0, 10], 25) == 2.5)
    }
}
