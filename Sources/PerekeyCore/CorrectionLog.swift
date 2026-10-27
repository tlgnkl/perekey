// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The last few automatic corrections, for the menu's «Recent corrections».
///
/// A value type with no storage: the app keeps it in memory only and it is gone
/// on quit (docs/PLAN.md, stage 6: typed text is never written to disk).
public struct CorrectionLog: Equatable, Sendable {
    /// How many corrections the log keeps.
    public static let limit = 5

    public struct Entry: Equatable, Sendable, Identifiable {
        /// Unique within the log's life. `seq` is not: it is the retype counter
        /// of the input machine and starts over.
        public let id: Int
        /// The `seq` of every correction the row stands for, oldest first.
        public var seqs: [UInt32]
        /// The newest one: the undo of the row's latest correction.
        public var seq: UInt32 { seqs[seqs.count - 1] }
        public var original: String
        public var replacement: String
        public var kind: Correction.Kind
        /// Why it happened: facts the menu's «Why?» puts into words.
        public var explanation: Explanation
        /// The classifier's decision as names and numbers, for a report.
        public var summary: String
        public var date: Date
        public var undone = false
        /// How many times this same correction happened: the menu shows «×3».
        public var count: Int { seqs.count }
    }

    /// Newest first, at most `limit`.
    public private(set) var entries: [Entry] = []
    private var nextID = 0

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// The newest correction that still stands: the menu shows it as the strip.
    public var latestStanding: Entry? { entries.first { !$0.undone } }

    /// Adds a correction at the top and drops the oldest past the limit. The same
    /// correction that still stands is not a second row: the row keeps its id (the
    /// menu keeps it open) and its earlier `seq`s, and takes the new one.
    public mutating func record(_ correction: Correction, at date: Date = Date()) {
        var id = nextID
        var seqs = [correction.seq]
        if let same = entries.firstIndex(where: {
            !$0.undone && $0.original == correction.original && $0.replacement == correction.replacement
                && $0.kind == correction.kind
        }) {
            let old = entries.remove(at: same)
            id = old.id
            seqs = old.seqs + seqs
        } else {
            nextID += 1
        }
        entries.insert(Entry(id: id, seqs: seqs, original: correction.original,
                             replacement: correction.replacement, kind: correction.kind,
                             explanation: Explanation(correction: correction),
                             summary: FalseSwitchReport.summary(of: correction), date: date), at: 0)
        trim()
    }

    /// Marks the newest standing entry with this `seq` as undone. In a row of
    /// several the row stands with one less and the undone correction becomes a
    /// struck row above it. An unknown `seq` (already pushed out of the log) does
    /// nothing. Returns whether an entry changed.
    @discardableResult
    public mutating func markUndone(seq: UInt32) -> Bool {
        guard let index = entries.firstIndex(where: { !$0.undone && $0.seqs.contains(seq) }) else { return false }
        guard entries[index].seqs.count > 1, let at = entries[index].seqs.lastIndex(of: seq) else {
            entries[index].undone = true
            return true
        }
        var struck = entries[index]
        struck.seqs = [seq]
        struck.undone = true
        entries[index].seqs.remove(at: at)
        entries.insert(Entry(id: nextID, seqs: struck.seqs, original: struck.original,
                             replacement: struck.replacement, kind: struck.kind,
                             explanation: struck.explanation, summary: struck.summary,
                             date: struck.date, undone: true), at: index)
        nextID += 1
        trim()
        return true
    }

    private mutating func trim() {
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }
}
