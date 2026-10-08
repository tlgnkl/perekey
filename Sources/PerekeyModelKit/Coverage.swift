// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// How many tokens of real text a language's model knows as word forms:
/// Tatoeba sentences of the language, split into words. The check for a
/// language built without a word-form dictionary (uk, data/SOURCES.md:
/// wordfreq alone gave 98.66 %).
public struct Coverage {
    public var language: String
    public var tokens = 0
    /// Tokens with a character outside the alphabet: Latin, digits.
    public var outsideAlphabet = 0
    /// Tokens in the alphabet that are known forms.
    public var known = 0

    /// Tatoeba files by model language.
    static let tatoeba = ["ru": "rus", "en": "eng", "uk": "ukr", "be": "bel", "kk": "kaz"]

    public static func measure(_ model: LanguageModel.Language, cache: String) throws -> Coverage {
        guard let name = tatoeba[model.code] else {
            throw ModelBuild.Failure(description: "no Tatoeba file for \(model.code)")
        }
        var coverage = Coverage(language: model.code)
        for line in try Archive.bunzip2("\(cache)/tatoeba/\(name)_sentences.tsv.bz2").lines() {
            let fields = line.split(separator: "\t")
            guard fields.count == 3 else { continue }
            for token in words(of: fields[2]) {
                coverage.tokens += 1
                var fingerprint = ModelFormat.Fingerprint()
                var inAlphabet = true
                for scalar in token.unicodeScalars {
                    // `’` is the apostrophe of the text, `'` of the model.
                    let value = scalar.value == 0x2019 ? 0x27 : scalar.value
                    inAlphabet = inAlphabet && model.isLetter(value)
                    fingerprint.add(ModelFormat.fold(value))
                }
                if !inAlphabet {
                    coverage.outsideAlphabet += 1
                } else if model.rank(of: fingerprint.value) != nil {
                    coverage.known += 1
                }
            }
        }
        return coverage
    }

    /// The words of a sentence: letters with the apostrophes and hyphens inside.
    static func words(of sentence: Substring) -> [Substring] {
        func isPart(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || "'’ʼ-".contains(character)
        }
        return sentence.split { !isPart($0) }.compactMap { token in
            var word = token
            while let first = word.first, !first.isLetter && !first.isNumber { word = word.dropFirst() }
            while let last = word.last, !last.isLetter && !last.isNumber { word = word.dropLast() }
            return word.isEmpty ? nil : word
        }
    }

    public var report: String {
        let inAlphabet = tokens - outsideAlphabet
        let share = inAlphabet > 0 ? Double(known) / Double(inAlphabet) * 100 : 0
        return String(format: "%@: %d tokens, %d outside the alphabet; known forms %.2f %% of %d",
                      language, tokens, outsideAlphabet, share, inAlphabet)
    }
}
