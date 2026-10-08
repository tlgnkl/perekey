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

        public init() {}

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

    private mutating func edit(_ date: Date, _ calendar: Calendar, _ change: (inout Day) -> Void) {
        let key = Self.key(for: date, calendar: calendar)
        var day = days[key] ?? Day()
        change(&day)
        days[key] = day
        prune(now: date, calendar: calendar)
    }

    /// Drops days before the retention window that ends today.
    public mutating func prune(now: Date, calendar: Calendar = .current) {
        guard let first = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: calendar.startOfDay(for: now))
        else { return }
        let cutoff = Self.key(for: first, calendar: calendar)
        days = days.filter { $0.key >= cutoff }
    }

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
        }
    }
}
