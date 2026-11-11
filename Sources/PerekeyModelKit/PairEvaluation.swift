// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// How much of held-out text the pair table knows (`perekey-eval pairs`,
/// docs/classifier.md, «Пары слов»): of the pairs of neighbouring known
/// words, how many have a lift in the table, and how large it is. Measured
/// before any consumer reads the table: a table that finds few pairs of
/// the text it is for gives its consumers nothing.
public struct PairEvaluation: Sendable {
    /// The text: "Tatoeba prose", "Tatoeba chat", "Wikipedia (held out)".
    public var name: String
    public var words = 0
    /// Pairs of two known words, or of the start of a sentence and a known word.
    public var pairs = 0
    /// Of them, pairs with a lift in the table.
    public var found = 0
    /// The lifts found, in eighths of a bit.
    public var liftSum = 0
    /// The same, for the pairs at the start of a sentence.
    public var startPairs = 0
    public var startFound = 0

    public init(name: String) {
        self.name = name
    }

    public var foundShare: Double { pairs > 0 ? Double(found) / Double(pairs) : 0 }
    /// Bits, over the pairs found.
    public var meanLift: Double { found > 0 ? Double(liftSum) / 8 / Double(found) : 0 }
    /// Bits, over all pairs of known words: a pair not found counts 0.
    public var meanLiftOfAll: Double { pairs > 0 ? Double(liftSum) / 8 / Double(pairs) : 0 }

    public var report: String {
        let start = startPairs > 0 ? String(format: "; at the start of a sentence %.1f %% of %d", Double(startFound) / Double(startPairs) * 100, startPairs) : ""
        return String(format: "  %@: %d words, %d pairs of known words, lift found for %.1f %%, mean lift %.2f bits of the found, %.2f bits of all%@",
                      name, words, pairs, foundShare * 100, meanLift, meanLiftOfAll, start)
    }

    /// Measures sentences, one per element.
    /// - Parameters:
    ///   - isKnown: whether the folded fingerprint is a known form of the language.
    ///   - lift: the table: the lift of `word` after `previous`, `nil` if it has none.
    public static func measure(_ sentences: some Sequence<String>, name: String, isKnown: (UInt64) -> Bool,
                               lift: (_ previous: UInt64, _ word: UInt64) -> UInt8?) -> PairEvaluation
    {
        var result = PairEvaluation(name: name)
        for sentence in sentences {
            var previous: UInt64? = ModelFormat.sentenceStart
            PairText.scan(sentence) { event in
                switch event {
                case .word(let fingerprint):
                    result.words += 1
                    let word = isKnown(fingerprint) ? fingerprint : nil
                    if let before = previous, let word {
                        result.pairs += 1
                        let atStart = before == ModelFormat.sentenceStart
                        if atStart { result.startPairs += 1 }
                        if let value = lift(before, word) {
                            result.found += 1
                            result.liftSum += Int(value)
                            if atStart { result.startFound += 1 }
                        }
                    }
                    previous = word
                case .sentenceEnd:
                    previous = ModelFormat.sentenceStart
                }
            }
        }
        return result
    }

    /// Tatoeba prose and chat of one language, the way `Corpus` cuts them:
    /// prose is a sentence of eight words or more as written; chat a sentence of one
    /// to six words, lower case, letters, hyphens and apostrophes only.
    public static func tatoeba(language: String, cache: String) throws -> (prose: [String], chat: [String]) {
        guard let name = Coverage.tatoeba[language] else {
            throw ModelBuild.Failure(description: "no Tatoeba file for \(language)")
        }
        var prose: [String] = []
        var chat: [String] = []
        for line in try Archive.bunzip2("\(cache)/tatoeba/\(name)_sentences.tsv.bz2").lines() {
            let fields = line.split(separator: "\t")
            guard fields.count == 3 else { continue }
            let sentence = String(fields[2])
            if sentence.split(separator: " ").count >= 8 { prose.append(sentence) }
            let tokens = sentence.lowercased().split(separator: " ").map { token in
                String(token.filter { $0.isLetter || $0 == "-" || $0 == "'" })
            }.filter { !$0.isEmpty }
            if (1...6).contains(tokens.count) { chat.append(tokens.joined(separator: " ")) }
        }
        return (prose, chat)
    }
}
