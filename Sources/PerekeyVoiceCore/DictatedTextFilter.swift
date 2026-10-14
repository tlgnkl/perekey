// SPDX-License-Identifier: GPL-3.0-or-later

/// What dictated text may hold when it goes into a field, whichever model
/// wrote it: a cloud answer is not trusted further than a language model's.
/// Control characters go, but a line break and a tab: Ctrl-O runs a shell's
/// line, ESC[201~ ends a bracketed paste. Bidirectional overrides and marks
/// go too: they make "fdp.exe" read as "exe.pdf".
public enum DictatedTextFilter {
    public static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x09:
                scalars.append(scalar)
            case 0x0D:
                // "\r\n" keeps its "\n"; a lone carriage return is Enter in a terminal.
                continue
            case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F:
                continue
            default:
                if scalar.properties.generalCategory != .control { scalars.append(scalar) }
            }
        }
        return String(scalars)
    }
}

/// Emoji sequences, as far as the filters need them.
enum Emoji {
    /// Close to Unicode's Extended_Pictographic, which Swift does not expose:
    /// an emoji that is not ASCII ("#", "1"), not a skin tone and not a flag letter.
    static func isPictograph(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        return properties.isEmoji && scalar.value > 0x7F && !properties.isEmojiModifier
            && !(0x1F1E6...0x1F1FF).contains(scalar.value)
    }

    /// Whether the zero-width joiner at `index` joins two pictographs. A
    /// variation selector or a skin tone may sit after the first one.
    static func joins(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var before = index - 1
        while before >= 0, scalars[before] == "\u{FE0F}" || scalars[before].properties.isEmojiModifier {
            before -= 1
        }
        let after = index + 1
        return before >= 0 && after < scalars.count && isPictograph(scalars[before]) && isPictograph(scalars[after])
    }
}
