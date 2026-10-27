// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

@Suite struct CorrectionLogTests {
    private func correction(_ seq: UInt32, _ original: String = "ghbdtn", kind: Correction.Kind = .layout) -> Correction {
        Correction(seq: seq, original: original, replacement: "привет", source: "en", target: "ru",
                   kind: kind)
    }

    @Test func newestComesFirst() {
        var log = CorrectionLog()
        log.record(correction(1, "one"))
        log.record(correction(2, "two"))
        #expect(log.entries.map(\.original) == ["two", "one"])
    }

    @Test func keepsOnlyTheLastFive() {
        var log = CorrectionLog()
        for seq in 1...8 { log.record(correction(UInt32(seq), "w\(seq)")) }
        #expect(log.entries.count == CorrectionLog.limit)
        #expect(log.entries.map(\.original) == ["w8", "w7", "w6", "w5", "w4"])
    }

    @Test func undoStrikesTheMatchingEntry() {
        var log = CorrectionLog()
        log.record(correction(1, "one"))
        log.record(correction(2, "two"))
        let changed = log.markUndone(seq: 1)
        #expect(changed)
        #expect(log.entries.map(\.undone) == [false, true])
    }

    @Test func undoOfAnEntryPushedOutDoesNothing() {
        var log = CorrectionLog()
        for seq in 1...6 { log.record(correction(UInt32(seq), "w\(seq)")) }
        let before = log
        let changed = log.markUndone(seq: 1)
        #expect(!changed)
        #expect(log == before)
    }

    @Test func repeatedSeqUndoesTheNewestStandingOne() {
        var log = CorrectionLog()
        log.record(correction(7, "old"))
        log.record(correction(7, "new"))
        log.markUndone(seq: 7)
        #expect(log.entries.map(\.undone) == [true, false])
        log.markUndone(seq: 7)
        #expect(log.entries.map(\.undone) == [true, true])
    }

    @Test func latestStandingSkipsUndone() {
        var log = CorrectionLog()
        #expect(log.latestStanding == nil)
        log.record(correction(1, "one"))
        log.record(correction(2, "two"))
        log.markUndone(seq: 2)
        #expect(log.latestStanding?.original == "one")
        log.markUndone(seq: 1)
        #expect(log.latestStanding == nil)
    }

    @Test func keepsTheKind() {
        var log = CorrectionLog()
        log.record(correction(1, "мвд", kind: .abbreviation))
        #expect(log.entries.first?.kind == .abbreviation)
    }

    @Test func idsStayUniquePastTheLimit() {
        var log = CorrectionLog()
        for seq in 1...12 { log.record(correction(UInt32(seq), "w\(seq)")) }
        #expect(Set(log.entries.map(\.id)).count == log.entries.count)
    }

    @Test func theSameCorrectionIsOneRowWithACount() {
        var log = CorrectionLog()
        log.record(correction(1))
        log.record(correction(2, "other"))
        log.record(correction(3))
        log.record(correction(4))
        #expect(log.entries.map(\.original) == ["ghbdtn", "other"])
        #expect(log.entries.map(\.count) == [3, 1])
        #expect(log.entries.first?.seq == 4)
    }

    @Test func aDifferentKindIsAnotherRow() {
        var log = CorrectionLog()
        log.record(correction(1, "мвд", kind: .abbreviation))
        log.record(correction(2, "мвд", kind: .layout))
        #expect(log.entries.map(\.count) == [1, 1])
    }

    @Test func undoOfTheNewestInAMergedRowStrikesOnlyThatOne() {
        var log = CorrectionLog()
        log.record(correction(1))
        log.record(correction(2))
        let changed = log.markUndone(seq: 2)
        #expect(changed)
        #expect(log.entries.map(\.undone) == [true, false])
        #expect(log.entries.map(\.count) == [1, 1])
        #expect(log.entries.map(\.seq) == [2, 1])
        #expect(log.latestStanding?.seq == 1)
    }

    @Test func undoOfAnOlderOneInAMergedRowKeepsTheRowStanding() {
        var log = CorrectionLog()
        log.record(correction(1))
        log.record(correction(2))
        log.record(correction(3))
        let changed = log.markUndone(seq: 1)
        #expect(changed)
        #expect(log.entries.map(\.undone) == [true, false])
        #expect(log.entries.map(\.count) == [1, 2])
        #expect(log.entries[1].seqs == [2, 3])
        #expect(Set(log.entries.map(\.id)).count == 2)
    }

    @Test func undoingAMergedRowTwiceStrikesItAll() {
        var log = CorrectionLog()
        log.record(correction(1))
        log.record(correction(2))
        let first = log.markUndone(seq: 2)
        let again = log.markUndone(seq: 2)
        let last = log.markUndone(seq: 1)
        #expect(first && !again && last)
        #expect(log.entries.map(\.undone) == [true, true])
        #expect(log.latestStanding == nil)
    }

    @Test func aStruckRowFromAMergeStillKeepsTheLimit() {
        var log = CorrectionLog()
        for seq in 1...5 { log.record(correction(UInt32(seq), "w\(seq)")) }
        log.record(correction(6, "w5"))
        #expect(log.entries.count == CorrectionLog.limit)
        log.markUndone(seq: 5)
        #expect(log.entries.count == CorrectionLog.limit)
        #expect(Set(log.entries.map(\.id)).count == log.entries.count)
    }

    @Test func aMergedRowKeepsItsID() {
        var log = CorrectionLog()
        log.record(correction(1))
        let id = log.entries[0].id
        log.record(correction(2, "other"))
        log.record(correction(3))
        #expect(log.entries.first?.id == id)
        #expect(log.entries.first?.count == 2)
        log.record(correction(4, "new"))
        #expect(Set(log.entries.map(\.id)).count == 3)
    }

    @Test func anUndoneCorrectionIsNotMergedInto() {
        var log = CorrectionLog()
        log.record(correction(1))
        log.markUndone(seq: 1)
        log.record(correction(2))
        #expect(log.entries.map(\.undone) == [false, true])
        #expect(log.entries.map(\.count) == [1, 1])
    }
}
