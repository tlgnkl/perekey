// SPDX-License-Identifier: GPL-3.0-or-later

/// Checks what a language model returned before it is pasted. A model that
/// took the dictation or the selected text for a question answers it
/// instead of editing it; then the dictation goes in as said.
///
/// An answer is a reply more than twice as long as the dictation, or one
/// that opens by talking to the user ("Sure", "Here is", "I can't"), unless
/// the dictation itself opens that way. Wrapping quotes and code fences the
/// model added are taken off first.
public enum OutputGuard {
    public enum Verdict: Hashable, Sendable {
        case accept(String)
        case reject(Reason)
    }

    public enum Reason: Hashable, Sendable {
        case empty
        /// More than twice the dictation.
        case tooLong
        /// Opens by talking to the user.
        case answers
        /// Repeats the prompt's tags: it did not edit, it echoed.
        case echoesPrompt
    }

    /// A short dictation may grow this much regardless of the ratio: "ок"
    /// becomes "Хорошо." in a clean copy.
    public static let shortAllowance = 24

    public static func check(_ output: String, dictation: String) -> Verdict {
        let text = cleaned(output, dictation: dictation)
        guard !text.isEmpty else { return .reject(.empty) }
        let lower = text.lowercased()
        if lower.contains("<dictation") || lower.contains("</dictation") || lower.contains("<selection")
            || lower.contains("</selection")
        {
            return .reject(.echoesPrompt)
        }
        let input = trimmed(dictation).count
        if text.count > max(2 * input, input + shortAllowance) { return .reject(.tooLong) }
        if let group = openingGroup(text), openingGroup(dictation) != group { return .reject(.answers) }
        return .accept(text)
    }

    // MARK: - Openings

    /// Ways a reply talks to the user, grouped by meaning across Russian and
    /// English: a translated "Конечно, давай" may open with "Sure".
    static let openings: [[String]] = [
        ["конечно", "разумеется", "безусловно", "sure", "certainly", "of course", "absolutely", "definitely"],
        ["вот", "here is", "here's", "here are", "below is"],
        ["извините", "простите", "прошу прощения", "sorry", "i'm sorry", "i am sorry", "apologies", "my apologies"],
        ["к сожалению", "unfortunately"],
        ["я не могу", "не могу", "i can't", "i cannot", "i can not", "i'm unable", "i am unable", "i won't", "i will not"],
        ["как ии", "как языковая модель", "как модель", "я — ии", "я ии", "as an ai", "as a language model", "i'm an ai"],
        ["хорошо", "ладно", "окей", "ок", "okay", "ok", "alright", "all right"],
        ["отличный вопрос", "хороший вопрос", "great question", "good question"],
        ["ответ:", "answer:", "the answer is", "ответ —", "ответ -"],
        ["исправленный текст", "отредактированный текст", "улучшенный текст", "перевод:",
         "corrected text", "edited text", "improved text", "revised text", "translation:"],
        ["я могу", "я помогу", "i can help", "i'd be happy", "i would be happy", "happy to help"],
        ["привет! я", "hello! i", "hi! i"],
    ]

    /// The index of the group the text opens with, if any.
    static func openingGroup(_ text: String) -> Int? {
        let lower = Substring(trimmed(text).lowercased()).drop { "\"'«“„*_#>-—– ".contains($0) }
        for (index, group) in openings.enumerated() {
            for phrase in group where lower.hasPrefix(phrase) {
                let next = lower.dropFirst(phrase.count).first
                // A whole word: "Вот" opens, "Вотсап" does not; a phrase ending in ":" is whole already.
                if phrase.last == ":" || next == nil || !(next!.isLetter || next!.isNumber) { return index }
            }
        }
        return nil
    }

    // MARK: - Cleaning

    /// Trims the reply and takes off a code fence or a pair of quotes around
    /// it that the dictation does not have.
    static func cleaned(_ output: String, dictation: String) -> String {
        var text = trimmed(output)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
            var inner = text.dropFirst(3).dropLast(3)
            // A language tag on the fence's first line.
            if let newline = inner.firstIndex(where: \.isNewline),
               inner[..<newline].allSatisfy({ $0.isLetter || $0.isNumber })
            {
                inner = inner[inner.index(after: newline)...]
            }
            text = trimmed(String(inner))
        }
        let source = trimmed(dictation)
        for (open, close) in [("\"", "\""), ("«", "»"), ("“", "”"), ("'", "'")] {
            if text.count >= 2, text.hasPrefix(open), text.hasSuffix(close), !source.hasPrefix(open) {
                text = trimmed(String(text.dropFirst().dropLast()))
                break
            }
        }
        return text
    }

    static func trimmed(_ text: String) -> String {
        var slice = Substring(text)
        while let first = slice.first, first.isWhitespace { slice.removeFirst() }
        while let last = slice.last, last.isWhitespace { slice.removeLast() }
        return String(slice)
    }
}
