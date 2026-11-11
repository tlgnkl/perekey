// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyVoiceCore

/// Recognizes a dictation in pieces while it is still spoken: each piece
/// (`SpeechSegmenter` cuts it) is read from the session's `DictationAudio`
/// and goes through `DictationRecognition` with the session's offline
/// engine, one after another, and its text is kept. At the stop only the
/// audio after the last piece is left (`finish`).
///
/// For Whisper the next piece is prompted with the last words of the text
/// so far (`SegmentedText.prompt`). Parakeet takes no prompt, and its
/// decoder starts afresh on every call (`FluidAudioEngine` makes a new
/// `TdtDecoderState` each time, as FluidAudio does for each 15 s chunk of
/// long audio): its pieces are as independent as its own chunks. It is cut
/// only between phrases (`SpeechEngine.pieces`): after a shorter pause it
/// lost the first words of the next piece.
///
/// A piece that fails ends the pieces: `finish` returns nil and the
/// controller recognizes the whole recording, as without pieces.
///
/// CoreML cannot be stopped half way: `cancel` lets the piece under way end
/// and starts no other. `idle` waits for it, so the session lets go of the
/// model only once nothing runs on it.
public actor SegmentedRecognizer {
    public struct Options: Sendable, Equatable {
        /// Where the pieces are cut; nil: where the model wants
        /// (`SpeechEngine.pieces`).
        public var segments: SpeechSegmenter.Options?
        /// Words of the text so far Whisper reads before the next piece: the
        /// end of a phrase, enough to carry the language and the casing over
        /// the cut, short enough that the dictionary's words keep their room
        /// in the prompt (`WhisperKitEngine.promptTokenLimit`, 48 tokens).
        /// 0 sends the dictionary alone. Measured with `perekey-voice-probe
        /// dictate-set --prompt-words`, report of stage 5, L5b.
        public var promptWords: Int

        public static let standard = Options(segments: nil, promptWords: 12)

        public init(segments: SpeechSegmenter.Options?, promptWords: Int) {
            self.segments = segments
            self.promptWords = promptWords
        }
    }

    private let audio: DictationAudio
    private let engine: any SpeechEngine
    private let detector: (any SpeechDetector)?
    private let dictionary: String?
    private let hint: LanguageHint?
    private let promptWords: Int
    /// The session's load of the model: a piece waits for it.
    private let ready: Task<Void, any Error>
    /// The pieces, one after another.
    private var queue: Task<Void, Never>?
    private var outcomes: [RecognitionOutcome] = []
    private var texts: [String] = []
    private var failed = false
    private var isCancelled = false
    private var isFinished = false
    /// The first sample after the pieces handed over so far.
    private(set) var end = 0

    init(audio: DictationAudio, engine: any SpeechEngine, detector: (any SpeechDetector)?, dictionary: String?,
         hint: LanguageHint?, promptWords: Int, ready: Task<Void, any Error>)
    {
        self.audio = audio
        self.engine = engine
        self.detector = detector
        self.dictionary = dictionary
        self.hint = hint
        self.promptWords = promptWords
        self.ready = ready
    }

    /// The next piece, right after the one before. Ignored once the
    /// pieces are finished, cancelled or failed.
    func add(_ piece: Range<Int>) {
        guard !isFinished else { return }
        enqueue(piece)
    }

    private func enqueue(_ piece: Range<Int>) {
        guard !isCancelled, !failed, piece.lowerBound == end, !piece.isEmpty else { return }
        end = piece.upperBound
        let previous = queue
        queue = Task {
            await previous?.value
            await recognize(piece)
        }
    }

    private func recognize(_ piece: Range<Int>) async {
        guard !isCancelled, !failed else { return }
        do {
            try await ready.value
            guard !isCancelled else { return }
            let outcome = try await DictationRecognition.recognize(
                AudioBuffer16k(audio.samples(in: piece)), engine: engine, detector: detector,
                prompt: SegmentedText.prompt(dictionary: dictionary, previous: texts, words: promptWords), hint: hint)
            outcomes.append(outcome)
            if case let .text(text) = outcome { texts.append(text) }
        } catch {
            failed = true
        }
    }

    /// The recording is over at `count` samples: the pieces under way end,
    /// the rest is recognized, and the text of all of them comes back. Nil
    /// when a piece failed: the whole recording is to be recognized.
    /// Throws `CancellationError` once cancelled.
    func finish(upTo count: Int) async throws -> RecognitionOutcome? {
        isFinished = true
        // The rest goes in the queue too: `idle` waits for it as for any piece.
        if count > end { enqueue(end..<count) }
        await queue?.value
        if isCancelled { throw CancellationError() }
        if failed { return nil }
        return SegmentedText.outcome(outcomes)
    }

    /// No piece starts any more; the one under way ends by itself.
    func cancel() {
        isCancelled = true
    }

    /// Once no piece runs, the rest of `finish` included.
    func idle() async {
        await queue?.value
    }
}
