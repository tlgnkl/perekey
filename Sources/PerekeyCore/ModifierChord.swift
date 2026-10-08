// SPDX-License-Identifier: GPL-3.0-or-later

/// A physical modifier key. Left and right variants are distinct keys.
public enum ModifierKey: String, CaseIterable, Hashable, Sendable, Codable {
    case leftShift, rightShift
    case leftControl, rightControl
    case leftOption, rightOption
    case leftCommand, rightCommand
    case function

    public var kind: ModifierKind {
        switch self {
        case .leftShift, .rightShift: .shift
        case .leftControl, .rightControl: .control
        case .leftOption, .rightOption: .option
        case .leftCommand, .rightCommand: .command
        case .function: .function
        }
    }

    var isLeft: Bool {
        switch self {
        case .leftShift, .leftControl, .leftOption, .leftCommand: true
        default: false
        }
    }

    var isRight: Bool {
        switch self {
        case .rightShift, .rightControl, .rightOption, .rightCommand: true
        default: false
        }
    }
}

public enum ModifierKind: String, CaseIterable, Hashable, Sendable, Codable {
    case shift, control, option, command, function
}

/// Which side(s) of a modifier kind a chord requires.
public enum SideRequirement: String, Hashable, Sendable, Codable {
    /// Exactly one key of this kind, either side.
    case either
    case left
    case right
    /// Both the left and the right key of this kind.
    case both
}

/// A modifier-only shortcut such as ⌥⇧, right ⌘, or left ⇧ + right ⇧.
///
/// A chord matches the set of modifiers that were held at the peak of a press,
/// and every modifier kind not listed in the chord must be absent.
public struct ModifierChord: Hashable, Sendable, Codable {
    public var requirements: [ModifierKind: SideRequirement]

    public init(_ requirements: [ModifierKind: SideRequirement]) {
        self.requirements = requirements
    }

    public func matches(_ pressed: Set<ModifierKey>) -> Bool {
        ModifierKind.allCases.allSatisfy { kind in
            let keys = pressed.filter { $0.kind == kind }
            switch requirements[kind] {
            case nil: return keys.isEmpty
            case .either: return keys.count == 1
            case .left: return keys.count == 1 && keys.allSatisfy(\.isLeft)
            case .right: return keys.count == 1 && keys.allSatisfy(\.isRight)
            case .both: return keys.count == 2
            }
        }
    }
}

public extension ModifierChord {
    static let shift = ModifierChord([.shift: .either])
    static let bothShifts = ModifierChord([.shift: .both])
    static let option = ModifierChord([.option: .either])
    static let leftOption = ModifierChord([.option: .left])
    static let optionShift = ModifierChord([.option: .either, .shift: .either])
    static let controlShift = ModifierChord([.control: .either, .shift: .either])
    static let commandShift = ModifierChord([.command: .either, .shift: .either])
    static let rightCommand = ModifierChord([.command: .right])
    static let rightOption = ModifierChord([.option: .right])
}
