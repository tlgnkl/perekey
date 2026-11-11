// SPDX-License-Identifier: GPL-3.0-or-later

import FluidAudio
import Foundation
import PerekeyCore
import PerekeyVoice
import PerekeyVoiceCore
import Testing

struct VoiceEnginesTests {
    /// One token per character, so the limits are easy to count.
    private func tokens(_ prompt: String, limit: Int) -> [Int] {
        WhisperKitEngine.promptTokens(prompt, limit: limit, specialTokenBegin: 1000) { text in
            text.unicodeScalars.map { Int($0.value) }
        }
    }

    @Test func whisperPromptKeepsWholeTermsWithinTheTokenLimit() {
        #expect(WhisperKitEngine.promptTokenLimit <= 48)
        #expect(WhisperKitEngine.promptTokenLimit < 224 / 2)
        let all = tokens("Perekey, Parakeet, iPhone", limit: 100)
        #expect(all.count == " Perekey, Parakeet, iPhone".count)
        // " Perekey" is 8, ", Parakeet" 10, ", iPhone" 8: the third does not fit in 20.
        let cut = tokens("Perekey, Parakeet, iPhone", limit: 20)
        #expect(cut.count == 18)
        #expect(tokens("", limit: 20).isEmpty)
        // A first term longer than the limit leaves no prompt at all, never half a word.
        #expect(tokens("Perekeyperekeyperekey", limit: 5).isEmpty)
    }

    @Test func recognizersHaveEngines() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = VoiceModelStore(
            locations: VoiceModelLocations(models: folder, managed: folder, coreMLCache: folder),
            managed: ManagedSettings())
        #expect(VoiceEngines.make(model: "parakeet-tdt-v3", store: store) is FluidAudioEngine)
        #expect(VoiceEngines.make(model: "whisper-large-v3-turbo-632mb", store: store) is WhisperKitEngine)
        #expect(VoiceEngines.make(model: "silero-vad", store: store) == nil)
        #expect(VoiceEngines.make(model: "nope", store: store) == nil)
    }

    /// «Распознавать во время речи»: Whisper cuts at a quarter of a second
    /// without speech, Parakeet only at half a second (a shorter pause cost it
    /// words at the start of the next piece).
    @Test func eachModelCutsAtItsOwnPause() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = VoiceModelStore(
            locations: VoiceModelLocations(models: folder, managed: folder, coreMLCache: folder),
            managed: ManagedSettings())
        let whisper = try #require(VoiceEngines.make(model: "whisper-large-v3-turbo-632mb", store: store))
        let parakeet = try #require(VoiceEngines.make(model: "parakeet-tdt-v3", store: store))
        #expect(whisper.pieces == SpeechSegmenter.Options(minimumPiece: 5, pause: 0.25))
        #expect(parakeet.pieces == SpeechSegmenter.Options(minimumPiece: 5, pause: 0.5))
        #expect(parakeet.pieces.pauseChunks == 2)
    }

    // Package.swift resolves FluidAudio with no traits, so its NeMo text
    // normalization engine (a static library for TTS and ITN) stays out.
    @Test func nemoTextProcessingIsOff() {
        #expect(!TextNormalizer.shared.isNativeAvailable)
    }
}
