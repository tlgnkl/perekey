// SPDX-License-Identifier: GPL-3.0-or-later

/// Where a dictation is cut into pieces while it is spoken, so that each
/// piece is recognized while the next one is said and only the last is left
/// after the stop («Распознавать во время речи»). A cut falls only in a pause
/// (`WindowCut`): a word is never split, so the pieces need no overlap and no
/// stitching. Speech without a pause is not cut at all.
///
/// Fed the speech probabilities of the recording so far, one per
/// `VoiceActivity.chunk` from its first sample, as the detector gives them
/// every half second.
public struct SpeechSegmenter: Sendable, Equatable {
    public struct Options: Sendable, Equatable {
        /// The shortest piece, seconds: a pause sooner after the last cut does
        /// not cut. A recording shorter than this is recognized whole, as
        /// before. Whisper decodes any piece as a 30 s window (about 0,75 s
        /// even for 2 s of audio, stage 5 baseline `score --head 2`), and
        /// short pieces lose the context of their words. On the speech set
        /// joined into dictations of up to 60 s, Whisper turbo with a pause of
        /// 0,25 s: 5 s gave a median of 1,29 s from the stop to the text and
        /// 9,5 % word errors, 3 s gave 1,64 s and 9,1 %
        /// (`perekey-voice-probe dictate-set whisper-large-v3-turbo-632mb
        /// .build/data-cache/speech --pieces --pause 0.25 [--minimum 3]`,
        /// report of stage 5, L5b).
        public var minimumPiece: Double
        /// The shortest pause that cuts, seconds; counted in whole chunks of
        /// the detector (0,256 s), so 0,25 s is one of them. With 0,5 s (two
        /// chunks) Whisper cut only between the set's sentences and left the
        /// last one whole: a median of 1,91 s from the stop to the text, 10,3 %
        /// word errors (same command, `--both`). One chunk below the
        /// threshold is a quarter of a second without speech: longer than the
        /// stop inside a word.
        public var pause: Double

        public static let standard = Options(minimumPiece: 5, pause: 0.25)
        /// Cuts only at a pause of half a second, between phrases. Parakeet
        /// v3 with `standard` lost the first words of a piece: 8,42 % word
        /// errors against 7,58 % for the whole recording; with this, 7,32 %
        /// and a median of 0,02 s from the stop to the text
        /// (`perekey-voice-probe dictate-set parakeet-tdt-v3
        /// .build/data-cache/speech --pieces --pause 0.5`; `--both` for the
        /// whole recording; report of stage 5, L5b).
        public static let betweenPhrases = Options(minimumPiece: 5, pause: 0.5)

        public init(minimumPiece: Double, pause: Double) {
            self.minimumPiece = minimumPiece
            self.pause = pause
        }

        /// The shortest piece in chunks, rounded up.
        public var minimumChunks: Int { chunks(minimumPiece) }
        /// The shortest pause in chunks, rounded up, at least one.
        public var pauseChunks: Int { max(1, chunks(pause)) }

        private func chunks(_ seconds: Double) -> Int {
            let samples = Int((seconds * VoiceCore.sampleRate).rounded())
            return (samples + VoiceActivity.chunk - 1) / VoiceActivity.chunk
        }
    }

    public let options: Options
    /// The first sample not yet in a piece.
    public private(set) var start = 0

    public init(options: Options = .standard) {
        self.options = options
    }

    /// The next piece, once the probabilities hold a pause of at least
    /// `options.pause` at least `options.minimumPiece` after the last cut.
    /// The cut is where `WindowCut` puts it among the chunks past the
    /// minimum: the middle of their longest pause. Nil while there is none.
    public mutating func next(_ probabilities: [Float], threshold: Float = VoiceActivity.threshold) -> Range<Int>? {
        let chunk = VoiceActivity.chunk
        let first = (start + chunk - 1) / chunk + options.minimumChunks
        guard probabilities.count - first >= options.pauseChunks else { return nil }
        let tail = Array(probabilities[first...])
        guard Self.longestPause(tail, threshold: threshold) >= options.pauseChunks else { return nil }
        let cut = WindowCut.cut(probabilities: tail, tailStart: first * chunk, threshold: threshold)
        let piece = start..<cut
        start = cut
        return piece
    }

    /// The longest run of chunks below `threshold`.
    static func longestPause(_ probabilities: [Float], threshold: Float) -> Int {
        var longest = 0
        var run = 0
        for probability in probabilities {
            run = probability < threshold ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }
}

/// The text of a dictation recognized in pieces.
public enum SegmentedText {
    /// What Whisper reads before a piece: the user's dictionary first, as for
    /// a whole dictation, then the last `words` words of the pieces before,
    /// as text it heard just before. Whisper keeps the prompt's terms in
    /// order while they fit (`WhisperKitEngine.promptTokens`), so the
    /// dictionary is never pushed out by the text. Nil for an empty prompt.
    public static func prompt(dictionary: String?, previous: [String], words: Int) -> String? {
        let tail = words > 0
            ? previous.joined(separator: " ").split(whereSeparator: \.isWhitespace).suffix(words).joined(separator: " ")
            : ""
        let parts = [dictionary ?? "", tail].filter { !$0.allSatisfy(\.isWhitespace) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The pieces' outcomes as one: their texts in order, joined by a
    /// space. With no text, speech the stop list took (`nothingLeft`) wins
    /// over silence: as for a whole dictation, the HUD says nothing was heard.
    public static func outcome(_ pieces: [RecognitionOutcome]) -> RecognitionOutcome {
        let texts = pieces.compactMap { if case let .text(text) = $0 { text } else { nil } }
        if !texts.isEmpty { return .text(texts.joined(separator: " ")) }
        return pieces.contains(.nothingLeft) ? .nothingLeft : .noSpeech
    }
}
