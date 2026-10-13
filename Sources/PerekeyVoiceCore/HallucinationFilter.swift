// SPDX-License-Identifier: GPL-3.0-or-later

/// Phrases speech models make up out of silence and noise: credits and
/// sign-offs of the videos they learned from ("Субтитры сделал DimaTorzok",
/// "Продолжение следует…", "Thank you for watching"). Whisper does it most.
///
/// Only whole sentences at the end of the text go: the text from a sentence
/// start to its end must be such a phrase. The same words inside a sentence,
/// or with more after them, are speech and stay.
///
/// - Credits go wherever they end the text: their words after the marker
///   look like a name or a site ("DimaTorzok", "Amara.org", "А.Семкин"),
///   which speech rarely ends with.
/// - Sign-offs ("Продолжение следует.") are also things people say. They go
///   when they are the whole text, after the speech gate let it through; at
///   the end of real speech only for a model that adds them (`signOffTails`).
public enum HallucinationFilter {
    struct Pattern: Sendable {
        let marker: [String]
        /// How many words may follow the marker.
        let extraWords: ClosedRange<Int>
        /// A word the extra words must hold, in `normalized` form.
        var needs: String?
        /// The last word must look like a name or a site.
        var endsWithName = false
        /// A sign-off: at the end of other speech only with `signOffTails`.
        var isSignOff = false

        func matches(_ words: [Word]) -> Bool {
            guard words.count >= marker.count, extraWords.contains(words.count - marker.count),
                  zip(words, marker).allSatisfy({ $0.normalized == $1 })
            else { return false }
            let extra = words.dropFirst(marker.count)
            if let needs, !extra.contains(where: { $0.normalized == needs }) { return false }
            if endsWithName, extra.last?.looksLikeName != true { return false }
            return true
        }
    }

    /// A word as written, without the punctuation around it.
    struct Word: Sendable {
        let text: Substring
        let normalized: String

        init(_ word: Substring) {
            let isPart = { (character: Character) in character.isLetter || character.isNumber }
            if let first = word.firstIndex(where: isPart), let last = word.lastIndex(where: isPart) {
                text = word[first...last]
            } else {
                text = word[word.endIndex...]
            }
            normalized = String(text.lowercased().map { $0 == "ё" ? "е" : $0 })
        }

        /// "DimaTorzok", "Amara.org", "А.Семкин": a capital, Latin letters, or a dot inside.
        var looksLikeName: Bool {
            text.first?.isUppercase == true || text.contains(".") || text.contains { $0.isASCII && $0.isLetter }
        }
    }

    private static func credit(_ marker: String, upTo extra: Int) -> Pattern {
        Pattern(marker: marker.split(separator: " ").map(String.init), extraWords: 1...extra, endsWithName: true)
    }

    private static func signOff(_ phrase: String) -> Pattern {
        Pattern(marker: phrase.split(separator: " ").map(String.init), extraWords: 0...0, isSignOff: true)
    }

    static let patterns: [Pattern] = [
        credit("субтитры сделал", upTo: 3),
        credit("субтитры делал", upTo: 3),
        credit("субтитры создавал", upTo: 3),
        credit("субтитры подготовил", upTo: 3),
        credit("субтитры сделаны", upTo: 4),
        credit("субтитры создавались", upTo: 4),
        credit("subtitles by", upTo: 4),
        Pattern(marker: ["редактор", "субтитров"], extraWords: 2...6, needs: "корректор", endsWithName: true),
        signOff("продолжение следует"),
        signOff("спасибо за просмотр"),
        signOff("подписывайтесь на канал"),
        signOff("подписывайтесь на наш канал"),
        signOff("thank you for watching"),
        signOff("thanks for watching"),
        signOff("please subscribe"),
        signOff("like and subscribe"),
    ]

    /// The longest phrase in words: tails are looked for no further back.
    static let longest = patterns.map { $0.marker.count + $0.extraWords.upperBound }.max() ?? 0

    /// The text without made-up sentences at its end; empty if nothing else
    /// was said. `signOffTails`: the model adds sign-offs to real speech
    /// (Whisper), so they go from its tail too.
    public static func clean(_ text: String, signOffTails: Bool = false) -> String {
        let starts = sentenceStarts(text)
        var end = trimmedEnd(text, before: text.endIndex)
        while end > text.startIndex {
            var cut: String.Index?
            // From the last sentence back, while the tail is short enough.
            for start in starts.reversed() where start < end {
                let words = text[start..<end].split(whereSeparator: \.isWhitespace).map(Word.init)
                    .filter { !$0.normalized.isEmpty }
                if words.count > longest { break }
                if isMadeUp(words, whole: start == starts.first, signOffTails: signOffTails) { cut = start }
            }
            guard let cut else { break }
            end = trimmedEnd(text, before: cut)
        }
        guard let first = text.firstIndex(where: { !$0.isWhitespace }), first < end else { return "" }
        return String(text[first..<end])
    }

    static func isMadeUp(_ words: [Word], whole: Bool, signOffTails: Bool) -> Bool {
        !words.isEmpty && patterns.contains { pattern in
            (!pattern.isSignOff || whole || signOffTails) && pattern.matches(words)
        }
    }

    /// Where sentences start: the text's first character, and the first one
    /// after ".", "!", "?" or "…" and white space. "А.Семкин" is one word.
    static func sentenceStarts(_ text: String) -> [String.Index] {
        var starts = [text.startIndex]
        var afterEnd = false
        var afterSpace = false
        for index in text.indices {
            let character = text[index]
            if character.isWhitespace {
                afterSpace = afterEnd
                continue
            }
            if afterSpace { starts.append(index) }
            afterEnd = ".!?…".contains(character)
            afterSpace = false
        }
        return starts
    }

    /// The end of the text before `index` without the white space before it.
    private static func trimmedEnd(_ text: String, before index: String.Index) -> String.Index {
        var end = index
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        return end
    }
}
