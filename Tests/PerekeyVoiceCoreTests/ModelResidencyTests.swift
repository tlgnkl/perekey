// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyVoiceCore
import Testing

struct ModelResidencyTests {
    private let hour: Duration = .seconds(3600)

    @Test func noTimerWithoutDictation() async throws {
        let clock = VirtualClock()
        let engine = FakeEngine()
        let residency = ModelResidency(engine, unloadDelay: hour, sleep: clock.sleep)
        #expect(await !residency.isTimerRunning)
        try await residency.begin()
        // Loaded for a dictation in progress: still no timer.
        #expect(await !residency.isTimerRunning)
        #expect(clock.pending.isEmpty)
        #expect(await engine.prepares == 1)
    }

    @Test func unloadsAfterTheDelay() async throws {
        let clock = VirtualClock()
        let engine = FakeEngine()
        let residency = ModelResidency(engine, unloadDelay: hour, sleep: clock.sleep)
        try await residency.begin()
        await residency.end()
        #expect(await eventually { clock.pending == [.seconds(3600)] })
        #expect(await engine.unloads == 0)
        clock.advance()
        #expect(await eventually { await engine.unloads == 1 })
        #expect(await !residency.isLoaded)
        // The next dictation loads it again.
        try await residency.begin()
        #expect(await engine.prepares == 2)
    }

    @Test func aNewDictationStopsTheTimer() async throws {
        let clock = VirtualClock()
        let engine = FakeEngine()
        let residency = ModelResidency(engine, unloadDelay: hour, sleep: clock.sleep)
        try await residency.begin()
        await residency.end()
        #expect(await eventually { clock.pending.count == 1 })
        try await residency.begin()
        #expect(await eventually { clock.pending.isEmpty })
        clock.advance()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await engine.unloads == 0)
        #expect(await residency.isLoaded)
        #expect(await engine.prepares == 1)
    }

    @Test func neverUnloads() async throws {
        let clock = VirtualClock()
        let residency = ModelResidency(FakeEngine(), unloadDelay: nil, sleep: clock.sleep)
        try await residency.begin()
        await residency.end()
        #expect(await !residency.isTimerRunning)
        #expect(clock.pending.isEmpty)
    }

    @Test func newDelayRestartsTheTimer() async throws {
        let clock = VirtualClock()
        let residency = ModelResidency(FakeEngine(), unloadDelay: hour, sleep: clock.sleep)
        try await residency.begin()
        await residency.end()
        #expect(await eventually { clock.pending == [.seconds(3600)] })
        await residency.setUnloadDelay(.seconds(600))
        #expect(await eventually { clock.pending == [.seconds(600)] })
        await residency.setUnloadDelay(nil)
        #expect(await eventually { clock.pending.isEmpty })
    }

    @Test func warmUpLoadsAndStartsTheTimer() async throws {
        let clock = VirtualClock()
        let engine = FakeEngine()
        let residency = ModelResidency(engine, unloadDelay: hour, sleep: clock.sleep)
        try await residency.warmUp()
        #expect(await residency.isLoaded)
        #expect(await eventually { clock.pending.count == 1 })
    }

    @Test func concurrentLoadsPrepareOnce() async throws {
        let engine = FakeEngine()
        let residency = ModelResidency(engine)
        async let first: Void = residency.begin()
        async let second: Void = residency.begin()
        _ = try await (first, second)
        #expect(await engine.prepares == 1)
    }

    @Test func failedLoadIsTriedAgain() async throws {
        let engine = FakeEngine()
        await engine.set(prepareError: SpeechEngineError.unsupported)
        let residency = ModelResidency(engine)
        await #expect(throws: SpeechEngineError.unsupported) { try await residency.begin() }
        #expect(await !residency.isLoaded)
        await engine.set(prepareError: nil)
        try await residency.begin()
        #expect(await residency.isLoaded)
        #expect(await engine.prepares == 2)
    }

    @Test func unloadOnlyWhatWasLoaded() async throws {
        let engine = FakeEngine()
        let residency = ModelResidency(engine)
        await residency.unload()
        #expect(await engine.unloads == 0)
        try await residency.warmUp()
        await residency.unload()
        await residency.unload()
        #expect(await engine.unloads == 1)
    }

    @Test func anOldSessionsEndDoesNotStartTheTimerUnderANewOne() async throws {
        let clock = VirtualClock()
        let engine = FakeEngine()
        let residency = ModelResidency(engine, unloadDelay: hour, sleep: clock.sleep)
        try await residency.begin() // the old session, its recognition still running
        try await residency.begin() // a new one starts
        await residency.end() // the old recognition is over
        #expect(await residency.holders == 1)
        #expect(await !residency.isTimerRunning)
        #expect(clock.pending.isEmpty)
        await residency.end()
        #expect(await eventually { clock.pending.count == 1 })
    }

    @Test func unloadWaitsForTheHolder() async throws {
        let engine = FakeEngine()
        let residency = ModelResidency(engine)
        try await residency.begin()
        let unloading = Task { await residency.unload() }
        try await Task.sleep(for: .milliseconds(20))
        // A transcription in progress keeps the model.
        #expect(await engine.unloads == 0)
        #expect(await residency.isLoaded)
        await residency.end()
        await unloading.value
        #expect(await engine.unloads == 1)
        #expect(await !residency.isLoaded)
    }

    @Test func aHolderDuringAWaitingUnloadKeepsTheModel() async throws {
        let engine = FakeEngine()
        let residency = ModelResidency(engine)
        try await residency.begin()
        let unloading = Task { await residency.unload() }
        try await Task.sleep(for: .milliseconds(10))
        try await residency.begin()
        await residency.end()
        try await Task.sleep(for: .milliseconds(10))
        #expect(await engine.unloads == 0, "one holder is left")
        await residency.end()
        await unloading.value
        #expect(await engine.unloads == 1)
    }

    @Test func unloadDuringALoad() async throws {
        let engine = FakeEngine()
        await engine.holdPrepare()
        let residency = ModelResidency(engine)
        let loading = Task { try await residency.warmUp() }
        #expect(await eventually { await engine.prepares == 1 })
        // Unloading waits for the load's holder, then unloads what it loaded.
        let unloading = Task { await residency.unload() }
        await engine.finishPrepare()
        try await loading.value
        await unloading.value
        #expect(await engine.unloads == 1)
        #expect(await !residency.isLoaded)
        try await residency.begin()
        #expect(await residency.isLoaded)
        #expect(await engine.prepares == 2)
    }

    @Test func theTimerWaitsForTheLastHolder() async throws {
        let clock = VirtualClock()
        let engine = FakeEngine()
        let residency = ModelResidency(engine, unloadDelay: hour, sleep: clock.sleep)
        try await residency.warmUp()
        #expect(await eventually { clock.pending.count == 1 })
        try await residency.begin()
        #expect(await eventually { clock.pending.isEmpty })
        clock.advance()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await engine.unloads == 0)
        await residency.end()
    }
}
