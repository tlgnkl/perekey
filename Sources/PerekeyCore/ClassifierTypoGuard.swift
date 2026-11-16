// SPDX-License-Identifier: GPL-3.0-or-later

extension Classifier {
    /// The longest word the guard looks at: it guards the switch inside a
    /// word, which acts after the third or fourth key.
    static let typoGuardLetters = 4

    /// Whether the strokes, read in `layout`, are two neighbouring letters
    /// swapped away from a common word of the layout's language and are no
    /// common word themselves: "hte" is "the", "taht" is "that". The common
    /// word must have at least `Options.typoWordRank` and be at least
    /// `Options.typoWordGap` above what was typed (the dictionaries hold
    /// "hte" as a rare token, and the slip must not hide a word that is one).
    ///
    /// Only the swap: a letter on a neighbouring key, a stray or a missing
    /// letter find too many common words one edit from a word of three or
    /// four letters, and a Ukrainian "Gkt" ("Пле…") is a neighbouring key
    /// away from "got" (docs/classifier.md, «Опечатка своего языка»).
    ///
    /// A word that is a slip of a common word of its own language is not a
    /// reason to type it in the other layout: the other reading of "hte" is
    /// "реу", which is no word either. Asked only where the switch would act
    /// on the first keys of the word, never on the per-word path.
    public func isSlipOfCommonWord(_ strokes: some Collection<KeyStroke>, in layout: LayoutMap) -> Bool {
        guard options.typoWordRank > 0, let code = layout.language, let language = model.language(code) else {
            return false
        }
        var scalars: [UInt32] = []
        for stroke in strokes {
            if stroke.keyCode == KeyCode.space { break }
            guard scalars.count < Self.typoGuardLetters, !stroke.modifiers.contains(.option),
                  let text = layout.text(for: stroke)
            else { return false }
            var iterator = text.unicodeScalars.makeIterator()
            guard let scalar = iterator.next()?.value, iterator.next() == nil else { return false }
            let folded = ModelFormat.fold(scalar)
            guard language.isLetter(folded), TypoCorrector.isAlphabetic(folded) else { return false }
            scalars.append(folded)
        }
        guard scalars.count >= 3 else { return false }

        func rank(_ word: [UInt32]) -> Int? {
            var fingerprint = ModelFormat.Fingerprint()
            for scalar in word { fingerprint.add(scalar) }
            return language.rank(of: fingerprint.value).map(Int.init)
        }
        // A word of the dictionary is as common as the dictionary says: it
        // is no slip when it is common itself.
        let bar = max(Int(options.typoWordRank), (rank(scalars) ?? 0) + Int(options.typoWordGap))
        func common(_ word: [UInt32]) -> Bool { (rank(word) ?? 0) >= bar }

        for index in scalars.indices {
            if index + 1 < scalars.count, scalars[index] != scalars[index + 1] {
                var swapped = scalars
                swapped.swapAt(index, index + 1)
                if common(swapped) { return true }
            }
        }
        return false
    }
}
