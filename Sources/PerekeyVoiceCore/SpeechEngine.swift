// SPDX-License-Identifier: GPL-3.0-or-later

/// A model that takes memory while loaded: a speech engine or a voice
/// activity detector. `ModelResidency` decides when it loads and unloads.
public protocol VoiceModel: Sendable {
    /// Loads the model and compiles it for CoreML, off the main thread. The
    /// first time after login or a macOS update this takes from seconds to
    /// minutes. Calling it on a loaded model does nothing.
    func prepare() async throws
    /// Frees the model; the next `prepare` loads it again.
    func unload() async
}

/// Turns speech into text.
public protocol SpeechEngine: VoiceModel {
    /// The `ModelCatalog` id of the model it runs.
    var id: String { get }
    /// The model ends real speech with video sign-offs ("Продолжение
    /// следует…") it learned from subtitles: Whisper does.
    var addsSignOffs: Bool { get }
    /// One dictation, held in memory whole. Throws if not prepared.
    func transcribe(_ audio: AudioBuffer16k) async throws -> Transcript
    /// The same, with words the model should spell as given (the user's
    /// dictionary). An engine without a prompt ignores it; Whisper reads it.
    func transcribe(_ audio: AudioBuffer16k, prompt: String?) async throws -> Transcript
    /// Long audio from disk, with timings: a file or a track's segments.
    func transcribe(source: AudioSource, progress: @escaping @Sendable (Double) -> Void) async throws
        -> TimedTranscript
}

extension SpeechEngine {
    public var addsSignOffs: Bool { false }

    public func transcribe(_ audio: AudioBuffer16k, prompt _: String?) async throws -> Transcript {
        try await transcribe(audio)
    }

    /// Files and call recordings come with stage 5.
    public func transcribe(source _: AudioSource, progress _: @escaping @Sendable (Double) -> Void) async throws
        -> TimedTranscript
    {
        throw SpeechEngineError.unsupported
    }
}

public enum SpeechEngineError: Error, Equatable, Sendable {
    /// The engine cannot do this yet.
    case unsupported
    /// `transcribe` before `prepare`, or after `unload`.
    case notPrepared
}

/// Audio at `VoiceCore.sampleRate`, mono.
public struct AudioBuffer16k: Sendable, Equatable {
    public var samples: [Float]

    public init(_ samples: [Float]) {
        self.samples = samples
    }

    public var seconds: Double { Double(samples.count) / VoiceCore.sampleRate }
}

public struct Transcript: Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// Audio on disk for `transcribe(source:progress:)`: a file, or the segments
/// of a track, each with its start in the track.
public enum AudioSource: Sendable, Equatable {
    case file(path: String)
    case segments([Segment])

    public struct Segment: Sendable, Equatable {
        public var path: String
        public var startOffset: Double

        public init(path: String, startOffset: Double) {
            self.path = path
            self.startOffset = startOffset
        }
    }
}

/// Text with timecodes, for subtitles.
public struct TimedTranscript: Sendable, Equatable {
    public var segments: [TimedSegment]

    public init(segments: [TimedSegment]) {
        self.segments = segments
    }
}

public struct TimedSegment: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [TimedWord]?

    public init(start: Double, end: Double, text: String, words: [TimedWord]? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

public struct TimedWord: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Finds speech in audio: Silero VAD in the app.
public protocol SpeechDetector: VoiceModel {
    /// The probability of speech in each `VoiceActivity.chunk` samples of
    /// 16 kHz audio, in order; a short last chunk counts as a whole one.
    func speechProbabilities(_ samples: [Float]) async throws -> [Float]
}
