// SPDX-License-Identifier: GPL-3.0-or-later

/// Finds the word the user meant when the typed word is no word of its
/// language: one edit away on the keyboard (docs/classifier.md, «Опечатки»).
///
/// Candidates are one edit from the typed word: a neighbouring key in place
/// of one key (`KeyboardGeometry`), two adjacent letters swapped, one letter
/// too many (a doubled one or a stray one) and one letter missing. A
/// candidate counts when it is a word form of the model's dictionary. Each
/// is scored as a noisy channel would: its frequency rank plus the log prior
/// of the edit that explains the typo (a neighbouring key is likely, a stray
/// letter is not). The best candidate is the correction when its score is
/// high enough and every other candidate scores much lower. The typed word
/// must be unknown to the dictionary, 4–24 letters long, without capitals
/// except a sentence-initial one, and typed without ⌥ or Caps Lock.
///
/// Runs once per word, at its boundary, on the tap thread: no allocation
/// until a correction is found, prefix hashes shared by all candidates.
public struct TypoCorrector: Sendable {
    public struct Options: Hashable, Sendable {
        /// The least score of a correction, in rank units (32 per unit of
        /// Zipf): a candidate below it is never put in place of what the
        /// user typed. 56 is a word of Zipf 2.4 reached by a swap, of Zipf 3
        /// by a neighbouring key, of Zipf 4.2 by a stray letter. The default
        /// and `margin` come from the sweep of `perekey-eval`
        /// (docs/classifier.md, «Опечатки»).
        public var minScore = 56
        /// How much lower every other candidate must score, in rank units
        /// (32 is one unit of Zipf, ten times less likely). Two candidates
        /// close together mean the word is ambiguous: nothing is corrected.
        public var margin = 48
        /// Log priors of the edits in rank units (`32·log₁₀`), from how
        /// people miss keys: a neighbouring key in 40 % of typos (spread over
        /// about six neighbours), two letters swapped in 20 %, a letter
        /// dropped in 20 %, a letter doubled in 10 %, a stray letter in 10 %
        /// (spread over the alphabet).
        public var substitutionPrior = -38
        public var transpositionPrior = -22
        public var dropPrior = -22
        public var doublePrior = -32
        public var strayPrior = -78
        /// Extra score a word with a capital first letter needs: at a
        /// sentence start it may still be a name, and names are the words
        /// the dictionary lacks most.
        public var capitalExtra = 48
        /// Shorter words are left alone: too many words are one edit away.
        public var minLetters = 4
        /// Longer words are left alone: no one types them in one go.
        public var maxLetters = 24
        /// The languages whose typos are corrected: those that passed the
        /// typo gate of `perekey-eval` (docs/classifier.md, «Опечатки»). uk
        /// has no word-form dictionary and no measured recall: a rare valid
        /// form could be «fixed», so its typos stay as typed until measured.
        public var languages: Set<String> = ["ru", "en"]
        /// Rank units one bit of lift is worth: 32 per unit of Zipf, a factor
        /// of ten, and a bit is a factor of two (`32·log₁₀2`).
        public static let rankUnitsPerBit = 32 * 0.301_029_995_663_981_2
        /// How much of the lift of a candidate after the word before it
        /// (the "pair" section of the model) counts in its score: the
        /// candidate gets `contextWeight × lift` bits, in rank units. 0 is
        /// the corrector without the word before it, byte for byte. Plan 8.2;
        /// the value comes from `perekey-eval run --typo-context-sweep`
        /// (docs/corrections.md, «Опечатки с контекстом»).
        public var contextWeight = 0.0
        /// Words that are words (`correct(…, realWords: true)`): the least lift,
        /// in bits, a candidate must have after the word before it. "form" after
        /// "letter" is a word; "from" after it is nine bits likelier than
        /// anywhere. 6 is the start of the sweep of
        /// `perekey-eval run --real-words --real-word-sweep`
        /// (docs/classifier.md, «Опечатки-слова»).
        public var realWordLift = 6.0
        /// Words that are words: how much rarer than the typed word the
        /// candidate may be, in rank units (32 per unit of Zipf). A candidate
        /// ranked below the typed word by more is not what the person meant.
        public var realWordSlack = 32
        /// Words that are words: how many bits of lift the best candidate must
        /// have over every other. Two likely answers mean nothing is fixed.
        public var realWordMargin = 1.0
        /// Words that are words: whether the edit may fall on the last letter.
        /// Off, "believes" is never "believed": a neighbouring key at the end
        /// of a word is mostly another form of the same word.
        public var realWordEnding = true
        /// Words that are words: whether a neighbouring key may be the edit.
        /// Off, only two letters swapped count.
        public var realWordKeys = true

        public init() {}
    }

    /// The correction: the keys that type it in the word's layout.
    public struct Candidate: Hashable, Sendable {
        public var strokes: [KeyStroke]
        public var text: String
        public var rank: UInt8
        /// What the one edit was.
        public var change: Change
    }

    /// The kind of the one edit, for explaining a correction.
    public enum Change: Hashable, Sendable, CaseIterable {
        /// A wrong letter.
        case substitute
        /// Two letters swapped.
        case transpose
        /// A letter too many.
        case delete
        /// A letter missing.
        case insert
    }

    /// The one edit that turns the typed word into the candidate.
    enum Edit {
        case substitute(Int, UInt32)
        case transpose(Int)
        case delete(Int)
        case insert(Int, UInt32)
    }

    public let model: LanguageModel
    public var options: Options

    public init(model: LanguageModel, options: Options = Options()) {
        self.model = model
        self.options = options
    }

    /// The correction of a word typed with these strokes in `layout`, or nil
    /// when the word is fine, unknown in a way no single edit explains, or
    /// not one to touch. Trailing spaces are ignored.
    /// - Parameters:
    ///   - sentenceStart: the word starts a sentence, so a capital first
    ///     letter is no name.
    ///   - previous: the fingerprint of the word before it
    ///     (`PreviousWord.fingerprint(of:)`, `ModelFormat.sentenceStart` at the
    ///     start of a sentence); nil when it is not known. Used only with
    ///     `Options.contextWeight` above 0 or `realWords`.
    ///   - realWords: a word of the dictionary may be replaced too, by a word
    ///     one swap or one neighbouring key away that the pair table likes far
    ///     more after `previous` (docs/classifier.md, «Опечатки-слова»). Off
    ///     is the corrector without the class, byte for byte.
    public func correct(_ strokes: some Collection<KeyStroke>, in layout: LayoutMap, sentenceStart: Bool,
                        previous: UInt64? = nil, realWords: Bool = false) -> Candidate?
    {
        guard let code = layout.language, options.languages.contains(code) else { return nil }
        return correct(strokes, inAllowed: layout, sentenceStart: sentenceStart, previous: previous,
                       realWords: realWords)
    }

    /// `correct(_:in:sentenceStart:)` for a caller that knows the layout's
    /// language is allowed (`LayoutState.correctsTypos`): no set lookup on
    /// the per-word path.
    func correct(_ strokes: some Collection<KeyStroke>, inAllowed layout: LayoutMap, sentenceStart: Bool,
                 previous: UInt64? = nil, realWords: Bool = false) -> Candidate?
    {
        guard let code = layout.language, let language = model.language(code) else { return nil }
        let capacity = options.maxLetters
        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: capacity) { scalars in
            withUnsafeTemporaryAllocation(of: UInt16.self, capacity: capacity) { keyCodes in
                withUnsafeTemporaryAllocation(of: UInt64.self, capacity: capacity + 1) { prefixes in
                    correct(strokes, in: layout, language: language, sentenceStart: sentenceStart, previous: previous,
                            realWords: realWords, scalars: scalars, keyCodes: keyCodes, prefixes: prefixes)
                }
            }
        }
    }

    private func correct(_ strokes: some Collection<KeyStroke>, in layout: LayoutMap, language: LanguageModel.Language,
                         sentenceStart: Bool, previous: UInt64?, realWords: Bool,
                         scalars: UnsafeMutableBufferPointer<UInt32>,
                         keyCodes: UnsafeMutableBufferPointer<UInt16>,
                         prefixes: UnsafeMutableBufferPointer<UInt64>) -> Candidate?
    {
        var count = 0
        var capital = false
        for stroke in strokes {
            if stroke.keyCode == KeyCode.space { break }
            guard count < scalars.count, !stroke.modifiers.contains(.option), !stroke.modifiers.contains(.capsLock),
                  let text = layout.text(for: stroke)
            else { return nil }
            var iterator = text.unicodeScalars.makeIterator()
            guard let scalar = iterator.next()?.value, iterator.next() == nil else { return nil }
            let folded = ModelFormat.fold(scalar)
            guard language.isLetter(folded), Self.isAlphabetic(folded) else { return nil }
            if folded != scalar {
                // A capital: a name or an abbreviation, unless it starts a sentence.
                guard count == 0, sentenceStart else { return nil }
                capital = true
            }
            scalars[count] = folded
            keyCodes[count] = stroke.keyCode
            count += 1
        }
        guard count >= options.minLetters else { return nil }

        // Hash states after each prefix: every candidate shares the prefix
        // before its edit and hashes only the rest.
        var fingerprint = ModelFormat.Fingerprint()
        prefixes[0] = fingerprint.hash
        for index in 0..<count {
            fingerprint.add(scalars[index])
            prefixes[index + 1] = fingerprint.hash
        }
        // A known form, however rare, is what the user meant, unless it is the
        // typo of a likelier word in this very place: one swap or one key away,
        // the table has no pair of the word before and this one, and has one
        // of it and the candidate that is far likelier (`Options.realWordLift`).
        let typedRank = language.rank(of: fingerprint.value)
        if typedRank != nil {
            guard realWords, !capital, language.hasPairTable, let previous,
                  language.pairLift(previous: previous, word: fingerprint.value) == nil
            else { return nil }
        }
        let floorRank = typedRank.map { Int($0) - options.realWordSlack }
        let barLift = Int((options.realWordLift * 8).rounded(.up))
        let realWord = typedRank != nil
        let typedValue = fingerprint.value

        // The word before counts only with a weight, a word known and a table in the model.
        let context = options.contextWeight > 0 && language.hasPairTable ? previous : nil
        let unitsPerEighth = options.contextWeight * Options.rankUnitsPerBit / 8
        var best: (fingerprint: UInt64, rank: UInt8, score: Int, edit: Edit)?
        var runnerUp = Int.min
        func consider(_ value: UInt64, _ edit: Edit, prior: Int) {
            guard let rank = language.rank(of: value) else { return }
            var score = Int(rank) + prior
            if let floorRank {
                // A word that is a word: scored by its lift alone, the rank only a floor.
                guard value != typedValue, Int(rank) >= floorRank,
                      let previous, let lift = language.pairLift(previous: previous, word: value), Int(lift) >= barLift
                else { return }
                score = Int(lift)
            } else if let context, let lift = language.pairLift(previous: context, word: value) {
                score += Int((Double(lift) * unitsPerEighth).rounded())
            }
            guard let current = best else {
                best = (value, rank, score, edit)
                return
            }
            if value == current.fingerprint {
                // The same word by another edit: the likelier edit counts.
                if score > current.score { best = (value, rank, score, edit) }
                return
            }
            if score > current.score {
                runnerUp = current.score
                best = (value, rank, score, edit)
            } else if score > runnerUp {
                runnerUp = score
            }
        }
        func rest(_ hash: inout ModelFormat.Fingerprint, from index: Int) -> UInt64 {
            var position = index
            while position < count {
                hash.add(scalars[position])
                position += 1
            }
            return hash.value
        }
        func letter(_ keyCode: UInt16) -> UInt32? {
            guard let text = layout.text(for: KeyStroke(keyCode)) else { return nil }
            var iterator = text.unicodeScalars.makeIterator()
            guard let scalar = iterator.next()?.value, iterator.next() == nil else { return nil }
            let folded = ModelFormat.fold(scalar)
            return language.isLetter(folded) && Self.isAlphabetic(folded) ? folded : nil
        }

        for index in 0..<count {
            // A neighbouring key.
            let endingEdit = realWord && (!options.realWordKeys || !options.realWordEnding && index == count - 1)
            for neighbour in KeyboardGeometry.neighbours(of: keyCodes[index]) where !endingEdit {
                guard let replacement = letter(neighbour), replacement != scalars[index] else { continue }
                var hash = ModelFormat.Fingerprint()
                hash.hash = prefixes[index]
                hash.add(replacement)
                consider(rest(&hash, from: index + 1), .substitute(index, replacement), prior: options.substitutionPrior)
            }
            // Two letters swapped.
            if index + 1 < count, scalars[index] != scalars[index + 1],
               !(realWord && !options.realWordEnding && index + 2 == count)
            {
                var hash = ModelFormat.Fingerprint()
                hash.hash = prefixes[index]
                hash.add(scalars[index + 1])
                hash.add(scalars[index])
                consider(rest(&hash, from: index + 2), .transpose(index), prior: options.transpositionPrior)
            }
            // One letter too many: a doubled one, or a stray one.
            if !realWord, count > options.minLetters, index == 0 || scalars[index] != scalars[index - 1] {
                var hash = ModelFormat.Fingerprint()
                hash.hash = prefixes[index]
                let doubled = index + 1 < count && scalars[index] == scalars[index + 1]
                consider(rest(&hash, from: index + 1), .delete(index),
                         prior: doubled ? options.doublePrior : options.strayPrior)
            }
        }
        // One letter missing.
        if !realWord, count < options.maxLetters {
            for index in 0...count {
                for inserted in language.letters {
                    // Inserting before an equal letter is the same word as after it.
                    if index < count, inserted == scalars[index] { continue }
                    var hash = ModelFormat.Fingerprint()
                    hash.hash = prefixes[index]
                    hash.add(inserted)
                    consider(rest(&hash, from: index), .insert(index, inserted), prior: options.dropPrior)
                }
            }
        }

        // A word that is a word: the lift is the score and its bar was met in
        // `consider`; the margin over the next answer is left.
        let margin = realWord ? max(Int((options.realWordMargin * 8).rounded(.up)), 1) : options.margin
        let least = realWord ? barLift : options.minScore + (capital ? options.capitalExtra : 0)
        guard let best, best.score >= least, runnerUp + margin <= best.score else { return nil }

        var corrected: [UInt32] = []
        corrected.reserveCapacity(count + 1)
        for index in 0..<count { corrected.append(scalars[index]) }
        switch best.edit {
        case let .substitute(index, scalar): corrected[index] = scalar
        case let .transpose(index): corrected.swapAt(index, index + 1)
        case let .delete(index): corrected.remove(at: index)
        case let .insert(index, scalar): corrected.insert(scalar, at: index)
        }
        var result: [KeyStroke] = []
        var text = ""
        result.reserveCapacity(corrected.count)
        for (index, scalar) in corrected.enumerated() {
            let wanted = index == 0 && capital ? Self.unfold(scalar) : scalar
            guard let unicode = Unicode.Scalar(wanted), let stroke = layout.stroke(for: Character(unicode)),
                  !stroke.modifiers.contains(.option)
            else { return nil }
            result.append(stroke)
            text.unicodeScalars.append(unicode)
        }
        let change: Change = switch best.edit {
        case .substitute: .substitute
        case .transpose: .transpose
        case .delete: .delete
        case .insert: .insert
        }
        return Candidate(strokes: result, text: text, rank: best.rank, change: change)
    }

    /// A letter proper, not a joiner the alphabet also has (`-`, `'`).
    static func isAlphabetic(_ scalar: UInt32) -> Bool {
        Unicode.Scalar(scalar)?.properties.isAlphabetic == true
    }

    /// The capital of a folded letter: the inverse of `ModelFormat.fold`.
    static func unfold(_ scalar: UInt32) -> UInt32 {
        switch scalar {
        case 0x61...0x7A: return scalar - 32 // a–z
        case 0x430...0x44F: return scalar - 32 // а–я
        case 0x451: return 0x401 // ё
        case 0x454: return 0x404 // є
        case 0x456: return 0x406 // і
        case 0x457: return 0x407 // ї
        case 0x491: return 0x490 // ґ
        default: return scalar
        }
    }
}
