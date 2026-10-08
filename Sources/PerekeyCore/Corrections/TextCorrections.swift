// SPDX-License-Identifier: GPL-3.0-or-later

/// Which stage 4 corrections are on (docs/corrections.md). Each has its own
/// switch in Settings → General.
///
/// Decoding tolerates missing keys: a file from an older version gets the
/// defaults, and a newer switch added here does not break older files.
public struct TextCorrections: Hashable, Sendable {
    /// Pressing the retype shortcut again: the second press puts the word
    /// back, the third retypes two words, the fourth puts them back, and so
    /// on. Off, every press only toggles the last word.
    public var phraseRetype: Bool
    /// "ПРивет" → "Привет" when the word is known.
    public var doubleCapitals: Bool
    /// "пРИВЕТ" → "Привет", and Caps Lock goes off.
    public var capsLock: Bool
    /// "мвд" → "МВД", from the model's list of abbreviations.
    public var abbreviations: Bool
    /// "еще" → "ещё" where the word without "ё" is no other word. Russian only.
    public var yo: Bool

    public init(phraseRetype: Bool = true, doubleCapitals: Bool = true, capsLock: Bool = false,
                abbreviations: Bool = false, yo: Bool = false)
    {
        self.phraseRetype = phraseRetype
        self.doubleCapitals = doubleCapitals
        self.capsLock = capsLock
        self.abbreviations = abbreviations
        self.yo = yo
    }

    /// Some correction of a finished word is on: the word boundary must look
    /// at the word even with automatic switching off.
    public var correctsWords: Bool { doubleCapitals || capsLock || abbreviations || yo }
}

extension TextCorrections: Codable {
    private enum CodingKeys: String, CodingKey {
        case phraseRetype, doubleCapitals, capsLock, abbreviations, yo
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TextCorrections()
        func value(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? fallback
        }
        phraseRetype = value(.phraseRetype, defaults.phraseRetype)
        doubleCapitals = value(.doubleCapitals, defaults.doubleCapitals)
        capsLock = value(.capsLock, defaults.capsLock)
        abbreviations = value(.abbreviations, defaults.abbreviations)
        yo = value(.yo, defaults.yo)
    }
}
