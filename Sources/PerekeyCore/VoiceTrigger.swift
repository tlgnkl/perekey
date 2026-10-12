// SPDX-License-Identifier: GPL-3.0-or-later

/// What starts and stops dictation.
public enum VoiceTrigger: Hashable, Sendable {
    /// Modifiers alone, tapped: one tap starts recording, the next one stops
    /// it. A tap is a press shorter than `ChordDetector.maxHoldDuration` with
    /// no other input and no mouse movement while it is held.
    case tap(ModifierChord)
    /// A key with modifiers, held: recording runs from key down until the key
    /// or one of the modifiers is released (`HoldTrigger`).
    case hold(keyCode: UInt16, modifiers: Set<ModifierKind>)

    /// A tap of the right Option key.
    public static let `default` = VoiceTrigger.tap(.rightOption)

    /// As a shortcut, for `ShortcutConflicts`.
    public var shortcut: Trigger {
        switch self {
        case let .tap(chord): .modifiers(chord, taps: .single)
        case let .hold(keyCode, modifiers): .key(keyCode: keyCode, modifiers: modifiers)
        }
    }

    /// The shortcuts as the event tap gets them while this trigger is on:
    /// when a tap of the right Option key starts dictation, the shortcuts on
    /// either Option key take only the left one. Others stay as they are.
    public func narrowing(_ hotkeys: [HotkeyBinding]) -> [HotkeyBinding] {
        guard case let .tap(chord) = self, chord.matches([.rightOption]) else { return hotkeys }
        return hotkeys.map { hotkey in
            guard case let .modifiers(.option, taps) = hotkey.trigger else { return hotkey }
            return HotkeyBinding(.modifiers(.leftOption, taps: taps), action: hotkey.action)
        }
    }
}

extension VoiceTrigger: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, chord, keyCode, modifiers
    }

    private enum Kind: String, Codable {
        case tap, hold
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .tap:
            self = try .tap(container.decode(ModifierChord.self, forKey: .chord))
        case .hold:
            self = try .hold(keyCode: container.decode(UInt16.self, forKey: .keyCode),
                             modifiers: container.decode(Set<ModifierKind>.self, forKey: .modifiers))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .tap(chord):
            try container.encode(Kind.tap, forKey: .kind)
            try container.encode(chord, forKey: .chord)
        case let .hold(keyCode, modifiers):
            try container.encode(Kind.hold, forKey: .kind)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers.sorted { $0.rawValue < $1.rawValue }, forKey: .modifiers)
        }
    }
}

/// What the voice trigger asks of dictation. Comes as `Effect.voice`.
public enum VoiceSignal: Hashable, Sendable {
    /// The tap trigger: start recording, or stop it if it runs.
    case toggle
    /// The hold trigger went down: start recording.
    case holdBegan
    /// The hold trigger is over: stop recording and keep what was said.
    case holdEnded(reason: HoldEndReason)
}

public enum HoldEndReason: Hashable, Sendable {
    /// The key or one of its modifiers came up.
    case released
    /// The key up was never seen: the system layer found the keys up
    /// (`InputEvent.voiceHoldLost`), or the trigger changed while held.
    case lost
}

/// Where the mouse pointer was when a modifier changed, in global display
/// coordinates. A modifier tap that moved the pointer is a gesture (⌥ while
/// hovering in Figma), not a voice tap.
public struct PointerLocation: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The user's dictation settings as stored on disk, in a file of their own
/// beside the settings file (`VoiceSettingsFile`). Off by default: without
/// the file Perekey behaves as it did before dictation.
///
/// Decoding tolerates missing keys, unknown keys and values it cannot read:
/// later versions add their own, and the file keeps them (see `VoiceSettingsFile`).
public struct VoiceSettings: Hashable, Sendable {
    /// The version of the layout of the file. Raise it when a key changes
    /// meaning; new keys need no new version.
    public static let schemaVersion = 1

    public var isEnabled: Bool
    public var trigger: VoiceTrigger

    public init(isEnabled: Bool = false, trigger: VoiceTrigger = .default) {
        self.isEnabled = isEnabled
        self.trigger = trigger
    }

    /// The trigger the event tap reacts to: none while dictation is off.
    public var activeTrigger: VoiceTrigger? { isEnabled ? trigger : nil }
}

extension VoiceSettings: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, isEnabled, trigger
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VoiceSettings()
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? defaults.isEnabled
        trigger = (try? container.decodeIfPresent(VoiceTrigger.self, forKey: .trigger)) ?? defaults.trigger
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(trigger, forKey: .trigger)
    }
}
