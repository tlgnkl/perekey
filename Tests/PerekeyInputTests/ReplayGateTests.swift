// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyInput

/// The tap's part after a fence: replayed keys go first, keys typed while
/// they are on their way wait behind them ("приветм ир" must not happen).
/// `#expect` cannot call mutating members, hence the locals.
@Suite struct ReplayGateTests {
    @Test func nothingInFlightNothingWaits() {
        var gate = ReplayGate<String>()
        let waits = gate.mustWait(at: 1)
        #expect(!waits)
        let ready = gate.takeReady()
        #expect(ready.isEmpty)
    }

    @Test func userKeysWaitForTheReplaysThenGoOutAsTheNextBatch() {
        var gate = ReplayGate<String>()
        gate.posted(2, at: 1) // " " and "v" held by the fence
        let bWaits = gate.mustWait(at: 1.001)
        #expect(bWaits)
        gate.hold("b")
        gate.replayedSeen()
        let early = gate.takeReady()
        #expect(early.isEmpty, "one replay is still on its way")
        let hWaits = gate.mustWait(at: 1.002)
        #expect(hWaits)
        gate.hold("h")
        gate.replayedSeen()
        let batch = gate.takeReady()
        #expect(batch == ["b", "h"])
        #expect(gate.waiting.isEmpty)
        // The batch is in flight now: the next key waits for it in turn.
        gate.posted(2, at: 1.003)
        let spaceWaits = gate.mustWait(at: 1.003)
        #expect(spaceWaits)
        gate.hold(" ")
        gate.replayedSeen()
        gate.replayedSeen()
        let next = gate.takeReady()
        #expect(next == [" "])
    }

    @Test func batchesAddUp() {
        var gate = ReplayGate<String>()
        gate.posted(1, at: 1)
        gate.posted(2, at: 1.001) // the machine released more while one was on its way
        #expect(gate.inFlight == 3)
        gate.hold("x")
        gate.replayedSeen()
        gate.replayedSeen()
        let early = gate.takeReady()
        #expect(early.isEmpty)
        gate.replayedSeen()
        let ready = gate.takeReady()
        #expect(ready == ["x"])
    }

    @Test func emptyBatchCountsForNothing() {
        var gate = ReplayGate<String>()
        gate.posted(0, at: 1)
        let waits = gate.mustWait(at: 1)
        #expect(!waits)
    }

    @Test func unexpectedReplaysDoNotGoNegative() {
        var gate = ReplayGate<String>()
        gate.replayedSeen()
        #expect(gate.inFlight == 0)
        let waits = gate.mustWait(at: 1)
        #expect(!waits)
    }

    @Test func lostReplaysDoNotHoldTheKeyboard() {
        var gate = ReplayGate<String>()
        gate.posted(2, at: 1)
        gate.hold("a")
        #expect(gate.deadline == 1 + ReplayGate<String>.timeout)
        let early = gate.expire(at: 1.1)
        #expect(early == nil, "not yet")
        let expired = gate.expire(at: 1 + ReplayGate<String>.timeout)
        #expect(expired == ["a"])
        #expect(gate.inFlight == 0)
        #expect(gate.deadline == nil)
        let waits = gate.mustWait(at: 2)
        #expect(!waits)
    }

    @Test func staleReplaysWithNothingWaitingAreDropped() {
        var gate = ReplayGate<String>()
        gate.posted(1, at: 1)
        let waitsSoon = gate.mustWait(at: 1.2)
        #expect(waitsSoon)
        var late = ReplayGate<String>()
        late.posted(1, at: 1)
        let waitsLate = late.mustWait(at: 1 + ReplayGate<String>.timeout)
        #expect(!waitsLate)
        #expect(late.inFlight == 0)
    }

    @Test func resetHandsBackWhatWaited() {
        var gate = ReplayGate<String>()
        gate.posted(3, at: 1)
        gate.hold("a")
        gate.hold("b")
        let left = gate.reset()
        #expect(left == ["a", "b"])
        #expect(gate.inFlight == 0)
        #expect(gate.waiting.isEmpty)
    }
}
