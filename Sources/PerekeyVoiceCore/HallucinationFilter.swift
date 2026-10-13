// SPDX-License-Identifier: GPL-3.0-or-later

/// Phrases speech models make up out of silence and noise: credits and
/// sign-offs of the videos they learned from ("Субтитры сделал DimaTorzok",
/// "Продолжение следует…", "Thank you for watching"). Whisper does it most.
///
/// Only whole sentences at the end of the text go: the text from a sentence
/// start to its end must be such a phrase. The same words inside a sentence,
/// or with more after them, are speech and stay.
public enum HallucinationFilter {
    /// A sentence that is `marker` followed by at most `extraWords` words
    /// (a name, a site). Markers are in `normalized` form.
    struct Pattern: Sendable {
        let marker: [Substring]
        let extraWords: Int

        init(_ marker: String, extraWords: Int = 0) {
            self.marker = marker.split(separator: " ")
            self.extraWords = extraWords
        }

        func matches(_ words: [Substring]) -> Bool {
            words.count >= marker.count && words.count <= marker.count + extraWords
                && words.starts(with: marker)
        }
    }

    static let patterns: [Pattern] = [
        Pattern("субтитры сделал", extraWords: 3),
        Pattern("субтитры делал", extraWords: 3),
        Pattern("субтитры создавал", extraWords: 3),
        Pattern("субтитры подготовил", extraWords: 3),
        Pattern("субтитры сделаны", extraWords: 4),
        Pattern("субтитры создавались", extraWords: 4),
        Pattern("редактор субтитров", extraWords: 6),
        Pattern("продолжение следует"),
        Pattern("спасибо за просмотр"),
        Pattern("подписывайтесь на канал"),
        Pattern("подписывайтесь на наш канал"),
        Pattern("subtitles by", extraWords: 4),
        Pattern("thank you for watching"),
        Pattern("thanks for watching"),
        Pattern("please subscribe"),
        Pattern("like and subscribe"),
    ]

    /// The text without made-up sentences at its end; empty if nothing else
    /// was said.
    public static func clean(_ text: String) -> String {
        var text = trimmed(text)
        while !text.isEmpty, let cut = sentenceStarts(text).first(where: { isMadeUp(text[$0...]) }) {
            text = trimmed(text[..<cut])
        }
        return text
    }

    static func isMadeUp(_ sentence: Substring) -> Bool {
        let words = normalized(sentence).split(separator: " ")
        return !words.isEmpty && patterns.contains { $0.matches(words) }
    }

    /// Lowercased, "ё" as "е", anything but letters and digits as one space.
    static func normalized(_ text: Substring) -> String {
        var result = ""
        var space = false
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                if space, !result.isEmpty { result.append(" ") }
                space = false
                result.append(character == "ё" ? "е" : character)
            } else {
                space = true
            }
        }
        return result
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

    private static func trimmed(_ text: some StringProtocol) -> String {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace })
        else { return "" }
        return String(text[first...last])
    }
}
