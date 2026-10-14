// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The time scale of a call recording: host time from the start minus the
/// pauses. Both tracks stamp their blocks with `mHostTime`, so a block of
/// either lands on the same second of the scale; segments and gaps in
/// `meta.json` carry their place on it (`startOffset`).
///
/// Should the two clocks drift apart past 50 ms an hour, the fix needs only
/// what `meta.json` already holds: each segment's `startHostTime` and
/// `frames` give the rate a track really ran at.
public struct CallTimeline: Sendable, Equatable {
    public let startHostTime: UInt64
    public let ticksPerSecond: Double
    /// Pauses in host time; the last one has no end while it lasts.
    public private(set) var pauses: [Pause] = []

    public struct Pause: Sendable, Equatable {
        public var start: UInt64
        public var end: UInt64?
    }

    public init(startHostTime: UInt64, ticksPerSecond: Double) {
        self.startHostTime = startHostTime
        self.ticksPerSecond = ticksPerSecond
    }

    public var isPaused: Bool { pauses.last.map { $0.end == nil } ?? false }

    /// Seconds on the scale at a host time. A time inside a pause is the
    /// pause's own place: the scale stands still while it lasts.
    public func offset(of hostTime: UInt64) -> Double {
        guard hostTime > startHostTime else { return 0 }
        var ticks = hostTime - startHostTime
        for pause in pauses where hostTime > pause.start {
            let end = min(pause.end ?? hostTime, hostTime)
            ticks -= min(ticks, end - min(end, pause.start))
        }
        return Double(ticks) / ticksPerSecond
    }

    /// Returns false if it is paused already.
    @discardableResult
    public mutating func pause(at hostTime: UInt64) -> Bool {
        guard !isPaused else { return false }
        pauses.append(Pause(start: max(hostTime, pauses.last?.end ?? startHostTime)))
        return true
    }

    /// Returns false if it is not paused.
    @discardableResult
    public mutating func resume(at hostTime: UInt64) -> Bool {
        guard isPaused, let last = pauses.indices.last else { return false }
        pauses[last].end = max(hostTime, pauses[last].start)
        return true
    }
}

/// The limits of a call recording.
public enum CallRecordingLimits {
    /// A recording stops by itself at 4 hours of its scale.
    public static let maxDuration: Double = 4 * 3600
    /// No start below 2 GB free: the recording and the transcription's
    /// temporary file both need room.
    public static let minFreeBytes: Int64 = 2_000_000_000
    /// Each track is written in segments of 5 minutes: a crash loses at
    /// most the one that was open.
    public static let segmentSeconds: Double = 300
}

/// When a call's audio goes: by the user's term, or as soon as the
/// transcript is written when a profile says so (`CallAudioKeepDisabled`).
/// The transcript always stays.
public struct CallAudioPolicy: Sendable, Equatable {
    public var retention: RecordingMeta.AudioRetention
    public var keepDisabled: Bool

    public init(retention: RecordingMeta.AudioRetention, keepDisabled: Bool) {
        self.retention = retention
        self.keepDisabled = keepDisabled
    }

    /// The term in force: the profile's when it forbids keeping the audio.
    public var effective: RecordingMeta.AudioRetention { keepDisabled ? .untilTranscribed : retention }

    /// Whether a recording's audio is to be removed now. Only once it is
    /// transcribed (`done`), by either term: a call stopped and never
    /// transcribed, or one the queue failed, keeps its audio, or nothing of
    /// it would be left. Never a file the user chose.
    public func removesAudio(of meta: RecordingMeta, now: Date) -> Bool {
        guard meta.kind == .call, meta.state == .done, meta.pendingJob == nil, meta.audioRemovedAt == nil,
              !meta.segments.isEmpty
        else { return false }
        switch effective {
        case .always:
            return false
        case .month:
            return now.timeIntervalSince(meta.createdAt) >= 30 * 24 * 3600
        case .untilTranscribed:
            return true
        }
    }
}
