// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Opt-in usage counters: how many corrections per day, by kind, and how many
/// were undone. Numbers only. There is no API to put a word, an app or a site
/// in here, and the file format has no field for one (docs/PLAN.md, stage 8).
public struct UsageStats: Equatable, Sendable {
    /// The file format this build writes.
    public static let currentVersion = 1
    /// Days kept, today included. Older days are dropped.
    public static let retentionDays = 56

    /// One calendar day.
    public struct Day: Equatable, Sendable, Codable {
        /// Automatic corrections by `Correction.Kind.statsKey`.
        public var corrections: [String: Int] = [:]
        /// Corrections the user undid that day.
        public var undone = 0
        /// Retypes the user asked for with a shortcut.
        public var manual = 0
        /// Words dictated that day. A number only: the words themselves are never kept here.
        public var dictatedWords = 0

        public init() {}

        private enum CodingKeys: String, CodingKey { case corrections, undone, manual, dictatedWords }

        // The key is written only once something was dictated: a build without voice
        // keeps writing the file as it did.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(corrections, forKey: .corrections)
            try container.encode(undone, forKey: .undone)
            try container.encode(manual, forKey: .manual)
            if dictatedWords > 0 { try container.encode(dictatedWords, forKey: .dictatedWords) }
        }

        // A file of an older version has no `dictatedWords`.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            corrections = try container.decodeIfPresent([String: Int].self, forKey: .corrections) ?? [:]
            undone = try container.decodeIfPresent(Int.self, forKey: .undone) ?? 0
            manual = try container.decodeIfPresent(Int.self, forKey: .manual) ?? 0
            dictatedWords = try container.decodeIfPresent(Int.self, forKey: .dictatedWords) ?? 0
        }

        public var correctionTotal: Int { corrections.values.reduce(0, +) }
    }

    /// Days by key `yyyy-MM-dd` in the user's calendar.
    public private(set) var days: [String: Day] = [:]

    public init() {}

    public var isEmpty: Bool { days.isEmpty }

    // MARK: Counting

    public mutating func recordCorrection(_ kind: Correction.Kind, at date: Date, calendar: Calendar = .current) {
        edit(date, calendar) { $0.corrections[kind.statsKey, default: 0] += 1 }
    }

    public mutating func recordUndo(at date: Date, calendar: Calendar = .current) {
        edit(date, calendar) { $0.undone += 1 }
    }

    public mutating func recordManualRetype(at date: Date, calendar: Calendar = .current) {
        edit(date, calendar) { $0.manual += 1 }
    }

    public mutating func recordDictation(words: Int, at date: Date, calendar: Calendar = .current) {
        guard words > 0 else { return }
        edit(date, calendar) { $0.dictatedWords += words }
    }

    private mutating func edit(_ date: Date, _ calendar: Calendar, _ change: (inout Day) -> Void) {
        let key = Self.key(for: date, calendar: calendar)
        var day = days[key] ?? Day()
        change(&day)
        days[key] = day
        prune(now: date, calendar: calendar)
    }

    /// Drops days before the retention window that ends today, then keeps at most
    /// `retentionDays` days.
    ///
    /// A normal day change drops one old day. A wrong clock (a jump to 2030) would
    /// drop them all, so a call that would drop more than `maxDroppedByDate` days by
    /// date drops none that way; the count limit alone then costs one day per new day.
    public mutating func prune(now: Date, calendar: Calendar = .current) {
        if let first = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: calendar.startOfDay(for: now)) {
            let cutoff = Self.key(for: first, calendar: calendar)
            let old = days.keys.filter { $0 < cutoff }
            if old.count <= Self.maxDroppedByDate { old.forEach { days[$0] = nil } }
        }
        if days.count > Self.retentionDays {
            for key in days.keys.sorted().prefix(days.count - Self.retentionDays) { days[key] = nil }
        }
    }

    /// The most days one call may drop for being too old.
    static let maxDroppedByDate = 2

    public mutating func erase() { days = [:] }

    // MARK: Reading

    public func day(at date: Date, calendar: Calendar = .current) -> Day {
        days[Self.key(for: date, calendar: calendar)] ?? Day()
    }

    /// The last `count` days, oldest first, ending today. A day with no entry is empty.
    public func recent(_ count: Int = 7, endingAt date: Date, calendar: Calendar = .current) -> [Day] {
        (0..<count).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: date) ?? date
            return self.day(at: day, calendar: calendar)
        }
    }

    /// Total corrections and undone ones over `days`.
    public static func totals(_ days: [Day]) -> (corrections: Int, undone: Int) {
        (days.reduce(0) { $0 + $1.correctionTotal }, days.reduce(0) { $0 + $1.undone })
    }

    /// Words dictated over `days`.
    public static func dictatedWords(_ days: [Day]) -> Int {
        days.reduce(0) { $0 + $1.dictatedWords }
    }

    /// `yyyy-MM-dd`, built by hand so no locale or calendar of the formatter matters.
    static func key(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension UsageStats: Codable {
    private enum CodingKeys: String, CodingKey { case version, days }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "newer format")
        }
        days = (try? container.decodeIfPresent([String: Day].self, forKey: .days)) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(days, forKey: .days)
    }
}

extension Correction.Kind {
    /// The name of the kind in the statistics file. Fixed: renaming a case must not change it.
    public var statsKey: String {
        switch self {
        case .layout: "layout"
        case .typo: "typo"
        case .capsLock: "capsLock"
        case .doubleCapitals: "doubleCapitals"
        case .abbreviation: "abbreviation"
        case .yo: "yo"
        case .hyphen: "hyphen"
        }
    }
}
