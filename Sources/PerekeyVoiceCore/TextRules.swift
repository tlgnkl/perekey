// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One replacement of the user's dictionary: what the speech model writes,
/// and what the text should say ("перекей" → "Perekey").
public struct DictionaryEntry: Codable, Hashable, Sendable, Identifiable {
    public var from: String
    public var to: String

    public var id: String { from.lowercased() }

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Edits of dictated text that need no language model: the user's
/// dictionary, filler words, the case of the first word and the space before
/// the text. A pure function of the text, the characters before the caret and
/// the dictionary.
public enum TextRules {
    /// Entries a new dictionary starts with.
    public static let defaultDictionary = [
        DictionaryEntry(from: "перекей", to: "Perekey"),
        DictionaryEntry(from: "перекэй", to: "Perekey"),
    ]

    /// Whisper reads at most 224 tokens of prompt; Cyrillic costs up to a token per two letters.
    public static let whisperPromptLimit = 240

    /// Dictated `text` as it goes into the field.
    ///
    /// - Parameter before: the characters before the caret, a few are enough.
    ///   nil when the field could not be read: the case and the space stay as
    ///   the speech model wrote them. Empty: the field is empty.
    /// - Returns: the text, with a leading space when the caret follows a word.
    ///   Empty when nothing is left after the fillers are gone.
    public static func apply(
        _ text: String, before: String?, dictionary: [DictionaryEntry] = [], removesFillers: Bool = true
    ) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }
        if removesFillers { result = removeFillers(result) }
        result = replace(result, with: dictionary)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }
        guard let before else { return result }
        result = fitCase(result, before: before, dictionary: dictionary)
        return (needsSpace(before: before, text: result) ? " " : "") + result
    }

    /// The `prompt` for Whisper: the words the dictionary turns the text into,
    /// so the model spells them from the start. Whole terms only, never cut.
    public static func whisperPrompt(dictionary: [DictionaryEntry], limit: Int = whisperPromptLimit) -> String {
        var seen = Set<String>()
        var prompt = ""
        for entry in dictionary {
            let word = entry.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word).inserted else { continue }
            let next = prompt.isEmpty ? word : prompt + ", " + word
            guard next.count <= limit else { continue }
            prompt = next
        }
        return prompt
    }

    // MARK: Dictionary

    /// Replaces whole words, whatever their case, in one pass: a replacement
    /// is never matched again by another entry.
    static func replace(_ text: String, with dictionary: [DictionaryEntry]) -> String {
        var targets: [String: String] = [:]
        for entry in dictionary {
            let key = normalized(entry.from)
            if !key.isEmpty, targets[key] == nil { targets[key] = entry.to }
        }
        guard !targets.isEmpty else { return text }
        let alternatives = targets.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        return transform(text, pattern: pattern, options: [.caseInsensitive]) { match, _ in
            targets[normalized(match)] ?? match
        }
    }

    private static func normalized(_ phrase: String) -> String {
        phrase.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Fillers

    private static let wordEdge = "(?<![\\p{L}\\p{N}_\\-])"
    private static let wordEnd = "(?![\\p{L}\\p{N}_])"
    private static let dash = "[-\u{2010}\u{2011}]"

    /// Sounds that carry no meaning in either language: removed wherever they stand.
    private static let hardFillers = [
        "э\(dash)э(?:\(dash)э)*", "м\(dash)м(?:\(dash)м)*", "эм+", "um+", "uh+", "erm+",
    ]
    /// Words that often mean something: removed only as an aside between
    /// commas or as an opening of the sentence followed by a comma.
    private static let softFillers = "(?:ну|как\\s+бы|типа|like)"

    static func removeFillers(_ text: String) -> String {
        var result = text
        // Sentence start stays a sentence start when its first word goes.
        let startsCapital = text.first(where: \.isLetter)?.isUppercase ?? false

        let hard = wordEdge + "(?:" + hardFillers.joined(separator: "|") + ")" + wordEnd + ",?[ \\t]*"
        // A filler that opens a later sentence hands the capital to the next word.
        result = transform(result, pattern: "([.!?\u{2026}]\\s+)" + hard + "(\\p{L})", options: [.caseInsensitive]) { _, groups in
            groups[1] + groups[2].uppercased()
        }
        result = transform(result, pattern: hard, options: [.caseInsensitive]) { _, _ in "" }

        for _ in 0..<3 {
            let before = result
            result = transform(result, pattern: ",\\s*" + softFillers + "\\s*,", options: [.caseInsensitive]) { _, _ in "," }
            result = transform(
                result, pattern: "([.!?\u{2026}]\\s+)" + softFillers + "\\s*,\\s*(\\p{L})", options: [.caseInsensitive]
            ) { _, groups in groups[1] + groups[2].uppercased() }
            result = transform(
                result, pattern: "^\\s*" + softFillers + "\\s*,\\s*", options: [.caseInsensitive]
            ) { _, _ in "" }
            if result == before { break }
        }
        guard result != text else { return text }

        result = tidy(result)
        if startsCapital { result = capitalizingFirst(result) }
        return result
    }

    /// Mends the punctuation and the spaces a removed word leaves.
    private static func tidy(_ text: String) -> String {
        var result = text
        result = transform(result, pattern: ",(?:\\s*,)+") { _, _ in "," }
        result = transform(result, pattern: "([.!?\u{2026}])\\s+[.,]+(?=\\s|$)") { _, groups in groups[1] }
        result = transform(result, pattern: ",\\s*([.!?\u{2026}])") { _, groups in groups[1] }
        result = transform(result, pattern: "[ \\t]+([,.;:!?\u{2026}])") { _, groups in groups[1] }
        result = transform(result, pattern: "[ \\t]{2,}") { _, _ in " " }
        result = transform(result, pattern: "^[\\s,.;:]+") { _, _ in "" }
        result = transform(result, pattern: "[\\s,;:]+$") { _, _ in "" }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Case

    private static func fitCase(_ text: String, before: String, dictionary: [DictionaryEntry]) -> String {
        guard let word = firstWord(of: text), !isDictionaryWord(word, dictionary) else { return text }
        let opens = opensSentence(before: before)
        if opens { return capitalizingFirst(text) }
        // Only a plain Capitalized word goes down: NASA, iPhone and "I" are not first words but names.
        guard isPlainCapitalized(word) else { return text }
        let first = text.startIndex
        return text[first].lowercased() + text[text.index(after: first)...]
    }

    /// The caret is at the start of a sentence: an empty field, a new line or the end of a sentence.
    static func opensSentence(before: String) -> Bool {
        var tail = Substring(before)
        while let last = tail.last, last == " " || last == "\t" || last == "\u{00A0}" { tail = tail.dropLast() }
        guard let last = tail.last else { return true }
        if last.isNewline { return true }
        // Closing quotes and brackets belong to the sentence they close.
        let closers: Set<Character> = ["\"", "'", ")", "]", "}", "\u{BB}", "\u{201D}", "\u{2019}"]
        var core = tail
        while let c = core.last, closers.contains(c) { core = core.dropLast() }
        guard let end = core.last else { return false }
        return ".!?\u{2026}".contains(end)
    }

    private static func firstWord(of text: String) -> String? {
        let word = text.prefix(while: { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}" || $0 == "-" })
        return word.isEmpty ? nil : String(word)
    }

    private static func isDictionaryWord(_ word: String, _ dictionary: [DictionaryEntry]) -> Bool {
        dictionary.contains { entry in
            entry.to.hasPrefix(word) && !(entry.to.dropFirst(word.count).first?.isLetter ?? false)
        }
    }

    private static func isPlainCapitalized(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count > 1, letters.first?.isUppercase == true else { return false }
        // "I'm", "I'll", "I'd" keep the capital.
        if word.first == "I", word.dropFirst().first == "'" || word.dropFirst().first == "\u{2019}" { return false }
        return letters.dropFirst().allSatisfy(\.isLowercase)
    }

    private static func capitalizingFirst(_ text: String) -> String {
        guard let index = text.firstIndex(where: \.isLetter), text[index].isLowercase else { return text }
        return text.replacingCharacters(in: index...index, with: text[index].uppercased())
    }

    // MARK: Space

    private static let closing: Set<Character> = [".", ",", ";", ":", "!", "?", "\u{2026}", ")", "]", "}", "\u{BB}", "\u{201D}", "%"]

    private static func needsSpace(before: String, text: String) -> Bool {
        guard let last = before.last, let first = text.first else { return false }
        // A comma or a dash that opens the text belongs to the word before it.
        if ",.;:!?\u{2026})]}%".contains(first) { return false }
        return last.isLetter || last.isNumber || closing.contains(last)
    }

    // MARK: Regex

    private static func transform(
        _ text: String, pattern: String, options: NSRegularExpression.Options = [],
        _ replacement: (_ match: String, _ groups: [String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            result += replacement(groups[0], groups)
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }
}
