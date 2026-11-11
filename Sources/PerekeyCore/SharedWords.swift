// SPDX-License-Identifier: GPL-3.0-or-later

/// The words other settings of the app name as the user's own, taken into the
/// personal lexicon as accepted from the start: the right side of the voice
/// dictionary («перекей» → «Perekey», docs/classifier.md, «Общие слова»). They
/// are never counted and never written to `lexicon.json`: the store adds their
/// fingerprints to the snapshot it publishes (`PersonalLexiconModel.snapshot`),
/// so a word leaves the snapshot the moment its source does.
extension PersonalKey {
    /// The languages of the model that have words in each script. A word has
    /// no language of its own, and the fingerprint has one
    /// (`fingerprint(_:language:_:)`): the word is put in under all the
    /// languages its letters can be typed in, the layouts the user has or not.
    /// Latin is English alone: the model has no other Latin language.
    static func languages(ofScript scalar: UInt32) -> [LanguageCode] {
        switch scalar {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: ["en"]
        case 0x400...0x52F: ["ru", "uk", "be", "kk"]
        default: []
        }
    }

    /// The observations that stand for `texts` in the lexicon: for each word
    /// of each text, its fingerprints and the fingerprints of its starts, one
    /// observation per language. The same key, the same domains and the same
    /// spelling as a word the user typed (`Classifier.personalObservation`),
    /// so «Perekey» and «perekey» are one word, and so are «Артём» and «артем».
    ///
    /// A text is split at white space. A piece counts when it is a word the
    /// classifier could ever read as one: letters of a single script, between
    /// `options.minLetters` and `options.maxLetters` of them, with no digit and
    /// no mark inside; marks around it are cut (`Reading.coreStart`). Any
    /// other piece is left out, and so is a text of none.
    public func sharedObservations(of texts: some Sequence<String>,
                                   options: PersonalOptions = PersonalOptions()) -> [PersonalObservation]
    {
        var found: [PersonalObservation] = []
        for text in texts {
            for piece in text.split(whereSeparator: \.isWhitespace) {
                let scalars = Array(piece.unicodeScalars)
                guard let first = scalars.firstIndex(where: { $0.properties.isAlphabetic }),
                      let last = scalars.lastIndex(where: { $0.properties.isAlphabetic }),
                      !scalars[..<first].contains(where: { $0.properties.numericType != nil }),
                      !scalars[(last + 1)...].contains(where: { $0.properties.numericType != nil })
                else { continue }
                let core = scalars[first...last].map(\.value)
                guard core.count >= options.minLetters, core.count <= options.maxLetters,
                      scalars[first...last].allSatisfy({ $0.properties.isAlphabetic })
                else { continue }
                let languages = Self.languages(ofScript: core[0])
                guard !languages.isEmpty, core.allSatisfy({ Self.languages(ofScript: $0) == languages }) else { continue }
                for language in languages {
                    found.append(PersonalObservation(
                        word: fingerprint(.word, language: language, core),
                        start3: fingerprint(.start3, language: language, core.prefix(Self.shortStart)),
                        start4: core.count >= Self.longStart
                            ? fingerprint(.start4, language: language, core.prefix(Self.longStart)) : nil,
                        language: language))
                }
            }
        }
        return found
    }
}
