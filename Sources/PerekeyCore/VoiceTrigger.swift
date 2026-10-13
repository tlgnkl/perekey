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
    /// Esc while a dictation session is on (`InputEvent.voiceSession`):
    /// cancel it. The key is swallowed.
    case cancel
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
/// Decoding tolerates missing keys and unknown keys. A value this version
/// cannot read (a trigger kind added later) keeps dictation off rather than
/// falling back to a default that would take a key from another shortcut,
/// and the file keeps that value on save until the user sets the key again.
public struct VoiceSettings: Hashable, Sendable {
    /// The version of the file's layout. A file of a higher version is read,
    /// but dictation stays off and the file is never overwritten
    /// (`VoiceSettingsFile.save`). New keys need no new version: raise it
    /// only when an older Perekey must not act on the file at all.
    public static let schemaVersion = 1

    public var isEnabled: Bool {
        didSet { unreadableKeys.remove(CodingKeys.isEnabled.stringValue) }
    }

    public var trigger: VoiceTrigger {
        didSet { unreadableKeys.remove(CodingKeys.trigger.stringValue) }
    }

    /// The speech model dictation uses, a `ModelCatalog` id.
    public var model: String {
        didSet { unreadableKeys.remove(CodingKeys.model.stringValue) }
    }

    /// Recording stops after this many seconds without speech; 0 never.
    public var silenceStopSeconds: Int {
        didSet { unreadableKeys.remove(CodingKeys.silenceStopSeconds.stringValue) }
    }

    /// The model leaves memory after this many minutes without dictation; 0 never.
    public var unloadAfterMinutes: Int {
        didSet { unreadableKeys.remove(CodingKeys.unloadAfterMinutes.stringValue) }
    }

    /// The system sounds at the start and the end of a recording.
    public var sounds: Bool {
        didSet { unreadableKeys.remove(CodingKeys.sounds.stringValue) }
    }

    /// After pasting, select the layout of the phrase's main language.
    public var switchesLayout: Bool {
        didSet { unreadableKeys.remove(CodingKeys.switchesLayout.stringValue) }
    }

    /// Keys the file has that this version could not read and the user has
    /// not set since. Encoding leaves them out, so the file keeps its values.
    public private(set) var unreadableKeys: Set<String> = []

    /// The `schemaVersion` of the file these settings were read from, if it
    /// is higher than this version's.
    public private(set) var newerSchemaVersion: Int?

    /// Parakeet TDT v3: the default since stage 0 (ru, en, uk, and English
    /// words kept in Latin letters within Russian phrases).
    public static let defaultModel = "parakeet-tdt-v3"

    public init(isEnabled: Bool = false, trigger: VoiceTrigger = .default, model: String = VoiceSettings.defaultModel,
                silenceStopSeconds: Int = 30, unloadAfterMinutes: Int = 60, sounds: Bool = true,
                switchesLayout: Bool = true)
    {
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.model = model
        self.silenceStopSeconds = silenceStopSeconds
        self.unloadAfterMinutes = unloadAfterMinutes
        self.sounds = sounds
        self.switchesLayout = switchesLayout
    }

    /// The trigger the event tap reacts to: none while dictation is off, and
    /// none when the file is of a newer version or its trigger or switch
    /// could not be read.
    public var activeTrigger: VoiceTrigger? {
        guard isEnabled, newerSchemaVersion == nil,
              unreadableKeys.isDisjoint(with: [CodingKeys.isEnabled.stringValue, CodingKeys.trigger.stringValue])
        else { return nil }
        return trigger
    }
}

extension VoiceSettings: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, isEnabled, trigger, model, silenceStopSeconds, unloadAfterMinutes, sounds, switchesLayout
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var unreadable: Set<String> = []
        func read<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            guard container.contains(key) else { return nil }
            if let value = try? container.decode(type, forKey: key) { return value }
            unreadable.insert(key.stringValue)
            return nil
        }
        let defaults = VoiceSettings()
        isEnabled = read(Bool.self, .isEnabled) ?? defaults.isEnabled
        trigger = read(VoiceTrigger.self, .trigger) ?? defaults.trigger
        model = read(String.self, .model) ?? defaults.model
        silenceStopSeconds = read(Int.self, .silenceStopSeconds) ?? defaults.silenceStopSeconds
        unloadAfterMinutes = read(Int.self, .unloadAfterMinutes) ?? defaults.unloadAfterMinutes
        sounds = read(Bool.self, .sounds) ?? defaults.sounds
        switchesLayout = read(Bool.self, .switchesLayout) ?? defaults.switchesLayout
        if let version = try? container.decodeIfPresent(Int.self, forKey: .schemaVersion), version > Self.schemaVersion {
            newerSchemaVersion = version
        }
        unreadableKeys = unreadable
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        if !unreadableKeys.contains(CodingKeys.isEnabled.stringValue) {
            try container.encode(isEnabled, forKey: .isEnabled)
        }
        if !unreadableKeys.contains(CodingKeys.trigger.stringValue) {
            try container.encode(trigger, forKey: .trigger)
        }
        func write(_ value: some Encodable, _ key: CodingKeys) throws {
            if !unreadableKeys.contains(key.stringValue) { try container.encode(value, forKey: key) }
        }
        try write(model, .model)
        try write(silenceStopSeconds, .silenceStopSeconds)
        try write(unloadAfterMinutes, .unloadAfterMinutes)
        try write(sounds, .sounds)
        try write(switchesLayout, .switchesLayout)
    }
}
