// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

/// A user may go back to 0.1.1 and forward again. 0.1.1 decodes `hotkeys`
/// with `try`: one shortcut it does not know, and it drops the whole file
/// (`SettingsFile.load`). So nothing new goes into `settings.json`; dictation
/// keeps its settings in `voice.json`.
@Suite struct SettingsRollbackTests {
    /// Every field away from its default, the shortcuts included.
    static var filled: AppSettings {
        var settings = AppSettings(capsLock: .instant, autoswitch: false, onboardingDone: true,
                                   apps: ["com.apple.Terminal": AppRule(mode: .manualOnly),
                                          "com.tinyspeck.slackmacgap": AppRule(defaultLayout: "com.apple.keylayout.Russian")],
                                   words: WordRules(), sites: ["github.com": SiteRule(rememberLastLayout: true)],
                                   layoutSound: SoundSetting(isOn: true, name: "Pop"),
                                   correctionSound: SoundSetting(isOn: true, name: "Purr"), checkForUpdates: false,
                                   typoCorrection: false,
                                   corrections: TextCorrections(phraseRetype: false, capsLock: true),
                                   caretHint: .automatic)
        settings.apply(.separateKeys)
        settings.setTrigger(.key(keyCode: 9, modifiers: [.control, .option]), for: .pastePlain)
        settings.setTrigger(.modifiers(.shift, taps: .double), for: .changeCase)
        settings.words.mine = ["kubectl", "перекей"]
        settings.words.learned = [LearnedWord(word: "ghbdtn", learnedAt: 1_790_000_000, undoCount: 2)]
        settings.words.always = ["артём"]
        settings.statistics = true
        return settings
    }

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The JSON as an object to compare. Sets and dictionaries with enum keys
    /// (`ModifierChord`) encode as arrays in hash order, which changes from
    /// run to run; arrays of strings are sorted. The decoded values are
    /// compared too, in order.
    static func object(_ data: Data) throws -> NSDictionary {
        func canonical(_ value: Any) -> Any {
            switch value {
            case let dictionary as [String: Any]: dictionary.mapValues(canonical)
            case let strings as [String]: strings.sorted()
            case let array as [Any]: array.map(canonical)
            default: value
            }
        }
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return canonical(object) as! NSDictionary
    }

    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    @Test func newFileSurvivesSavingIn0_1_1() throws {
        let settings = Self.filled
        let saved = try Self.encode(settings)
        // 0.1.1 opens it: a decoding error here would make it drop every setting.
        let legacy = try JSONDecoder().decode(LegacyAppSettings_0_1_1.self, from: saved)
        let resaved = try Self.encode(legacy)
        #expect(try Self.object(resaved) == Self.object(saved), "0.1.1 writes back what it read")
        #expect(try JSONDecoder().decode(AppSettings.self, from: resaved) == settings)
    }

    @Test func dictationWritesNothingNewToSettings() throws {
        let saved = try Self.object(Self.encode(Self.filled))
        #expect(Set(saved.allKeys.compactMap { $0 as? String }) == LegacyAppSettings_0_1_1.keys)
        // Dictation on narrows the retype to the left Option key in the
        // snapshot only; the shortcuts as saved stay the preset's.
        let voice = VoiceSettings(isEnabled: true)
        var settings = AppSettings()
        _ = settings.snapshot(voice: voice)
        #expect(settings.preset == .standard)
        #expect(try Self.encode(settings) == Self.encode(AppSettings()))
    }

    @Test func fileOf0_1_1OpensAndSavesBack() throws {
        let data = try Self.fixture("settings-0.1.1")
        let legacy = try JSONDecoder().decode(LegacyAppSettings_0_1_1.self, from: data)
        #expect(try Self.object(Self.encode(legacy)) == Self.object(data), "the fixture is as 0.1.1 writes it")

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings == Self.filled)
        let resaved = try Self.encode(settings)
        #expect(try Self.object(resaved) == Self.object(data))
        #expect(try JSONDecoder().decode(LegacyAppSettings_0_1_1.self, from: resaved) == legacy)
    }

    @Test func voiceFileOfLaterVersionsLoads() throws {
        let data = try Self.fixture("voice-later")
        let voice = try JSONDecoder().decode(VoiceSettings.self, from: data)
        #expect(voice == VoiceSettings(isEnabled: true, trigger: .hold(keyCode: KeyCode.space, modifiers: [.option])))
    }
}
