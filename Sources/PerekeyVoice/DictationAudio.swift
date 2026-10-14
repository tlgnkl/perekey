// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate
import Dispatch
import os
import PerekeyVoiceCore

/// The audio of one dictation, a subscriber of `AudioCapture`. Its memory is
/// allocated whole when the session starts, not as a ring: a ring would
/// overwrite the start of a long phrase, and growing would reallocate on the
/// capture thread. Pages are touched only as audio arrives. At the limit it
/// takes no more audio and calls `onLimit` once, on a queue of its own: the
/// capture thread must not wait for it. The first gap in the audio goes to
/// `onInterruption` the same way.
public final class DictationAudio: AudioSink, @unchecked Sendable {
    /// The longest dictation: 10 minutes.
    public static let limitSeconds = 600

    public let capacity: Int
    // Written by the capture thread up to `state.count`; read below it.
    private let storage: UnsafeMutablePointer<Float>
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onLimit: @Sendable () -> Void
    private let onInterruption: @Sendable (AudioCaptureInterruption) -> Void

    private struct State {
        var count = 0
        var firstHostTime: UInt64?
        var interruption: AudioCaptureInterruption?
        var level: Float = 0
    }

    public init(seconds: Int = DictationAudio.limitSeconds, onLimit: @escaping @Sendable () -> Void = {},
                onInterruption: @escaping @Sendable (AudioCaptureInterruption) -> Void = { _ in })
    {
        capacity = seconds * Int(VoiceCore.sampleRate)
        storage = .allocate(capacity: capacity)
        self.onLimit = onLimit
        self.onInterruption = onInterruption
    }

    deinit {
        storage.deallocate()
    }

    public func receive(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        var rms: Float = 0
        if let base = samples.baseAddress, !samples.isEmpty {
            vDSP_rmsqv(base, 1, &rms, vDSP_Length(samples.count))
        }
        let reachedLimit = state.withLockUnchecked { state -> Bool in
            state.level = rms
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
            DispatchQueue.global(qos: .userInitiated).async(execute: onLimit)
        }
    }

    public func captureInterrupted(_ reason: AudioCaptureInterruption) {
        let first = state.withLock { state -> Bool in
            defer { state.interruption = state.interruption ?? reason }
            return state.interruption == nil
        }
        if first {
            let onInterruption = self.onInterruption
            DispatchQueue.global(qos: .userInitiated).async { onInterruption(reason) }
        }
    }

    /// The audio so far, 16 kHz mono. Meant for after the dictation stopped,
    /// but safe while it runs: the copy, up to 38 MB, is made outside the lock,
    /// of samples the capture thread no longer writes.
    public var samples: [Float] {
        let count = state.withLock { $0.count }
        return Array(UnsafeBufferPointer(start: storage, count: count))
    }

    /// The samples in `range`, clamped to what was heard: a piece of a
    /// running recording, for the silence check.
    public func samples(in range: Range<Int>) -> [Float] {
        let count = state.withLock { $0.count }
        let range = range.clamped(to: 0..<count)
        return Array(UnsafeBufferPointer(start: storage + range.lowerBound, count: range.count))
    }

    /// The loudness of the latest block, RMS of samples in -1...1.
    public var level: Float { state.withLock { $0.level } }

    public var count: Int { state.withLock { $0.count } }
    public var seconds: Double { Double(count) / VoiceCore.sampleRate }
    public var isFull: Bool { count == capacity }
    /// When the first sample was heard, to line the audio up with the hotkey.
    public var firstHostTime: UInt64? { state.withLock { $0.firstHostTime } }
    /// The first gap in the audio, if any: dictation stops and recognizes what it has.
    public var interruption: AudioCaptureInterruption? { state.withLock { $0.interruption } }
}
