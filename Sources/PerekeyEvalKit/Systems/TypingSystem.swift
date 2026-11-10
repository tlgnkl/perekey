// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyDesk

/// What a system under test gets before the first event of a case.
public struct CaseSetup: Sendable {
    public var item: EvalCase
    /// The case's layouts, in its order.
    public var layouts: [LayoutMap]
    public var start: LayoutMap
    /// The preset of the case with its own words.
    public var settings: Settings
    /// The classifier of the run, for the systems that judge words.
    public var classifier: Classifier?

    public init(item: EvalCase, library: LayoutLibrary, classifier: Classifier?) throws {
        self.item = item
        layouts = try library.maps(of: item)
        guard let start = library[item.start] else { throw EvalError.input("\(item.id): unknown layout \(item.start)") }
        self.start = start
        settings = try EvalSettings.settings(for: item.effectiveEnv)
        self.classifier = classifier
    }
}

/// What a system knows about its own actions. The scorer never reads it: it
/// only labels and slices (docs/eval.md, «Исходы»).
public struct TraceEntry: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// The layout of a word was switched.
        case switched
        /// A word was corrected in its layout: `correction` says how.
        case corrected
        /// A correction was undone.
        case undone
        /// A retype was not carried out: the text before the caret differed.
        case cancelled
    }

    /// The index of the typist's event during which it happened.
    public var event: Int
    public var kind: Kind
    /// The `Correction.Kind` of a correction: layout, typo, capsLock…
    public var correction: String?
    /// The classifier's reason, for a switch at the end of a word.
    public var reason: String?
    /// Nil when the score is not finite: the other reading is no word.
    public var score: Double?
    /// The score the switch needed (`Classifier.Decision.margin`).
    public var margin: Double?
    /// A switch inside the word (an impossible start).
    public var insideWord: Bool?
}

/// The outcome of one case on one system.
public struct RunResult: Hashable, Sendable {
    /// The text of the field at the end.
    public var text: String
    /// The layout in force at the end.
    public var layout: LayoutID
    /// Corrections shown.
    public var corrections: Int
    public var undone: Int
    /// May be empty.
    public var trace: [TraceEntry]

    public init(text: String, layout: LayoutID, corrections: Int = 0, undone: Int = 0, trace: [TraceEntry] = []) {
        self.text = text
        self.layout = layout
        self.corrections = corrections
        self.undone = undone
        self.trace = trace
    }
}

/// A system under test: Perekey in memory, nothing, the ideal, or a real
/// app. Every system gets the same events of the typist.
public protocol TypingSystem {
    init(setup: CaseSetup) throws
    mutating func send(_ event: TypistEvent, at time: Double) throws
    mutating func finish() throws -> RunResult
}

/// The systems `perekey-eval play` knows.
public enum SystemName: String, Sendable, CaseIterable {
    case machine, null, oracle

    public func play(_ setup: CaseSetup, events: [TypedEvent]) throws -> RunResult {
        switch self {
        case .machine: try Self.play(MachineSystem.self, setup, events)
        case .null: try Self.play(NullSystem.self, setup, events)
        case .oracle: try Self.play(OracleSystem.self, setup, events)
        }
    }

    static func play<System: TypingSystem>(_: System.Type, _ setup: CaseSetup, _ events: [TypedEvent]) throws
        -> RunResult
    {
        var system = try System(setup: setup)
        for typed in events { try system.send(typed.event, at: typed.time) }
        return try system.finish()
    }
}
