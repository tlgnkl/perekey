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
        try await residency.load()
        // Loaded for a dictation in progress: still no timer.
        #expect(await !residency.isTimerRunning)
        #expect(clock.pending.isEmpty)
        #expect(await engine.prepares == 1)
    }

    @Test func unloadsAfterTheDelay() async throws {
        let clock = VirtualClock()
        let engine = FakeEngine()
        let residency = ModelResidency(engine, unloadDelay: hour, sleep: clock.sleep)
        try await residency.load()
        await residency.used()
        #expect(await eventually { clock.pending == [.seconds(3600)] })
        #expect(await engine.unloads == 0)
        clock.advance()
        #expect(await eventually { await engine.unloads == 1 })
        #expect(await !residency.isLoaded)
        // The next dictation loads it again.
        try await residency.load()
        #expect(await engine.prepares == 2)
    }

    @Test func aNewDictationStopsTheTimer() async throws {
        let clock = VirtualClock()
        let engine = FakeEngine()
        let residency = ModelResidency(engine, unloadDelay: hour, sleep: clock.sleep)
        try await residency.load()
        await residency.used()
        #expect(await eventually { clock.pending.count == 1 })
        try await residency.load()
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
        try await residency.load()
        await residency.used()
        #expect(await !residency.isTimerRunning)
        #expect(clock.pending.isEmpty)
    }

    @Test func newDelayRestartsTheTimer() async throws {
        let clock = VirtualClock()
        let residency = ModelResidency(FakeEngine(), unloadDelay: hour, sleep: clock.sleep)
        try await residency.load()
        await residency.used()
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
        async let first: Void = residency.load()
        async let second: Void = residency.load()
        _ = try await (first, second)
        #expect(await engine.prepares == 1)
    }

    @Test func failedLoadIsTriedAgain() async throws {
        let engine = FakeEngine()
        await engine.set(prepareError: SpeechEngineError.unsupported)
        let residency = ModelResidency(engine)
        await #expect(throws: SpeechEngineError.unsupported) { try await residency.load() }
        #expect(await !residency.isLoaded)
        await engine.set(prepareError: nil)
        try await residency.load()
        #expect(await residency.isLoaded)
        #expect(await engine.prepares == 2)
    }

    @Test func unloadOnlyWhatWasLoaded() async throws {
        let engine = FakeEngine()
        let residency = ModelResidency(engine)
        await residency.unload()
        #expect(await engine.unloads == 0)
        try await residency.load()
        await residency.unload()
        await residency.unload()
        #expect(await engine.unloads == 1)
    }
}
