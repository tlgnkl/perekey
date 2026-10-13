// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyVoiceCore
import Testing

struct DictationPreferencesTests {
    @Test func defaultsMatchTheSettings() {
        #expect(DictationPreferences(VoiceSettings()) == DictationPreferences())
    }

    @Test func fromTheSettings() {
        var settings = VoiceSettings()
        settings.microphoneUID = "usb-mic"
        settings.model = "whisper-large-v3-turbo-632mb"
        settings.switchesLayout = false
        settings.playsSounds = false
        settings.autoStop = .seconds15
        settings.unload = .minutes10
        #expect(DictationPreferences(settings) == DictationPreferences(
            microphoneUID: "usb-mic", modelID: "whisper-large-v3-turbo-632mb", switchesLayout: false,
            playsSounds: false, silenceStop: .seconds(15), unloadAfter: .seconds(600)))
    }

    @Test func offAndNever() {
        var settings = VoiceSettings()
        settings.autoStop = .off
        settings.unload = .never
        let preferences = DictationPreferences(settings)
        #expect(preferences.silenceStop == nil)
        #expect(preferences.unloadAfter == nil)
    }
}
