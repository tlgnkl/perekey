// SPDX-License-Identifier: GPL-3.0-or-later

/// A token is the longest run of characters without whitespace
/// (`Character.isWhitespace`). Spaces and line breaks at the end of the text
/// fall away with it.
public enum Tokenizer {
    public static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Each token with what follows it: the whitespace character after it,
    /// nil at the end of the text.
    public static func tokensWithEnds(_ text: String) -> [(token: String, end: Character?)] {
        var result: [(String, Character?)] = []
        var current = ""
        for character in text {
            if character.isWhitespace {
                if !current.isEmpty {
                    result.append((current, character))
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append((current, nil)) }
        return result
    }

    /// Whether the token has a letter: a word of the metrics' denominator.
    public static func isWord(_ token: String) -> Bool {
        token.contains(where: \.isLetter)
    }
}
