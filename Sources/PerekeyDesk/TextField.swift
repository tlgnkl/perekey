// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// A plain text field: characters, a caret, and a selection to the left of
/// the caret (what ⇧← selects).
///
/// The bench types into it for every system under test, Perekey or none, so
/// editing works the same way for all of them.
public struct TextField: Hashable, Sendable {
    public private(set) var characters: [Character] = []
    /// The caret: how many characters are before it.
    public private(set) var caret = 0
    /// How many characters left of the caret are selected.
    public private(set) var selection = 0

    public init(_ text: String = "") {
        characters = Array(text)
        caret = characters.count
    }

    public var text: String { String(characters) }

    public var selectedText: String { String(characters[(caret - selection)..<caret]) }

    /// Whether the text before the caret ends with `suffix`.
    public func textBeforeCaret(endsWith suffix: String) -> Bool {
        let tail = Array(suffix)
        guard tail.count <= caret else { return false }
        return characters[(caret - tail.count)..<caret].elementsEqual(tail)
    }

    /// Types `text` at the caret. Typing replaces the selection.
    public mutating func insert(_ text: String) {
        deleteSelection()
        let typed = Array(text)
        characters.insert(contentsOf: typed, at: caret)
        caret += typed.count
    }

    /// Backspace: the selection, else the character left of the caret.
    public mutating func backspace() {
        if selection > 0 {
            deleteSelection()
        } else if caret > 0 {
            characters.remove(at: caret - 1)
            caret -= 1
        }
    }

    /// ⌥⌫: the selection, else the word left of the caret with the spaces and
    /// marks after it, as macOS text fields do.
    public mutating func deleteWordLeft() {
        guard selection == 0 else { return deleteSelection() }
        var start = caret
        while start > 0, !Self.isWordCharacter(characters[start - 1]) { start -= 1 }
        while start > 0, Self.isWordCharacter(characters[start - 1]) { start -= 1 }
        characters.removeSubrange(start..<caret)
        caret = start
    }

    /// Deletes `count` characters left of the caret, as Backspaces of a retype.
    public mutating func deleteLeft(_ count: Int) {
        for _ in 0..<count { backspace() }
    }

    /// ←: to the start of the selection, else one character left.
    public mutating func moveLeft() {
        if selection > 0 {
            caret -= selection
            selection = 0
        } else if caret > 0 {
            caret -= 1
        }
    }

    /// →: drops the selection, else one character right.
    public mutating func moveRight() {
        if selection > 0 {
            selection = 0
        } else if caret < characters.count {
            caret += 1
        }
    }

    /// ⇧←: one more character selected.
    public mutating func extendLeft() {
        if selection < caret { selection += 1 }
    }

    /// A click puts the caret here, clamped to the text, and drops the selection.
    public mutating func place(caret position: Int) {
        caret = min(max(position, 0), characters.count)
        selection = 0
    }

    public mutating func placeAtEnd() { place(caret: characters.count) }

    /// A key down that reached the app, typed in `map`: what the field does
    /// with it. Keys with ⌘ or ⌃ type nothing. ↑ and ↓ go to the start and
    /// the end: the field is one paragraph.
    public mutating func press(_ keyCode: UInt16, flags: UInt64, in map: LayoutMap?) {
        switch keyCode {
        case KeyCode.delete:
            if flags & EventFlags.option != 0 { deleteWordLeft() } else { backspace() }
        case KeyCode.return, KeyCode.keypadEnter:
            insert("\n")
        case KeyCode.tab:
            insert("\t")
        case KeyCode.leftArrow:
            if flags & EventFlags.shift != 0 { extendLeft() } else { moveLeft() }
        case KeyCode.rightArrow:
            moveRight()
        case KeyCode.upArrow:
            place(caret: 0)
        case KeyCode.downArrow:
            placeAtEnd()
        case _ where KeyCode.navigation.contains(keyCode):
            break
        default:
            guard flags & (EventFlags.command | EventFlags.control) == 0 else { return }
            let stroke = KeyStroke(keyCode, LayoutModifiers(eventFlags: flags))
            if let typed = map?.text(for: stroke) { insert(typed) }
        }
    }

    private mutating func deleteSelection() {
        guard selection > 0 else { return }
        characters.removeSubrange((caret - selection)..<caret)
        caret -= selection
        selection = 0
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
