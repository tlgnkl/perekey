// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyModelKit

/// One slip of the fingers in a word, for the suites `typos.synth.*`
/// (docs/eval.md, «Наборы правок слова»).
///
/// The shares of the kinds of slip come from the suite's manifest and are
/// not the corrector's own (40 / 20 / 20 / 10 / 10 in `Synthetic.typo`):
/// a number measured on the corrector's own assumption says how well it
/// knows itself. Three suites with three sets of shares show how much the
/// number depends on the assumption.
enum TypoMaker {
    /// Numbers of the generator. A first guess, not a measurement.
    struct Options {
        /// The shortest word that gets a slip: the corrector looks at words of
        /// four letters and more (`TypoCorrector.Options.minLetters`), and a
        /// shorter word would only measure that rule. `Synthetic.typo` also
        /// takes four.
        var minLetters = 4
    }

    enum Kind: String, CaseIterable {
        case neighbor, swap, drop, double, stray
    }

    /// The letter rows of the two layouts, for the keys next to a letter.
    /// Written out here on purpose: the bench must not borrow the geometry
    /// of the corrector it measures, nor that of `Synthetic.typo` either.
    static let rows: [String: [(offset: Double, letters: String)]] = [
        "en": [(0, "qwertyuiop"), (0.25, "asdfghjkl"), (0.75, "zxcvbnm")],
        "ru": [(0, "йцукенгшщзхъ"), (0.25, "фывапролджэ"), (0.75, "ячсмитьбю")],
    ]

    /// Letters on the keys next to this one: in its row, and in the rows
    /// above and below when the keys overlap by more than half a key.
    static func neighbours(of letter: Character, language: String) -> [Character] {
        guard let lines = rows[language] else { return [] }
        let lower = Character(letter.lowercased())
        var position: (row: Int, x: Double)?
        for (row, line) in lines.enumerated() {
            if let index = line.letters.firstIndex(of: lower) {
                position = (row, line.offset + Double(line.letters.distance(from: line.letters.startIndex, to: index)))
            }
        }
        guard let position else { return [] }
        var found: [Character] = []
        for (row, line) in lines.enumerated() {
            for (index, other) in line.letters.enumerated() where other != lower {
                let distance = abs(line.offset + Double(index) - position.x)
                let gap = abs(row - position.row)
                if (gap == 0 && distance < 1.5) || (gap == 1 && distance < 1) { found.append(other) }
            }
        }
        return found
    }

    /// The word with one slip, and which one; nil when the word has no
    /// place for the slip the dice chose (the same letter twice for a swap,
    /// a letter the rows do not know for a neighbour).
    static func make(word: String, language: String, weights: SuiteManifest.TypoWeights,
                     options: Options = Options(), random: inout SplitMix64) -> (typo: String, kind: Kind)?
    {
        var letters = Array(word)
        guard letters.count >= options.minLetters, letters.allSatisfy(\.isLetter), let lines = rows[language] else {
            return nil
        }
        let alphabet = Array(lines.map(\.letters).joined())
        let kind = pick(weights, &random)
        let index = Int(random.next() % UInt64(letters.count))
        switch kind {
        case .neighbor:
            let around = neighbours(of: letters[index], language: language)
            guard !around.isEmpty else { return nil }
            let chosen = around[Int(random.next() % UInt64(around.count))]
            letters[index] = letters[index].isUppercase ? Character(chosen.uppercased()) : chosen
        case .swap:
            let at = min(index, letters.count - 2)
            guard letters[at] != letters[at + 1] else { return nil }
            letters.swapAt(at, at + 1)
        case .drop:
            letters.remove(at: index)
        case .double:
            letters.insert(letters[index], at: index)
        case .stray:
            let chosen = alphabet[Int(random.next() % UInt64(alphabet.count))]
            letters.insert(index == 0 && letters[0].isUppercase ? Character(chosen.uppercased()) : chosen, at: index)
        }
        let typo = String(letters)
        return typo == word ? nil : (typo, kind)
    }

    static func pick(_ weights: SuiteManifest.TypoWeights, _ random: inout SplitMix64) -> Kind {
        var roll = Int(random.next() % UInt64(max(weights.total, 1)))
        for (kind, share) in [(Kind.neighbor, weights.neighbor), (.swap, weights.swap), (.drop, weights.drop),
                              (.double, weights.double), (.stray, weights.stray)]
        {
            if roll < share { return kind }
            roll -= share
        }
        return .stray
    }
}
