// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
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
                case .left: caps += [String(localized: "left"), kind.glyph]
                case .right: caps += [String(localized: "right"), kind.glyph]
                case .both: caps += [kind.glyph, "+", kind.glyph]
                }
            }
            if taps == .double { caps.append(String(localized: "twice")) }
            return caps
        case let .key(keyCode, modifiers):
            return ModifierKind.displayOrder.filter(modifiers.contains).map(\.glyph) + [keyName(keyCode)]
        }
    }

    static func keyName(_ keyCode: UInt16) -> String {
        // Named as Apple's Russian manuals do: «Пробел», but «Return», «Tab», «Esc», «Delete».
        switch keyCode {
        case KeyCode.space: return String(localized: "Space")
        case KeyCode.return: return String(localized: "Return")
        case KeyCode.tab: return String(localized: "Tab")
        case KeyCode.escape: return String(localized: "Escape")
        case KeyCode.delete: return String(localized: "Delete")
        default: break
        }
        if let name = fixedNames[keyCode] { return name }
        let stroke = KeyStroke(keyCode)
        if let text = LayoutReader.installedLayout("com.apple.keylayout.ABC")?.text(for: stroke)?.uppercased(),
           !text.isEmpty
        {
            return text
        }
        return String(localized: "Key \(Int(keyCode))")
    }

    private static let fixedNames: [UInt16: String] = {
        var names: [UInt16: String] = [
            KeyCode.leftArrow: "←", KeyCode.rightArrow: "→", KeyCode.downArrow: "↓", KeyCode.upArrow: "↑",
        ]
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                      105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in functionKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()

    static func name(of action: HotkeyAction) -> String {
        switch action {
        case .switchLayout: String(localized: "Switch layout")
        case .convertLastWord: String(localized: "Retype last word or selection")
        case .toggleAutoswitch: String(localized: "Turn automatic switching on or off")
        case .changeCase: String(localized: "Change case of the word or selection")
        case .transliterate: String(localized: "Transliterate the selection")
        case .pastePlain: String(localized: "Paste without formatting")
        case .undoLastCorrection: String(localized: "Undo last correction")
        case let .selectLanguage(code):
            switch code {
            case "en": String(localized: "Select English")
            case "ru": String(localized: "Select Russian")
            default: String(localized: "Select \(code)")
            }
        }
    }

    static func warning(for conflict: ShortcutConflict) -> String {
        switch conflict {
        case .spotlight: String(localized: "⌘Space also opens Spotlight. Both will run.")
        case .systemInputSwitch: String(localized: "macOS switches the input source on this shortcut too. The layout would change twice.")
        case .globeKey: String(localized: "The fn / 🌐 key also runs its own macOS action, which can switch the input source.")
        case .dictation: String(localized: "fn twice starts Dictation in macOS.")
        case .jetBrainsSearch: String(localized: "Shift twice opens Search Everywhere in JetBrains IDEs. Pick another shortcut if you use them.")
        case .launcherDoubleTap: String(localized: "Raycast or Alfred may use this double tap.")
        case let .otherAction(action): String(localized: "Also runs “\(name(of: action))”.")
        }
    }
}

extension HotkeyPreset {
    var title: String {
        switch self {
        case .standard: String(localized: "Shift")
        case .windowsAltShift: String(localized: "Option + Shift")
        case .windowsControlShift: String(localized: "Control + Shift")
        case .commandShift: String(localized: "Command + Shift")
        case .doubleShift: String(localized: "Double Shift")
        case .separateKeys: String(localized: "Two keys")
        }
    }

    var note: String {
        switch self {
        case .standard: String(localized: "Shift alone, Option retypes")
        case .windowsAltShift: String(localized: "Like Alt+Shift on Windows")
        case .windowsControlShift: String(localized: "Like Ctrl+Shift on Windows")
        case .commandShift: String(localized: "Ctrl+Shift habit on a Mac")
        case .doubleShift: String(localized: "Shift twice retypes")
        case .separateKeys: String(localized: "Right ⌘ — EN, right ⌥ — RU")
        }
    }
}
