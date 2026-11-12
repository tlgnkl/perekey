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
    /// Harms that mend a typo of the source (plan, 7.5): not in `harm`.
    public var disputed = 0
    /// Harmed and botched tokens whose output is a word of the lexicon (plan, 7.3, «тихая»).
    public var silent = 0
    /// The same counts with the weight `w` of the token (class suites, plan, 8.4).
    public var weightedWords = 0.0
    public var weightedHarm = 0.0
    public var weightedLayoutErrors = 0.0
    public var weightedMissLayout = 0.0
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
        /// Т: harmed and botched tokens the person does not notice, per 1000 words.
        public var silent: Double?
        /// Disputed tokens per 1000 words.
        public var disputed: Double?
        /// В and П with the weights of the tokens; nil where every weight is 1.
        public var harmWeighted: Double?
        public var missLayoutWeighted: Double?
    }

    public init() {}

    /// The counts of one case.
    public init(_ score: CaseScore) {
        add(score)
    }

    /// Adds the counts of another group (not its rates).
    public mutating func merge(_ other: Metrics) {
        cases += other.cases
        exact += other.exact
        fail += other.fail
        checksFailed += other.checksFailed
        tokens += other.tokens
        words += other.words
        ok += other.ok
        fixed += other.fixed
        harm += other.harm
        harmEvents += other.harmEvents
        miss += other.miss
        botched += other.botched
        spill += other.spill
        disputed += other.disputed
        silent += other.silent
        weightedWords += other.weightedWords
        weightedHarm += other.weightedHarm
        weightedLayoutErrors += other.weightedLayoutErrors
        weightedMissLayout += other.weightedMissLayout
        layoutErrors += other.layoutErrors
        missLayout += other.missLayout
        errors += other.errors
        wrong += other.wrong
        wrongNull += other.wrongNull
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
            if Tokenizer.isWord(token.want) { weightedWords += token.weight }
            switch token.outcome {
            case .ok: ok += 1
            case .fixed: fixed += 1
            case .harm: harm += 1
            case .miss: miss += 1
            case .botched: botched += 1
            case .spill: spill += 1
            case .disputed: disputed += 1
            }
            if token.outcome == .harm { weightedHarm += token.weight }
            if token.silent { silent += 1 }
            if token.err == .layout {
                layoutErrors += 1
                weightedLayoutErrors += token.weight
                if token.outcome == .miss {
                    missLayout += 1
                    weightedMissLayout += token.weight
                }
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
        rates.silent = perMille(silent, words)
        rates.disputed = perMille(disputed, words)
        let weighted = abs(weightedWords - Double(words)) > 1e-9
        if weighted, weightedWords > 0 { rates.harmWeighted = (weightedHarm * 1000 / weightedWords * 1000).rounded() / 1000 }
        if weighted, weightedLayoutErrors > 0 {
            rates.missLayoutWeighted = (weightedMissLayout * 1000 / weightedLayoutErrors * 1000).rounded() / 1000
        }
        rates.exact = cases > 0 ? (Double(exact) / Double(cases) * 10000).rounded() / 10000 : nil
    }
}

/// `summary.json`: the metrics by suite and scenario, and the incidents.
public struct Summary: Hashable, Sendable, Codable {
    public static let schema = 2

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
        var accumulator = Accumulator()
        for score in scores { accumulator.add(score) }
        self.init(accumulator)
    }

    /// The counts of cases one at a time, so a run need not keep all its scores.
    public struct Accumulator {
        fileprivate var groups: [String: Group] = [:]
        fileprivate var total = Metrics()
        fileprivate var incidents = Incidents()

        public init() {}

        public mutating func add(_ score: CaseScore) {
            let key = score.suite + "\u{1F}" + score.scenario
            let counts = Metrics(score)
            groups[key, default: Group(suite: score.suite, scenario: score.scenario, metrics: Metrics())].metrics.merge(counts)
            total.merge(counts)
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
    }

    public init(_ accumulated: Accumulator) {
        total = accumulated.total
        incidents = accumulated.incidents
        groups = accumulated.groups.keys.sorted().compactMap { accumulated.groups[$0] }
        for index in groups.indices { groups[index].metrics.computeRates() }
        total.computeRates()
    }
}
