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
        /// Which sentence it is from: the words of one are in a row.
        public var sentence = 0
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
        /// Every word with a wrong context: the word before, or the three
        /// before, taken for the other Cyrillic language.
        public var wrongContext1 = Count()
        public var wrongContext3 = Count()
    }

    /// How a sentence gets out of a wrong guess: it starts with three words
    /// taken for the other Cyrillic language, and each word's decision is
    /// what the next one sees, as in the app.
    public struct Recovery: Hashable, Sendable {
        public var language: String
        public var sentences = 0
        /// Sentences whose first word already lands in its language.
        public var atOnce = 0
        /// Sentences that land by the third word.
        public var byThird = 0
        /// Sentences that never land.
        public var never = 0
        /// Words until the first that lands, over the sentences that do.
        public var words = 0
        public var recovered = 0

        public var meanWords: Double { recovered > 0 ? Double(words) / Double(recovered) : 0 }
    }

    /// The plan's bound for the wrong Cyrillic language with context.
    public static let target = 0.005

    public static func build(cache: String, words: Int, seed: UInt64) throws -> [Item] {
        var random = SplitMix64(seed: seed)
        var items: [Item] = []
        var sentenceIndex = 0
        for (language, file) in [("ru", "rus"), ("uk", "ukr")] {
            var count = 0
            for sentence in try Corpus.tatoeba("\(cache)/tatoeba/\(file)_sentences.tsv.bz2", random: &random)
                where count < words
            {
                var recent: [String?] = []
                sentenceIndex += 1
                for token in sentence.split(separator: " ") {
                    let word = Self.word(Corpus.apostrophes(token))
                    guard !word.isEmpty, word.unicodeScalars.allSatisfy({ (0x400...0x4FF).contains($0.value)
                        || $0 == "'" || $0 == "-" }), word.contains(where: \.isLetter)
                    else {
                        recent.insert(nil, at: 0)
                        continue
                    }
                    items.append(Item(language: language, text: word,
                                      recent: Array(recent.prefix(RecentLanguages.capacity)), sentence: sentenceIndex))
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
                           layouts: [String: LayoutMap]) -> [Row]
    {
        var rows: [Row] = []
        for language in ["ru", "uk"] {
            for first in ["ru", "uk"] {
                guard let own = layouts[language], let a = layouts[first],
                      let b = layouts[first == "ru" ? "uk" : "ru"]
                else { continue }
                let candidates = [a, b]
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
                    let other: String? = language == "ru" ? "uk" : "ru"
                    count(Classifier.Context(recent: RecentLanguages([other])), into: &row.wrongContext1)
                    count(Classifier.Context(recent: RecentLanguages([other, other, other])), into: &row.wrongContext3)
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

    public static func recover(_ items: [Item], classifier: Classifier, abc: LayoutMap,
                               layouts: [String: LayoutMap]) -> [Recovery]
    {
        guard let russian = layouts["ru"], let ukrainian = layouts["uk"] else { return [] }
        var results: [Recovery] = []
        for language in ["ru", "uk"] {
            guard let own = layouts[language] else { continue }
            let other: String? = language == "ru" ? "uk" : "ru"
            var recovery = Recovery(language: language)
            var sentence = -1
            var recent = RecentLanguages()
            var position = 0
            var done = true
            func close() {
                guard sentence >= 0 else { return }
                recovery.sentences += 1
                if !done { recovery.never += 1 }
            }
            for item in items where item.language == language {
                if item.sentence != sentence {
                    close()
                    sentence = item.sentence
                    recent = RecentLanguages([other, other, other])
                    position = 0
                    done = false
                }
                guard !done else { continue }
                var strokes: [KeyStroke] = []
                for character in item.text {
                    guard let stroke = own.stroke(for: character) else { break }
                    strokes.append(stroke)
                }
                guard strokes.count == item.text.count else { continue }
                position += 1
                let decision = classifier.classify(strokes, typed: abc, candidates: [russian, ukrainian],
                                                   context: Classifier.Context(recent: recent))
                if decision.verdict == .switch(to: own.id) {
                    done = true
                    recovery.recovered += 1
                    recovery.words += position
                    if position == 1 { recovery.atOnce += 1 }
                    if position <= 3 { recovery.byThird += 1 }
                } else {
                    recent.push(decision.language)
                }
            }
            close()
            results.append(recovery)
        }
        return results
    }

    public static func report(_ rows: [Row]) -> String {
        var text = "words typed on ABC, Russian and Ukrainian-PC installed: wrong Cyrillic language / own language\n"
        text += "lang first   words   no context              first words             with context\n"
        for row in rows {
            func cell(_ count: Count) -> String {
                String(format: "%6.2f%% / %6.2f%% (%5d)", count.wrongRate * 100, count.recall * 100, count.words)
            }
            text += String(format: "%-4@ %-5@ %7d  ", row.language as NSString, row.first as NSString,
                           row.noContext.words)
            text += "\(cell(row.noContext))  \(cell(row.firstWords))  \(cell(row.withContext))\n"
        }
        text += "\nwith a wrong context: the word before, the three before taken for the other Cyrillic language\n"
        for row in rows where row.first == row.language {
            text += String(format: "%-4@ 1 word: %6.2f%% wrong, %6.2f%% own;  3 words: %6.2f%% wrong, %6.2f%% own\n",
                           row.language as NSString, row.wrongContext1.wrongRate * 100,
                           row.wrongContext1.recall * 100, row.wrongContext3.wrongRate * 100,
                           row.wrongContext3.recall * 100)
        }
        return text
    }

    public static func report(_ recoveries: [Recovery]) -> String {
        var text = "recovery: sentences that start after three words taken for the other Cyrillic language\n"
        for recovery in recoveries {
            let share = { (count: Int) in
                recovery.sentences > 0 ? Double(count) / Double(recovery.sentences) * 100 : 0
            }
            text += String(format: "%-4@ %6d sentences: first word %5.1f%%, by the third %5.1f%%, never %5.1f%%; "
                + "mean %.2f words\n", recovery.language as NSString, recovery.sentences, share(recovery.atOnce),
                share(recovery.byThird), share(recovery.never), recovery.meanWords)
        }
        return text
    }

    /// The gate: with context, under `target` for each language and order.
    public static func targetsMet(_ rows: [Row]) -> Bool {
        rows.allSatisfy { $0.withContext.wrongRate < target }
    }
}
