// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// A word of a replayed session with what the user did about it, and the
/// label that gives (docs/classifier.md, «Замер на живых сессиях»).
public struct ObservedWord: Sendable {
    /// What happened after the decision.
    public enum Outcome: Hashable, Sendable {
        case notJudged(JudgeTrace.Skip)
        /// Kept, and the user typed on.
        case kept
        /// Kept, and the user retyped it with the shortcut.
        case keptThenRetyped
        /// Kept, and the user erased it and typed the same keys in another layout.
        case keptThenRetypedAfterErasing
        /// Switched or corrected, and it stayed.
        case acted
        /// Switched or corrected, and undone: by which channel, and what the
        /// user did after a Backspace undo. Nil when the machine did not
        /// report the undo (learning from undos off).
        case actedThenUndone(UndoChannel?, UndoFollowUp?)
        /// The retype was never posted: the text before the caret was not
        /// the word, or the fence ran out first.
        case cancelled
    }

    public enum Label: String, Hashable, Sendable, Codable, CaseIterable {
        /// Nothing to say: not judged, or never retyped.
        case none
        /// What Perekey did was right.
        case right
        /// A switch the user undid.
        case falseSwitch
        /// Undone, but what the Backspace was for is not clear.
        case unclear
        /// A word the user switched themselves.
        case miss
        /// A word correction the user undid.
        case wrongCorrection
    }

    public enum Strength: String, Hashable, Sendable, Codable {
        /// The user said so: an undo, a retype.
        case strong
        /// The user typed on: nothing said otherwise.
        case weak
    }

    public var trace: JudgeTrace
    /// `ReplayStep.source` of the event the word was judged at.
    public var source: Int?
    /// Its index in `ReplayRun.steps`.
    public var step: Int
    public var outcome: Outcome
    public var label: Label
    /// Nil for `.none` and `.unclear`.
    public var strength: Strength?
    /// The layout the user retyped a missed word into, when known.
    public var retypedTo: LayoutID?
}

public enum SessionWords {
    public struct Options: Sendable {
        /// A kept word erased and typed again counts as missed from this
        /// many keys: shorter words are retyped for many reasons. The same
        /// floor as `WordJudge.endsPart` uses for a word.
        public var minKeys = 3
        /// Seconds from the end of the word to the last key typed again.
        /// A first guess: long enough to notice the word and retype it,
        /// short enough not to meet the same word typed later on purpose.
        /// Check it on recordings: `perekey-eval replay words --show-words`.
        public var maxRetypeDelay = 15.0

        public init() {}
    }

    /// The words of a replayed segment, each with its label.
    public static func extract(_ run: ReplayRun, options: Options = Options()) -> [ObservedWord] {
        let traced = run.steps.indices.filter { run.steps[$0].trace != nil }
        return traced.enumerated().map { number, index in
            let next = number + 1 < traced.count ? traced[number + 1] : run.steps.count
            return observe(run, at: index, next: next, options: options)
        }
    }

    private static func observe(_ run: ReplayRun, at index: Int, next: Int, options: Options) -> ObservedWord {
        let step = run.steps[index]
        let trace = step.trace!
        var word = ObservedWord(trace: trace, source: step.source, step: index, outcome: .kept, label: .right,
                                strength: .weak)
        switch trace.action {
        case let .notJudged(skip):
            word.outcome = .notJudged(skip)
        case .switched, .corrected:
            word.outcome = acted(run, seq: trace.seq, from: index, next: next)
        case .kept:
            if let target = retypedByHand(run, from: index) {
                word.outcome = .keptThenRetyped
                word.retypedTo = target
            } else if erasedAndRetyped(run, trace: trace, from: index, options: options) {
                word.outcome = .keptThenRetypedAfterErasing
            }
        }
        (word.label, word.strength) = label(word.outcome, action: trace.action)
        return word
    }

    static func label(_ outcome: ObservedWord.Outcome,
                      action: JudgeTrace.Action) -> (ObservedWord.Label, ObservedWord.Strength?)
    {
        switch outcome {
        case .notJudged, .cancelled:
            return (.none, nil)
        case .kept, .acted:
            return (.right, .weak)
        case .keptThenRetyped, .keptThenRetypedAfterErasing:
            return (.miss, .strong)
        case let .actedThenUndone(channel, followUp):
            // A switch and a correction are read alike: what the undo was
            // for decides, not what was undone.
            var wrong = ObservedWord.Label.falseSwitch
            if case .corrected = action { wrong = .wrongCorrection }
            switch (channel, followUp) {
            case (.button?, _), (.shortcut?, _), (.backspace?, .continued?):
                return (wrong, .strong)
            case (.backspace?, .retyped?):
                // Undone with Backspace and put back with the shortcut: the
                // switch or correction was what the user wanted
                // (`UndoFollowUp.retyped`). `InputMachine` reads it the same way.
                return (.right, .strong)
            default:
                return (.unclear, nil)
            }
        }
    }

    /// What became of the retype `seq` that switched or corrected the word.
    private static func acted(_ run: ReplayRun, seq: UInt32?, from index: Int, next: Int) -> ObservedWord.Outcome {
        guard let seq, posted(run, seq: seq, after: index) != nil else { return .cancelled }
        // The undo is a retype of its own, asked for before the next word.
        for undoAt in index + 1..<max(index + 1, next) {
            for case let .retype(retype) in run.steps[undoAt].output.effects where retype.origin == "undo" {
                // Cancelled: the text stays corrected.
                guard let undoPosted = posted(run, seq: retype.seq, after: undoAt - 1) else { return .acted }
                // The report comes with the undo, at the next key after a
                // Backspace, or at the end of a word undone inside it. An
                // undo posted after that has no report in sight.
                let end = min(run.steps.count, next + 1)
                guard undoPosted < end else { return .actedThenUndone(nil, nil) }
                for reportAt in undoPosted..<end {
                    for case let .undoSettled(report) in run.steps[reportAt].output.effects {
                        return .actedThenUndone(report.channel, report.followUp)
                    }
                }
                return .actedThenUndone(nil, nil)
            }
        }
        return .acted
    }

    /// The step the retype `seq` was posted at, after `index`.
    private static func posted(_ run: ReplayRun, seq: UInt32, after index: Int) -> Int? {
        for at in (index + 1)..<max(index + 1, run.steps.count) {
            if case let .retypePosted(found, _) = run.steps[at].event, found == seq { return at }
            if case let .retypeCancelled(found) = run.steps[at].event, found == seq { return nil }
        }
        return nil
    }

    /// The retype shortcut on the word right after it ended: the layout it
    /// went to. Any other key of the user's but a space ends the chance.
    private static func retypedByHand(_ run: ReplayRun, from index: Int) -> LayoutID? {
        for at in index + 1..<run.steps.count {
            let step = run.steps[at]
            for case let .retype(retype) in step.output.effects where retype.origin == "manual.convertLastWord" {
                return retype.target
            }
            if let key = step.event.userKeyDown, key.keyCode != KeyCode.space { return nil }
            switch step.event {
            case .click, .focusChanged, .inputLost, .layoutsChanged: return nil
            default: continue
            }
        }
        return nil
    }

    /// The word erased (Backspace at least once per key, or ⌥⌫) with no other
    /// key of text, the layout changed by the user before or after, and the
    /// same keys typed again in a row: in one focus, within `maxRetypeDelay`.
    private static func erasedAndRetyped(_ run: ReplayRun, trace: JudgeTrace, from index: Int,
                                         options: Options) -> Bool
    {
        let keys = trace.keys.map(\.keyCode)
        guard keys.count >= options.minKeys, let start = lastTime(run, upTo: index) else { return false }
        var erased = 0
        var retyped = 0
        var layoutChanged = false
        for at in index + 1..<run.steps.count {
            let step = run.steps[at]
            if let time = step.event.time, time - start > options.maxRetypeDelay { return false }
            if step.userLayoutChange, retyped == 0 { layoutChanged = true }
            switch step.event {
            case .click, .inputLost, .layoutsChanged: return false
            case let .focusChanged(_, change) where change == .moved: return false
            default: break
            }
            guard let key = step.event.userKeyDown else { continue }
            if retyped == 0, erased < keys.count {
                guard key.keyCode == KeyCode.delete else { return false }
                erased += key.flags & EventFlags.option != 0 ? keys.count : 1
                continue
            }
            if retyped == 0, key.keyCode == KeyCode.delete {
                erased += 1
                continue
            }
            guard key.keyCode == keys[retyped] else { return false }
            retyped += 1
            if retyped == keys.count { return layoutChanged }
        }
        return false
    }

    private static func lastTime(_ run: ReplayRun, upTo index: Int) -> Double? {
        for at in stride(from: index, through: 0, by: -1) {
            if let time = run.steps[at].event.time { return time }
        }
        return nil
    }
}
