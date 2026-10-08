// SPDX-License-Identifier: GPL-3.0-or-later

/// The case of a word or selection, and the cycle repeated presses walk through.
public enum TextCase: CaseIterable, Hashable, Sendable {
    case lower, title, upper

    /// The text in this case. `.title` capitalizes the first letter of every
    /// word and lowercases the rest. A character whose case form is not one
    /// character (ß becomes SS) stays as it is, so key strokes keep matching.
    public func apply(to text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var afterLetter = false
        for character in text {
            let isLetter = character.isLetter
            let wantsUpper: Bool = switch self {
            case .lower: false
            case .upper: true
            case .title: !afterLetter
            }
            if isLetter {
                let changed = wantsUpper ? character.uppercased() : character.lowercased()
                result += changed.count == 1 ? changed : String(character)
            } else {
                result.append(character)
            }
            // An apostrophe or a digit inside a word does not start a new word.
            afterLetter = isLetter || character.isNumber || (afterLetter && (character == "'" || character == "’"))
        }
        return result
    }

    /// The text after one more press: lower, then Title, then UPPER, then lower
    /// again. Mixed case counts as UPPER, so the first press lowers it. A case
    /// that would not change the text (Title of one letter equals UPPER) is
    /// skipped. `nil` if the text has no letters with a case.
    public static func next(after text: String) -> String? {
        let current = allCases.firstIndex { $0.apply(to: text) == text } ?? 2
        for step in 1...allCases.count {
            let candidate = allCases[(current + step) % allCases.count].apply(to: text)
            if candidate != text { return candidate }
        }
        return nil
    }
}
