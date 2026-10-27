// SPDX-License-Identifier: GPL-3.0-or-later

// The settings decoder and encoder of Perekey 0.1.1, for the rollback tests
// (`SettingsRollbackTests`). Copied from the v0.1.1 tag:
// Sources/PerekeyCore/AppSettings.swift, HotkeyPreset.swift (`HotkeyAction`),
// Trigger.swift and the coding of WordRules.swift. Never edit them to follow
// the app: they stand for the binary a user goes back to.
//
// The types of the fields 0.1.1 decodes with `try?` (`AppRule`, `SiteRule`,
// `TextCorrections`, the modifier types) are the app's own:
// they have not changed since v0.1.1 (`git diff v0.1.1 -- Sources/PerekeyCore`).
// Copy one here before changing how it is encoded.

import Foundation
@testable import PerekeyCore

enum Legacy_0_1_1 {
    enum HotkeyAction: Hashable, Sendable, Codable {
        case switchLayout
        case selectLanguage(String)
        case convertLastWord
        case toggleAutoswitch
        case changeCase
        case transliterate
        case pastePlain
        case undoLastCorrection
    }

    enum Taps: Int, Hashable, Sendable, Codable {
        case single = 1
        case double = 2
    }

    enum Trigger: Hashable, Sendable, Codable {
        case modifiers(ModifierChord, taps: Taps)
        case key(keyCode: UInt16, modifiers: Set<ModifierKind>)
    }

    struct HotkeyBinding: Hashable, Sendable, Codable {
        var trigger: Trigger
        var action: HotkeyAction
    }

    enum CapsLockMode: String, CaseIterable, Hashable, Sendable, Codable {
        case untouched, system, instant
    }

    enum CaretHintMode: String, CaseIterable, Hashable, Sendable, Codable {
        case all, automatic, off
    }

    struct SoundSetting: Hashable, Sendable, Codable {
        var isOn: Bool
        var name: String
    }

    struct LearnedWord: Hashable, Sendable {
        var word: String
        var learnedAt: Double
        var undoCount: Int
        var lastUndoneAt: Double
    }

    struct WordRules: Hashable, Sendable, Codable {
        var mine: [String] = []
        var learned: [LearnedWord] = []
        var always: [String] = []
        var learnFromUndos = true
    }
}

extension Legacy_0_1_1.LearnedWord: Codable {
    private enum CodingKeys: String, CodingKey {
        case word, learnedAt, undoCount, lastUndoneAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        word = try container.decode(String.self, forKey: .word)
        learnedAt = try container.decode(Double.self, forKey: .learnedAt)
        undoCount = max(1, (try? container.decodeIfPresent(Int.self, forKey: .undoCount)) ?? 1)
        lastUndoneAt = (try? container.decodeIfPresent(Double.self, forKey: .lastUndoneAt)) ?? learnedAt
    }
}

extension Legacy_0_1_1.WordRules {
    private enum CodingKeys: String, CodingKey {
        case mine, learned, always, learnFromUndos
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var seen = Set<String>()
        func words(_ key: CodingKeys) -> [String] {
            guard let raw = try? container.decodeIfPresent([String].self, forKey: key) else { return [] }
            var words: [String] = []
            for word in raw.map(PerekeyCore.WordRules.normalize) where !word.isEmpty && seen.insert(word).inserted {
                words.append(word)
            }
            return words
        }
        let mine = words(.mine)
        var learned: [Legacy_0_1_1.LearnedWord] = []
        if var list = try? container.nestedUnkeyedContainer(forKey: .learned) {
            while !list.isAtEnd {
                guard var item = try? list.decode(Legacy_0_1_1.LearnedWord.self) else {
                    _ = try? list.decode(LegacySkip.self)
                    continue
                }
                item.word = PerekeyCore.WordRules.normalize(item.word)
                if !item.word.isEmpty, seen.insert(item.word).inserted {
                    learned.append(item)
                }
            }
        }
        self.mine = mine
        self.learned = learned
        always = words(.always)
        learnFromUndos = (try? container.decodeIfPresent(Bool.self, forKey: .learnFromUndos)) ?? true
    }
}

private struct LegacySkip: Decodable {
    init(from decoder: any Decoder) throws {}
}

/// `AppSettings` of v0.1.1, field for field.
struct LegacyAppSettings_0_1_1: Hashable, Sendable {
    typealias Legacy = Legacy_0_1_1

    var hotkeys: [Legacy.HotkeyBinding]
    var capsLock: Legacy.CapsLockMode
    var autoswitch: Bool
    var onboardingDone: Bool
    var apps: [String: AppRule]
    var sites: [String: SiteRule]
    var words: Legacy.WordRules
    var layoutSound: Legacy.SoundSetting
    var correctionSound: Legacy.SoundSetting
    var checkForUpdates: Bool
    var corrections: TextCorrections
    var typoCorrection: Bool
    var caretHint: Legacy.CaretHintMode
    var statistics = false

    /// The defaults of v0.1.1: the standard preset, which is ⇧ switches, ⌥
    /// retypes, ⇧+⇧ toggles automatic switching.
    init() {
        hotkeys = [
            .init(trigger: .modifiers(.bothShifts, taps: .single), action: .toggleAutoswitch),
            .init(trigger: .modifiers(.shift, taps: .single), action: .switchLayout),
            .init(trigger: .modifiers(.option, taps: .single), action: .convertLastWord),
        ]
        capsLock = .untouched
        autoswitch = true
        onboardingDone = false
        apps = [:]
        sites = [:]
        words = Legacy.WordRules()
        layoutSound = .init(isOn: false, name: "Tink")
        correctionSound = .init(isOn: false, name: "Glass")
        checkForUpdates = true
        corrections = TextCorrections()
        typoCorrection = true
        caretHint = .all
    }
}

extension LegacyAppSettings_0_1_1: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case hotkeys, capsLock, autoswitch, onboardingDone, apps, words, sites, layoutSound, correctionSound
        case checkForUpdates, typoCorrection, corrections, caretHint, statistics
    }

    /// The keys 0.1.1 writes.
    static let keys = Set(CodingKeys.allCases.map(\.rawValue))

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LegacyAppSettings_0_1_1()
        hotkeys = try container.decodeIfPresent([Legacy.HotkeyBinding].self, forKey: .hotkeys) ?? defaults.hotkeys
        capsLock = (try? container.decodeIfPresent(Legacy.CapsLockMode.self, forKey: .capsLock)) ?? defaults.capsLock
        autoswitch = try container.decodeIfPresent(Bool.self, forKey: .autoswitch) ?? defaults.autoswitch
        onboardingDone = try container.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? defaults.onboardingDone
        apps = (try? container.decodeIfPresent([String: AppRule].self, forKey: .apps)) ?? defaults.apps
        words = (try? container.decodeIfPresent(Legacy.WordRules.self, forKey: .words)) ?? defaults.words
        sites = (try? container.decodeIfPresent([String: SiteRule].self, forKey: .sites)) ?? defaults.sites
        layoutSound = (try? container.decodeIfPresent(Legacy.SoundSetting.self, forKey: .layoutSound))
            ?? defaults.layoutSound
        correctionSound = (try? container.decodeIfPresent(Legacy.SoundSetting.self, forKey: .correctionSound))
            ?? defaults.correctionSound
        checkForUpdates = (try? container.decodeIfPresent(Bool.self, forKey: .checkForUpdates)) ?? defaults.checkForUpdates
        corrections = (try? container.decodeIfPresent(TextCorrections.self, forKey: .corrections))
            ?? defaults.corrections
        typoCorrection = (try? container.decodeIfPresent(Bool.self, forKey: .typoCorrection)) ?? defaults.typoCorrection
        caretHint = (try? container.decodeIfPresent(Legacy.CaretHintMode.self, forKey: .caretHint)) ?? defaults.caretHint
        statistics = (try? container.decodeIfPresent(Bool.self, forKey: .statistics)) ?? defaults.statistics
    }
}
