// SPDX-License-Identifier: GPL-3.0-or-later

/// How many times a modifier chord is tapped.
public enum Taps: Int, Hashable, Sendable, Codable {
    case single = 1
    case double = 2
}

/// What the user presses to run an action.
public enum Trigger: Hashable, Sendable, Codable {
    /// Modifiers alone, fired on release: Shift, ⌥⇧, right ⌘, Shift twice.
    case modifiers(ModifierChord, taps: Taps)
    /// A regular key with modifiers, fired on key down: ⌃⌥E, F18
    /// (Caps Lock remapped by `hidutil`).
    case key(keyCode: UInt16, modifiers: Set<ModifierKind>)
}

/// One shortcut: a trigger and the action it runs.
public struct HotkeyBinding: Hashable, Sendable, Codable {
    public var trigger: Trigger
    public var action: HotkeyAction

    public init(_ trigger: Trigger, action: HotkeyAction) {
        self.trigger = trigger
        self.action = action
    }
}

extension ModifierKind {
    /// The device-independent `CGEventFlags` bit of this kind.
    var eventFlag: UInt64 {
        switch self {
        case .shift: EventFlags.shift
        case .control: EventFlags.control
        case .option: EventFlags.option
        case .command: EventFlags.command
        case .function: EventFlags.function
        }
    }

    /// The modifier kinds held according to device-independent event flags.
    static func held(inEventFlags flags: UInt64) -> Set<ModifierKind> {
        Set(allCases.filter { flags & $0.eventFlag != 0 })
    }
}

public extension HotkeyPreset {
    /// The preset as general shortcuts, ready for `Settings`.
    var hotkeys: [HotkeyBinding] {
        bindings.map { binding in
            HotkeyBinding(.modifiers(binding.chord, taps: Taps(rawValue: binding.taps) ?? .single),
                          action: binding.action)
        }
    }
}
