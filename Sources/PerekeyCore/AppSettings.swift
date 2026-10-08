// SPDX-License-Identifier: GPL-3.0-or-later

/// How Caps Lock takes part in switching layouts.
public enum CapsLockMode: String, CaseIterable, Hashable, Sendable, Codable {
    /// Perekey does not touch Caps Lock.
    case untouched
    /// The macOS setting "Use Caps Lock to switch to and from ABC". Perekey
    /// only shows where it is: no risk, but macOS adds a short delay.
    case system
    /// Caps Lock is remapped to F18 with `hidutil`, and F18 switches the
    /// layout at once. Perekey removes the remap when it quits.
    case instant
}

/// Which edits the hint at the caret reports.
public enum CaretHintMode: String, CaseIterable, Hashable, Sendable, Codable {
    /// Automatic switches and manual retypes.
    case all
    /// Only what Perekey did by itself.
    case automatic
    case off

    /// Whether the hint shows for an edit that is `automatic` or the user's own retype.
    public func shows(automatic: Bool) -> Bool {
        switch self {
        case .all: true
        case .automatic: automatic
        case .off: false
        }
    }
}

/// A sound for one event: on or off, and the name of a system sound
/// (a file in /System/Library/Sounds, without the extension).
public struct SoundSetting: Hashable, Sendable, Codable {
    public var isOn: Bool
    public var name: String

    public init(isOn: Bool = false, name: String) {
        self.isOn = isOn
        self.name = name
    }

    public static let layoutSwitch = SoundSetting(name: "Tink")
    public static let correction = SoundSetting(name: "Glass")
}

/// The user's settings as stored on disk.
///
/// Decoding tolerates missing keys, so settings written by an older version
/// still load after new ones are added.
public struct AppSettings: Hashable, Sendable {
    public var hotkeys: [HotkeyBinding]
    public var capsLock: CapsLockMode
    public var autoswitch: Bool
    /// Whether the user has been through the onboarding window. It opens once, on first launch.
    public var onboardingDone: Bool
    /// The user's rules per app, keyed by bundle ID. Apps without a rule use `AppModes`.
    public var apps: [String: AppRule]
    /// The user's rules per site in Safari and Chromium browsers, keyed by normalized host.
    /// A site rule wins over the browser's app rule.
    public var sites: [String: SiteRule]
    /// Words never corrected: the user's own and the learned ones.
    public var words: WordExceptions
    /// Played on the main thread when a shortcut selects a layout. Off by default.
    public var layoutSound: SoundSetting
    /// Played after a successful retype. Off by default.
    public var correctionSound: SoundSetting
    /// Sparkle checks for updates on its own schedule. On by default. Off, Perekey
    /// makes no network requests unless the user clicks "Check Now".
    public var checkForUpdates: Bool
    /// The stage 4 corrections, each with its own switch.
    public var corrections: TextCorrections
    /// Typo correction (Settings → General, «Correct typos»). Off by default
    /// until it meets the plan's metric (docs/classifier.md, «Опечатки»).
    public var typoCorrection: Bool
    /// Which edits the hint at the caret reports (Settings → General).
    public var caretHint: CaretHintMode

    public init(hotkeys: [HotkeyBinding] = HotkeyPreset.default.hotkeys, capsLock: CapsLockMode = .untouched,
                autoswitch: Bool = true, onboardingDone: Bool = false, apps: [String: AppRule] = [:],
                words: WordExceptions = WordExceptions(), sites: [String: SiteRule] = [:],
                layoutSound: SoundSetting = .layoutSwitch, correctionSound: SoundSetting = .correction,
                checkForUpdates: Bool = true, typoCorrection: Bool = true,
                corrections: TextCorrections = TextCorrections(), caretHint: CaretHintMode = .all)
    {
        self.caretHint = caretHint
        self.checkForUpdates = checkForUpdates
        self.corrections = corrections
        self.typoCorrection = typoCorrection
        self.sites = sites
        self.layoutSound = layoutSound
        self.correctionSound = correctionSound
        self.apps = apps
        self.words = words
        self.hotkeys = hotkeys
        self.capsLock = capsLock
        self.autoswitch = autoswitch
        self.onboardingDone = onboardingDone
    }

    /// The preset these shortcuts are, or `nil` for the user's own set.
    public var preset: HotkeyPreset? { HotkeyPreset(matching: hotkeys) }

    public mutating func apply(_ preset: HotkeyPreset) {
        hotkeys = preset.hotkeys
    }

    /// Sets the shortcut of an action; `nil` removes it.
    public mutating func setTrigger(_ trigger: Trigger?, for action: HotkeyAction) {
        hotkeys.removeAll { $0.action == action }
        if let trigger { hotkeys.append(HotkeyBinding(trigger, action: action)) }
    }

    public func trigger(for action: HotkeyAction) -> Trigger? {
        hotkeys.first { $0.action == action }?.trigger
    }

    /// The mode in force for an app: see `AppModes.effectiveMode`.
    public func effectiveMode(bundleID: String, isGame: Bool) -> AppMode {
        AppModes.effectiveMode(bundleID: bundleID, isGame: isGame, rules: apps)
    }

    /// The snapshot for the event tap. In `.instant` mode Caps Lock arrives as
    /// F18, which switches the layout.
    public var snapshot: Settings {
        var hotkeys = hotkeys
        if capsLock == .instant {
            hotkeys.append(HotkeyBinding(.key(keyCode: KeyCode.f18, modifiers: []), action: .switchLayout))
        }
        var exceptions = Set(words.mine)
        for learned in words.learned { exceptions.insert(learned.word) }
        return Settings(hotkeys: hotkeys, autoswitch: autoswitch, exceptions: exceptions,
                        learnFromUndos: words.learnFromUndos, corrections: corrections,
                        typoCorrection: typoCorrection)
    }
}

extension AppSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case hotkeys, capsLock, autoswitch, onboardingDone, apps, words, sites, layoutSound, correctionSound
        case checkForUpdates, typoCorrection, corrections, caretHint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        hotkeys = try container.decodeIfPresent([HotkeyBinding].self, forKey: .hotkeys) ?? defaults.hotkeys
        capsLock = (try? container.decodeIfPresent(CapsLockMode.self, forKey: .capsLock)) ?? defaults.capsLock
        autoswitch = try container.decodeIfPresent(Bool.self, forKey: .autoswitch) ?? defaults.autoswitch
        onboardingDone = try container.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? defaults.onboardingDone
        apps = (try? container.decodeIfPresent([String: AppRule].self, forKey: .apps)) ?? defaults.apps
        words = (try? container.decodeIfPresent(WordExceptions.self, forKey: .words)) ?? defaults.words
        sites = (try? container.decodeIfPresent([String: SiteRule].self, forKey: .sites)) ?? defaults.sites
        layoutSound = (try? container.decodeIfPresent(SoundSetting.self, forKey: .layoutSound)) ?? defaults.layoutSound
        correctionSound = (try? container.decodeIfPresent(SoundSetting.self, forKey: .correctionSound))
            ?? defaults.correctionSound
        checkForUpdates = (try? container.decodeIfPresent(Bool.self, forKey: .checkForUpdates)) ?? defaults.checkForUpdates
        corrections = (try? container.decodeIfPresent(TextCorrections.self, forKey: .corrections))
            ?? defaults.corrections
        typoCorrection = (try? container.decodeIfPresent(Bool.self, forKey: .typoCorrection)) ?? defaults.typoCorrection
        caretHint = (try? container.decodeIfPresent(CaretHintMode.self, forKey: .caretHint)) ?? defaults.caretHint
    }
}
