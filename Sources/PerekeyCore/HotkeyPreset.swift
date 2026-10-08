// SPDX-License-Identifier: GPL-3.0-or-later

/// What a modifier-only shortcut can do.
public enum HotkeyAction: Hashable, Sendable, Codable {
    /// Switch to the next enabled keyboard layout.
    case switchLayout
    /// Select the layout for a language, e.g. "en" or "ru".
    case selectLanguage(String)
    /// Retype the last word, or the selection, in the other layout.
    case convertLastWord
    /// Turn automatic switching on or off.
    case toggleAutoswitch
    /// Cycle the case of the last word, or of the selection: lower, Title, UPPER.
    case changeCase
    /// Write the selection in the other script (Cyrillic ↔ Latin).
    case transliterate
    /// Paste the pasteboard's text without formatting. Off by default and
    /// only for a key trigger: ⌘⇧V is taken in VS Code, Slack and Chrome.
    case pastePlain

    /// Whether a shortcut of modifiers alone may run the action. Paste needs
    /// a key: a lone modifier would fire on every Shift tap or Option press.
    public var acceptsModifierOnlyTrigger: Bool { self != .pastePlain }
}

/// A ready-made set of shortcuts. Onboarding asks which one fits the user.
public enum HotkeyPreset: String, CaseIterable, Hashable, Sendable, Codable {
    /// Shift switches the layout, Option retypes the word. Same as Caramba Switcher.
    case standard
    /// Shift switches the layout, double Shift retypes the word.
    case doubleShift
    /// ⌥⇧ switches the layout, as Alt+Shift on Windows.
    case windowsAltShift
    /// ⌃⇧ switches the layout, as Ctrl+Shift on Windows.
    case windowsControlShift
    /// ⌘⇧ switches the layout: Ctrl+Shift muscle memory on a Mac keyboard.
    case commandShift
    /// Right ⌘ selects English, right ⌥ selects Russian, left ⌥ retypes the word.
    case separateKeys

    public static let `default` = HotkeyPreset.standard

    public var bindings: [ChordDetector<HotkeyAction>.Binding] {
        var result: [ChordDetector<HotkeyAction>.Binding] = [
            .init(.bothShifts, action: .toggleAutoswitch),
        ]
        switch self {
        case .standard:
            result += [.init(.shift, action: .switchLayout), .init(.option, action: .convertLastWord)]
        case .doubleShift:
            result += [.init(.shift, action: .switchLayout), .init(.shift, taps: 2, action: .convertLastWord)]
        case .windowsAltShift:
            result += [.init(.optionShift, action: .switchLayout), .init(.option, action: .convertLastWord)]
        case .windowsControlShift:
            result += [.init(.controlShift, action: .switchLayout), .init(.option, action: .convertLastWord)]
        case .commandShift:
            result += [.init(.commandShift, action: .switchLayout), .init(.option, action: .convertLastWord)]
        case .separateKeys:
            result += [
                .init(.rightCommand, action: .selectLanguage("en")),
                .init(.rightOption, action: .selectLanguage("ru")),
                .init(.leftOption, action: .convertLastWord),
            ]
        }
        return result
    }
}
