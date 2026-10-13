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

    func set(text: String) { self.text = text }
    func set(prepareError: (any Error)?) { self.prepareError = prepareError }

    func prepare() async throws {
        prepares += 1
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

/// Waits until `condition` holds, up to two seconds.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
