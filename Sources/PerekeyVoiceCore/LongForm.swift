// SPDX-License-Identifier: GPL-3.0-or-later

/// Long audio, 16 kHz mono, read a piece at a time: four hours never sit in
/// memory. Where a track has no audio (a gap) it reads zeros.
public protocol LongAudio: Sendable {
    var sampleCount: Int { get }
    /// Exactly `range.count` samples; past the end, zeros.
    func read(_ range: Range<Int>) throws -> [Float]
    /// Frees what the audio holds on disk (a decoded file). Called once.
    func close()
}

extension LongAudio {
    public func close() {}
}

/// Opens an `AudioSource` for reading: the voice layer, with AVFoundation.
public protocol LongAudioOpener: Sendable {
    func open(_ source: AudioSource) async throws -> any LongAudio
}

/// How long audio is cut for the model. One window goes to the model at a
/// time; between windows the queue yields to dictation, checks for cancel
/// and saves its progress. Stage 0 measured 60 s windows as fast as 300 s
/// ones, with five times shorter waits.
public struct WindowSettings: Sendable, Equatable {
    /// The longest window, seconds.
    public var window: Double
    /// Where the window ends is looked for in its last `search` seconds.
    public var search: Double
    /// Seconds two windows share; words are split at its middle.
    public var overlap: Double

    public static let standard = WindowSettings(window: 60, search: 15, overlap: 2)

    public init(window: Double, search: Double, overlap: Double) {
        self.window = window
        self.search = search
        self.overlap = overlap
    }
}

/// Where a window ends: in the quietest stretch of its tail, so that a cut
/// falls between words.
public enum WindowCut {
    /// `probabilities`: one per `VoiceActivity.chunk` from `tailStart`.
    /// Returns the sample (from the window's start) to cut at: the middle of
    /// the longest run below the threshold, the latest of equal ones, or
    /// else the middle of the quietest chunk.
    public static func cut(probabilities: [Float], tailStart: Int, threshold: Float = VoiceActivity.threshold) -> Int {
        let chunk = VoiceActivity.chunk
        guard !probabilities.isEmpty else { return tailStart }
        var best = (start: 0, length: 0)
        var run = (start: 0, length: 0)
        for (i, p) in probabilities.enumerated() {
            if p < threshold {
                run = run.length == 0 ? (i, 1) : (run.start, run.length + 1)
                if run.length >= best.length { best = run }
            } else {
                run = (0, 0)
            }
        }
        if best.length > 0 {
            return tailStart + best.start * chunk + best.length * chunk / 2
        }
        let quietest = probabilities.indices.min { probabilities[$0] < probabilities[$1] }!
        return tailStart + quietest * chunk + chunk / 2
    }
}

/// Joins the windows of one track. A window's words count from its start
/// on the track and are kept from the middle of the overlap with the window
/// before to the middle of the overlap with the next: a word at the edge is
/// neither lost nor doubled. A phrase without word timings is kept by its
/// start; such windows do not overlap (`TranscriptionCheckpoint.wordless`).
public struct WindowStitcher: Codable, Sendable, Equatable {
    /// Seconds on the track from which the next window's words are kept.
    public private(set) var keepFrom: Double = 0
    public private(set) var words: [TimedWord] = []
    /// Phrases of engines that give no word timings.
    public private(set) var phrases: [TimedSegment] = []

    public init() {}

    /// - Parameters:
    ///   - offset: the window's start on the track, seconds.
    ///   - keepUntil: the middle of the overlap with the next window; nil for the last window.
    public mutating func add(_ window: TimedTranscript, offset: Double, keepUntil: Double?) {
        let until = keepUntil ?? .infinity
        func kept(_ start: Double) -> Bool { start >= keepFrom && start < until }
        for segment in window.segments {
            let segment = segment.shifted(by: offset)
            if let words = segment.words, !words.isEmpty {
                self.words += words.filter { kept($0.start) }
            } else if segment.end > keepFrom, segment.start < until {
                // A phrase without words reaching past `keepFrom` is kept
                // whole (Whisper starts a window's first phrase at 0): what it
                // covers of the window before goes, so nothing is said twice.
                if segment.start < keepFrom {
                    self.words.removeAll { $0.start >= segment.start }
                    phrases.removeAll { $0.start >= segment.start }
                }
                phrases.append(segment)
            }
        }
        keepFrom = until
    }

    /// The track's text, in phrases.
    public func transcript(language: String?) -> TimedTranscript {
        let all = PhraseSplitter.split(words) + phrases
        return TimedTranscript(segments: all.sorted { $0.start < $1.start }, language: language)
    }
}

/// Words into phrases, the lines of a transcript and the cues of subtitles:
/// a phrase ends after a sentence, at a pause, or once it runs long.
public enum PhraseSplitter {
    /// A pause this long ends a phrase, seconds.
    public static let pause = 1.0
    /// Past this a phrase ends at the next short pause or comma.
    public static let long = 12.0
    /// A phrase never runs longer.
    public static let longest = 20.0

    public static func split(_ words: [TimedWord]) -> [TimedSegment] {
        var phrases: [TimedSegment] = []
        var current: [TimedWord] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                phrases.append(TimedSegment(start: first.start, end: last.end, text: text, words: current))
            }
            current = []
        }
        for word in words {
            if let previous = current.last, let first = current.first {
                let gap = word.start - previous.end
                let length = word.end - first.start
                let trimmed = previous.text.trimmingCharacters(in: .whitespaces)
                let endsSentence = trimmed.last.map { ".?!…".contains($0) } ?? false
                let endsClause = trimmed.last.map { ",;:".contains($0) } ?? false
                if endsSentence || gap >= pause || length > longest
                    || (word.start - first.start > long && (gap >= 0.3 || endsClause))
                {
                    close()
                }
            }
            current.append(word)
        }
        close()
        return phrases
    }
}

/// What a recording's transcription has done so far, saved between windows
/// in `transcript.partial.json` beside `meta.json`: quitting Perekey loses one window
/// at most, and the queue goes on from there at the next launch.
public struct TranscriptionCheckpoint: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public var schemaVersion = Self.schemaVersion
    /// A checkpoint of another model is thrown away.
    public var model: String
    /// The tracks done: `mic`, `sys`, or `file`.
    public var finished: [String: TimedTranscript] = [:]
    /// The track in work.
    public var track: String?
    /// Its next window's first sample.
    public var position = 0
    public var stitcher = WindowStitcher()
    /// The language found in the track's first window with speech.
    public var language: String?
    /// The engine gave phrases without word timings on this track: windows
    /// no longer overlap, for a phrase on an edge cannot be split by its words.
    public var wordless = false

    public init(model: String) {
        self.model = model
    }
}

/// The model files and calls are transcribed with. The cloud only by the
/// user's own choice for transcriptions: a recording holds other people's
/// voices, and a cloud model for dictation is no consent to send them.
public enum TranscriptionModel {
    /// - Parameters:
    ///   - chosen: the setting «Модель для расшифровок»; nil for none.
    ///   - dictation: the dictation model.
    public static func resolve(chosen: String?, dictation: String) -> String {
        if let chosen, !chosen.isEmpty { return chosen }
        if ModelCatalog.entry(id: dictation)?.engine.recognizes == true { return dictation }
        return DictationPreferences.defaultModel
    }

    /// A model of a server, not of this Mac.
    public static func isCloud(_ id: String) -> Bool {
        CloudSpeechModel(id: id) != nil
    }
}
