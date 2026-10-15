// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Time that moves only when the test says: `sleep` waits for `advance`.
/// The same as in PerekeyVoiceCoreTests: test targets do not share code.
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
