// SPDX-License-Identifier: GPL-3.0-or-later

/// Lines up the tokens of `want` (W) with the tokens of an output (O): a
/// correction may merge or cut tokens («во первых» → «во-первых»), so the
/// n-th token of one is not always the n-th of the other (docs/eval.md,
/// «Выравнивание»).
public struct Aligner: Sendable {
    /// The costs of the operations. A first guess, not a measurement.
    public struct Options: Hashable, Sendable {
        /// 1:1, the tokens differ: this plus the Levenshtein distance over the longer length.
        public var mismatch = 1.0
        /// 2:1 or 1:2 where the two tokens glued without a space or with a hyphen give the one.
        public var gluedJoin = 0.5
        /// 2:1 or 1:2 otherwise.
        public var otherJoin = 2.5
        /// 1:0, a token of W is gone.
        public var dropped = 2.0
        /// 0:1, an extra token of O.
        public var extra = 2.0
        /// Slack when comparing sums of costs.
        public var epsilon = 1e-9

        public init() {}
    }

    /// One operation of the alignment. Indices are of W and O.
    public enum Op: Hashable, Sendable {
        case pair(w: Int, o: Int)
        /// W[w] and W[w + 1] became O[o].
        case merge(w: Int, o: Int)
        /// W[w] became O[o] and O[o + 1].
        case split(w: Int, o: Int)
        case dropped(w: Int)
        case extra(o: Int)
    }

    /// When a group of W counts as right. Given to the aligner by the
    /// scorer: folds and `accept` live there.
    public struct Judge {
        /// W[w] and this output token.
        public var same: (_ w: Int, _ out: String) -> Bool
        /// The text of W[w] and W[w + 1] glued, against an output token.
        public var merged: (_ w: Int, _ out: String) -> Bool
        /// W[w] against two output tokens glued.
        public var cut: (_ w: Int, _ first: String, _ second: String) -> Bool

        public init(same: @escaping (Int, String) -> Bool, merged: @escaping (Int, String) -> Bool,
                    cut: @escaping (Int, String, String) -> Bool)
        {
            self.same = same
            self.merged = merged
            self.cut = cut
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// The operations in order. Equal lists go token to token; otherwise the
    /// cheapest alignment, and at equal cost the order of preference: 1:1,
    /// merge, cut, dropped, extra.
    public func align(want: [String], out: [String], judge: Judge) -> [Op] {
        let n = want.count, m = out.count
        if n == m, (0..<n).allSatisfy({ judge.same($0, out[$0]) }) {
            return (0..<n).map { .pair(w: $0, o: $0) }
        }
        let infinity = Double.infinity
        var cost = Array(repeating: Array(repeating: infinity, count: m + 1), count: n + 1)
        cost[0][0] = 0
        for i in 0...n {
            for j in 0...m where !(i == 0 && j == 0) {
                var best = infinity
                for (_, previous, step) in steps(i, j, want: want, out: out, judge: judge) {
                    best = min(best, cost[previous.0][previous.1] + step)
                }
                cost[i][j] = best
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            let target = cost[i][j]
            guard let chosen = steps(i, j, want: want, out: out, judge: judge).first(where: {
                abs(cost[$0.previous.0][$0.previous.1] + $0.cost - target) <= options.epsilon
            }) else { break }
            ops.append(chosen.op)
            (i, j) = chosen.previous
        }
        return ops.reversed()
    }

    /// The operations that end at (i, j), in the order of preference.
    private func steps(_ i: Int, _ j: Int, want: [String], out: [String], judge: Judge)
        -> [(op: Op, previous: (Int, Int), cost: Double)]
    {
        var result: [(op: Op, previous: (Int, Int), cost: Double)] = []
        if i >= 1, j >= 1 {
            let cost = judge.same(i - 1, out[j - 1]) ? 0
                : options.mismatch + Self.distance(want[i - 1], out[j - 1])
            result.append((.pair(w: i - 1, o: j - 1), (i - 1, j - 1), cost))
        }
        if i >= 2, j >= 1 {
            let cost = judge.merged(i - 2, out[j - 1]) ? options.gluedJoin : options.otherJoin
            result.append((.merge(w: i - 2, o: j - 1), (i - 2, j - 1), cost))
        }
        if i >= 1, j >= 2 {
            let cost = judge.cut(i - 1, out[j - 2], out[j - 1]) ? options.gluedJoin : options.otherJoin
            result.append((.split(w: i - 1, o: j - 2), (i - 1, j - 2), cost))
        }
        if i >= 1 { result.append((.dropped(w: i - 1), (i - 1, j), options.dropped)) }
        if j >= 1 { result.append((.extra(o: j - 1), (i, j - 1), options.extra)) }
        return result
    }

    /// Levenshtein distance over the longer length, in characters.
    static func distance(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        if a.isEmpty || b.isEmpty { return a.isEmpty && b.isEmpty ? 0 : 1 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let up = row[j]
                row[j] = min(up + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                diagonal = up
            }
        }
        return Double(row[b.count]) / Double(max(a.count, b.count))
    }
}
