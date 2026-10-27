// SPDX-License-Identifier: GPL-3.0-or-later

/// The shadow journal of learning: every counted undo, answer and unlearned
/// word, to tune `LearningOptions` on real use. It stays on this Mac
/// (`LearningJournalFile`) and holds no word: the channel, what came after
/// the undo, the classifier's facts, the evidence and the outcome, the
/// app's bundle ID and the time. It keeps the latest `capacity` entries.
public struct LearningJournal: Hashable, Sendable, Codable {
    public static let capacity = 500

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = Array(entries.suffix(Self.capacity))
    }

    public mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    public struct Entry: Hashable, Sendable, Codable {
        public enum Event: String, Hashable, Sendable, Codable {
            /// An undo counted (`WordRules.count`).
            case undo
            /// The user answered a `LearningQuestion`.
            case answer
            /// A learned word was retyped by hand and forgotten (`WordRules.unlearn`).
            case unlearn
        }

        public var event: Event
        /// Seconds since 1970.
        public var time: Double
        public var app: String?
        public var channel: UndoChannel?
        public var followUp: UndoFollowUp?
        public var facts: UndoFacts?
        public var threshold: Int?
        /// The word's evidence in the app after the undo.
        public var evidence: Int?
        public var outcome: LearningStep.Outcome?
        /// What one undo did before learning by evidence.
        public var oldRule: LearningStep.OldRule?
        public var answer: LearningAnswer?
        /// The word was learned everywhere, by the answer, or forgotten everywhere.
        public var everywhere: Bool?

        public init(undo report: UndoReport, step: LearningStep, at time: Double) {
            event = .undo
            self.time = time
            app = report.app
            channel = report.channel
            followUp = report.followUp
            facts = report.facts
            threshold = step.threshold
            evidence = step.evidence
            outcome = step.outcome
            oldRule = step.oldRule
        }

        public init(answer: LearningAnswer, to question: LearningQuestion, learned: LearnedWord?, at time: Double) {
            event = .answer
            self.time = time
            app = question.app
            self.answer = answer
            everywhere = learned.map { $0.app == nil }
        }

        public init(unlearned: Unlearned, app: String?, at time: Double) {
            event = .unlearn
            self.time = time
            self.app = app
            everywhere = unlearned.app == nil
        }
    }
}
