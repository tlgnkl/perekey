// SPDX-License-Identifier: GPL-3.0-or-later

import FluidAudio
import Foundation
import PerekeyCore
import PerekeyVoice
import Testing

struct VoiceEnginesTests {
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

    // Package.swift resolves FluidAudio with no traits, so its NeMo text
    // normalization engine (a static library for TTS and ITN) stays out.
    @Test func nemoTextProcessingIsOff() {
        #expect(!TextNormalizer.shared.isNativeAvailable)
    }
}
