// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyInput

/// How a trigger and an action read in the settings window.
@MainActor
enum TriggerText {
    /// The keycaps of a trigger, left to right.
    static func keycaps(of trigger: Trigger) -> [String] {
        switch trigger {
        case let .modifiers(chord, taps):
            var caps: [String] = []
            for (kind, side) in chord.parts {
                switch side {
                case .either: caps.append(kind.glyph)
                case .left: caps += ["left", kind.glyph]
                case .right: caps += ["right", kind.glyph]
                case .both: caps += [kind.glyph, "+", kind.glyph]
                }
            }
            if taps == .double { caps.append("twice") }
            return caps
        case let .key(keyCode, modifiers):
            return ModifierKind.displayOrder.filter(modifiers.contains).map(\.glyph) + [keyName(keyCode)]
        }
    }

    static func keyName(_ keyCode: UInt16) -> String {
        if let name = fixedNames[keyCode] { return name }
        let stroke = KeyStroke(keyCode)
        if let text = LayoutReader.installedLayout("com.apple.keylayout.ABC")?.text(for: stroke)?.uppercased(),
           !text.isEmpty
        {
            return text
        }
        return "Key \(keyCode)"
    }

    private static let fixedNames: [UInt16: String] = {
        var names: [UInt16: String] = [
            KeyCode.space: "Space", KeyCode.return: "Return", KeyCode.tab: "Tab", KeyCode.escape: "Escape",
            KeyCode.leftArrow: "←", KeyCode.rightArrow: "→", KeyCode.downArrow: "↓", KeyCode.upArrow: "↑",
        ]
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                      105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in functionKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()

    static func name(of action: HotkeyAction) -> String {
        switch action {
        case .switchLayout: "Switch layout"
        case .convertLastWord: "Retype last word or selection"
        case .toggleAutoswitch: "Turn automatic switching on or off"
        case let .selectLanguage(code):
            switch code {
            case "en": "Select English"
            case "ru": "Select Russian"
            default: "Select \(code)"
            }
        }
    }

    static func warning(for conflict: ShortcutConflict) -> String {
        switch conflict {
        case .spotlight: "⌘Space also opens Spotlight. Both will run."
        case .systemInputSwitch: "macOS switches the input source on this shortcut too. The layout would change twice."
        case .globeKey: "The fn / 🌐 key also runs its own macOS action, which can switch the input source."
        case .dictation: "fn twice starts Dictation in macOS."
        case .jetBrainsSearch: "Shift twice opens Search Everywhere in JetBrains IDEs. Pick another shortcut if you use them."
        case .launcherDoubleTap: "Raycast or Alfred may use this double tap."
        case let .otherAction(action): "Also runs “\(name(of: action))”."
        }
    }
}

extension HotkeyPreset {
    var title: String {
        switch self {
        case .standard: "Shift"
        case .windowsAltShift: "Option + Shift"
        case .windowsControlShift: "Control + Shift"
        case .commandShift: "Command + Shift"
        case .doubleShift: "Double Shift"
        case .separateKeys: "Two keys"
        }
    }

    var note: String {
        switch self {
        case .standard: "Like Caramba"
        case .windowsAltShift: "Like Alt+Shift on Windows"
        case .windowsControlShift: "Like Ctrl+Shift on Windows"
        case .commandShift: "Ctrl+Shift habit on a Mac"
        case .doubleShift: "Shift twice retypes"
        case .separateKeys: "Right ⌘ — EN, right ⌥ — RU"
        }
    }
}
