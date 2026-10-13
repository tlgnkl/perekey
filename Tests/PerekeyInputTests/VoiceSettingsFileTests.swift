// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

struct VoiceSettingsFileTests {
    private let optionSpace = VoiceTrigger.hold(keyCode: 49, modifiers: [.option])

    /// Runs `body` with a voice file in a fresh temporary directory.
    private func withFile(_ body: (VoiceSettingsFile) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "perekey-voice-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(VoiceSettingsFile(url: directory.appending(path: "nested/voice.json")))
    }

    private func write(_ text: String, to file: VoiceSettingsFile) throws {
        try FileManager.default.createDirectory(
            at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file.url)
    }

    private func object(_ file: VoiceSettingsFile) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
    }

    @Test func liesBesideTheSettingsFile() {
        #expect(VoiceSettingsFile.defaultURL.deletingLastPathComponent()
            == SettingsFile.defaultURL.deletingLastPathComponent())
        #expect(VoiceSettingsFile.defaultURL.lastPathComponent == "voice.json")
    }

    @Test func missingFileMeansVoiceOff() throws {
        try withFile { file in
            #expect(file.load() == VoiceSettings())
            #expect(file.load().activeTrigger == nil)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test func saveThenLoadRoundTrips() throws {
        try withFile { file in
            let settings = VoiceSettings(isEnabled: true, trigger: optionSpace)
            try file.save(settings)
            #expect(file.load() == settings)
            #expect(try object(file)["schemaVersion"] as? Int == VoiceSettings.schemaVersion)
        }
    }

    @Test func saveKeepsUnknownKeys() throws {
        try withFile { file in
            try write(#"{"schemaVersion":1,"isEnabled":true,"model":"parakeet","microphone":{"uid":"X"}}"#, to: file)
            #expect(file.load() == VoiceSettings(isEnabled: true))
            try file.save(VoiceSettings(isEnabled: false, trigger: optionSpace))
            let saved = try object(file)
            #expect(saved["model"] as? String == "parakeet")
            #expect((saved["microphone"] as? [String: Any])?["uid"] as? String == "X")
            #expect(saved["schemaVersion"] as? Int == VoiceSettings.schemaVersion)
            #expect(saved["isEnabled"] as? Bool == false)
            #expect(file.load() == VoiceSettings(isEnabled: false, trigger: optionSpace))
        }
    }

    @Test func saveKeepsAnUnreadableTriggerUntilItIsSet() throws {
        try withFile { file in
            try write(#"{"schemaVersion":1,"isEnabled":true,"trigger":{"kind":"fnTwice","taps":2}}"#, to: file)
            var settings = file.load()
            #expect(settings.activeTrigger == nil, "a trigger it cannot read keeps dictation off")
            settings.isEnabled = false
            try file.save(settings)
            var saved = try object(file)
            #expect((saved["trigger"] as? [String: Any])?["kind"] as? String == "fnTwice")
            #expect(saved["isEnabled"] as? Bool == false)

            settings.trigger = optionSpace
            settings.isEnabled = true
            try file.save(settings)
            saved = try object(file)
            #expect((saved["trigger"] as? [String: Any])?["kind"] as? String == "hold")
            #expect(file.load().activeTrigger == optionSpace)
        }
    }

    @Test func newerFileIsReadButNeverWritten() throws {
        try withFile { file in
            let text = #"{"schemaVersion":2,"isEnabled":true,"model":"parakeet"}"#
            try write(text, to: file)
            let settings = file.load()
            #expect(settings.isEnabled)
            #expect(settings.newerSchemaVersion == 2)
            #expect(settings.activeTrigger == nil)
            #expect(throws: VoiceSettingsFile.NewerVersionError(schemaVersion: 2)) {
                try file.save(VoiceSettings(isEnabled: true))
            }
            #expect(try Data(contentsOf: file.url) == Data(text.utf8))
        }
    }

    @Test func corruptFileIsMovedAside() throws {
        try withFile { file in
            try write("{ not json", to: file)
            #expect(file.load() == VoiceSettings())
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
            #expect(try Data(contentsOf: file.brokenURL) == Data("{ not json".utf8))
            try file.save(VoiceSettings(isEnabled: true))
            #expect(file.load() == VoiceSettings(isEnabled: true))
        }
    }

    /// Dictation on narrows the retype to the left Option key in the tap's
    /// snapshot only: `settings.json` saved and loaded with it on is the same.
    @Test func snapshotWithVoiceChangesNoSavedSetting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "perekey-voice-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsFile = SettingsFile(url: directory.appending(path: "settings.json"))
        let voiceFile = VoiceSettingsFile(url: directory.appending(path: "voice.json"))
        var original = AppSettings(capsLock: .instant)
        original.setTrigger(.modifiers(.option, taps: .double), for: .changeCase)
        try settingsFile.save(original)
        let before = try Data(contentsOf: settingsFile.url)
        try voiceFile.save(VoiceSettings(isEnabled: true))

        let loaded = settingsFile.load()
        let snapshot = loaded.snapshot(voice: voiceFile.load())
        #expect(snapshot.voice == .default)
        #expect(snapshot.hotkeys.contains(HotkeyBinding(.modifiers(.leftOption, taps: .single), action: .convertLastWord)))
        #expect(snapshot.hotkeys.contains(HotkeyBinding(.modifiers(.leftOption, taps: .double), action: .changeCase)))

        try settingsFile.save(loaded)
        let reloaded = settingsFile.load()
        #expect(reloaded == original)
        #expect(reloaded.trigger(for: .convertLastWord) == .modifiers(.option, taps: .single))
        #expect(reloaded.trigger(for: .changeCase) == .modifiers(.option, taps: .double))
        #expect(try Data(contentsOf: settingsFile.url) == before)
        #expect(try String(contentsOf: settingsFile.url, encoding: .utf8).contains("voice") == false)
    }

    @Test func tapTriggerIsNeverHeld() {
        #expect(!VoiceTrigger.default.isHeldNow)
    }
}
