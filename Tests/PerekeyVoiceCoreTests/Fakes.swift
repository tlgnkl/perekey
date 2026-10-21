// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import PerekeyVoiceCore

/// A speech engine without a model: says what it is told, counts its calls.
actor FakeEngine: SpeechEngine {
    nonisolated let id: String
    var text: String
    var prepareError: (any Error)?
    private(set) var prepares = 0
    private(set) var unloads = 0
    private(set) var transcribed: [AudioBuffer16k] = []
    private(set) var isPrepared = false

    init(id: String = "fake", text: String = "привет") {
        self.id = id
        self.text = text
    }

    private var holdsPrepare = false
    private var prepareGate: CheckedContinuation<Void, Never>?

    func set(text: String) { self.text = text }
    func set(prepareError: (any Error)?) { self.prepareError = prepareError }
    func holdPrepare() { holdsPrepare = true }

    func finishPrepare() {
        holdsPrepare = false
        prepareGate?.resume()
        prepareGate = nil
    }

    func prepare() async throws {
        prepares += 1
        if holdsPrepare { await withCheckedContinuation { prepareGate = $0 } }
        if let prepareError { throw prepareError }
        isPrepared = true
    }

    func unload() async {
        unloads += 1
        isPrepared = false
    }

    func transcribe(_ audio: AudioBuffer16k) async throws -> Transcript {
        guard isPrepared else { throw SpeechEngineError.notPrepared }
        transcribed.append(audio)
        return Transcript(text: text)
    }
}

/// A detector that hears speech where the samples are loud.
actor FakeDetector: SpeechDetector {
    private(set) var calls = 0
    var fails = false

    func set(fails: Bool) { self.fails = fails }

    func prepare() async throws {}
    func unload() async {}

    func speechProbabilities(_ samples: [Float]) async throws -> [Float] {
        calls += 1
        if fails { throw SpeechEngineError.notPrepared }
        return stride(from: 0, to: samples.count, by: VoiceActivity.chunk).map { start in
            let chunk = samples[start..<min(samples.count, start + VoiceActivity.chunk)]
            return chunk.contains { abs($0) > 0.1 } ? 0.9 : 0.05
        }
    }
}

/// Time that moves only when the test says: `sleep` waits for `advance`.
final class VirtualClock: Sendable {
    private struct Sleeper {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var sleepers: [Sleeper] = []
        var cancelled: Set<UUID> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    @Sendable func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLockUnchecked { state -> Bool in
                    if state.cancelled.remove(id) != nil { return true }
                    state.sleepers.append(Sleeper(id: id, duration: duration, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = state.withLockUnchecked { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// The durations asked for and not over yet.
    var pending: [Duration] { state.withLockUnchecked { $0.sleepers.map(\.duration) } }

    /// Ends every sleep now.
    func advance() {
        let sleepers = state.withLockUnchecked { state -> [Sleeper] in
            defer { state.sleepers = [] }
            return state.sleepers
        }
        for sleeper in sleepers { sleeper.continuation.resume() }
    }
}

/// Waits until `condition` holds. It counts polls, not wall time: when other
/// tests keep the pool busy, the polls slow down with the work they wait for.
/// At least 20 s on an idle machine before it gives up.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// A file queue that only records what it is told, and says the phases it is given.
final class FakeFileQueue: FileTranscribing {
    private struct State {
        var jobs: [TranscriptionJob] = []
        var cancelled: [UUID] = []
        var phases: [UUID: TranscriptionPhase] = [:]
        var continuations: [AsyncStream<[UUID: TranscriptionPhase]>.Continuation] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var jobs: [TranscriptionJob] { state.withLock(\.jobs) }
    var cancelled: [UUID] { state.withLock(\.cancelled) }
    var isBusy: Bool { state.withLock { $0.phases.values.contains(where: \.isPending) } }

    func enqueue(_ job: TranscriptionJob) async {
        state.withLock { $0.jobs.append(job) }
        publish(job.recording, .queued)
    }

    func cancel(_ recording: UUID) async {
        state.withLock { $0.cancelled.append(recording) }
        publish(recording, .cancelled)
    }

    func phases() -> AsyncStream<[UUID: TranscriptionPhase]> {
        AsyncStream { continuation in
            state.withLock { state in
                state.continuations.append(continuation)
                continuation.yield(state.phases)
            }
        }
    }

    /// Sets a recording's phase and tells everyone who listens.
    func publish(_ recording: UUID, _ phase: TranscriptionPhase) {
        state.withLock { state in
            state.phases[recording] = phase
            for continuation in state.continuations { continuation.yield(state.phases) }
        }
    }
}
