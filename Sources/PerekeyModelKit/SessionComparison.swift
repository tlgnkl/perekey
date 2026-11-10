// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// `perekey-eval replay compare`: where a candidate classifier decides
/// otherwise than the recorded one, against the labels of the recording.
/// A strong label names the right decision: keep a switch the user undid,
/// switch a word the user switched, leave a correction the user undid, keep
/// a switch the user put back. The candidate fixes the word when it moves
/// to that decision, and breaks it when it moves away.
public struct SessionComparison: Codable, Equatable, Sendable {
    /// What was decided about a word, without the details.
    public enum Decided: Hashable, Sendable {
        case notJudged
        case kept
        case switched(LayoutID)
        case corrected(Correction.Kind)

        init(_ action: JudgeTrace.Action?) {
            switch action {
            case nil, .notJudged?: self = .notJudged
            case .kept?: self = .kept
            case let .switched(to, _)?: self = .switched(to)
            case let .corrected(kind)?: self = .corrected(kind)
            }
        }
    }

    public enum Change: String, Sendable {
        case fixed, broken, differs
    }

    /// A word decided otherwise, for `--show-words`.
    public struct Row: Sendable {
        public var word: ObservedWord
        public var candidate: JudgeTrace?
        public var change: Change
    }

    /// How far the simulated replay is from the exact one on the same model:
    /// words of the exact run decided otherwise by the simulated run of the
    /// same classifier. Not the candidate's doing, so it is kept apart; what
    /// `differ` counts is the candidate against the base in the same mode.
    public struct Calibration: Codable, Equatable, Sendable {
        public var words = 0
        public var differ = 0

        public init() {}
    }

    /// How many recorded events before a word's own a trace of the other run
    /// may sit and still be the same word, when a switch inside the word was
    /// judged at a letter and not at its end. A word has at most one key per
    /// event, and 64 is longer than any word a person types; not measured.
    /// Check it with `replay compare --show-words`: a word listed with
    /// «no trace» that the candidate did judge is one it missed.
    static let matchWindow = 64

    public var words = 0
    /// Decided otherwise by the candidate.
    public var differ = 0
    public var strongFixed = 0
    public var strongBroken = 0
    /// Decided otherwise on a word with a weak label.
    public var weakDiffer = 0
    public var unclearDiffer = 0
    public var rows: [Row] = []
    public var calibration = Calibration()

    private enum CodingKeys: String, CodingKey {
        case words, differ, strongFixed, strongBroken, weakDiffer, unclearDiffer, calibration
    }

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.words, lhs.differ, lhs.strongFixed, lhs.strongBroken, lhs.weakDiffer, lhs.unclearDiffer)
            == (rhs.words, rhs.differ, rhs.strongFixed, rhs.strongBroken, rhs.weakDiffer, rhs.unclearDiffer)
            && lhs.calibration == rhs.calibration
    }

    /// Adds a segment: its labelled words, and the candidate's simulated run.
    public mutating func add(base: [ObservedWord], candidate: ReplayRun) {
        add(Self.compared(base: base, candidate: candidate))
    }

    /// Adds the calibration of a segment: the words of the exact run of a
    /// classifier, and the simulated run of the same one.
    public mutating func calibrate(exact: [ObservedWord], simulated: ReplayRun) {
        let part = Self.compared(base: exact, candidate: simulated)
        calibration.words += part.words
        calibration.differ += part.differ
    }

    private static func compared(base: [ObservedWord], candidate: ReplayRun) -> SessionComparison {
        var result = SessionComparison()
        result.collect(base: base, candidate: candidate)
        return result
    }

    private mutating func collect(base: [ObservedWord], candidate: ReplayRun) {
        let traces = candidate.steps.compactMap { step in step.trace.map { (source: step.source, trace: $0) } }
        var used = Set<Int>()
        for (number, word) in base.enumerated() {
            words += 1
            let limit = number + 1 < base.count ? base[number + 1].source : nil
            let found = Self.match(word, in: traces, before: limit, used: &used)
            let before = Decided(word.trace.action)
            let after = Decided(found?.action)
            guard before != after else { continue }
            differ += 1
            var change = Change.differs
            if word.strength == .strong {
                let right = { (decided: Decided) in Self.isRight(decided, for: word) }
                if !right(before), right(after) {
                    strongFixed += 1
                    change = .fixed
                } else if right(before), !right(after) {
                    strongBroken += 1
                    change = .broken
                }
            } else if word.label == .right {
                weakDiffer += 1
            } else if word.label == .unclear {
                unclearDiffer += 1
            }
            rows.append(Row(word: word, candidate: found, change: change))
        }
    }

    /// The candidate's trace of the same word: judged at the same recorded
    /// event, or, when one of them switched inside the word, the next one
    /// of the other run on the same keys.
    private static func match(_ word: ObservedWord, in traces: [(source: Int?, trace: JudgeTrace)], before limit: Int?,
                              used: inout Set<Int>) -> JudgeTrace?
    {
        if let index = traces.firstIndex(where: { $0.source == word.source && $0.source != nil }), !used.contains(index) {
            used.insert(index)
            return traces[index].trace
        }
        guard let source = word.source else { return nil }
        let keys = word.trace.keys.map(\.keyCode)
        for (index, candidate) in traces.enumerated() where !used.contains(index) {
            guard let at = candidate.source, at >= source - Self.matchWindow, limit.map({ at < $0 }) ?? true else { continue }
            let other = candidate.trace.keys.map(\.keyCode)
            if other.starts(with: keys) || keys.starts(with: other) {
                used.insert(index)
                return candidate.trace
            }
        }
        return nil
    }

    /// Whether a decision is the one a strong label calls right.
    static func isRight(_ decided: Decided, for word: ObservedWord) -> Bool {
        switch word.label {
        case .falseSwitch:
            if case .switched = decided { false } else { true }
        case .miss:
            if case let .switched(to) = decided { word.retypedTo.map { $0 == to } ?? true } else { false }
        case .wrongCorrection:
            if case .corrected = decided { false } else { true }
        case .right:
            decided == Decided(word.trace.action)
        case .none, .unclear:
            false
        }
    }

    public func render() -> String {
        """
        words \(words): decided otherwise \(differ)
        strong labels: fixed \(strongFixed), broken \(strongBroken)
        weak labels decided otherwise \(weakDiffer), unclear ones \(unclearDiffer)
        calibration, simulated against exact on the same model: words \(calibration.words), \
        decided otherwise \(calibration.differ)
        """
    }

    /// The words decided otherwise, for `--show-words` only.
    public func renderWords(layouts: [LayoutMap]) -> String {
        rows.map { row in
            let line = SessionReport.words([row.word], layouts: layouts)
            let after = row.candidate.map { "\($0.action)" } ?? "no trace"
            return "\(row.change.rawValue): \(line) → \(after)"
        }.joined(separator: "\n")
    }
}
