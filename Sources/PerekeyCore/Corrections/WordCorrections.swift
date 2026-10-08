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
    /// word; then the fixed spellings. Typos come before all of them.
    public static let steps: [any WordCorrectionStep] = [
        CapsLockStep(),
        DoubleCapitalsStep(),
        AbbreviationStep(),
        YoStep(),
    ]

    /// Whether some step is on: without one the boundary does not build the word.
    public static func anyOn(_ settings: Settings) -> Bool {
        steps.contains { $0.isOn(settings) }
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
