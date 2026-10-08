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

    /// This kind as one bit of a `kindMask`.
    var maskBit: UInt8 {
        switch self {
        case .shift: 1 << 0
        case .control: 1 << 1
        case .option: 1 << 2
        case .command: 1 << 3
        case .function: 1 << 4
        }
    }

    /// The held kinds as a bit mask: the same as `held(inEventFlags:)`, without
    /// allocating, for the per-keystroke path.
    static func kindMask(inEventFlags flags: UInt64) -> UInt8 {
        var mask: UInt8 = 0
        if flags & EventFlags.shift != 0 { mask |= ModifierKind.shift.maskBit }
        if flags & EventFlags.control != 0 { mask |= ModifierKind.control.maskBit }
        if flags & EventFlags.option != 0 { mask |= ModifierKind.option.maskBit }
        if flags & EventFlags.command != 0 { mask |= ModifierKind.command.maskBit }
        if flags & EventFlags.function != 0 { mask |= ModifierKind.function.maskBit }
        return mask
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
