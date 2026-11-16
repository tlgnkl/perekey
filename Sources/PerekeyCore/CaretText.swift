// SPDX-License-Identifier: GPL-3.0-or-later

/// How the text before the caret compares with the text a retype is about to erase.
///
/// The app may not leave the typed word alone: macOS raises the first letter
/// of a sentence ("привет " becomes "Привет ") right after Perekey typed it.
/// The word is still there and the Backspaces erase the same number of
/// characters, so this is no mismatch. Any other difference is one.
public enum CaretText {
    public enum Match: Hashable, Sendable {
        /// The same text.
        case exact
        /// The same text, except the app made its first letter a capital.
        case firstLetterRaised
    }

    /// `actual` against `expected`; nil when they differ. A no-break space
    /// stands for a space: browsers turn the trailing one of contenteditable text into it.
    public static func match(expected: String, actual: String) -> Match? {
        let expected = normalized(expected)
        let actual = normalized(actual)
        if actual == expected { return .exact }
        guard let first = expected.first, let raised = actual.first, first != raised,
              expected.dropFirst() == actual.dropFirst(),
              String(first).lowercased() == String(first), String(first).uppercased() == String(raised)
        else { return nil }
        return .firstLetterRaised
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

extension Retype {
    /// The retype with its first letter a capital: the field raised the word
    /// it is about to replace, so the word comes back raised too. That is what
    /// the user saw ("Привет " goes back to "Ghbdtn ", not to "ghbdtn "), and
    /// what the app would have made of the typed word in the first place.
    public func raisingFirstLetter() -> Retype {
        guard var first = keys.first, let letter = first.text.first else { return self }
        first.text = String(letter).uppercased() + first.text.dropFirst()
        var raised = self
        raised.keys[0] = first
        return raised
    }
}
