// SPDX-License-Identifier: GPL-3.0-or-later

/// How far recognized text is from its reference: the word and character
/// error rates `perekey-voice-probe score` prints. Case and punctuation do
/// not count; the rest of the text must match.
public enum SpeechScore {
    /// The words of `text` in lower case, with punctuation as a separator and
    /// apostrophes dropped ("don't" is one word).
    public static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "’" {
                continue
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Single edits (substitution, insertion, deletion) to turn `a` into `b`.
    public static func distance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var row = [i + 1]
            row.reserveCapacity(b.count + 1)
            for (j, y) in b.enumerated() {
                row.append(min(previous[j] + (x == y ? 0 : 1), previous[j + 1] + 1, row[j] + 1))
            }
            previous = row
        }
        return previous[b.count]
    }

    public static func wordErrors(reference: String, hypothesis: String) -> Int {
        distance(words(reference), words(hypothesis))
    }

    /// Over the normalized text, words joined by one space.
    public static func characterErrors(reference: String, hypothesis: String) -> Int {
        distance(Array(words(reference).joined(separator: " ")), Array(words(hypothesis).joined(separator: " ")))
    }

    /// The first words of `reference` that a recording cut to `share` of its
    /// length holds, by the share of the words: at least one. The cut has no
    /// alignment of its own, so this is an estimate, the same for both arms
    /// of a comparison.
    public static func leadingWords(of reference: String, share: Double) -> String {
        let all = words(reference)
        guard !all.isEmpty else { return "" }
        let count = min(all.count, max(1, Int((Double(all.count) * share).rounded())))
        return all.prefix(count).joined(separator: " ")
    }

    /// Errors over many recordings, to be divided once at the end.
    public struct Tally: Sendable, Equatable {
        public private(set) var recordings = 0
        public private(set) var referenceWords = 0
        public private(set) var wordErrors = 0
        public private(set) var referenceCharacters = 0
        public private(set) var characterErrors = 0

        public init() {}

        public mutating func add(reference: String, hypothesis: String) {
            recordings += 1
            referenceWords += SpeechScore.words(reference).count
            wordErrors += SpeechScore.wordErrors(reference: reference, hypothesis: hypothesis)
            referenceCharacters += SpeechScore.words(reference).joined(separator: " ").count
            characterErrors += SpeechScore.characterErrors(reference: reference, hypothesis: hypothesis)
        }

        public var wordErrorRate: Double { referenceWords == 0 ? 0 : Double(wordErrors) / Double(referenceWords) }
        public var characterErrorRate: Double {
            referenceCharacters == 0 ? 0 : Double(characterErrors) / Double(referenceCharacters)
        }
    }
}
