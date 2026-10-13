// SPDX-License-Identifier: GPL-3.0-or-later

/// Speech or not, from the probabilities of a `SpeechDetector`.
public enum VoiceActivity {
    /// Silero VAD's window in FluidAudio: 4096 samples, 256 ms.
    public static let chunk = 4096
    public static var chunkSeconds: Double { Double(chunk) / VoiceCore.sampleRate }
    /// Silero's usual threshold. FluidAudio's 0.85 is for cutting long audio
    /// into segments; here a missed word costs more than a breath let through.
    public static let threshold: Float = 0.5

    /// The gate at the end of a recording: is there any speech at all?
    /// Without it, models make up text out of silence.
    public static func hasSpeech(_ probabilities: [Float], threshold: Float = threshold, minimumChunks: Int = 1)
        -> Bool
    {
        probabilities.lazy.filter { $0 >= threshold }.count >= minimumChunks
    }
}

/// Stops a recording after `limit` seconds without speech, counted from the
/// start while nothing was said yet. Fed while the recording runs, with the
/// speech decision of each piece of audio as it comes.
public struct SilenceWatch: Sendable, Equatable {
    public let limit: Double
    private var lastSpeech: Double = 0

    public init(limit: Double) {
        self.limit = limit
    }

    /// `end`: the seconds of audio recorded so far, the piece included.
    /// Returns true once the silence reaches the limit.
    public mutating func observe(speech: Bool, upTo end: Double) -> Bool {
        if speech { lastSpeech = end }
        return end - lastSpeech >= limit
    }
}

/// What one recording turned into.
public enum RecognitionOutcome: Hashable, Sendable {
    case text(String)
    /// The detector heard no speech: nothing was recognized.
    case noSpeech
    /// The model gave nothing, or only phrases it makes up (`HallucinationFilter`).
    case nothingLeft
}

public enum DictationRecognition {
    /// The steps after a recording: the speech gate, the model, the stop
    /// list. A detector that fails lets the audio through: losing a phrase
    /// is worse than a made-up one the stop list may still catch.
    public static func recognize(_ audio: AudioBuffer16k, engine: any SpeechEngine,
                                 detector: (any SpeechDetector)?) async throws -> RecognitionOutcome
    {
        guard !audio.samples.isEmpty else { return .noSpeech }
        if let detector, let probabilities = try? await detector.speechProbabilities(audio.samples),
           !VoiceActivity.hasSpeech(probabilities)
        {
            return .noSpeech
        }
        let transcript = try await engine.transcribe(audio)
        let text = HallucinationFilter.clean(transcript.text)
        return text.isEmpty ? .nothingLeft : .text(text)
    }
}
