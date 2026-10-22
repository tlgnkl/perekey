// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

/// A user may go back to 0.1.1 and forward again. 0.1.1 decodes `hotkeys`
/// with `try`: one shortcut it does not know, and it drops the whole file
/// (`SettingsFile.load`). So nothing new goes into `settings.json`; dictation
/// keeps its settings in `voice.json`. The one exception is the two scalar
/// menu bar keys (`addedSince0_1_1`): 0.1.1 ignores keys it does not know and
/// drops them when it saves, so the choice falls back to the capsule, and the
/// rest of the file is read as before. A new switch inside `corrections`
/// (`addedToCorrectionsSince0_1_1`) is the same: 0.1.1 reads the keys of that
/// object one by one, ignores the new one and drops it on save. Learning by
/// evidence (`addedToWordsSince0_1_1`, and `app` on a learned word) is the
/// same inside `words`: 0.1.1 takes a word learned for one app as learned
/// everywhere, and drops the candidates.
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

    /// Keys a later version added to `settings.json`; 0.1.1 does not write them back.
    static let addedSince0_1_1: Set<String> = ["menuBarIcon", "menuBarVisibility"]

    /// Keys of `corrections` that a later version added.
    static let addedToCorrectionsSince0_1_1: Set<String> = ["hyphen"]

    /// Keys of `words` that a later version added, and of its learned words.
    static let addedToWordsSince0_1_1: Set<String> = ["candidates", "learning"]
    static let addedToLearnedWordsSince0_1_1: Set<String> = ["app"]

    /// The JSON object without the keys 0.1.1 does not know.
    static func object(_ data: Data, as0_1_1: Bool) throws -> NSDictionary {
        let object = try Self.object(data).mutableCopy() as! NSMutableDictionary
        for key in addedSince0_1_1 { object.removeObject(forKey: key) }
        if let corrections = (object["corrections"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary {
            for key in addedToCorrectionsSince0_1_1 { corrections.removeObject(forKey: key) }
            object["corrections"] = corrections
        }
        if let words = (object["words"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary {
            for key in addedToWordsSince0_1_1 { words.removeObject(forKey: key) }
            if let learned = words["learned"] as? [NSDictionary] {
                words["learned"] = learned.map { word in
                    let word = word.mutableCopy() as! NSMutableDictionary
                    for key in addedToLearnedWordsSince0_1_1 { word.removeObject(forKey: key) }
                    return word
                }
            }
            object["words"] = words
        }
        return object
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
        #expect(try Self.object(resaved, as0_1_1: true) == Self.object(saved, as0_1_1: true), "0.1.1 writes back what it read")
        #expect(try JSONDecoder().decode(AppSettings.self, from: resaved) == settings)
    }

    @Test func hyphenSwitchSurvivesSavingIn0_1_1() throws {
        var settings = Self.filled
        settings.corrections.hyphen = true
        let saved = try Self.encode(settings)
        let legacy = try JSONDecoder().decode(LegacyAppSettings_0_1_1.self, from: saved)
        let resaved = try Self.encode(legacy)
        // 0.1.1 reads the file without error and writes back everything it knows;
        // the stand-in keeps the new switch because it shares `TextCorrections`.
        #expect(try Self.object(resaved, as0_1_1: true) == Self.object(saved, as0_1_1: true))
        #expect(try JSONDecoder().decode(AppSettings.self, from: resaved) == settings)
    }

    @Test func learningByEvidenceSurvivesSavingIn0_1_1() throws {
        var settings = Self.filled
        settings.words.learned.append(LearnedWord(word: "jrtq", learnedAt: 1_790_000_100, app: "com.apple.Notes"))
        settings.words.candidates = [LearningCandidate(word: "ytn", app: "com.apple.Notes", evidence: 1, threshold: 2,
                                                       undoCount: 1, firstUndoneAt: 1_790_000_200,
                                                       lastCountedDay: 20_717)]
        let saved = try Self.encode(settings)
        // 0.1.1 opens it without error and keeps every word it knows.
        let legacy = try JSONDecoder().decode(LegacyAppSettings_0_1_1.self, from: saved)
        #expect(legacy.words.learned.map(\.word) == ["ghbdtn", "jrtq"], "a word learned for an app: everywhere")
        let resaved = try Self.encode(legacy)
        #expect(try Self.object(resaved, as0_1_1: true) == Self.object(saved, as0_1_1: true))
        // Forward again: no `learning` key. The first forward trip migrates a word learned from one undo ...
        let back = try JSONDecoder().decode(AppSettings.self, from: resaved)
        #expect(back.words.learned == Self.filled.words.learned)
        #expect(back.words.candidates.map(\.word) == ["jrtq"])
    }

    @Test func roundTripThrough0_1_1KeepsWordsLearnedByEvidence() throws {
        var settings = Self.filled
        // One button undo at threshold 1: learned by evidence, undoCount 1.
        settings.words.learned.append(LearnedWord(word: "jrtq", learnedAt: 1_790_000_100, undoCount: 1))
        let legacy = try JSONDecoder().decode(LegacyAppSettings_0_1_1.self, from: Self.encode(settings))
        let resaved = try Self.encode(legacy)
        // ... and the migration mark outside the file turns it off (`SettingsFile`).
        let decoder = JSONDecoder()
        decoder.userInfo[WordRules.migratesLearningKey] = false
        let back = try decoder.decode(AppSettings.self, from: resaved)
        #expect(back.words.learned.map(\.word) == ["ghbdtn", "jrtq"])
        #expect(back.words.candidates.isEmpty)
    }

    @Test func dictationWritesNothingNewToSettings() throws {
        let saved = try Self.object(Self.encode(Self.filled))
        let keys = Set(saved.allKeys.compactMap { $0 as? String })
        #expect(keys.subtracting(Self.addedSince0_1_1) == LegacyAppSettings_0_1_1.keys)
        #expect(keys.isSuperset(of: Self.addedSince0_1_1))
        // The snapshot with dictation on saved and loaded through
        // `SettingsFile`: VoiceSettingsFileTests.snapshotWithVoiceChangesNoSavedSetting.
    }

    @Test func fileOf0_1_1OpensAndSavesBack() throws {
        let data = try Self.fixture("settings-0.1.1")
        let legacy = try JSONDecoder().decode(LegacyAppSettings_0_1_1.self, from: data)
        #expect(try Self.object(Self.encode(legacy), as0_1_1: true) == Self.object(data),
                "the fixture is as 0.1.1 writes it")

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings == Self.filled)
        let resaved = try Self.encode(settings)
        #expect(try Self.object(resaved, as0_1_1: true) == Self.object(data))
        #expect(try JSONDecoder().decode(LegacyAppSettings_0_1_1.self, from: resaved) == legacy)
    }

    @Test func voiceFileOfLaterVersionsLoads() throws {
        let data = try Self.fixture("voice-later")
        let voice = try JSONDecoder().decode(VoiceSettings.self, from: data)
        #expect(voice.isEnabled)
        #expect(voice.trigger == .hold(keyCode: KeyCode.space, modifiers: [.option]))
        #expect(voice.newerSchemaVersion == 2)
        #expect(voice.activeTrigger == nil, "a newer file keeps dictation off here")
    }
}
