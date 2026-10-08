// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct UsageStatsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, month: Int = 10, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func countsByDayAndKind() {
        var stats = UsageStats()
        stats.recordCorrection(.layout, at: date(8), calendar: calendar)
        stats.recordCorrection(.layout, at: date(8, hour: 23), calendar: calendar)
        stats.recordCorrection(.typo, at: date(8), calendar: calendar)
        let day = stats.day(at: date(8), calendar: calendar)
        #expect(day.corrections == ["layout": 2, "typo": 1])
        #expect(day.correctionTotal == 3)
    }

    @Test func midnightStartsANewDay() {
        var stats = UsageStats()
        stats.recordCorrection(.layout, at: date(8, hour: 23), calendar: calendar)
        stats.recordCorrection(.layout, at: date(9, hour: 0), calendar: calendar)
        #expect(stats.days.count == 2)
        #expect(stats.day(at: date(9), calendar: calendar).correctionTotal == 1)
    }

    @Test func undoAndManualRetypeAreCountedApart() {
        var stats = UsageStats()
        stats.recordCorrection(.layout, at: date(8), calendar: calendar)
        stats.recordUndo(at: date(8), calendar: calendar)
        stats.recordManualRetype(at: date(8), calendar: calendar)
        stats.recordManualRetype(at: date(8), calendar: calendar)
        let day = stats.day(at: date(8), calendar: calendar)
        #expect(day.undone == 1)
        #expect(day.manual == 2)
        #expect(day.correctionTotal == 1)
    }

    @Test func keepsFiftySixDaysAndDropsOlder() {
        var stats = UsageStats()
        // Sept 1 is 37 days before Oct 8; the first of July is 99.
        stats.recordCorrection(.layout, at: date(1, month: 7), calendar: calendar)
        stats.recordCorrection(.layout, at: date(1, month: 9), calendar: calendar)
        stats.recordCorrection(.layout, at: date(8), calendar: calendar)
        #expect(stats.days.count == 2)
        #expect(stats.day(at: date(1, month: 7), calendar: calendar).correctionTotal == 0)
    }

    @Test func windowEdgeIsExact() {
        var stats = UsageStats()
        let today = date(8)
        let last = calendar.date(byAdding: .day, value: -(UsageStats.retentionDays - 1), to: today)!
        let gone = calendar.date(byAdding: .day, value: -UsageStats.retentionDays, to: today)!
        stats.recordCorrection(.yo, at: gone, calendar: calendar)
        stats.recordCorrection(.yo, at: last, calendar: calendar)
        stats.prune(now: today, calendar: calendar)
        #expect(stats.days.count == 1)
        #expect(stats.day(at: last, calendar: calendar).correctionTotal == 1)
    }

    @Test func recentWeekIsOldestFirstWithEmptyDays() {
        var stats = UsageStats()
        stats.recordCorrection(.layout, at: date(8), calendar: calendar)
        stats.recordCorrection(.layout, at: date(6), calendar: calendar)
        let week = stats.recent(7, endingAt: date(8), calendar: calendar)
        #expect(week.map(\.correctionTotal) == [0, 0, 0, 0, 1, 0, 1])
        let totals = UsageStats.totals(week)
        #expect(totals.corrections == 2)
    }

    @Test func encodedFileHasNumbersAndFixedNamesOnly() throws {
        var stats = UsageStats()
        for kind in [Correction.Kind.layout, .typo, .capsLock, .doubleCapitals, .abbreviation, .yo] {
            stats.recordCorrection(kind, at: date(8), calendar: calendar)
        }
        stats.recordUndo(at: date(8), calendar: calendar)
        stats.recordManualRetype(at: date(8), calendar: calendar)
        let data = try JSONEncoder().encode(stats)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == ["version", "days"])
        let days = try #require(root["days"] as? [String: [String: Any]])
        for (key, day) in days {
            #expect(key.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil)
            #expect(Set(day.keys) == ["corrections", "undone", "manual"])
            let kinds = try #require(day["corrections"] as? [String: Int])
            #expect(Set(kinds.keys).isSubset(of: ["layout", "typo", "capsLock", "doubleCapitals", "abbreviation", "yo"]))
        }
    }

    @Test func roundTrips() throws {
        var stats = UsageStats()
        stats.recordCorrection(.typo, at: date(8), calendar: calendar)
        stats.recordUndo(at: date(8), calendar: calendar)
        let back = try JSONDecoder().decode(UsageStats.self, from: JSONEncoder().encode(stats))
        #expect(back == stats)
    }

    @Test func newerFormatIsRefused() {
        let json = Data(#"{"version":99,"days":{}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(UsageStats.self, from: json) }
    }
}
