// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Text with timecodes: what a file or a call recording turns into.
public struct TimedTranscript: Codable, Sendable, Equatable {
    public var segments: [TimedSegment]
    /// The language the model heard, as an ISO 639-1 code, if it says.
    public var language: String?

    public init(segments: [TimedSegment], language: String? = nil) {
        self.segments = segments
        self.language = language
    }
}

/// A phrase: one subtitle, one line of the transcript.
public struct TimedSegment: Codable, Sendable, Equatable {
    /// Seconds from the start of the file or of the recording's scale.
    public var start: Double
    public var end: Double
    public var text: String
    /// Nil when the engine gives timings of phrases only (some cloud models).
    public var words: [TimedWord]?
    /// `TranscriptSpeaker.id`; nil when nobody is known (a file without diarization).
    public var speaker: String?

    public init(start: Double, end: Double, text: String, words: [TimedWord]? = nil, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.speaker = speaker
    }

    /// The same phrase later on the scale by `seconds`, its words too.
    public func shifted(by seconds: Double) -> TimedSegment {
        var segment = self
        segment.start += seconds
        segment.end += seconds
        segment.words = words?.map { $0.shifted(by: seconds) }
        return segment
    }
}

public struct TimedWord: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// As the model wrote it, punctuation included, with the space before it
    /// if there is one: a phrase's text is its words run together and
    /// trimmed, in a language with spaces or without.
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public func shifted(by seconds: Double) -> TimedWord {
        TimedWord(start: start + seconds, end: end + seconds, text: text)
    }
}

/// Long audio on disk: a file the user chose, or one track of a call recording.
public enum AudioSource: Sendable, Equatable {
    /// Anything AVFoundation reads (mp3, m4a, wav, mp4, mov), at any rate
    /// and channel count; the reader turns it into 16 kHz mono.
    case file(FileReference)
    /// A track of a call recording: AAC segments in ADTS, each at its own
    /// start on the recording's scale.
    case track(RecordingTrack, [TrackSegment])
}

/// A file outside Perekey's folders. It is never copied: a bookmark finds it
/// again after a move or a rename, and opens it in a sandbox.
public struct FileReference: Codable, Sendable, Equatable {
    /// Where the file was when it was chosen; used when the bookmark fails.
    public var path: String
    /// `URL.bookmarkData()`; nil if it could not be made.
    public var bookmark: Data?

    public init(path: String, bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
    }
}

/// One segment file of a track, as `AudioSource.track` reads it.
public struct TrackSegment: Sendable, Equatable {
    public var path: String
    /// Seconds on the recording's scale of the first written sample.
    public var startOffset: Double
    /// Samples written. Nil for a segment a crash left open: it is read up
    /// to its last whole packet.
    public var frames: Int64?

    public init(path: String, startOffset: Double, frames: Int64?) {
        self.path = path
        self.startOffset = startOffset
        self.frames = frames
    }
}

/// The two tracks of a call. The tracks give the speakers for free: the
/// microphone is the user, the system audio is everyone else.
public enum RecordingTrack: String, Codable, Sendable, CaseIterable {
    /// The microphone: «Я».
    case mic
    /// The system audio of the call: «Собеседники».
    case sys

    /// The speaker a track's phrases belong to before any diarization.
    public var speaker: TranscriptSpeaker.Kind {
        switch self {
        case .mic: .me
        case .sys: .others
        }
    }
}

/// A place in a track's audio: the segment and the frame in its file.
public struct TrackPosition: Sendable, Equatable {
    /// Index in the track's segments.
    public var segment: Int
    /// Frame in the segment's file, as `AVAudioFile.framePosition` takes it:
    /// the encoder's priming included.
    public var frame: Int64

    public init(segment: Int, frame: Int64) {
        self.segment = segment
        self.frame = frame
    }
}

extension [TrackSegment] {
    /// Where a second of the recording's scale lies in the files: the queue
    /// reads windows by it, the window plays a phrase from it. Skips the
    /// 2112 frames of priming at a segment's start and stays within the
    /// frames written. Nil before the first segment, in a gap and past the
    /// end. The segments go by their start, as `RecordingMeta.audio` gives them.
    public func locate(_ seconds: Double, sampleRate: Double = VoiceCore.sampleRate) -> TrackPosition? {
        guard let index = lastIndex(where: { $0.startOffset <= seconds }) else { return nil }
        let segment = self[index]
        let frame = Int64(((seconds - segment.startOffset) * sampleRate).rounded(.down))
        // An open segment, cut off by a crash, runs until the next one starts.
        let next = index + 1 < count ? self[index + 1].startOffset - segment.startOffset : nil
        let limit = segment.frames ?? next.map { Int64(($0 * sampleRate).rounded(.down)) } ?? .max
        guard frame < limit else { return nil }
        return TrackPosition(segment: index, frame: RecordingMeta.adtsPrimingFrames + frame)
    }
}
