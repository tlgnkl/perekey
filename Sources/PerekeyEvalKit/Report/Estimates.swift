// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A metric of the report as a ratio of two counts (docs/eval.md, «Метрики»).
public enum Measure: String, CaseIterable, Sendable, Codable {
    /// В: harm per word.
    case harm
    /// Т: harmed and botched tokens the person does not notice, per word.
    case silent
    /// П: layout mistakes left, per layout mistake.
    case missLayout
    /// Пч: botched, per token with a mistake of the person.
    case botched
    /// О: wrong tokens with the system, per word.
    case rest
    /// О₀: wrong tokens without it, per word.
    case restNull
    /// Disputed tokens per word.
    case disputed
    /// Чисто: share of exact cases.
    case exact

    /// The counts of a case that the bootstrap sums, in this order.
    enum Channel: Int, CaseIterable {
        case words, harm, harmEvents, silent, layoutErrors, missLayout, errors, botched, wrong, wrongNull, disputed,
             exact, cases

        func value(in metrics: Metrics) -> Int {
            switch self {
            case .words: metrics.words
            case .harm: metrics.harm
            case .harmEvents: metrics.harmEvents
            case .silent: metrics.silent
            case .layoutErrors: metrics.layoutErrors
            case .missLayout: metrics.missLayout
            case .errors: metrics.errors
            case .botched: metrics.botched
            case .wrong: metrics.wrong
            case .wrongNull: metrics.wrongNull
            case .disputed: metrics.disputed
            case .exact: metrics.exact
            case .cases: metrics.cases
            }
        }
    }

    static let channelCount = Channel.allCases.count

    /// The numerator and the denominator among the channels.
    var parts: (numerator: Channel, denominator: Channel) {
        switch self {
        case .harm: (.harm, .words)
        case .silent: (.silent, .words)
        case .missLayout: (.missLayout, .layoutErrors)
        case .botched: (.botched, .errors)
        case .rest: (.wrong, .words)
        case .restNull: (.wrongNull, .words)
        case .disputed: (.disputed, .words)
        case .exact: (.exact, .cases)
        }
    }

    var channelPair: (Int, Int) { (parts.numerator.rawValue, parts.denominator.rawValue) }

    /// Per mille, except `exact`, which is a share (percent).
    public var scale: Double { self == .exact ? 100 : 1000 }
}

/// A number of the report with its interval and its counts: «В 0,31 ‰ (37 из
/// 119 804), 95 % 0,22–0,43» (plan, 10.3).
public struct Estimate: Hashable, Sendable, Codable {
    /// The ratio, 0…1; nil without a denominator.
    public var value: Double?
    public var low: Double?
    public var high: Double?
    public var events: Int
    public var of: Int
    /// With no event: the upper bound 3 / n of the rule of three.
    public var upperIfNone: Double?

    public static let none = Estimate(value: nil, low: nil, high: nil, events: 0, of: 0, upperIfNone: nil)
}

extension Metrics {
    /// The channels of the bootstrap, in the order of `Measure.channels`.
    var channelValues: [Double] { Measure.Channel.allCases.map { Double($0.value(in: self)) } }

    func count(_ measure: Measure) -> (events: Int, of: Int) {
        let (numerator, denominator) = measure.parts
        return (numerator.value(in: self), denominator.value(in: self))
    }

    func ratio(_ measure: Measure) -> Double? {
        let (events, of) = count(measure)
        return of > 0 ? Double(events) / Double(of) : nil
    }
}

/// Estimates of a group of cases: the value from the counts and the interval
/// from the bootstrap over the cases (plan, 10.3).
enum Estimator {
    /// Every measure of the cases in one set of resamples.
    static func estimates(of rows: some Collection<RunData.Row>, options: Stats.Options = Stats.Options()) -> [Measure: Estimate] {
        var total = Metrics()
        var sample = Stats.Sample(channels: Measure.channelCount)
        for row in rows {
            total.merge(row.metrics)
            sample.append(row.metrics.channelValues)
        }
        let measures = Measure.allCases
        let intervals = Stats.bootstrap(strata: [sample], statistics: measures.count, options: options) { sums in
            measures.map { measure in
                let (n, d) = measure.channelPair
                return sums[0][d] > 0 ? sums[0][n] / sums[0][d] : nil
            }
        }
        var result: [Measure: Estimate] = [:]
        for (measure, interval) in zip(measures, intervals) {
            let (events, of) = total.count(measure)
            result[measure] = Estimate(value: total.ratio(measure), low: interval?.low, high: interval?.high,
                                       events: events, of: of,
                                       upperIfNone: events == 0 && measure != .exact ? Stats.ruleOfThree(of: of) : nil)
        }
        return result
    }
}
