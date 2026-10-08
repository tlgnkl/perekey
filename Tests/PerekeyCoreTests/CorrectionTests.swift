// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

/// Settings with automatic switching off and the given corrections on, so a
/// test sees one correction at a time.
private func only(_ change: (inout TextCorrections) -> Void, autoswitch: Bool = false,
                  exceptions: Set<String> = []) -> Settings
{
    var corrections = TextCorrections(phraseRetype: false, doubleCapitals: false)
    change(&corrections)
    return Settings(autoswitch: autoswitch, exceptions: exceptions, corrections: corrections, typoCorrection: false)
}

extension Desk {
    /// Types `text` in `layout` with Caps Lock on: every key carries the
    /// Caps Lock flag, Shift where `shifted` says.
    mutating func typeWithCapsLock(_ text: String, on layout: LayoutMap, shifted: Set<Int> = []) {
        for (index, character) in text.enumerated() {
            let stroke = layout.stroke(for: Character(character.lowercased()))!
            var flags = EventFlags.capsLock
            if shifted.contains(index) { flags |= Keyboard.leftShift }
            press(stroke.keyCode, flags: flags)
        }
    }
}

@Suite struct DoubleCapitalsTests {
    @Test func knownWordLosesTheSecondCapital() throws {
        var desk = Desk(only { $0.doubleCapitals = true }, current: ru)
        desk.type("ПРивет ", on: Fixture.russian)
        #expect(desk.text == "Привет ")
        let correction = try #require(desk.corrections.first)
        #expect(correction.original == "ПРивет")
        #expect(correction.replacement == "Привет")
        #expect(correction.source == ru && correction.target == ru)
        #expect(desk.appLayout == ru)
    }

    @Test func englishToo() {
        var desk = Desk(only { $0.doubleCapitals = true })
        desk.type("HEllo, world")
        #expect(desk.text == "Hello, world")
    }

    @Test(arguments: ["ПРиветик ", "ПРИВЕТ ", "ПР ", "ПРи ", "Привет "])
    func othersStay(typed: String) {
        // Unknown word, all capitals, too short, nothing to fix.
        var desk = Desk(only { $0.doubleCapitals = true }, current: ru)
        desk.type(typed, on: Fixture.russian)
        #expect(desk.text == typed)
        #expect(desk.corrections.isEmpty)
    }

    @Test func wordOfItsOwnCaseStays() {
        var desk = Desk(only { $0.doubleCapitals = true })
        desk.type("IPhone ")
        #expect(desk.text == "IPhone ")
    }

    @Test func punctuationAroundTheWordStays() {
        var desk = Desk(only { $0.doubleCapitals = true }, current: ru)
        desk.type("(ПРивет) ", on: Fixture.russian)
        #expect(desk.text == "(Привет) ")
    }

    @Test func offByItsSwitch() {
        var desk = Desk(only { _ in }, current: ru)
        desk.type("ПРивет ", on: Fixture.russian)
        #expect(desk.text == "ПРивет ")
    }

    @Test func backspaceUndoesAndLearns() throws {
        var desk = Desk(only { $0.doubleCapitals = true }, current: ru)
        desk.type("ПРивет ", on: Fixture.russian)
        #expect(desk.text == "Привет ")
        desk.press(KeyCode.delete)
        #expect(desk.text == "ПРивет ")
        #expect(desk.undone == [try #require(desk.corrections.first).seq])
        #expect(desk.learned == ["привет"])
    }

    @Test func togetherWithASwitch() throws {
        // "ПРивет" typed on the ABC keys: one retype switches and fixes it.
        var desk = Desk(only({ $0.doubleCapitals = true }, autoswitch: true))
        desk.type("GHbdtn ")
        #expect(desk.text == "Привет ")
        #expect(desk.appLayout == ru)
        let correction = try #require(desk.corrections.first)
        #expect(correction.original == "GHbdtn")
        #expect(correction.replacement == "Привет")
        #expect(correction.source == en && correction.target == ru)
        #expect(desk.corrections.count == 1)
        desk.press(KeyCode.delete)
        #expect(desk.text == "GHbdtn ")
        #expect(desk.appLayout == en)
    }

    @Test func afterATypo() throws {
        // Typos first, then the dictionary steps on the fixed word: one retype.
        var settings = only { $0.yo = true }
        settings.typoCorrection = true
        var desk = Desk(settings, current: ru)
        desk.type("еллка ", on: Fixture.russian)
        #expect(desk.text == "ёлка ")
        let correction = try #require(desk.corrections.first)
        #expect(correction.kind == .typo)
        #expect(desk.corrections.count == 1)
        desk.press(KeyCode.delete)
        #expect(desk.text == "еллка ")
    }

    @Test func kindNamesTheStep() throws {
        var desk = Desk(only { $0.doubleCapitals = true }, current: ru)
        desk.type("ПРивет ", on: Fixture.russian)
        #expect(try #require(desk.corrections.first).kind == .doubleCapitals)
    }

    @Test func fastTypingKeepsOrder() {
        var desk = Desk(only { $0.doubleCapitals = true }, current: ru)
        desk.type("ПРивет мир", on: Fixture.russian, settling: false)
        desk.settle()
        #expect(desk.text == "Привет мир")
    }
}

@Suite struct CorrectionGuardTests {
    private static let settings = only { $0.doubleCapitals = true; $0.abbreviations = true; $0.yo = true }

    @Test(arguments: [AppMode.manualOnly, .off])
    func notInManualOrOffApps(mode: AppMode) {
        var desk = Desk(Self.settings, current: ru)
        desk.send(.appModeChanged(mode))
        desk.type("ПРивет еще мвд ", on: Fixture.russian)
        #expect(desk.text == "ПРивет еще мвд ")
    }

    @Test func notInPasswordFieldsOrUnknownFocus() {
        for focus in [Focus(bundleID: "x", isSecureField: true), Focus.unknown(bundleID: "x")] {
            var desk = Desk(Self.settings, current: ru, focus: focus)
            desk.type("ПРивет еще ", on: Fixture.russian)
            #expect(desk.text == "ПРивет еще ")
        }
    }

    @Test func notUnderSecureInput() {
        var desk = Desk(Self.settings, current: ru)
        desk.send(.secureInputChanged(true))
        desk.type("ПРивет ", on: Fixture.russian)
        #expect(desk.corrections.isEmpty)
    }

    @Test func notForExceptions() {
        var desk = Desk(only({ $0.doubleCapitals = true; $0.yo = true }, exceptions: ["привет", "еще"]), current: ru)
        desk.type("ПРивет еще ", on: Fixture.russian)
        #expect(desk.text == "ПРивет еще ")
    }

    @Test func notWithoutAModel() {
        var desk = Desk(Self.settings, current: ru, classifier: nil)
        desk.type("ПРивет ", on: Fixture.russian)
        #expect(desk.text == "ПРивет ")
    }

    @Test func cancelledRetypeLeavesTheWord() {
        var desk = Desk(Self.settings, current: ru)
        desk.cancelRetypes = true
        desk.type("ПРивет ", on: Fixture.russian)
        #expect(desk.text == "ПРивет ")
        #expect(desk.corrections.isEmpty)
    }
}

@Suite struct CapsLockCorrectionTests {
    @Test func shiftOnTheFirstKeyMeansOneCapital() throws {
        var desk = Desk(only { $0.capsLock = true }, current: ru)
        desk.typeWithCapsLock("привет", on: Fixture.russian, shifted: [0])
        #expect(desk.text == "ПРИВЕТ")
        desk.press(KeyCode.space)
        #expect(desk.text == "Привет ")
        #expect(desk.log.contains(.capsLockOff))
        #expect(try #require(desk.corrections.first).original == "ПРИВЕТ")
    }

    @Test func invertedCaseIsFixed() {
        // Remote desktops invert Shift under Caps Lock: "пРИВЕТ".
        var desk = Desk(only { $0.capsLock = true }, current: ru)
        desk.type("пРИВЕТ ", on: Fixture.russian)
        #expect(desk.text == "Привет ")
        #expect(!desk.log.contains(.capsLockOff), "Caps Lock was not on")
    }

    @Test func capitalsWithoutShiftStay() {
        var desk = Desk(only { $0.capsLock = true }, current: ru)
        desk.typeWithCapsLock("привет ", on: Fixture.russian)
        #expect(desk.text == "ПРИВЕТ ")
        #expect(desk.corrections.isEmpty)
        #expect(!desk.log.contains(.capsLockOff))
    }

    @Test func unknownWordStays() {
        var desk = Desk(only { $0.capsLock = true }, current: ru)
        desk.typeWithCapsLock("приветик ", on: Fixture.russian, shifted: [0])
        #expect(desk.corrections.isEmpty)
        #expect(!desk.log.contains(.capsLockOff))
    }

    @Test func offByDefault() {
        #expect(TextCorrections().capsLock == false)
        var desk = Desk(current: ru)
        desk.type("пРИВЕТ ", on: Fixture.russian)
        #expect(desk.text == "пРИВЕТ ")
    }

    @Test func cancelledRetypeKeepsCapsLock() {
        var desk = Desk(only { $0.capsLock = true }, current: ru)
        desk.cancelRetypes = true
        desk.typeWithCapsLock("привет ", on: Fixture.russian, shifted: [0])
        #expect(!desk.log.contains(.capsLockOff))
    }
}

@Suite struct AbbreviationTests {
    @Test(arguments: [("мвд ", "МВД "), ("Мвд, ", "МВД, "), ("врио ", "ВрИО ")])
    func russian(typed: String, expected: String) {
        var desk = Desk(only { $0.abbreviations = true }, current: ru)
        desk.type(typed, on: Fixture.russian)
        #expect(desk.text == expected)
    }

    @Test func withDigits() {
        var desk = Desk(only { $0.abbreviations = true })
        desk.type("mp3 nasa ")
        #expect(desk.text == "MP3 NASA ")
    }

    @Test func spellingsThatOnlyKeepStay() {
        var desk = Desk(only { $0.abbreviations = true })
        desk.type("iphone ")
        #expect(desk.text == "iphone ")
        desk = Desk(only { $0.abbreviations = true }, current: ru)
        desk.type("гост ", on: Fixture.russian)
        #expect(desk.text == "гост ")
    }

    @Test func undoLearns() {
        var desk = Desk(only { $0.abbreviations = true }, current: ru)
        desk.type("мвд ", on: Fixture.russian)
        desk.press(KeyCode.delete)
        #expect(desk.text == "мвд ")
        #expect(desk.learned == ["мвд"])
    }

    @Test func offByDefault() {
        var desk = Desk(current: ru)
        desk.type("мвд ", on: Fixture.russian)
        #expect(desk.text == "мвд ")
    }
}

@Suite struct YoTests {
    @Test(arguments: [("еще ", "ещё "), ("Еще! ", "Ещё! "), ("елка ", "ёлка "), ("ЕЩЕ ", "ЕЩЁ "),
                      ("трехзвездный ", "трёхзвёздный ")])
    func unambiguousWords(typed: String, expected: String) {
        var desk = Desk(only { $0.yo = true }, current: ru)
        desk.type(typed, on: Fixture.russian)
        #expect(desk.text == expected)
    }

    @Test(arguments: ["все ", "всё ", "привет ", "трехзвёздный "])
    func othersStay(typed: String) {
        // "все" is a word of its own; a word with "ё" was written on purpose.
        var desk = Desk(only { $0.yo = true }, current: ru)
        desk.type(typed, on: Fixture.russian)
        #expect(desk.text == typed)
    }

    @Test func russianOnly() {
        // The English keys of "еще" are ",o," – no word, nothing to do.
        var desk = Desk(only { $0.yo = true })
        desk.type("tom ")
        #expect(desk.corrections.isEmpty)
    }

    @Test func offByDefault() {
        var desk = Desk(current: ru)
        desk.type("еще ", on: Fixture.russian)
        #expect(desk.text == "еще ")
    }

    @Test func withCapsLockFix() {
        // The steps run in order: case first, then "ё".
        var desk = Desk(only { $0.capsLock = true; $0.yo = true }, current: ru)
        desk.typeWithCapsLock("еще ", on: Fixture.russian, shifted: [0])
        #expect(desk.text == "Ещё ")
    }
}

@Suite struct PhraseRetypeTests {
    private static let settings = Settings(autoswitch: false, typoCorrection: false)

    @Test func everyOtherPressTakesOneWordMore() {
        var desk = Desk(Self.settings)
        desk.type("ghbdtn vbh")
        desk.tapOption()
        #expect(desk.text == "ghbdtn мир")
        desk.tapOption()
        #expect(desk.text == "ghbdtn vbh", "the second press puts the word back, as always")
        desk.tapOption()
        #expect(desk.text == "привет мир")
        #expect(desk.appLayout == ru)
        desk.tapOption()
        #expect(desk.text == "ghbdtn vbh")
        #expect(desk.appLayout == en)
    }

    @Test func spacesAfterTheLastWordStay() {
        var desk = Desk(Self.settings)
        desk.type("rfr ltkf ")
        for _ in 0..<3 { desk.tapOption() }
        #expect(desk.text == "как дела ")
    }

    @Test func withoutAWordBeforeTheSameWordAgain() {
        var desk = Desk(Self.settings)
        desk.type("vbh")
        for _ in 0..<3 { desk.tapOption() }
        #expect(desk.text == "мир")
    }

    @Test func goesBackAsFarAsTheBufferKeeps() {
        var desk = Desk(Self.settings)
        let words = Array(repeating: "vbh", count: WordBuffer.historyWords + 3)
        desk.type(words.joined(separator: " "))
        for _ in 0..<(2 * (WordBuffer.historyWords + 2) + 1) { desk.tapOption() }
        let kept = words.count - WordBuffer.historyWords - 1
        let expected = Array(repeating: "vbh", count: kept) + Array(repeating: "мир", count: words.count - kept)
        #expect(desk.text == expected.joined(separator: " "))
    }

    @Test func wordsAlreadyInTheTargetStay() {
        // The phrase goes into one layout: the target of the last word.
        var desk = Desk(Self.settings)
        desk.type("ghbdtn ")
        desk.tapOption()
        #expect(desk.text == "привет ")
        desk.tapShift() // back to ABC
        desk.type("vbh")
        desk.tapOption()
        desk.tapOption()
        desk.tapOption()
        #expect(desk.text == "привет мир")
    }

    @Test func typingStartsOver() {
        var desk = Desk(Self.settings)
        desk.type("ghbdtn vbh")
        desk.tapOption()
        desk.tapOption()
        desk.type(" c")
        desk.tapOption()
        #expect(desk.text == "ghbdtn vbh с", "a first press again: the last word only")
    }

    @Test func offEveryPressTogglesTheLastWord() {
        var settings = Self.settings
        settings.corrections.phraseRetype = false
        var desk = Desk(settings)
        desk.type("ghbdtn vbh")
        for _ in 0..<3 { desk.tapOption() }
        #expect(desk.text == "ghbdtn мир")
    }

    @Test func aClickStartsOver() {
        var desk = Desk(Self.settings)
        desk.type("ghbdtn vbh")
        desk.tapOption()
        desk.tapOption()
        desk.send(.click(time: desk.time, onHint: false))
        desk.tapOption()
        #expect(desk.text == "ghbdtn vbh", "the buffer is gone: nothing to retype")
    }
}

@Suite struct CorrectionModelTests {
    @Test func casedFormsAndYoMasks() throws {
        let model = ModelFixture.model
        let mvd = try #require(model.casedForm(of: ModelFormat.Fingerprint.of("мвд".unicodeScalars, folded: true)))
        #expect(mvd.form == "МВД" && mvd.corrects)
        let phone = try #require(model.casedForm(of: ModelFormat.Fingerprint.of("IPHONE".unicodeScalars, folded: true)))
        #expect(phone.form == "iPhone" && !phone.corrects)
        #expect(model.casedForm(of: ModelFormat.Fingerprint.of("привет".unicodeScalars, folded: true)) == nil)

        let russian = try #require(model.language("ru"))
        #expect(russian.yoMask(of: ModelFormat.Fingerprint.of("еще".unicodeScalars, folded: true)) == 0b10)
        #expect(russian.yoMask(of: ModelFormat.Fingerprint.of("трехзвездный".unicodeScalars, folded: true)) == 0b11)
        #expect(russian.yoMask(of: ModelFormat.Fingerprint.of("все".unicodeScalars, folded: true)) == nil)
        #expect(model.language("en")?.yoMask(of: 1) == nil)
    }

    @Test func tablesDoNotDependOnTheOrderOfCalls() {
        func build(_ yo: [String], _ cased: [(String, Bool)]) -> [UInt8] {
            var builder = ModelBuilder()
            builder.addLanguage("ru", alphabet: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-")
            for word in yo { builder.addYo(word, language: "ru") }
            for (form, corrects) in cased { builder.addCasedForm(form, corrects: corrects) }
            return builder.build()
        }
        let cased = [("МВД", false), ("Мвд", true), ("ООН", true)]
        let a = build(["ещё", "ёлка", "берёза"], cased)
        let b = build(["берёза", "ещё", "ёлка"], cased.reversed())
        #expect(a == b)
        let model = try? LanguageModel(bytes: a)
        let mvd = model?.casedForm(of: ModelFormat.Fingerprint.of("мвд".unicodeScalars, folded: true))
        #expect(mvd?.form == "Мвд" && mvd?.corrects == true, "a correcting spelling wins")
    }

    @Test func modelWithoutTheTablesCorrectsNothing() throws {
        var builder = ModelBuilder()
        builder.addLanguage("ru", alphabet: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-")
        builder.addForm("ещё", language: "ru", rank: 200, weight: 1)
        let model = try LanguageModel(bytes: builder.build())
        #expect(model.casedForm(of: 1) == nil)
        var word = BoundaryWord(characters: Array("еще"), modifiers: Array(repeating: [], count: 3), language: "ru")
        var settings = Settings()
        settings.corrections = TextCorrections(abbreviations: true, yo: true)
        #expect(!WordCorrections.run(&word, settings: settings, model: model))
    }

    @Test func yoRejectsWhatItCannotStore() {
        var builder = ModelBuilder()
        builder.addLanguage("ru", alphabet: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-")
        let noYo = builder.addYo("еще", language: "ru")
        let outside = builder.addYo("ёq", language: "ru")
        let tooMany = builder.addYo("ееееееёее", language: "ru")
        let fine = builder.addYo("ещё", language: "ru")
        #expect(!noYo && !outside && !tooMany && fine)
    }
}

@Suite struct TextCorrectionsTests {
    @Test func defaults() {
        let corrections = TextCorrections()
        #expect(corrections.phraseRetype && corrections.doubleCapitals)
        #expect(!corrections.capsLock && !corrections.abbreviations && !corrections.yo)
    }

    @Test func missingKeysDecodeToDefaults() throws {
        let decoded = try JSONDecoder().decode(TextCorrections.self, from: Data(#"{"yo": true}"#.utf8))
        #expect(decoded == TextCorrections(yo: true))
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.corrections == TextCorrections())
        #expect(settings.snapshot.corrections == TextCorrections())
    }
}
