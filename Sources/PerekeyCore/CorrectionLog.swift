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
        public let seq: UInt32
        public var original: String
        public var replacement: String
        public var kind: Correction.Kind
        public var date: Date
        public var undone = false
    }

    /// Newest first, at most `limit`.
    public private(set) var entries: [Entry] = []
    private var nextID = 0

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// The newest correction that still stands: the menu shows it as the strip.
    public var latestStanding: Entry? { entries.first { !$0.undone } }

    /// Adds a correction at the top and drops the oldest past the limit.
    public mutating func record(_ correction: Correction, at date: Date = Date()) {
        entries.insert(Entry(id: nextID, seq: correction.seq, original: correction.original,
                             replacement: correction.replacement, kind: correction.kind, date: date), at: 0)
        nextID += 1
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// Marks the newest entry with this `seq` as undone. An unknown `seq` (already
    /// pushed out of the log) does nothing. Returns whether an entry changed.
    @discardableResult
    public mutating func markUndone(seq: UInt32) -> Bool {
        guard let index = entries.firstIndex(where: { $0.seq == seq && !$0.undone }) else { return false }
        entries[index].undone = true
        return true
    }
}
