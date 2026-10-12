// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyVoiceCore
import Testing

struct VoiceCoreTests {
    @Test func modelsTake16kHz() {
        #expect(VoiceCore.sampleRate == 16_000)
    }
}
