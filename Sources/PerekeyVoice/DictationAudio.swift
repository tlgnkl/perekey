// SPDX-License-Identifier: GPL-3.0-or-later

import os
import PerekeyVoiceCore

/// The audio of one dictation, a subscriber of `AudioCapture`. Its memory is
/// allocated whole when the session starts, not as a ring: a ring would
/// overwrite the start of a long phrase, and growing would reallocate on the
/// capture thread. Pages are touched only as audio arrives. At the limit it
/// takes no more audio and calls `onLimit` once.
public final class DictationAudio: AudioSink, @unchecked Sendable {
    /// The longest dictation: 10 minutes.
    public static let limitSeconds = 600

    public let capacity: Int
    // Written by the capture thread up to `state.count`; read below it.
    private let storage: UnsafeMutablePointer<Float>
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onLimit: @Sendable () -> Void

    private struct State {
        var count = 0
        var firstHostTime: UInt64?
        var interruption: AudioCaptureInterruption?
    }

    public init(seconds: Int = DictationAudio.limitSeconds, onLimit: @escaping @Sendable () -> Void = {}) {
        capacity = seconds * Int(VoiceCore.sampleRate)
        storage = .allocate(capacity: capacity)
        self.onLimit = onLimit
    }

    deinit {
        storage.deallocate()
    }

    public func receive(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        let reachedLimit = state.withLockUnchecked { state -> Bool in
            guard state.count < capacity else { return false }
            if state.firstHostTime == nil {
                state.firstHostTime = hostTime
            }
            let taken = min(samples.count, capacity - state.count)
            (storage + state.count).update(from: samples.baseAddress!, count: taken)
            state.count += taken
            return state.count == capacity
        }
        if reachedLimit {
            onLimit()
        }
    }

    public func captureInterrupted(_ reason: AudioCaptureInterruption) {
        state.withLock { $0.interruption = $0.interruption ?? reason }
    }

    /// The audio so far, 16 kHz mono.
    public var samples: [Float] {
        state.withLockUnchecked { Array(UnsafeBufferPointer(start: storage, count: $0.count)) }
    }

    public var count: Int { state.withLock { $0.count } }
    public var seconds: Double { Double(count) / VoiceCore.sampleRate }
    public var isFull: Bool { count == capacity }
    /// When the first sample was heard, to line the audio up with the hotkey.
    public var firstHostTime: UInt64? { state.withLock { $0.firstHostTime } }
    /// The first gap in the audio, if any: dictation stops and recognizes what it has.
    public var interruption: AudioCaptureInterruption? { state.withLock { $0.interruption } }
}
