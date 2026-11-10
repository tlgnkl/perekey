// SPDX-License-Identifier: GPL-3.0-or-later

/// The counts and rates of a group of cases (docs/eval.md, «Метрики»).
/// Counts are of tokens of the measured part; rates are per 1000 words,
/// tokens with a letter, except where the denominator is named.
public struct Metrics: Hashable, Sendable, Codable {
    public var cases = 0
    /// Cases with every token right (`scoring: case`: the text alone; the checks are a label).
    public var exact = 0
    public var fail = 0
    /// Cases whose checks failed (layout at the end, corrections, undos):
    /// a label of the case, apart from `exact`.
    public var checksFailed = 0
    public var tokens = 0
    public var words = 0
    public var ok = 0
    public var fixed = 0
    public var harm = 0
    /// Runs of harmed tokens one after another: how many times the system erred.
    public var harmEvents = 0
    public var miss = 0
    public var botched = 0
    public var spill = 0
    /// Tokens the person typed in the wrong layout, and those left so.
    public var layoutErrors = 0
    public var missLayout = 0
    /// Tokens with any mistake of the person.
    public var errors = 0
    /// Wrong tokens with the system and without it.
    public var wrong = 0
    public var wrongNull = 0
    public var rates = Rates()

    /// В, П, Пч, О, О₀ (‰) and «чисто» (share of cases); nil without a denominator.
    public struct Rates: Hashable, Sendable, Codable {
        /// В: harm per 1000 words.
        public var harm: Double?
        public var harmEvents: Double?
        /// П: layout mistakes left, per 1000 layout mistakes.
        public var missLayout: Double?
        /// Пч: botched per 1000 tokens with a mistake.
        public var botched: Double?
        /// О: wrong tokens per 1000 words.
        public var rest: Double?
        /// О₀: the same without the system.
        public var restNull: Double?
        /// Share of exact cases, 0…1.
        public var exact: Double?
    }

    mutating func add(_ score: CaseScore) {
        cases += 1
        if score.exact { exact += 1 } else { fail += 1 }
        if !score.failedChecks.isEmpty { checksFailed += 1 }
        words += score.words
        harmEvents += score.harmEvents
        for token in score.tokens {
            if !token.measured {
                if token.outcome == .spill { spill += 1 }
                continue
            }
            tokens += 1
            switch token.outcome {
            case .ok: ok += 1
            case .fixed: fixed += 1
            case .harm: harm += 1
            case .miss: miss += 1
            case .botched: botched += 1
            case .spill: spill += 1
            }
            if token.err == .layout {
                layoutErrors += 1
                if token.outcome == .miss { missLayout += 1 }
            }
            if token.err != .none { errors += 1 }
            if [.harm, .miss, .botched].contains(token.outcome) { wrong += 1 }
            if [.fixed, .miss, .botched].contains(token.outcome) { wrongNull += 1 }
        }
    }

    mutating func computeRates() {
        func perMille(_ count: Int, _ of: Int) -> Double? {
            of > 0 ? (Double(count) * 1000 / Double(of) * 1000).rounded() / 1000 : nil
        }
        rates.harm = perMille(harm, words)
        rates.harmEvents = perMille(harmEvents, words)
        rates.missLayout = perMille(missLayout, layoutErrors)
        rates.botched = perMille(botched, errors)
        rates.rest = perMille(wrong, words)
        rates.restNull = perMille(wrongNull, words)
        rates.exact = cases > 0 ? (Double(exact) / Double(cases) * 10000).rounded() / 10000 : nil
    }
}

/// `summary.json`: the metrics by suite and scenario, and the incidents.
public struct Summary: Hashable, Sendable, Codable {
    public static let schema = 1

    public struct Group: Hashable, Sendable, Codable {
        public var suite: String
        public var scenario: String
        public var metrics: Metrics
    }

    /// The incidents by status: how many there are, how many pass.
    public struct Incidents: Hashable, Sendable, Codable {
        public var fixed = 0
        public var fixedPassing = 0
        public var open = 0
        /// An open incident that passes: its status needs updating.
        public var openPassing = 0
    }

    public var schema = Summary.schema
    public var scorer = Scorer.version
    public var groups: [Group] = []
    public var total = Metrics()
    public var incidents = Incidents()

    public init(_ scores: [CaseScore]) {
        var groups: [String: Group] = [:]
        for score in scores {
            let key = score.suite + "\u{1F}" + score.scenario
            groups[key, default: Group(suite: score.suite, scenario: score.scenario, metrics: Metrics())].metrics.add(score)
            total.add(score)
            switch score.status {
            case "fixed"?:
                incidents.fixed += 1
                if score.exact { incidents.fixedPassing += 1 }
            case "open"?:
                incidents.open += 1
                if score.exact { incidents.openPassing += 1 }
            default:
                break
            }
        }
        self.groups = groups.keys.sorted().compactMap { groups[$0] }
        for index in self.groups.indices { self.groups[index].metrics.computeRates() }
        total.computeRates()
    }
}
