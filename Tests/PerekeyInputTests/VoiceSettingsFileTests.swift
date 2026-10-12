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

    @Test func saveKeepsKeysOfLaterVersions() throws {
        try withFile { file in
            try write(#"{"schemaVersion":3,"isEnabled":true,"model":"parakeet","microphone":{"uid":"X"}}"#, to: file)
            #expect(file.load() == VoiceSettings(isEnabled: true))
            try file.save(VoiceSettings(isEnabled: false, trigger: optionSpace))
            let saved = try object(file)
            #expect(saved["model"] as? String == "parakeet")
            #expect((saved["microphone"] as? [String: Any])?["uid"] as? String == "X")
            #expect(saved["schemaVersion"] as? Int == 3, "a later version's file keeps its version")
            #expect(saved["isEnabled"] as? Bool == false)
            #expect(file.load() == VoiceSettings(isEnabled: false, trigger: optionSpace))
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

    @Test func voiceLeavesTheSettingsFileAlone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "perekey-voice-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsFile = SettingsFile(url: directory.appending(path: "settings.json"))
        let voiceFile = VoiceSettingsFile(url: directory.appending(path: "voice.json"))
        try settingsFile.save(AppSettings())
        let before = try Data(contentsOf: settingsFile.url)
        try voiceFile.save(VoiceSettings(isEnabled: true))
        let settings = settingsFile.load()
        #expect(settings.snapshot(voice: voiceFile.load()).voice == .default)
        try settingsFile.save(settings)
        #expect(try Data(contentsOf: settingsFile.url) == before)
    }

    @Test func tapTriggerIsNeverHeld() {
        #expect(!VoiceTrigger.default.isHeldNow)
    }
}
