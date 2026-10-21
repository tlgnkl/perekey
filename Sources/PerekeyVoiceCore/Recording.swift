// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `meta.json` of a recording: a call, or a file the user gave to transcribe.
/// One folder per recording, `Recordings/<id>/` (`RecordingsFolder`).
///
/// A call's tracks are written in segments; each carries its own start on
/// the recording's scale. Durations of segments are never summed: AAC adds
/// priming frames to every file. The scale is host time from the start minus
/// pauses; a gap in a track does not move it.
public struct RecordingMeta: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    /// AAC in ADTS (`.aac`): each packet carries its own header, so a segment
    /// a crash cut off reads up to its last whole packet.
    public static let adts = "adts"
    /// Samples of encoder priming at the start of every ADTS segment.
    /// `AVAudioFile` does not drop them for ADTS (`.m4a` does), so a reader
    /// skips them, or every segment plays 132 ms late.
    public static let adtsPrimingFrames: Int64 = 2112

    public enum Kind: String, Codable, Sendable {
        case call
        case file
    }

    /// `recording` while the tracks are written: found so at launch, the
    /// recording was cut off by a crash.
    public enum State: String, Codable, Sendable {
        case recording
        case stopped
        case transcribing
        case done
    }

    /// What was recorded.
    public struct Source: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            /// One program and its helper processes.
            case app
            /// All system audio but Perekey's.
            case system
            /// A file the user chose.
            case file
        }

        public var kind: Kind
        /// The program's bundle ID, for `app`.
        public var bundleID: String?
        /// The program's name as it was then, for `app`.
        public var name: String?
        /// For `file`.
        public var file: FileReference?

        public static func app(bundleID: String, name: String) -> Source {
            Source(kind: .app, bundleID: bundleID, name: name)
        }

        public static let system = Source(kind: .system)

        public static func file(_ file: FileReference) -> Source {
            Source(kind: .file, file: file)
        }

        public init(kind: Kind, bundleID: String? = nil, name: String? = nil, file: FileReference? = nil) {
            self.kind = kind
            self.bundleID = bundleID
            self.name = name
            self.file = file
        }
    }

    public struct Segment: Codable, Sendable, Equatable {
        public var track: RecordingTrack
        /// The file name inside the recording's folder: `mic-0001.aac`.
        public var file: String
        /// `mHostTime` of the segment's first sample.
        public var startHostTime: UInt64
        /// Seconds on the recording's scale of the first sample.
        public var startOffset: Double
        /// Samples written; 0 while the segment is open.
        public var frames: Int64
        /// False while the segment is written. A segment found open after a
        /// crash is read to its end.
        public var closed: Bool

        public init(track: RecordingTrack, file: String, startHostTime: UInt64, startOffset: Double,
                    frames: Int64 = 0, closed: Bool = false)
        {
            self.track = track
            self.file = file
            self.startHostTime = startHostTime
            self.startOffset = startOffset
            self.frames = frames
            self.closed = closed
        }

        /// `mic-0001.aac`: the track, the segment's number from 1, `.aac`.
        public static func fileName(track: RecordingTrack, number: Int) -> String {
            "\(track.rawValue)-\(String(format: "%04d", number)).aac"
        }
    }

    /// Audio missing from a track from `startOffset` until its next segment.
    /// After any gap the track goes on in a new segment. A pause is a gap of
    /// no length on both tracks: the scale stops while it lasts.
    public struct Gap: Codable, Sendable, Equatable {
        public var track: RecordingTrack
        public var startOffset: Double
        public var reason: Reason

        public init(track: RecordingTrack, startOffset: Double, reason: Reason) {
            self.track = track
            self.startOffset = startOffset
            self.reason = reason
        }

        /// Why a track broke off. A string in JSON: a reason a newer
        /// Perekey wrote reads as it is.
        public struct Reason: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
            public static let paused: Reason = "paused"
            public static let deviceChanged: Reason = "deviceChanged"
            public static let writeFailed: Reason = "writeFailed"
            public static let permissionDenied: Reason = "permissionDenied"

            public var rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            public init(stringLiteral value: String) {
                rawValue = value
            }

            public init(from decoder: any Decoder) throws {
                rawValue = try decoder.singleValueContainer().decode(String.self)
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }
        }
    }

    /// How long a call's audio stays on disk.
    public enum AudioRetention: String, Codable, Sendable, CaseIterable {
        case always
        case month
        /// Removed once the transcript is written.
        case untilTranscribed
    }

    public var schemaVersion = Self.schemaVersion
    public var kind: Kind
    public var source: Source
    public var createdAt: Date
    public var state: State
    /// Seconds on the recording's scale; nil until known.
    public var duration: Double?
    /// `adts` for a call; nil for a file, which keeps its own format.
    public var format: String?
    public var sampleRate: Double
    /// `mHostTime` of the recording's start, for a call.
    public var startHostTime: UInt64?
    public var segments: [Segment]
    public var gaps: [Gap]
    /// For a call; a file's audio is the user's and never removed.
    public var audioRetention: AudioRetention?
    /// When the call's audio was removed by its term; the transcript stays.
    public var audioRemovedAt: Date?
    /// What to transcribe it with: set when it is queued, cleared when its
    /// transcript is written or the user cancels. Found set at launch, the
    /// queue was cut off and starts again from its last window.
    public var pendingJob: TranscriptionJob?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, kind, source, createdAt, state, duration, format, sampleRate, startHostTime, segments,
             gaps, audioRetention, audioRemovedAt, pendingJob
    }

    public init(kind: Kind, source: Source, createdAt: Date, state: State, duration: Double? = nil,
                format: String? = nil, sampleRate: Double = VoiceCore.sampleRate, startHostTime: UInt64? = nil,
                segments: [Segment] = [], gaps: [Gap] = [], audioRetention: AudioRetention? = nil)
    {
        self.kind = kind
        self.source = source
        self.createdAt = createdAt
        self.state = state
        self.duration = duration
        self.format = format
        self.sampleRate = sampleRate
        self.startHostTime = startHostTime
        self.segments = segments
        self.gaps = gaps
        self.audioRetention = audioRetention
    }

    /// A call that starts recording now.
    public static func call(source: Source, startHostTime: UInt64, createdAt: Date = Date(),
                            audioRetention: AudioRetention) -> RecordingMeta
    {
        RecordingMeta(kind: .call, source: source, createdAt: createdAt, state: .recording, format: adts,
                      startHostTime: startHostTime, audioRetention: audioRetention)
    }

    /// A file waiting for its transcript.
    public static func file(_ file: FileReference, createdAt: Date = Date()) -> RecordingMeta {
        RecordingMeta(kind: .file, source: .file(file), createdAt: createdAt, state: .stopped)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        kind = try c.decode(Kind.self, forKey: .kind)
        source = try c.decode(Source.self, forKey: .source)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        state = try c.decode(State.self, forKey: .state)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? VoiceCore.sampleRate
        startHostTime = try c.decodeIfPresent(UInt64.self, forKey: .startHostTime)
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        gaps = try c.decodeIfPresent([Gap].self, forKey: .gaps) ?? []
        audioRetention = try c.decodeIfPresent(AudioRetention.self, forKey: .audioRetention)
        audioRemovedAt = try c.decodeIfPresent(Date.self, forKey: .audioRemovedAt)
        pendingJob = try c.decodeIfPresent(TranscriptionJob.self, forKey: .pendingJob)
    }

    /// The tracks that have audio, in order.
    public var tracks: [RecordingTrack] {
        RecordingTrack.allCases.filter { track in segments.contains { $0.track == track } }
    }

    /// The audio to transcribe: the chosen file, or one track's segments by
    /// their start. Nil if there is none.
    public func audio(of track: RecordingTrack? = nil, in directory: URL) -> AudioSource? {
        switch kind {
        case .file:
            return source.file.map(AudioSource.file)
        case .call:
            guard let track else { return nil }
            let parts = segments.filter { $0.track == track }.sorted { $0.startOffset < $1.startOffset }
            guard !parts.isEmpty else { return nil }
            return .track(track, parts.map { segment in
                TrackSegment(path: directory.appending(path: segment.file, directoryHint: .notDirectory).path,
                             startOffset: segment.startOffset, frames: segment.closed ? segment.frames : nil)
            })
        }
    }
}

/// Someone in a transcript.
public struct TranscriptSpeaker: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// The microphone track of a call: «Я».
        case me
        /// The system audio of a call, not split: «Собеседники».
        case others
        /// One voice the diarizer found: «Спикер N».
        case speaker
    }

    public static let me = TranscriptSpeaker(id: "me", kind: .me)
    public static let others = TranscriptSpeaker(id: "others", kind: .others)

    public static func speaker(_ number: Int) -> TranscriptSpeaker {
        TranscriptSpeaker(id: "speaker-\(number)", kind: .speaker, number: number)
    }

    /// What phrases point to: `me`, `others`, `speaker-1`, …
    public var id: String
    public var kind: Kind
    /// From 1, in order of first appearance; for `speaker`.
    public var number: Int?
    /// The user's name for the speaker: «Аня». Nil shows the default label
    /// in the app's language («Я», «Собеседники», «Спикер 2»).
    public var name: String?

    public init(id: String, kind: Kind, number: Int? = nil, name: String? = nil) {
        self.id = id
        self.kind = kind
        self.number = number
        self.name = name
    }
}

/// `transcript.json`: the text of a recording with timecodes and speakers.
public struct TranscriptDocument: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public var schemaVersion = Self.schemaVersion
    /// The `ModelCatalog` id, or a cloud model's name.
    public var model: String
    /// The engine that ran it: `parakeet`, `whisper`, `cloud`.
    public var engine: String
    /// ISO 639-1, if the model said.
    public var language: String?
    public var createdAt: Date
    public var segments: [TimedSegment]
    public var speakers: [TranscriptSpeaker]

    /// Speakers are taken from the segments, in order of first appearance.
    public init(model: String, engine: String, language: String?, createdAt: Date = Date(),
                segments: [TimedSegment])
    {
        self.model = model
        self.engine = engine
        self.language = language
        self.createdAt = createdAt
        self.segments = segments
        speakers = Self.speakers(of: segments)
    }

    public static func speakers(of segments: [TimedSegment]) -> [TranscriptSpeaker] {
        var seen: [TranscriptSpeaker] = []
        for id in segments.compactMap(\.speaker) where !seen.contains(where: { $0.id == id }) {
            switch id {
            case TranscriptSpeaker.me.id: seen.append(.me)
            case TranscriptSpeaker.others.id: seen.append(.others)
            default:
                let number = Int(id.dropFirst("speaker-".count))
                seen.append(TranscriptSpeaker(id: id, kind: .speaker, number: number))
            }
        }
        return seen
    }

    /// Gives a speaker the user's name; nil brings back the default label.
    public mutating func rename(speaker id: String, to name: String?) {
        guard let i = speakers.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        speakers[i].name = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// «Расшифровать заново»: a new transcript in place of `old`. The names of
    /// «Я» and «Собеседники» stay; diarized speakers are found anew, and the
    /// old names would land on other voices.
    public func keepingNames(from old: TranscriptDocument) -> TranscriptDocument {
        var document = self
        for i in document.speakers.indices where document.speakers[i].kind != .speaker {
            document.speakers[i].name = old.speakers.first { $0.id == document.speakers[i].id }?.name
        }
        return document
    }
}
