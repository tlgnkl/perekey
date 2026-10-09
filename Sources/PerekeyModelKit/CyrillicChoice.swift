// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// ABC, Russian and Ukrainian installed together: a Cyrillic word typed on
/// ABC must go to its own language, not to the other Cyrillic one, because
/// ru ↔ uk is never switched back by itself (docs/classifier.md, «Больше
/// двух раскладок»). Words of Tatoeba `rus` and `ukr` sentences, each typed
/// on ABC and judged against both Cyrillic layouts, in both orders of the
/// candidates (the order is the layout used last, which the corpus cannot
/// know). With context, a word sees the languages of the words before it in
/// its sentence; the first word of a sentence has none.
public struct CyrillicChoice {
    public struct Item: Hashable, Sendable {
        public var language: String
        public var text: String
        /// The languages of the words before it in its sentence, latest first.
        public var recent: [String?]
    }

    public struct Count: Hashable, Sendable {
        public var words = 0
        /// Switched to the other Cyrillic language.
        public var wrong = 0
        /// Switched to its own language.
        public var right = 0

        public var wrongRate: Double { words > 0 ? Double(wrong) / Double(words) : 0 }
        public var recall: Double { words > 0 ? Double(right) / Double(words) : 0 }
    }

    /// One language with one order of the candidates.
    public struct Row: Hashable, Sendable {
        public var language: String
        /// The candidate tried first.
        public var first: String
        /// Every word, judged without context.
        public var noContext = Count()
        /// The first words of sentences: no context to go on.
        public var firstWords = Count()
        /// The other words, with the languages of the words before.
        public var withContext = Count()
    }

    /// The plan's bound for the wrong Cyrillic language with context.
    public static let target = 0.005

    /// Tatoeba files of the Cyrillic languages.
    static let tatoebaFiles = ["ru": "rus", "uk": "ukr", "be": "bel"]

    public static func build(cache: String, words: Int, seed: UInt64, languages: [String] = ["ru", "uk"]) throws -> [Item] {
        var random = SplitMix64(seed: seed)
        var items: [Item] = []
        for (language, file) in languages.compactMap({ code in tatoebaFiles[code].map { (code, $0) } }) {
            var count = 0
            for sentence in try Corpus.tatoeba("\(cache)/tatoeba/\(file)_sentences.tsv.bz2", random: &random)
                where count < words
            {
                var recent: [String?] = []
                for token in sentence.split(separator: " ") {
                    let word = Self.word(Corpus.apostrophes(token))
                    guard !word.isEmpty, word.unicodeScalars.allSatisfy({ (0x400...0x4FF).contains($0.value)
                        || $0 == "'" || $0 == "-" }), word.contains(where: \.isLetter)
                    else {
                        recent.insert(nil, at: 0)
                        continue
                    }
                    items.append(Item(language: language, text: word,
                                      recent: Array(recent.prefix(RecentLanguages.capacity))))
                    recent.insert(language, at: 0)
                    count += 1
                }
            }
        }
        return items
    }

    /// The token without the punctuation around it.
    static func word(_ token: String) -> String {
        var text = Substring(token)
        while let first = text.first, !first.isLetter { text.removeFirst() }
        while let last = text.last, !last.isLetter { text.removeLast() }
        return String(text)
    }

    /// - Parameter layouts: ABC, and the Cyrillic layout of each language.
    public static func run(_ items: [Item], classifier: Classifier, abc: LayoutMap,
                           layouts: [String: LayoutMap], languages: [String] = ["ru", "uk"]) -> [Row]
    {
        var rows: [Row] = []
        for language in languages {
            for first in languages {
                guard let own = layouts[language] else { continue }
                // The layout used last first, the others in the order given.
                let candidates = ([first] + languages.filter { $0 != first }).compactMap { layouts[$0] }
                guard candidates.count == languages.count else { continue }
                var row = Row(language: language, first: first)
                for item in items where item.language == language {
                    var strokes: [KeyStroke] = []
                    for character in item.text {
                        guard let stroke = own.stroke(for: character) else { break }
                        strokes.append(stroke)
                    }
                    guard strokes.count == item.text.count else { continue }
                    func count(_ context: Classifier.Context, into counter: inout Count) {
                        let decision = classifier.classify(strokes, typed: abc, candidates: candidates,
                                                           context: context)
                        counter.words += 1
                        if decision.verdict == .switch(to: own.id) {
                            counter.right += 1
                        } else if case .switch = decision.verdict {
                            counter.wrong += 1
                        }
                    }
                    count(Classifier.Context(), into: &row.noContext)
                    if item.recent.contains(where: { $0 != nil }) {
                        count(Classifier.Context(recent: RecentLanguages(item.recent)), into: &row.withContext)
                    } else {
                        count(Classifier.Context(recent: RecentLanguages(item.recent)), into: &row.firstWords)
                    }
                }
                rows.append(row)
            }
        }
        return rows
    }

    public static func report(_ rows: [Row]) -> String {
        var text = "words typed on ABC, the Cyrillic layouts installed: wrong Cyrillic language / own language\n"
        text += "lang first   words   no context              first words             with context\n"
        for row in rows {
            func cell(_ count: Count) -> String {
                String(format: "%6.2f%% / %6.2f%% (%5d)", count.wrongRate * 100, count.recall * 100, count.words)
            }
            text += String(format: "%-4@ %-5@ %7d  ", row.language as NSString, row.first as NSString,
                           row.noContext.words)
            text += "\(cell(row.noContext))  \(cell(row.firstWords))  \(cell(row.withContext))\n"
        }
        return text
    }

    /// The gate: with context, under `target` for each language and order.
    public static func targetsMet(_ rows: [Row]) -> Bool {
        rows.allSatisfy { $0.withContext.wrongRate < target }
    }
}
