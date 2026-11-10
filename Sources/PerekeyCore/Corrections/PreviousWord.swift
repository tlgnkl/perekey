// SPDX-License-Identifier: GPL-3.0-or-later

/// The word before the one being corrected, as the "pair" section of the
/// model knows it (docs/corrections.md, «Опечатки с контекстом»).
///
/// Reads the text of the previous word with the marks typed after it
/// ("hello." with its period) the way the training text was read
/// (`PairText` in `PerekeyModelKit`; `PreviousWordAgreementTests` compares
/// this with it): a word is letters and digits with apostrophes and hyphens inside,
/// none at the ends; `. ! ? …` after the last word end the sentence, and the
/// next word is the first of one. Commas, brackets and quotes do not.
///
/// A single pass over the scalars, no allocation: it runs at the boundary of
/// a word on the tap thread. `Reader` takes the scalars one by one, so the
/// caller needs no sequence of them (and no `String` for the text of a key).
public enum PreviousWord {
    /// The fingerprint of the last word of `text`, `ModelFormat.sentenceStart`
    /// when a sentence ended after it, and nil when the text has no word.
    public static func fingerprint(of text: some Sequence<Unicode.Scalar>) -> UInt64? {
        var reader = Reader()
        for scalar in text { reader.add(scalar) }
        return reader.result
    }

    /// The most joiners ("'", "-") kept between two letters: "a----b" is no
    /// word of any language, and the fifth joiner ends the token. The same
    /// limit as `PairText`'s.
    static let joinerLimit = 4

    /// The pass over the scalars of a text, one at a time.
    public struct Reader {
        private var word = ModelFormat.Fingerprint()
        private var last: UInt64?
        private var inWord = false
        private var ended = false
        // Joiners after the last letter: part of the word when a letter follows.
        private var joiners: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
        private var joinerCount = 0

        public init() {}

        /// The fingerprint of the last word, the sentence start or nil, as of the scalars added so far.
        public var result: UInt64? {
            var copy = self
            copy.finishWord()
            return copy.ended ? ModelFormat.sentenceStart : copy.last
        }

        public mutating func add(_ scalar: Unicode.Scalar) {
            switch PreviousWord.kind(of: scalar.value) {
            case .letter:
                if inWord { flushJoiners() }
                inWord = true
                joinerCount = 0
                ended = false
                word.add(ModelFormat.fold(scalar.value))
            case .joiner:
                guard inWord else { return }
                if joinerCount == PreviousWord.joinerLimit {
                    finishWord()
                    return
                }
                switch joinerCount {
                case 0: joiners.0 = scalar.value
                case 1: joiners.1 = scalar.value
                case 2: joiners.2 = scalar.value
                default: joiners.3 = scalar.value
                }
                joinerCount += 1
            case .separator:
                finishWord()
            case .sentenceEnd:
                finishWord()
                if last != nil { ended = true }
            }
        }

        private mutating func finishWord() {
            guard inWord else { return }
            last = word.value
            word = ModelFormat.Fingerprint()
            inWord = false
            joinerCount = 0
        }

        private mutating func flushJoiners() {
            for index in 0..<joinerCount {
                let scalar = index == 0 ? joiners.0 : index == 1 ? joiners.1 : index == 2 ? joiners.2 : joiners.3
                word.add(scalar == 0x2019 ? 0x27 : ModelFormat.fold(scalar))
            }
            joinerCount = 0
        }
    }

    private enum Kind {
        case letter, joiner, separator, sentenceEnd
    }

    private static func kind(of scalar: UInt32) -> Kind {
        if scalar < 0x80 {
            switch scalar {
            case 0x61...0x7A, 0x41...0x5A, 0x30...0x39: return .letter
            case 0x27, 0x2D: return .joiner
            case 0x2E, 0x21, 0x3F, 0x09, 0x0A, 0x0D: return .sentenceEnd
            default: return .separator
            }
        }
        switch scalar {
        case 0x2019, 0x2BC: return .joiner
        case 0x2026, 0x2029: return .sentenceEnd
        default: break
        }
        guard let value = Unicode.Scalar(scalar) else { return .separator }
        switch value.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return .letter
        default:
            return .separator
        }
    }
}
