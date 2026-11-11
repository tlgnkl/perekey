// SPDX-License-Identifier: GPL-3.0-or-later

/// The personal lexicon in the classifier (docs/classifier.md, «Личный
/// словарь»): a word the user keeps typing reads as a known form, and the
/// words that may become such words are picked here. No allocation: the
/// readings go into stack buffers, as `judgeWord`'s do.
extension Classifier {
    /// Marks a reading the model does not know as personal when `personal`
    /// has it: its rank becomes `Options.personalRank`. Only a word of
    /// letters, as long as the lexicon keeps; an empty lexicon computes no
    /// fingerprint.
    /// - Parameter scalars: the buffer `reading` was read into.
    func markPersonal(_ reading: inout Reading, language: String, scalars: Slice<UnsafeMutableBufferPointer<UInt32>>,
                      _ personal: PersonalLexicon)
    {
        guard personal.hasWords, let key = personal.key, reading.isWord, reading.digits == 0,
              reading.letters >= personal.minLetters, reading.letters <= personal.maxLetters, !isKnown(reading)
        else { return }
        let buffer = UnsafeMutableBufferPointer(rebasing: scalars)
        let core = UnsafeBufferPointer(rebasing: buffer[reading.coreStart..<reading.coreEnd])
        guard personal.containsWord(key.fingerprint(.word, language: language, core)) else { return }
        reading.personal = true
        reading.rank = options.personalRank
    }

    /// Whether the strokes read in `layout` are a word of `personal` the
    /// model does not know. The word corrections leave such a word alone
    /// (`WordJudge.correctWord`), and `perekey-eval` does as they do.
    public func isPersonal(_ strokes: some Collection<KeyStroke>, in layout: LayoutMap,
                           personal: PersonalLexicon) -> Bool
    {
        guard personal.hasWords, let code = layout.language, let language = model.language(code) else { return false }
        let count = Self.wordLength(strokes)
        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: Self.maxScalars) { scalars in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.maxScalars) { symbols in
                guard var reading = Reading(strokes, count: count, in: layout, language: language,
                                            scalars: scalars[...], symbols: symbols[...])
                else { return false }
                markPersonal(&reading, language: code, scalars: scalars[...], personal)
                return reading.personal
            }
        }
    }

    /// Whether the 3 or 4 strokes so far, read in `layout`, start a word
    /// of `personal`: a switch inside the word must wait for its end
    /// (`WordJudge.insideWord`). Only letters, from the first key.
    public func startsPersonalWord(_ strokes: some Collection<KeyStroke>, in layout: LayoutMap,
                                   personal: PersonalLexicon) -> Bool
    {
        guard personal.hasWords, let key = personal.key, let code = layout.language,
              let language = model.language(code)
        else { return false }
        let count = Self.wordLength(strokes)
        guard count == 3 || count == 4 else { return false }
        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: Self.maxScalars) { scalars in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.maxScalars) { symbols in
                guard let reading = Reading(strokes, count: count, in: layout, language: language,
                                            scalars: scalars[...], symbols: symbols[...]),
                      reading.isWord, reading.digits == 0, reading.coreStart == 0, reading.coreEnd == reading.count,
                      reading.letters == reading.count
                else { return false }
                let start = UnsafeBufferPointer(rebasing: scalars[0..<reading.letters])
                return personal.containsStart(key.fingerprint(reading.letters == 3 ? .start3 : .start4,
                                                              language: code, start))
            }
        }
    }

    /// What the personal lexicon may learn from a word kept as it reads in
    /// `result`, or nil when the word is no candidate. The word must be
    /// (docs/classifier.md, «Личный словарь», conditions 3–6):
    /// - a word of letters, `PersonalOptions.minLetters` to `maxLetters`
    ///   long, without digits, without a capital inside, not like a
    ///   password, not on the model's never-switch list;
    /// - unknown to the model (not `isKnown`): a known word needs no lexicon;
    /// - without a rival: no reading in `rivals` (the layouts it could have
    ///   gone to, or came from) is a known form. "ghbdtn" kept by oversight
    ///   has "привет" for a rival and never becomes a word;
    /// - no typo the corrector would fix, whether typo correction is on or
    ///   not (`corrector`): a habitual "превет" stays a typo.
    ///
    /// The caller decides the rest: the word was kept by a `.keep` decision
    /// (never `.unsure`) or switched there and the switch stood, nothing
    /// else corrected it, automatic switching could act there. Nil when
    /// `personal` is off.
    public func personalObservation(_ strokes: some Collection<KeyStroke>, in result: LayoutMap,
                                    rivals: some Collection<LayoutMap>, personal: PersonalLexicon,
                                    corrector: TypoCorrector?, sentenceStart: Bool) -> PersonalObservation?
    {
        guard let key = personal.key, let code = result.language, let language = model.language(code) else {
            return nil
        }
        let count = Self.wordLength(strokes)
        let found: PersonalObservation? = withUnsafeTemporaryAllocation(of: UInt32.self, capacity: Self.maxScalars) {
            scalars in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.maxScalars) { symbols in
                guard let reading = Reading(strokes, count: count, in: result, language: language,
                                            scalars: scalars[...], symbols: symbols[...]),
                      reading.isWord, reading.digits == 0, reading.upperInside == 0, !reading.isPasswordLike,
                      reading.letters >= personal.minLetters, reading.letters <= personal.maxLetters,
                      reading.coreEnd - reading.coreStart == reading.letters,
                      !isKnown(reading), !model.isKept(reading.exactFingerprint)
                else { return nil }
                let core = UnsafeBufferPointer(rebasing: scalars[reading.coreStart..<reading.coreEnd])
                return PersonalObservation(
                    word: key.fingerprint(.word, language: code, core),
                    start3: key.fingerprint(.start3, language: code, core.prefix(3)),
                    start4: reading.letters >= 4 ? key.fingerprint(.start4, language: code, core.prefix(4)) : nil,
                    language: code
                )
            }
        }
        guard let found else { return nil }
        for rival in rivals where rival.language != code {
            if isKnownForm(strokes, count: count, in: rival) { return nil }
        }
        if corrector?.correct(strokes, in: result, sentenceStart: sentenceStart) != nil { return nil }
        return found
    }

    /// The strokes read in `layout` are a known form of its language, by
    /// the model alone.
    private func isKnownForm(_ strokes: some Collection<KeyStroke>, count: Int, in layout: LayoutMap) -> Bool {
        guard let code = layout.language, let language = model.language(code) else { return false }
        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: Self.maxScalars) { scalars in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.maxScalars) { symbols in
                guard let reading = Reading(strokes, count: count, in: layout, language: language,
                                            scalars: scalars[...], symbols: symbols[...])
                else { return false }
                return reading.isWord && isKnown(reading)
            }
        }
    }
}
