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
        for seq in 1...6 { log.record(correction(UInt32(seq))) }
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
        for seq in 1...12 { log.record(correction(UInt32(seq))) }
        #expect(Set(log.entries.map(\.id)).count == log.entries.count)
    }
}
