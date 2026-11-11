// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// What the corrector does to words that are words in clean running text
/// (`perekey-eval realword`, docs/classifier.md, «Опечатки-слова»): every
/// word of the text goes through `TypoCorrector.correct` with the word
/// before it, as the machine would read it, and every dictionary word it
/// changes is a wrong change, because the text has no typos in it. Counts by
/// the edit and by the place in the sentence, and the most frequent
/// changes by name, so a narrowing can be read off the numbers.
public struct RealWordEvaluation: Sendable {
    /// The text: "Tatoeba prose", "Wikipedia (held out)".
    public var name: String
    /// Words the corrector saw: letters only, typeable in the layout.
    public var words = 0
    /// Of them, forms of the dictionary.
    public var known = 0
    /// Of the known ones, how many it changed, by the edit and by the place.
    public var changed = 0
    public var byTransposition = 0
    public var byKey = 0
    public var atSentenceStart = 0
    /// Words not in the dictionary it changed (the ordinary typo correction, not the class).
    public var typosChanged = 0
    /// "form → from": how often each change was made.
    public var changes: [String: Int] = [:]

    public init(name: String) {
        self.name = name
    }

    /// Changes per million known words.
    public var perMillion: Double { known > 0 ? Double(changed) / Double(known) * 1_000_000 : 0 }

    public var report: String {
        String(format: "  %@: %d words, %d of the dictionary, %d changed (%.1f per million): %d by a swap, %d by a key, "
               + "%d at the start of a sentence; %d unknown words corrected as typos", name, words, known, changed,
               perMillion, byTransposition, byKey, atSentenceStart, typosChanged)
    }

    /// The most frequent changes, "form → from  12".
    public func top(_ count: Int) -> [String] {
        changes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(count)
            .map { "\($0.key)  \($0.value)" }
    }

    /// Measures texts, one per element; a tab inside one starts a new sentence.
    /// - Parameters:
    ///   - language: the model's tables of the layout's language.
    ///   - realWords: look for words that are words (the run to compare with is without).
    public static func measure(_ texts: some Sequence<String>, name: String, corrector: TypoCorrector,
                               layout: LayoutMap, language: LanguageModel.Language, realWords: Bool = true)
        -> RealWordEvaluation
    {
        var result = RealWordEvaluation(name: name)
        for text in texts {
            for segment in text.split(separator: "\t") {
                var reader = PreviousWord.Reader()
                for token in segment.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                    let before = reader.result ?? ModelFormat.sentenceStart
                    for scalar in token.unicodeScalars { reader.add(scalar) }
                    reader.add(" ")
                    let core = Self.core(of: token)
                    guard core.count >= 1, core.allSatisfy(\.isLetter) else { continue }
                    var strokes: [KeyStroke] = []
                    strokes.reserveCapacity(core.count)
                    for character in core {
                        guard let stroke = layout.stroke(for: character), !stroke.modifiers.contains(.option) else { break }
                        strokes.append(stroke)
                    }
                    guard strokes.count == core.count else { continue }
                    result.words += 1
                    let known = language.rank(of: ModelFormat.Fingerprint.of(core.unicodeScalars, folded: true)) != nil
                    if known { result.known += 1 }
                    let atStart = before == ModelFormat.sentenceStart
                    guard let fix = corrector.correct(strokes, in: layout, sentenceStart: atStart, previous: before,
                                                      realWords: realWords)
                    else { continue }
                    guard known else {
                        result.typosChanged += 1
                        continue
                    }
                    result.changed += 1
                    if fix.change == .transpose { result.byTransposition += 1 } else { result.byKey += 1 }
                    if atStart { result.atSentenceStart += 1 }
                    result.changes["\(core.lowercased()) → \(fix.text)", default: 0] += 1
                }
            }
        }
        return result
    }

    /// The letters of a token without the marks around it.
    static func core(of token: Substring) -> Substring {
        var start = token.startIndex
        var end = token.endIndex
        while start < end, !token[start].isLetter { start = token.index(after: start) }
        while end > start, !token[token.index(before: end)].isLetter { end = token.index(before: end) }
        return token[start..<end]
    }
}
