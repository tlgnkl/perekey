// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// How the hyphen step (`HyphenStep`, docs/corrections.md, «Дефис») does on
/// the Russian Tatoeba sentences, which it never saw:
///
/// - **Recovery.** Every word with one hyphen ("что-то"), typed merged
///   ("чтото"): how many the step gives back exactly. The words it does not
///   know are counted by spelling, to show what the list misses.
/// - **False corrections.** Every word as written: each change is wrong,
///   since the text is right. The target is none.
public struct HyphenEvaluation {
    public var tokens = 0
    /// Words with one hyphen between letters.
    public var hyphenated = 0
    /// Of them, given back exactly when typed merged.
    public var restored = 0
    /// Typed merged, changed, but not into the word as written.
    public var wrong: [String: Int] = [:]
    /// Hyphenated words the step does not know, lowercase, by count.
    public var missed: [String: Int] = [:]
    /// Words of the clean text the step changed: "word → change".
    public var changed: [String: Int] = [:]

    public static func measure(_ model: LanguageModel, cache: String) throws -> HyphenEvaluation {
        var result = HyphenEvaluation()
        for line in try Archive.bunzip2("\(cache)/tatoeba/rus_sentences.tsv.bz2").lines() {
            let fields = line.split(separator: "\t")
            guard fields.count == 3 else { continue }
            for token in Coverage.words(of: fields[2]) {
                result.tokens += 1
                let word = Array(token)
                if let after = correct(word, model), after != word {
                    result.changed["\(token) → \(String(after))", default: 0] += 1
                }
                let parts = token.split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isLetter) }) else { continue }
                result.hyphenated += 1
                switch correct(word.filter { $0 != "-" }, model) {
                case word?: result.restored += 1
                case let other?: result.wrong["\(token) → \(String(other))", default: 0] += 1
                case nil: result.missed[token.lowercased(), default: 0] += 1
                }
            }
        }
        return result
    }

    /// The word after the step, `nil` when it stays.
    static func correct(_ characters: [Character], _ model: LanguageModel) -> [Character]? {
        var word = BoundaryWord(characters: characters, modifiers: Array(repeating: [], count: characters.count),
                                language: "ru")
        HyphenStep().apply(to: &word, model: model)
        return word.characters == characters ? nil : word.characters
    }

    /// The counts, then the `list` most frequent missed words and every
    /// false correction.
    public func report(list: Int) -> String {
        let share = hyphenated > 0 ? Double(restored) / Double(hyphenated) * 100 : 0
        let falseCount = changed.values.reduce(0, +)
        var lines = [
            "ru Tatoeba: \(tokens) words, \(hyphenated) with a hyphen",
            String(format: "recovery: %d of %d typed merged (%.1f %%), %d changed wrongly, %d words not on the list",
                   restored, hyphenated, share, wrong.values.reduce(0, +), missed.values.reduce(0, +)),
            "false corrections of clean text: \(falseCount) in \(tokens) words",
        ]
        for (text, count) in changed.sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) }) {
            lines.append("  false: \(text) ×\(count)")
        }
        for (text, count) in wrong.sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) }) {
            lines.append("  wrong: \(text) ×\(count)")
        }
        if list > 0 {
            lines.append("most frequent words not on the list:")
            for (text, count) in missed.sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) }).prefix(list) {
                lines.append("  \(text) ×\(count)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
