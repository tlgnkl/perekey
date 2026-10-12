// SPDX-License-Identifier: GPL-3.0-or-later

import FluidAudio
import PerekeyVoice
import Testing

struct VoiceEnginesTests {
    @Test func bothPackagesLink() {
        #expect(VoiceEngines.linked.count == 4)
    }

    // Package.swift resolves FluidAudio with no traits, so its NeMo text
    // normalization engine (a static library for TTS and ITN) stays out.
    @Test func nemoTextProcessingIsOff() {
        #expect(!TextNormalizer.shared.isNativeAvailable)
    }
}
