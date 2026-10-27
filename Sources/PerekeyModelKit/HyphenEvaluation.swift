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
///
/// The same for the form with a space (`SpacedHyphenStep`): every word with
/// one hyphen typed with a space ("что нибудь"), and every two neighbours of
/// the clean text, as the space between them leaves them ("кое с", "что
/// либо,").
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
    /// Of `hyphenated`, given back exactly when typed with a space.
    public var spacedRestored = 0
    /// Typed with a space, changed, but not into the word as written.
    public var spacedWrong: [String: Int] = [:]
    /// Two neighbours of the clean text, one space between them.
    public var pairs = 0
    /// Neighbours of the clean text the step changed: "words → change".
    public var spacedChanged: [String: Int] = [:]

    public static func measure(_ model: LanguageModel, cache: String) throws -> HyphenEvaluation {
        var result = HyphenEvaluation()
        for line in try Archive.bunzip2("\(cache)/tatoeba/rus_sentences.tsv.bz2").lines() {
            let fields = line.split(separator: "\t")
            guard fields.count == 3 else { continue }
            // The neighbours as the space key leaves them, punctuation and all.
            let chunks = fields[2].split(separator: " ")
            for (first, second) in zip(chunks, chunks.dropFirst()) {
                result.pairs += 1
                let phrase = Array("\(first) \(second)")
                if let after = correctSpaced(phrase, model) {
                    result.spacedChanged["\(String(phrase)) → \(String(after))", default: 0] += 1
                }
            }
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
                switch correctSpaced(word.map { $0 == "-" ? " " : $0 }, model) {
                case word?: result.spacedRestored += 1
                case let other?: result.spacedWrong["\(token) → \(String(other))", default: 0] += 1
                case nil: break
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

    /// The words after the step for the form with a space, `nil` when they stay.
    static func correctSpaced(_ characters: [Character], _ model: LanguageModel) -> [Character]? {
        var phrase = BoundaryWord(characters: characters, modifiers: Array(repeating: [], count: characters.count),
                                  language: "ru")
        SpacedHyphenStep().apply(to: &phrase, model: model)
        return phrase.characters == characters ? nil : phrase.characters
    }

    /// The words of the list, typed merged, that the typo step would change
    /// before the hyphen step sees them ("гдето" → a neighbour word): "word → typo".
    public static func typoClashes(_ words: [String], model: LanguageModel, layout: LayoutMap) -> [String] {
        let corrector = TypoCorrector(model: model)
        var clashes: [String] = []
        for entry in words {
            let merged = entry.replacingOccurrences(of: "-", with: "")
            let strokes = merged.compactMap { layout.stroke(for: $0) }
            guard strokes.count == merged.count,
                  let candidate = corrector.correct(strokes, in: layout, sentenceStart: false)
            else { continue }
            clashes.append("\(merged) → \(candidate.text)")
        }
        return clashes
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
        let spacedShare = hyphenated > 0 ? Double(spacedRestored) / Double(hyphenated) * 100 : 0
        lines.append(String(format: "with a space: %d of %d typed with a space (%.1f %%), %d changed wrongly",
                            spacedRestored, hyphenated, spacedShare, spacedWrong.values.reduce(0, +)))
        lines.append("false corrections of clean neighbours: \(spacedChanged.values.reduce(0, +)) in \(pairs) pairs")
        for (text, count) in spacedChanged.sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) }) {
            lines.append("  false: \(text) ×\(count)")
        }
        for (text, count) in spacedWrong.sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) }) {
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
