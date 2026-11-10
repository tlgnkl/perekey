// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The counts of one slice: the tokens that share a value of a feature (or of
/// two). A slice of the whole run, with `ok` the rest of `tokens`.
public struct SliceCounters: Hashable, Sendable, Codable {
    public var tokens = 0
    /// Tokens with a letter: the denominator of the rates.
    public var words = 0
    public var fixed = 0
    public var harm = 0
    public var miss = 0
    public var botched = 0
    public var disputed = 0
    public var silent = 0
    public var layoutErrors = 0
    public var missLayout = 0
    /// Wrong without the system.
    public var wrongNull = 0

    public init() {}

    /// Wrong with the system: harm, miss, botched.
    public var wrong: Int { harm + miss + botched }

    mutating func add(_ token: TokenScore) {
        tokens += 1
        if Tokenizer.isWord(token.want) { words += 1 }
        switch token.outcome {
        case .fixed: fixed += 1
        case .harm: harm += 1
        case .miss: miss += 1
        case .botched: botched += 1
        case .disputed: disputed += 1
        case .ok, .spill: break
        }
        if token.silent { silent += 1 }
        if token.err == .layout {
            layoutErrors += 1
            if token.outcome == .miss { missLayout += 1 }
        }
        if [.fixed, .miss, .botched].contains(token.outcome) { wrongNull += 1 }
    }

    mutating func merge(_ other: SliceCounters) {
        tokens += other.tokens
        words += other.words
        fixed += other.fixed
        harm += other.harm
        miss += other.miss
        botched += other.botched
        disputed += other.disputed
        silent += other.silent
        layoutErrors += other.layoutErrors
        missLayout += other.missLayout
        wrongNull += other.wrongNull
    }
}

/// `slices.json`: the counts of every value of every feature, and of every
/// pair of values of two features, over all tokens of the measured part,
/// the `ok` ones too (docs/eval.md, «Срезы»).
public struct SliceTable: Hashable, Sendable, Codable {
    public static let schema = 1
    /// The features in the order slices name them. `tags` takes a value per tag.
    public static let featureNames = ["lang", "len", "pos", "ctx", "cap", "punct", "digits", "known", "zipf",
                                      "collision", "seen", "err", "end", "reason", "margin", "early", "kind", "tags"]
    /// A pair is kept in the file from this many words; the report asks for more
    /// (plan, 10.4: 200). Cheap to keep, so a report can lower its own bound.
    public static let storedPairSupport = 50

    public var schema = SliceTable.schema
    /// Feature → value → counts.
    public var features: [String: [String: SliceCounters]] = [:]
    /// `"ctx=against & len=1-2"` → counts; the features in the order of `featureNames`.
    public var pairs: [String: SliceCounters] = [:]

    public init() {}

    public init(_ scores: [CaseScore], pairSupport: Int = SliceTable.storedPairSupport) {
        // Tokens with the same values and the same outcome count the same: group first.
        var names: [String] = []
        var ids: [String: Int] = [:]
        func id(_ feature: String, _ value: String) -> Int {
            let name = feature + "=" + value
            if let known = ids[name] { return known }
            names.append(name)
            ids[name] = names.count - 1
            return names.count - 1
        }
        struct Signature: Hashable {
            var values: [Int]
            var outcome: Outcome
            var silent: Bool
            var layoutError: Bool
            var word: Bool
        }
        var groups: [Signature: Int] = [:]
        for score in scores {
            for token in score.tokens where token.measured {
                guard let found = token.features else { continue }
                var values: [Int] = []
                for (feature, value) in Self.values(of: found) { values.append(id(feature, value)) }
                let signature = Signature(values: values, outcome: token.outcome, silent: token.silent,
                                          layoutError: token.err == .layout, word: Tokenizer.isWord(token.want))
                groups[signature, default: 0] += 1
            }
        }
        var singles: [Int: SliceCounters] = [:]
        var pairCounts: [UInt64: SliceCounters] = [:]
        for (signature, count) in groups {
            let counters = Self.counters(of: signature.outcome, silent: signature.silent,
                                         layoutError: signature.layoutError, word: signature.word, times: count)
            for value in signature.values { singles[value, default: SliceCounters()].merge(counters) }
            let values = signature.values.sorted()
            for first in values.indices {
                for second in values.indices where second > first {
                    pairCounts[UInt64(values[first]) << 32 | UInt64(values[second]), default: SliceCounters()]
                        .merge(counters)
                }
            }
        }
        func split(_ name: String) -> (feature: String, value: String) {
            let parts = name.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), String(parts[1]))
        }
        for (value, counters) in singles {
            let (feature, name) = split(names[value])
            features[feature, default: [:]][name] = counters
        }
        let order = Dictionary(uniqueKeysWithValues: Self.featureNames.enumerated().map { ($1, $0) })
        for (key, counters) in pairCounts where counters.words >= pairSupport {
            let one = split(names[Int(key >> 32)]), two = split(names[Int(key & 0xFFFF_FFFF)])
            if one.feature == two.feature { continue }
            let (first, second) = order[one.feature, default: 99] <= order[two.feature, default: 99] ? (one, two) : (two, one)
            pairs["\(first.feature)=\(first.value) & \(second.feature)=\(second.value)"] = counters
        }
    }

    private static func counters(of outcome: Outcome, silent: Bool, layoutError: Bool, word: Bool, times: Int)
        -> SliceCounters
    {
        var counters = SliceCounters()
        counters.tokens = times
        counters.words = word ? times : 0
        switch outcome {
        case .fixed: counters.fixed = times
        case .harm: counters.harm = times
        case .miss: counters.miss = times
        case .botched: counters.botched = times
        case .disputed: counters.disputed = times
        case .ok, .spill: break
        }
        if silent { counters.silent = times }
        if layoutError {
            counters.layoutErrors = times
            if outcome == .miss { counters.missLayout = times }
        }
        if [.fixed, .miss, .botched].contains(outcome) { counters.wrongNull = times }
        return counters
    }

    /// The (feature, value) pairs of a token, in the order of `featureNames`;
    /// features the run does not have are left out.
    static func values(of features: TokenFeatures) -> [(String, String)] {
        var result: [(String, String)] = [("lang", features.lang), ("len", features.len), ("pos", features.pos),
                                           ("ctx", features.ctx), ("cap", features.cap), ("punct", features.punct),
                                           ("digits", features.digits)]
        for (name, value) in [("known", features.known), ("zipf", features.zipf), ("collision", features.collision),
                              ("seen", features.seen)] {
            if let value { result.append((name, value)) }
        }
        result += [("err", features.err), ("end", features.end)]
        for (name, value) in [("reason", features.reason), ("margin", features.margin), ("early", features.early),
                              ("kind", features.kind)] {
            if let value { result.append((name, value)) }
        }
        for tag in features.tags { result.append(("tags", tag)) }
        return result
    }

    /// The counts of the whole run: the sum over one feature that every token has.
    public var total: SliceCounters {
        var sum = SliceCounters()
        for counters in (features["lang"] ?? [:]).values { sum.merge(counters) }
        return sum
    }
}
