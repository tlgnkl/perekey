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

    public init(hotkeys: [HotkeyBinding] = HotkeyPreset.default.hotkeys, capsLock: CapsLockMode = .untouched,
                autoswitch: Bool = true, onboardingDone: Bool = false, apps: [String: AppRule] = [:],
                words: WordExceptions = WordExceptions(), sites: [String: SiteRule] = [:],
                layoutSound: SoundSetting = .layoutSwitch, correctionSound: SoundSetting = .correction)
    {
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
        return Settings(hotkeys: hotkeys, autoswitch: autoswitch)
    }
}

extension AppSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case hotkeys, capsLock, autoswitch, onboardingDone, apps, words, sites, layoutSound, correctionSound
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
    }
}
