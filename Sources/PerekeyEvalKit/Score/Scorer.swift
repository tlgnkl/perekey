// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// What became of a token (docs/eval.md, «Исходы»). Defined by the text
/// alone: right or wrong without the system (Null) and with it.
public enum Outcome: String, Hashable, Sendable, Codable, CaseIterable {
    /// Right without the system, right with it.
    case ok
    /// Wrong without, right with: the person's mistake fixed.
    case fixed
    /// Right without, wrong with.
    case harm
    /// Wrong without, wrong with, and the same.
    case miss
    /// Wrong without, wrong with, and changed.
    case botched
    /// A token of the warm-up came out wrong.
    case spill
    /// Right without, wrong with, but the source's own typo mended (7.5): no harm.
    case disputed

    /// The letter of `cases.tsv`.
    public var letter: Character {
        switch self {
        case .ok: "o"
        case .fixed: "F"
        case .harm: "H"
        case .miss: "M"
        case .botched: "B"
        case .spill: "S"
        case .disputed: "D"
        }
    }
}

/// The features of a token for slices (docs/eval.md, «Признаки токена»).
public struct TokenFeatures: Hashable, Sendable, Codable {
    public var lang: String
    public var len: String
    public var pos: String
    public var ctx: String
    public var cap: String
    public var punct: String
    public var digits: String
    public var err: String
    public var end: String
    public var tags: [String]
    /// From the trace of the system, when it names this token.
    public var reason: String?
    public var margin: String?
    public var early: String?
    public var kind: String?
    /// From the lexicon and the lists, when the run has them (plan, 7.6): the
    /// model has the word form (`yes`/`no`), its Zipf range, whether the keys in
    /// another layout of the case give a word, whether `data/` lists the word.
    public var known: String?
    public var zipf: String?
    public var collision: String?
    public var seen: String?
}

/// The score of one token of `want`.
public struct TokenScore: Hashable, Sendable {
    /// Its index among the tokens of `want`, the warm-up included.
    public var index: Int
    public var measured: Bool
    public var want: String
    /// What the alignment gave it from the output of Null and of the system.
    public var null: String
    public var out: String
    public var outcome: Outcome
    /// For harm and botched: `layout` when the output is the token's keys in
    /// another layout of the case, `edit` otherwise.
    public var form: String?
    /// The system switched the layout before the token and did not touch the token.
    public var cascade: Bool
    public var features: TokenFeatures?
    public var trace: [TraceEntry]
    public var err: TokenError
    /// For harm and botched: the output is a word of the lexicon in its own
    /// script, so the person does not notice it (plan, 7.3). Needs `Knowledge`.
    public var silent = false
    /// The weight of the token (`w` of the case, 1 by default).
    public var weight = 1.0
}

/// The score of a case.
public struct CaseScore: Hashable, Sendable {
    public var id: String
    public var suite: String
    public var scenario: String
    public var split: EvalCase.Split
    public var scoring: EvalCase.Scoring
    public var status: String?
    /// The epoch of the case's sample (plan, 9.5).
    public var epoch = 1
    /// Every token of `want`, the warm-up first; empty for `scoring: case`.
    public var tokens: [TokenScore]
    public var warmupTokens: Int
    /// Tokens of the measured part with a letter.
    public var words: Int
    /// Every token right; for `scoring: case`, the text.
    public var exact: Bool
    /// How many checks the case has.
    public var checkCount = 0
    /// The case's checks that failed. A label the runner puts on the case
    /// (`Runner.failedChecks`): the scorer reads the text alone (rule 2.7).
    public var failedChecks: [Check]
    /// Tokens from the first token with a layout mistake to the first one
    /// that came out right; for `slip` and `stuck` scenarios.
    public var lag: Int?
    public var wantText: String
    public var nullText: String
    public var outText: String
    /// The words of this case stay out of files and output: it is in the
    /// test part, and the run does not reveal it (rule 2.8). Set by the runner.
    public var hidden = false
    /// The case is of a personal set (`personal.` suite): its words are the
    /// person's own, and files and output carry hashes in their place (rule 2.9).
    public var personal = false

    public var measured: [TokenScore] { tokens.filter(\.measured) }

    /// Events of harm: runs of harmed tokens one after another.
    public var harmEvents: Int {
        var events = 0
        var inRun = false
        for token in measured {
            if token.outcome == .harm {
                if !inRun { events += 1 }
                inRun = true
            } else {
                inRun = false
            }
        }
        return events
    }

    /// The outcome letters of every token, the warm-up first.
    public var outcomeString: String { String(tokens.map(\.outcome.letter)) }
}

/// The scorer: the case, the output of Null and of the system, and nothing
/// about how the system works (docs/eval.md, «Исходы»). The trace only adds
/// labels and features.
public struct Scorer: Sendable {
    /// The version of the scoring rules, written into every run. A change of
    /// meaning is a new version and a line in docs/eval.md, «История определений».
    public static let version = 4

    public let aligner: Aligner
    public let library: LayoutLibrary
    public let knowledge: Knowledge?

    public init(library: LayoutLibrary, aligner: Aligner = Aligner(), knowledge: Knowledge? = nil) {
        self.library = library
        self.aligner = aligner
        self.knowledge = knowledge
    }

    /// Scores a case. `model` is the language model the system played with, for
    /// the feature `known`; without it the feature stays out.
    public func score(_ item: EvalCase, null: RunResult, out: RunResult, events: [TypedEvent] = [],
                      model: LanguageModel? = nil) -> CaseScore
    {
        let fold = item.effectiveFold
        let wantTokens = Tokenizer.tokens(item.want)
        let warmupCount = item.warmupTokenCount
        let measuredWords = Array(wantTokens.dropFirst(warmupCount)).filter(Tokenizer.isWord).count
        var result = CaseScore(
            id: item.id, suite: item.suite, scenario: item.scenario, split: item.split,
            scoring: item.effectiveScoring, status: item.status, tokens: [], warmupTokens: warmupCount,
            words: measuredWords, exact: false, failedChecks: [], lag: nil, wantText: item.want, nullText: null.text,
            outText: out.text
        )
        result.checkCount = item.checks?.count ?? 0
        result.epoch = item.effectiveEpoch
        guard item.effectiveScoring == .token, let specs = item.tokens else {
            result.exact = Self.normalize(out.text, fold) == Self.normalize(item.want, fold)
            return result
        }
        func spec(_ index: Int) -> TokenSpec? {
            index >= warmupCount && index - warmupCount < specs.count ? specs[index - warmupCount] : nil
        }
        // The decisions about the source's noise (7.5), for the dev part only.
        let decisions = knowledge?.noise.decisions(for: item) ?? [:]
        let accept = { (index: Int) -> [String] in
            var forms = spec(index)?.accept ?? []
            if case let .sourceTypo(form)? = decisions[index] { forms.append(form) }
            return forms
        }
        let judge = Self.judge(want: wantTokens, fold: fold, accept: accept)
        let right = Self.groupRight(fold: fold, accept: accept)
        let nullSide = side(want: wantTokens, out: Tokenizer.tokens(null.text), judge: judge, right: right)
        let outSide = side(want: wantTokens, out: Tokenizer.tokens(out.text), judge: judge, right: right)

        let map = TokenMap(item, events: events)
        var traceByToken: [Int: [TraceEntry]] = [:]
        for entry in out.trace {
            if let token = map.token(ofEvent: entry.event) { traceByToken[token, default: []].append(entry) }
        }
        let languages = tokenLanguages(item, wantTokens, warmupCount: warmupCount)
        let caseLanguages = Array(Set(item.layouts.compactMap { library[$0]?.language })).sorted()
        let ends = Tokenizer.tokensWithEnds(item.want)

        for index in wantTokens.indices {
            let measured = index >= warmupCount
            let nullRight = nullSide.right[index], outRight = outSide.right[index]
            let outcome: Outcome
            if !measured {
                outcome = outRight ? .ok : .spill
            } else {
                switch (nullRight, outRight) {
                case (true, true): outcome = .ok
                case (true, false): outcome = .harm
                case (false, true): outcome = .fixed
                case (false, false): outcome = outSide.text[index] == nullSide.text[index] ? .miss : .botched
                }
            }
            let trace = traceByToken[index] ?? []
            var token = TokenScore(
                index: index, measured: measured, want: wantTokens[index], null: nullSide.text[index],
                out: outSide.text[index], outcome: outcome, form: nil, cascade: false, features: nil, trace: trace,
                err: spec(index)?.err ?? .none
            )
            if outcome == .harm || outcome == .botched {
                token.form = isOtherLayout(token.want, typedAs: token.out, layouts: item.layouts) ? "layout" : "edit"
                token.cascade = isCascade(index, trace: out.trace, map: map, events: events, own: trace)
            }
            token.weight = spec(index)?.w ?? 1
            if measured, let knowledge {
                let language = languages[index]
                // 7.5: a harm that mends the source's typo is disputed, unless a decision says harm.
                if outcome == .harm, token.form == "edit", knowledge.disputes(suite: item.suite),
                   decisions[index] != .harm,
                   knowledge.isDisputed(want: token.want, out: token.out, language: language)
                {
                    token.outcome = .disputed
                }
                if token.outcome == .harm || token.outcome == .botched {
                    token.silent = knowledge.isSilent(out: token.out, languages: caseLanguages)
                }
            }
            if measured {
                token.features = features(index, tokens: wantTokens, languages: languages, spec: spec(index),
                                          end: ends[index].end, trace: trace, tags: item.tags ?? [])
                if let knowledge {
                    addKnowledge(&token.features!, token: wantTokens[index], language: languages[index], item: item,
                                 knowledge: knowledge, model: model)
                }
            }
            result.tokens.append(token)
        }
        result.exact = result.tokens.allSatisfy { outSide.right[$0.index] }
        if item.scenario.hasPrefix("slip") || item.scenario.hasPrefix("stuck") {
            result.lag = Self.lag(result.measured)
        }
        return result
    }

    // MARK: - Equality

    static func fold(_ text: String, _ folds: Set<EvalCase.Fold>) -> String {
        guard folds.contains(.yo) else { return text }
        return String(text.map { $0 == "ё" ? "е" : $0 == "Ё" ? "Е" : $0 })
    }

    /// The text without the whitespace at its end, folded.
    static func normalize(_ text: String, _ folds: Set<EvalCase.Fold>) -> String {
        var text = text
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return fold(text, folds)
    }

    /// What the alignment prices: equal tokens by the folds or `accept`,
    /// and the glue rule of merges and cuts (two tokens glued without a space
    /// or with a hyphen give the one). The glue rule only lines tokens up;
    /// whether a group is right is `groupRight`.
    static func judge(want: [String], fold folds: Set<EvalCase.Fold>, accept: @escaping (Int) -> [String])
        -> Aligner.Judge
    {
        let folded = want.map { fold($0, folds) }
        func accepted(_ w: Int, _ text: String) -> Bool {
            let text = fold(text, folds)
            return accept(w).contains { fold($0, folds) == text }
        }
        return Aligner.Judge(
            same: { w, out in folded[w] == fold(out, folds) || accepted(w, out) },
            merged: { w, out in
                let out = fold(out, folds)
                return out == folded[w] + folded[w + 1] || out == folded[w] + "-" + folded[w + 1] || accepted(w, out)
            },
            cut: { w, first, second in
                let glued = fold(first + second, folds), hyphened = fold(first + "-" + second, folds)
                return folded[w] == glued || folded[w] == hyphened || accepted(w, first + second)
                    || accepted(w, first + "-" + second) || accepted(w, first + " " + second)
            }
        )
    }

    /// Whether a group of `want` is right (7.2, clarified 10.11.2026): the
    /// output text given to it equals the group's text by the folds, or is
    /// one of the `accept` forms of its first token. «во первых» for «во-первых»
    /// is wrong, though the glue rule lines them up.
    static func groupRight(fold folds: Set<EvalCase.Fold>, accept: @escaping (Int) -> [String])
        -> (_ w: Int, _ group: String, _ out: String) -> Bool
    {
        { w, group, out in
            let out = fold(out, folds)
            return fold(group, folds) == out || accept(w).contains { fold($0, folds) == out }
        }
    }

    /// One side of the comparison: for each token of `want`, the output the
    /// alignment gave it and whether it is right.
    private func side(want: [String], out: [String], judge: Aligner.Judge,
                      right isRight: (Int, String, String) -> Bool) -> (text: [String], right: [Bool])
    {
        var text = Array(repeating: "", count: want.count)
        var right = Array(repeating: false, count: want.count)
        /// Extra tokens of the output, with the group of `want` on their
        /// left, or the first token (`before`) when nothing is on the left.
        var extras: [(o: Int, group: [Int], before: Bool)] = []
        var last: [Int]?
        for op in aligner.align(want: want, out: out, judge: judge) {
            switch op {
            case let .pair(w, o):
                text[w] = out[o]
                right[w] = isRight(w, want[w], out[o])
                last = [w]
            case let .merge(w, o):
                text[w] = out[o]
                text[w + 1] = out[o]
                right[w] = isRight(w, want[w] + " " + want[w + 1], out[o])
                right[w + 1] = right[w]
                last = [w, w + 1]
            case let .split(w, o):
                text[w] = out[o] + " " + out[o + 1]
                right[w] = isRight(w, want[w], text[w])
                last = [w]
            case let .dropped(w):
                right[w] = false
                last = [w]
            case let .extra(o):
                if !want.isEmpty { extras.append((o, last ?? [0], last == nil)) }
            }
        }
        // An extra token makes the whole group on its left wrong and joins its output.
        for extra in extras {
            let token = out[extra.o]
            for w in extra.group {
                text[w] = text[w].isEmpty ? token : extra.before ? token + " " + text[w] : text[w] + " " + token
                right[w] = false
            }
        }
        return (text, right)
    }

    // MARK: - Lag

    static func lag(_ measured: [TokenScore]) -> Int? {
        guard let first = measured.firstIndex(where: { $0.err == .layout }) else { return nil }
        let right: Set<Outcome> = [.ok, .fixed]
        guard let fixed = measured[first...].firstIndex(where: { right.contains($0.outcome) }) else {
            return measured.count
        }
        return fixed - first
    }

    // MARK: - Labels

    /// Whether `out` is the keys of `want` typed in another layout of the case.
    private func isOtherLayout(_ want: String, typedAs out: String, layouts names: [String]) -> Bool {
        let maps = names.compactMap { library[$0] }
        for source in maps where want.allSatisfy({ source.stroke(for: $0) != nil }) {
            for target in maps where target.id != source.id && target.convert(want, from: source) == out {
                return true
            }
        }
        return false
    }

    /// The system switched the layout before the token (after the person last
    /// chose one) and left the token alone.
    private func isCascade(_ index: Int, trace: [TraceEntry], map: TokenMap, events: [TypedEvent],
                           own: [TraceEntry]) -> Bool
    {
        guard own.isEmpty, let first = map.firstEvent[index],
              let switched = trace.last(where: { $0.kind == .switched && $0.event < first })
        else { return false }
        let between = events.indices.filter { $0 > switched.event && $0 < first }
        return !between.contains { if case .userLayout = events[$0].event { true } else { false } }
    }

    // MARK: - Features

    /// The language of every token of `want`: from the case for the measured
    /// part; for the warm-up, the first layout of the case that types the
    /// token's letters.
    private func tokenLanguages(_ item: EvalCase, _ tokens: [String], warmupCount: Int) -> [String] {
        let maps = item.layouts.compactMap { library[$0] }
        return tokens.indices.map { index in
            if index >= warmupCount, let specs = item.tokens, index - warmupCount < specs.count {
                return specs[index - warmupCount].lang
            }
            let letters = tokens[index].filter(\.isLetter)
            guard !letters.isEmpty else { return "-" }
            let map = maps.first { map in letters.allSatisfy { map.stroke(for: $0) != nil } }
            return map?.language ?? "-"
        }
    }

    /// The features that need the lexicon, the model or the lists (plan, 7.6).
    private func addKnowledge(_ features: inout TokenFeatures, token: String, language: String, item: EvalCase,
                              knowledge: Knowledge, model: LanguageModel?)
    {
        let core = Lexicon.core(token)
        features.zipf = knowledge.zipfBucket(token, language: language)
        features.seen = knowledge.seen.map { $0.contains(core) ? "yes" : "no" }
        if language == "-" || core.isEmpty {
            features.collision = "-"
        } else {
            features.collision = hasCollision(token, layouts: item.layouts, knowledge: knowledge) ? "yes" : "no"
        }
        if let model {
            if language == "-" || core.isEmpty {
                features.known = "-"
            } else if let table = model.language(language) {
                let fingerprint = ModelFormat.Fingerprint.of(core.unicodeScalars, folded: true)
                features.known = table.rank(of: fingerprint) != nil ? "yes" : "no"
            }
        }
    }

    /// The keys of the token in another layout of the case give a word of that
    /// layout's language with Zipf from 3 (plan, 7.6: «vs» and «мы»).
    private func hasCollision(_ token: String, layouts names: [String], knowledge: Knowledge) -> Bool {
        let maps = names.compactMap { library[$0] }
        for source in maps where token.allSatisfy({ source.stroke(for: $0) != nil }) {
            for target in maps where target.id != source.id {
                guard let language = target.language else { continue }
                let converted = Lexicon.core(target.convert(token, from: source))
                if let zipf = knowledge.lexicon.zipf(of: converted, language: language),
                   zipf >= knowledge.options.collisionMinZipf
                {
                    return true
                }
            }
        }
        return false
    }

    private func features(_ index: Int, tokens: [String], languages: [String], spec: TokenSpec?, end: Character?,
                          trace: [TraceEntry], tags: [String]) -> TokenFeatures
    {
        let token = tokens[index]
        let lang = languages[index]
        let letters = token.filter(\.isLetter)
        let len = switch letters.count {
        case 0...2: "1-2"
        case 3: "3"
        case 4: "4"
        case 5...7: "5-7"
        default: "8+"
        }
        let pos = index == 0 ? "first" : index == tokens.count - 1 ? "last" : "mid"
        let ctx: String
        let before = tokens.indices.prefix(index).reversed().filter { languages[$0] != "-" }.prefix(3).map { languages[$0] }
        if lang == "-" {
            ctx = "-"
        } else if before.isEmpty {
            ctx = "cold"
        } else if before.contains(lang), before.contains(where: { $0 != lang }) {
            ctx = "mixed"
        } else {
            ctx = before[0] == lang ? "agree" : "against"
        }
        // What the system decided about the word: a switch, a correction, or, with the
        // trace of judgements, that it kept the word or did not judge it.
        let entry = trace.last { [.switched, .corrected, .kept, .notJudged].contains($0.kind) }
        return TokenFeatures(
            lang: lang, len: len, pos: pos, ctx: ctx, cap: Self.capitals(letters), punct: Self.punctuation(token),
            digits: token.contains(where: \.isNumber) ? "yes" : "no", err: (spec?.err ?? .none).rawValue,
            end: Self.end(token, end), tags: tags + (spec?.tags ?? []).filter { !tags.contains($0) }, reason: entry?.reason,
            margin: entry.flatMap { entry in
                guard let score = entry.score, let margin = entry.margin else { return nil }
                return Self.marginBucket(score: score, margin: margin)
            },
            early: entry?.insideWord.map { $0 ? "yes" : "no" }, kind: entry?.correction
        )
    }

    /// How far the decision was from the threshold, in bits, on either side:
    /// a switch above it, a word kept under it. `nil` when the other reading
    /// is no word (the score is not finite) and there is no threshold to measure.
    static func marginBucket(score: Double, margin: Double) -> String? {
        guard score.isFinite else { return nil }
        let distance = abs(score - margin)
        return distance < 3 ? "<3" : distance < 10 ? "3-10" : "10+"
    }

    static func capitals(_ letters: String) -> String {
        let flags = letters.map(\.isUppercase)
        guard flags.contains(true) else { return letters.isEmpty ? "-" : "lower" }
        if flags.allSatisfy({ $0 }) { return flags.count >= 2 ? "UPPER" : "Title" }
        if flags[0], !flags.dropFirst().contains(true) { return "Title" }
        return flags[0] ? "mixed" : "inner"
    }

    static func punctuation(_ token: String) -> String {
        let characters = Array(token)
        let isMark = { (character: Character) in !character.isLetter && !character.isNumber }
        guard let first = characters.firstIndex(where: { !isMark($0) }),
              let last = characters.lastIndex(where: { !isMark($0) })
        else { return characters.isEmpty ? "none" : "both" }
        let lead = first > 0, trail = last < characters.count - 1
        if lead, trail { return "both" }
        if lead { return "lead" }
        if trail { return "trail" }
        return characters[first...last].contains(where: isMark) ? "inside" : "none"
    }

    static func end(_ token: String, _ next: Character?) -> String {
        if let last = token.last, !last.isLetter, !last.isNumber { return "punct" }
        switch next {
        case nil: return "none"
        case "\n"?, "\r"?, "\r\n"?: return "return"
        case "\t"?: return "tab"
        default: return "space"
        }
    }
}
