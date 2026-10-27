// SPDX-License-Identifier: GPL-3.0-or-later

/// The dictionary corrections of a finished word, after its layout is
/// decided and its typos fixed (docs/corrections.md).
///
/// At the key that ends a word `WordJudge` decides the layout first
/// (automatic switching), fixes a typo (`TypoCorrector`), then hands the
/// word, as it reads in that layout, to these steps in order
/// (`WordJudge.correctWord`). Each step may change the letters; the next
/// one sees the result. If the word changed, it goes out as one retype with
/// the switch, if any: one `Correction`, one hint, one Backspace to undo it.
///
/// Steps work on the letters and digits of the word (`BoundaryWord.core`);
/// punctuation around them stays as typed: "(ПРивет" → "(Привет".
public enum WordCorrections {
    /// The steps in order: case first, so the lookups after it see a plain
    /// word; then the fixed spellings. Typos come before all of them. The
    /// hyphen goes last: it changes the length, and the case steps read the
    /// modifiers by position.
    public static let steps: [any WordCorrectionStep] = [
        CapsLockStep(),
        DoubleCapitalsStep(),
        AbbreviationStep(),
        YoStep(),
        HyphenStep(),
    ]

    /// The steps over the last few words together, tried at the end of a
    /// word that stays in its layout, before `steps`: the first that
    /// changes the words wins.
    public static let phraseSteps: [any PhraseCorrectionStep] = [
        SpacedHyphenStep(),
    ]

    /// Whether some step is on: without one the boundary does not build the word.
    public static func anyOn(_ settings: Settings) -> Bool {
        steps.contains { $0.isOn(settings) } || phraseSteps.contains { $0.isOn(settings) }
    }

    /// Runs the steps that are on. Returns true when the word changed.
    @discardableResult
    public static func run(_ word: inout BoundaryWord, settings: Settings, model: LanguageModel) -> Bool {
        let before = word.characters
        for step in steps where step.isOn(settings) {
            let input = word.characters
            step.apply(to: &word, model: model)
            if word.kind == nil, word.characters != input { word.kind = step.kind }
        }
        return word.characters != before
    }
}

/// One step of the word-boundary corrections.
public protocol WordCorrectionStep: Sendable {
    /// What the hint and `Correction.kind` call it.
    var kind: Correction.Kind { get }
    /// Its switch in the settings.
    func isOn(_ settings: Settings) -> Bool
    /// Changes `word.characters` when it corrects the word, else leaves it.
    func apply(to word: inout BoundaryWord, model: LanguageModel)
}

/// A correction of the last few words together, at the key that ends the
/// last one: "во первых" → "во-первых". The judge hands it the words as one
/// `BoundaryWord`, one space between them, and retypes them all at once:
/// one `Correction`, one hint, one Backspace to undo it (docs/corrections.md).
public protocol PhraseCorrectionStep: Sendable {
    /// What the hint and `Correction.kind` call it.
    var kind: Correction.Kind { get }
    /// How many words it reads, the one just ended included: 2 or more.
    var words: Int { get }
    /// Its switch in the settings.
    func isOn(_ settings: Settings) -> Bool
    /// Changes `phrase.characters` when it corrects the words, else leaves
    /// them. It may change the number of characters only as a word step does
    /// (`BoundaryWord.insertedAt`).
    func apply(to phrase: inout BoundaryWord, model: LanguageModel)
}

/// A finished word as it reads in the layout it stays in.
public struct BoundaryWord: Hashable, Sendable {
    /// One character per key: "пРИВЕТ!".
    public var characters: [Character]
    /// The modifiers of the key behind each character, as typed. A step
    /// that changes the number of characters makes them meaningless: steps
    /// after it must not read them.
    public let modifiers: [LayoutModifiers]
    /// The language of the layout: "ru", "en".
    public let language: String?
    /// Turn Caps Lock off once the correction is posted.
    public var capsLockOff = false
    /// The first step that changed the word.
    public var kind: Correction.Kind?
    /// The index of the one character a step inserted, which has no key of
    /// its own ("-" of "что-то"); `nil` when the word keeps its length.
    public var insertedAt: Int?

    public init(characters: [Character], modifiers: [LayoutModifiers], language: String?) {
        self.characters = characters
        self.modifiers = modifiers
        self.language = language
    }

    /// The letters and digits, without punctuation before and after.
    public var core: Range<Int> {
        var start = characters.startIndex
        var end = characters.endIndex
        while start < end, !Self.isWordCharacter(characters[start]) { start += 1 }
        while end > start, !Self.isWordCharacter(characters[end - 1]) { end -= 1 }
        return start..<end
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// The core is letters only, `minimum` or more of them.
    func coreIsLetters(minimum: Int) -> Bool {
        let core = core
        return core.count >= minimum && characters[core].allSatisfy(\.isLetter)
    }

    /// The folded fingerprint of the core: the dictionary key.
    func coreFingerprint() -> UInt64 {
        var fingerprint = ModelFormat.Fingerprint()
        for character in characters[core] {
            for scalar in character.unicodeScalars { fingerprint.add(ModelFormat.fold(scalar.value)) }
        }
        return fingerprint.value
    }

    /// The dictionary knows the core, in any case.
    func coreIsKnown(_ model: LanguageModel) -> Bool {
        guard let language, let table = model.language(language) else { return false }
        return table.rank(of: coreFingerprint()) != nil
    }

    /// The core has a spelling of its own case ("iPhone", "МВД").
    func coreHasFixedCase(_ model: LanguageModel) -> Bool {
        model.casedForm(of: coreFingerprint()) != nil
    }

    /// The core as "Привет": the first letter capital, the rest small.
    func capitalizedCore() -> [Character] {
        var result = characters
        for (offset, index) in core.enumerated() {
            let character = characters[index]
            result[index] = Character(offset == 0 ? character.uppercased() : character.lowercased())
        }
        return result
    }
}

// MARK: - Steps

/// "пРИВЕТ" → "Привет", and Caps Lock off.
///
/// macOS types capitals for Shift with Caps Lock on, so the usual trace of
/// a forgotten Caps Lock is "ПРИВЕТ" typed with Shift on the first key only:
/// the user wanted one capital. "пРИВЕТ" itself comes from remote desktops
/// and virtual machines that invert Shift under Caps Lock. A word typed in
/// capitals without Shift is left alone: that is what Caps Lock is for.
public struct CapsLockStep: WordCorrectionStep {
    public init() {}

    public var kind: Correction.Kind { .capsLock }

    public func isOn(_ settings: Settings) -> Bool { settings.corrections.capsLock }

    public func apply(to word: inout BoundaryWord, model: LanguageModel) {
        guard word.coreIsLetters(minimum: 3), word.modifiers.count == word.characters.count else { return }
        let core = word.core
        let letters = word.characters[core]
        let first = letters.first!
        let rest = letters.dropFirst()
        let keys = word.modifiers[core]
        let capsLock = keys.contains { $0.contains(.capsLock) }
        let inverted = first.isLowercase && rest.allSatisfy(\.isUppercase)
        let shiftedFirst = keys.allSatisfy { $0.contains(.capsLock) } && keys.first!.contains(.shift)
            && !keys.dropFirst().contains { $0.contains(.shift) } && letters.allSatisfy(\.isUppercase)
        guard inverted || shiftedFirst, word.coreIsKnown(model), !word.coreHasFixedCase(model) else { return }
        word.characters = word.capitalizedCore()
        if capsLock { word.capsLockOff = true }
    }
}

/// "ПРивет" → "Привет": Shift held a key too long. Only for a word the
/// dictionary knows and that has no case of its own ("IPhone" stays).
public struct DoubleCapitalsStep: WordCorrectionStep {
    public init() {}

    public var kind: Correction.Kind { .doubleCapitals }

    public func isOn(_ settings: Settings) -> Bool { settings.corrections.doubleCapitals }

    public func apply(to word: inout BoundaryWord, model: LanguageModel) {
        guard word.coreIsLetters(minimum: 3) else { return }
        let letters = word.characters[word.core]
        let start = letters.startIndex
        guard letters[start].isUppercase, letters[start + 1].isUppercase,
              letters[(start + 2)...].allSatisfy(\.isLowercase),
              word.coreIsKnown(model), !word.coreHasFixedCase(model),
              !model.isKept(ModelFormat.Fingerprint.of(letters.flatMap(\.unicodeScalars), folded: false))
        else { return }
        word.characters = word.capitalizedCore()
    }
}

/// "мвд" → "МВД", "врио" → "ВрИО", "mp3" → "MP3": the spellings the model
/// lists as corrected (`data/<язык>/abbreviations.txt`).
public struct AbbreviationStep: WordCorrectionStep {
    public init() {}

    public var kind: Correction.Kind { .abbreviation }

    public func isOn(_ settings: Settings) -> Bool { settings.corrections.abbreviations }

    public func apply(to word: inout BoundaryWord, model: LanguageModel) {
        let core = word.core
        guard core.count >= 2, let fixed = model.casedForm(of: word.coreFingerprint()), fixed.corrects else { return }
        let spelling = Array(fixed.form)
        guard spelling.count == core.count, spelling != Array(word.characters[core]) else { return }
        word.characters.replaceSubrange(core, with: spelling)
    }
}

/// "еще" → "ещё" where the word with "е" is no other word ("все" stays):
/// the model's table, derived from the dictionary when it is built.
public struct YoStep: WordCorrectionStep {
    public init() {}

    public var kind: Correction.Kind { .yo }

    public func isOn(_ settings: Settings) -> Bool { settings.corrections.yo }

    public func apply(to word: inout BoundaryWord, model: LanguageModel) {
        guard word.language == "ru", word.coreIsLetters(minimum: 2),
              let table = model.language("ru") else { return }
        let core = word.core
        var hasE = false
        for character in word.characters[core] {
            switch character {
            case "ё", "Ё": return // the user wrote it
            case "е", "Е": hasE = true
            default: continue
            }
        }
        guard hasE, let mask = table.yoMask(of: word.coreFingerprint()) else { return }
        var count = 0
        for index in core {
            let character = word.characters[index]
            guard character == "е" || character == "Е" else { continue }
            if count < 8, mask & (1 << UInt8(count)) != 0 { word.characters[index] = character == "е" ? "ё" : "Ё" }
            count += 1
        }
    }
}

/// "вопервых" → "во-первых": the hyphen dropped in fast typing, merged
/// form only. Letters and their case stay as typed: "ЧТОТО" → "ЧТО-ТО",
/// "всетаки" → "все-таки".
///
/// The model's table comes first: `data/ru/hyphen.txt` and the words the
/// builder derives by rule from the dictionary ("поновому", "вообщето",
/// "тихотихо", "давайка"), each with a merged spelling that is no word. A
/// word the table does not know may start with a prefix of `prefixes`
/// before a word ("вицемэр"): the rest must be a frequent word
/// (`minimumRestRank`) and the merged spelling unknown to the model. A model
/// without the table (built before the rules) has no prefix rule either.
///
/// A word of a rule with a capital first letter is a name or a word of
/// another language, also at the start of a sentence and in capitals:
/// "Оконто", "Лейбниц", "ОБАТО". Only the hand list fixes "Чтото", "ЧТОТО".
public struct HyphenStep: WordCorrectionStep {
    public init() {}

    public var kind: Correction.Kind { .hyphen }

    public func isOn(_ settings: Settings) -> Bool { settings.corrections.hyphen }

    /// Prefixes written with a hyphen before a noun: вице-мэр, штаб-квартира.
    public static let prefixes = ["вице", "лейб", "унтер", "штаб"].map { Array($0.unicodeScalars).map(\.value) }

    /// The word after a prefix: three letters or more, frequent (rank Zipf ×
    /// 32, `WordFreq.rank`): "мэр", "квартира", not "штурмфюрер".
    static let minimumRest = 3
    static let minimumRestRank: UInt8 = 128

    /// How many letters of the word are a prefix of `prefixes` with enough
    /// letters after it, `nil` when none is. Reads the characters as they
    /// are, folded, and allocates nothing: it runs on every word.
    static func prefixLength(of letters: ArraySlice<Character>) -> Int? {
        prefixes.first { prefix in
            letters.count - prefix.count >= minimumRest
                && zip(letters, prefix).allSatisfy { character, folded in
                    var scalars = character.unicodeScalars.makeIterator()
                    guard let scalar = scalars.next(), scalars.next() == nil else { return false }
                    return ModelFormat.fold(scalar.value) == folded
                }
        }?.count
    }

    public func apply(to word: inout BoundaryWord, model: LanguageModel) {
        guard word.language == "ru", word.coreIsLetters(minimum: 4), let table = model.language("ru") else { return }
        let core = word.core
        let position: Int
        let byRule: Bool
        let fingerprint = word.coreFingerprint()
        if let entry = table.hyphenEntry(of: fingerprint) {
            (position, byRule) = (Int(entry.position), entry.byRule)
        } else {
            guard table.hasHyphenTable, let split = Self.prefixLength(of: word.characters[core]) else { return }
            let letters = word.characters[core].flatMap(\.unicodeScalars).map { ModelFormat.fold($0.value) }
            guard letters.count == core.count, table.rank(of: fingerprint) == nil,
                  let rest = table.rank(of: Self.fingerprint(letters[split...])), rest >= Self.minimumRestRank
            else { return }
            (position, byRule) = (split, true)
        }
        guard position > 0, position < core.count else { return }
        if byRule, word.characters[core.lowerBound].isUppercase { return }
        word.characters.insert("-", at: core.lowerBound + position)
        word.insertedAt = core.lowerBound + position
    }

    static func fingerprint(_ letters: ArraySlice<UInt32>) -> UInt64 {
        var fingerprint = ModelFormat.Fingerprint()
        for letter in letters { fingerprint.add(letter) }
        return fingerprint.value
    }
}

/// "во первых" → "во-первых": the hyphen typed as a space. Only the words of
/// the hyphen table marked for it, whose form with a space is no two right
/// words: во-первых, во-вторых, the pronouns with -нибудь and -либо (not
/// "что либо"), кое- with a pronoun (`data/ru/hyphen.txt`, `space`). Letters
/// and their case stay as typed: "Кое что" → "Кое-что".
public struct SpacedHyphenStep: PhraseCorrectionStep {
    public init() {}

    public var kind: Correction.Kind { .hyphen }

    public var words: Int { 2 }

    public func isOn(_ settings: Settings) -> Bool { settings.corrections.hyphen }

    public func apply(to phrase: inout BoundaryWord, model: LanguageModel) {
        guard phrase.language == "ru", let table = model.language("ru") else { return }
        let core = phrase.core
        guard let space = phrase.characters[core].firstIndex(of: " ") else { return }
        let first = core.lowerBound..<space
        let second = (space + 1)..<core.upperBound
        guard !first.isEmpty, !second.isEmpty, phrase.characters[first].allSatisfy(\.isLetter),
              phrase.characters[second].allSatisfy(\.isLetter)
        else { return }
        var fingerprint = ModelFormat.Fingerprint()
        for index in core where index != space {
            for scalar in phrase.characters[index].unicodeScalars { fingerprint.add(ModelFormat.fold(scalar.value)) }
        }
        guard let position = table.spacedHyphenPosition(of: fingerprint.value), Int(position) == first.count
        else { return }
        phrase.characters[space] = "-"
    }
}
