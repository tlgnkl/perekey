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

    /// The trigger a recorded shortcut makes: modifiers alone, tapped once, are
    /// a tap; a key with modifiers is a hold. A double tap is neither.
    public init?(recorded trigger: Trigger) {
        switch trigger {
        case let .modifiers(chord, .single): self = .tap(chord)
        case let .key(keyCode, modifiers): self = .hold(keyCode: keyCode, modifiers: modifiers)
        case .modifiers: return nil
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

/// How long a recording may run before it stops by itself.
public enum VoiceAutoStop: Int, Hashable, Sendable, CaseIterable, Codable {
    case off = 0
    case seconds15 = 15
    case seconds30 = 30
    case seconds60 = 60

    /// The limit in seconds, nil when recordings are not limited.
    public var seconds: Int? { self == .off ? nil : rawValue }
}

/// How long the speech model stays loaded after the last dictation.
public enum VoiceUnload: Int, Hashable, Sendable, CaseIterable, Codable {
    case never = 0
    case minutes10 = 10
    case minutes60 = 60

    /// Idle time before the unload, in seconds; nil when the model stays loaded.
    public var seconds: Int? { self == .never ? nil : rawValue * 60 }
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
/// An unreadable value of any other key falls back to its default and is kept
/// the same way, but does not switch dictation off.
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

    /// The model dictation uses when the user has not picked one: an id of
    /// `ModelCatalog` (Parakeet TDT v3).
    public static let defaultModel = "parakeet-tdt-v3"

    /// The UID of the input device (`Microphone.uid`), nil for the system one.
    /// A device that is gone keeps its UID here: dictation falls back to the
    /// system device and the settings show the device as unavailable.
    public var microphoneUID: String? {
        didSet { unreadableKeys.remove(CodingKeys.microphoneUID.stringValue) }
    }

    /// The name the device had when it was picked, to name it while it is not connected.
    public var microphoneName: String? {
        didSet { unreadableKeys.remove(CodingKeys.microphoneName.stringValue) }
    }

    /// The id of the speech model (`ModelCatalog` entry).
    public var model: String {
        didSet { unreadableKeys.remove(CodingKeys.model.stringValue) }
    }

    /// Switch the layout to the language of the phrase after dictation.
    public var switchesLayout: Bool {
        didSet { unreadableKeys.remove(CodingKeys.switchesLayout.stringValue) }
    }

    /// Start and stop sounds.
    public var playsSounds: Bool {
        didSet { unreadableKeys.remove(CodingKeys.playsSounds.stringValue) }
    }

    public var autoStop: VoiceAutoStop {
        didSet { unreadableKeys.remove(CodingKeys.autoStop.stringValue) }
    }

    public var unload: VoiceUnload {
        didSet { unreadableKeys.remove(CodingKeys.unload.stringValue) }
    }

    /// The «What's new: voice input» window was answered (turned on or put
    /// off): it does not come back.
    public var introAnswered: Bool {
        didSet { unreadableKeys.remove(CodingKeys.introAnswered.stringValue) }
    }

    /// Keys the file has that this version could not read and the user has
    /// not set since. Encoding leaves them out, so the file keeps its values.
    public private(set) var unreadableKeys: Set<String> = []

    /// The `schemaVersion` of the file these settings were read from, if it
    /// is higher than this version's.
    public private(set) var newerSchemaVersion: Int?

    public init(isEnabled: Bool = false, trigger: VoiceTrigger = .default, microphoneUID: String? = nil,
                microphoneName: String? = nil,
                model: String = VoiceSettings.defaultModel, switchesLayout: Bool = true, playsSounds: Bool = true,
                autoStop: VoiceAutoStop = .seconds30, unload: VoiceUnload = .minutes60,
                introAnswered: Bool = false)
    {
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.microphoneUID = microphoneUID
        self.microphoneName = microphoneName
        self.model = model
        self.switchesLayout = switchesLayout
        self.playsSounds = playsSounds
        self.autoStop = autoStop
        self.unload = unload
        self.introAnswered = introAnswered
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
        case schemaVersion, isEnabled, trigger, microphoneUID, microphoneName, model, switchesLayout, playsSounds, autoStop, unload, introAnswered
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
        // `null` is a readable "system device"; a value of another type is not.
        if container.contains(.microphoneUID), (try? container.decodeNil(forKey: .microphoneUID)) == true {
            microphoneUID = nil
        } else {
            microphoneUID = read(String.self, .microphoneUID)
        }
        if container.contains(.microphoneName), (try? container.decodeNil(forKey: .microphoneName)) == true {
            microphoneName = nil
        } else {
            microphoneName = read(String.self, .microphoneName)
        }
        model = read(String.self, .model) ?? defaults.model
        switchesLayout = read(Bool.self, .switchesLayout) ?? defaults.switchesLayout
        playsSounds = read(Bool.self, .playsSounds) ?? defaults.playsSounds
        autoStop = read(VoiceAutoStop.self, .autoStop) ?? defaults.autoStop
        unload = read(VoiceUnload.self, .unload) ?? defaults.unload
        introAnswered = read(Bool.self, .introAnswered) ?? defaults.introAnswered
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
        // An explicit null: the save merges over the file, and an absent key
        // would leave the old device in it.
        if !unreadableKeys.contains(CodingKeys.microphoneUID.stringValue) {
            try container.encode(microphoneUID, forKey: .microphoneUID)
        }
        if !unreadableKeys.contains(CodingKeys.microphoneName.stringValue) {
            try container.encode(microphoneName, forKey: .microphoneName)
        }
        if !unreadableKeys.contains(CodingKeys.model.stringValue) {
            try container.encode(model, forKey: .model)
        }
        if !unreadableKeys.contains(CodingKeys.switchesLayout.stringValue) {
            try container.encode(switchesLayout, forKey: .switchesLayout)
        }
        if !unreadableKeys.contains(CodingKeys.playsSounds.stringValue) {
            try container.encode(playsSounds, forKey: .playsSounds)
        }
        if !unreadableKeys.contains(CodingKeys.autoStop.stringValue) {
            try container.encode(autoStop, forKey: .autoStop)
        }
        if !unreadableKeys.contains(CodingKeys.unload.stringValue) {
            try container.encode(unload, forKey: .unload)
        }
        if !unreadableKeys.contains(CodingKeys.introAnswered.stringValue) {
            try container.encode(introAnswered, forKey: .introAnswered)
        }
    }
}
