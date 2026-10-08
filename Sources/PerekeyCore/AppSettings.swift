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

/// The user's settings as stored on disk.
///
/// Decoding tolerates missing keys, so settings written by an older version
/// still load after new ones are added.
public struct AppSettings: Hashable, Sendable {
    public var hotkeys: [HotkeyBinding]
    public var capsLock: CapsLockMode
    public var autoswitch: Bool

    public init(hotkeys: [HotkeyBinding] = HotkeyPreset.default.hotkeys, capsLock: CapsLockMode = .untouched,
                autoswitch: Bool = true)
    {
        self.hotkeys = hotkeys
        self.capsLock = capsLock
        self.autoswitch = autoswitch
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
        case hotkeys, capsLock, autoswitch
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        hotkeys = try container.decodeIfPresent([HotkeyBinding].self, forKey: .hotkeys) ?? defaults.hotkeys
        capsLock = (try? container.decodeIfPresent(CapsLockMode.self, forKey: .capsLock)) ?? defaults.capsLock
        autoswitch = try container.decodeIfPresent(Bool.self, forKey: .autoswitch) ?? defaults.autoswitch
    }
}
