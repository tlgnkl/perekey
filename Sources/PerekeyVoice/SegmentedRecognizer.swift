// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
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
/// controller recognizes the whole recording, as without pieces. The failure
/// is logged by its type and code only, never by a text (it may hold the
/// dictation). A `CancellationError` is not a failure: the pieces are
/// cancelled, as by `cancel`.
///
/// CoreML cannot be stopped half way: `cancel` lets the piece under way end
/// and starts no other. It takes effect at once, from any thread, so that no
/// piece starts between the caller's Esc and the cancel. `idle` waits for the
/// piece under way, so the session lets go of the model only once nothing
/// runs on it.
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
        ///
        /// Whisper turbo on the speech set joined into dictations of up to
        /// 60 s: the whole recording 21,84 % word errors and a median of
        /// 3,930 s from the stop to the text, in pieces 9,21 % and 1,233 s
        /// (`perekey-voice-probe dictate-set whisper-large-v3-turbo-632mb
        /// .build/data-cache/speech --both`, commit 44d7b78, report of stage
        /// 5, L5b).
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
    /// Set from any thread (`cancel`), read by the pieces before they start.
    private nonisolated let cancelled = OSAllocatedUnfairLock(initialState: false)
    private var isFinished = false
    private let log: Logger
    /// The type and code of the error that failed a piece, as logged.
    private(set) var failure: String?
    /// The first sample after the pieces handed over so far.
    private(set) var end = 0

    private var isCancelled: Bool { cancelled.withLock { $0 } }

    init(audio: DictationAudio, engine: any SpeechEngine, detector: (any SpeechDetector)?, dictionary: String?,
         hint: LanguageHint?, promptWords: Int, ready: Task<Void, any Error>, log: Logger)
    {
        self.audio = audio
        self.engine = engine
        self.detector = detector
        self.dictionary = dictionary
        self.hint = hint
        self.promptWords = promptWords
        self.ready = ready
        self.log = log
    }

    /// The next piece, right after the one before. Ignored once the
    /// pieces are finished, cancelled or failed.
    func add(_ piece: Range<Int>) {
        guard !isFinished else { return }
        enqueue(piece)
    }

    private func enqueue(_ piece: Range<Int>) {
        guard !isCancelled, !failed else { return }
        // `SpeechSegmenter` hands over pieces one right after the other; a gap,
        // an overlap or an empty piece is a bug of the caller, and dropping it
        // would lose speech quietly.
        guard piece.lowerBound == end, !piece.isEmpty else {
            assertionFailure("piece \(piece) does not follow the pieces so far, which end at \(end)")
            return
        }
        end = piece.upperBound
        let previous = queue
        queue = Task(priority: .userInitiated) {
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
        } catch is CancellationError {
            // The model load or the piece was cancelled: not a failure of the
            // piece, the pieces end as after `cancel`.
            cancel()
        } catch {
            failed = true
            let description = Self.describe(error)
            failure = description
            log.error("speech piece: \(description, privacy: .public)")
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
        return SegmentedText.outcome(outcomes, language: hint?.language)
    }

    /// No piece starts any more; the one under way ends by itself. At once:
    /// a piece that starts after this call sees it.
    nonisolated func cancel() {
        cancelled.withLock { $0 = true }
    }

    /// The type and the code of an error, never its message: a message may
    /// hold the text.
    static func describe(_ error: any Error) -> String {
        "\(type(of: error)) \((error as NSError).code)"
    }

    /// Once no piece runs, the rest of `finish` included.
    func idle() async {
        await queue?.value
    }
}
