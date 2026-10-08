// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

/// The corrector on its own: candidates, the choice and the refusals.
@Suite struct TypoCorrectorTests {
    static let corrector = TypoCorrector(model: ModelFixture.model)

    static func correct(_ word: String, on layout: LayoutMap = Fixture.abc, sentenceStart: Bool = false) -> String? {
        corrector.correct(layout.strokes(word), in: layout, sentenceStart: sentenceStart)?.text
    }

    @Test func neighbouringKeys() {
        // Same row, rows above and below, staggered: "g" touches f h t y v b.
        #expect(KeyboardGeometry.neighbours(of: 5) == [3, 4, 9, 11, 16, 17])
        #expect(KeyboardGeometry.neighbours(of: 12) == [0, 13, 18, 19]) // q: a w 1 2; ` is too far
        #expect(KeyboardGeometry.neighbours(of: KeyCode.space).isEmpty)
        #expect(KeyboardGeometry.neighbours(of: 200).isEmpty)
    }

    @Test(arguments: [
        ("hwllo", "hello"), // w is next to e
        ("wrold", "world"), // transposition
        ("helllo", "hello"), // doubled letter
        ("wrld", "world"), // dropped letter
        ("keybaord", "keyboard"),
    ])
    func oneEditInEnglish(typed: String, expected: String) {
        #expect(Self.correct(typed) == expected)
    }

    @Test(arguments: [
        ("прривет", "привет"),
        ("рпивет", "привет"),
        ("првет", "привет"),
        ("спасибр", "спасибо"), // р is next to о
    ])
    func oneEditInRussian(typed: String, expected: String) {
        #expect(Self.correct(typed, on: Fixture.russian) == expected)
    }

    @Test func correctionKeepsASentenceInitialCapital() throws {
        let candidate = try #require(Self.corrector.correct(Fixture.abc.strokes("Wrold"), in: Fixture.abc,
                                                            sentenceStart: true))
        #expect(candidate.text == "World")
        #expect(candidate.strokes.first?.modifiers == [.shift])
        #expect(Fixture.abc.type(candidate.strokes) == "World")
    }

    @Test(arguments: ["Wrold", "wRold", "WROLD"])
    func capitalsInsideASentenceAreNames(typed: String) {
        #expect(Self.correct(typed) == nil)
    }

    @Test func knownWordsAreLeftAlone() {
        #expect(Self.correct("world") == nil)
        #expect(Self.correct("привет", on: Fixture.russian) == nil)
    }

    @Test func shortWordsAreLeftAlone() {
        #expect(Self.correct("wrd") == nil)
        #expect(Self.correct("hlo") == nil)
    }

    @Test func noCorrectionToAShorterWordThanTheMinimum() {
        // "them" is a word; "thm" is not touched: 3 letters.
        #expect(Self.correct("thm") == nil)
    }

    @Test func ambiguousWordsAreLeftAlone() {
        // "then" and "them" are one deletion away and as frequent as each other.
        #expect(Self.correct("thenm") == nil)
    }

    @Test func rareCandidatesAreNotOffered() {
        var options = TypoCorrector.Options()
        options.minScore = 150
        let strict = TypoCorrector(model: ModelFixture.model, options: options)
        // "keyboard" has rank 160 in the fixture; a swap costs 22.
        #expect(strict.correct(Fixture.abc.strokes("keybaord"), in: Fixture.abc, sentenceStart: false) == nil)
        #expect(Self.correct("keybaord") == "keyboard")
    }

    @Test func likelyEditsWinOverStrayLetters() {
        // "yeasr": a swap gives "years", a stray "s" gives "year". The swap
        // is the likelier typo, so "year" being a little more frequent does
        // not make the word ambiguous.
        let model = ModelFixture.model(withRareEnglish: ["year", "years"])
        let corrector = TypoCorrector(model: model)
        #expect(corrector.correct(Fixture.abc.strokes("yeasr"), in: Fixture.abc, sentenceStart: false)?.text == "years")
    }

    @Test func wordsWithSymbolsOrOptionAreLeftAlone() {
        #expect(Self.correct("wor-ld") == nil)
        #expect(Self.correct("don't") == nil)
        let strokes = Fixture.abc.strokes("wrol") + [KeyStroke(2, [.option])]
        #expect(Self.corrector.correct(strokes, in: Fixture.abc, sentenceStart: false) == nil)
    }

    @Test func trailingSpacesAreIgnored() {
        let strokes = Fixture.abc.strokes("wrold") + [KeyStroke(KeyCode.space)]
        #expect(Self.corrector.correct(strokes, in: Fixture.abc, sentenceStart: false)?.text == "world")
    }
}

/// Typo correction inside the machine: the retype, the hint, the undo and
/// the gates.
@Suite struct TypoCorrectionTests {
    static let on = Settings(typoCorrection: true)

    @Test func onByDefaultSinceItMetTheMetric() {
        #expect(Settings().typoCorrection)
        #expect(AppSettings().typoCorrection)
        var desk = Desk(Settings(typoCorrection: false))
        desk.type("wrold ")
        #expect(desk.text == "wrold ")
        #expect(desk.corrections.isEmpty)
    }

    @Test func fixesATypoAtTheSpace() throws {
        var desk = Desk(Self.on)
        desk.type("wrold ")
        #expect(desk.text == "world ")
        #expect(desk.appLayout == en)
        let correction = try #require(desk.corrections.first)
        #expect(correction.kind == .typo)
        #expect(correction.original == "wrold")
        #expect(correction.replacement == "world")
        #expect(correction.source == en)
        #expect(correction.target == en)
        #expect(correction.undoable)
        #expect(desk.corrections.count == 1)
    }

    @Test func fixesRussianTypos() {
        var desk = Desk(Self.on, current: ru)
        desk.type("прривет мир ", on: Fixture.russian)
        #expect(desk.text == "привет мир ")
        #expect(desk.corrections.count == 1)
    }

    @Test func punctuationEndsTheWordToo() {
        var desk = Desk(Self.on)
        desk.type("wrold!")
        #expect(desk.text == "world!")
    }

    @Test func returnEndsTheWordButCannotBeUndone() throws {
        var desk = Desk(Self.on)
        desk.type("wrold")
        desk.press(KeyCode.return)
        #expect(desk.text == "world\n")
        #expect(try #require(desk.corrections.first).undoable == false)
    }

    @Test func backspaceUndoesAndLearns() throws {
        var desk = Desk(Self.on)
        desk.type("wrold ")
        let seq = try #require(desk.corrections.first).seq
        desk.press(KeyCode.delete)
        #expect(desk.text == "wrold ")
        #expect(desk.undone == [seq])
        #expect(desk.learned == ["wrold"])
        // The Backspace was the undo, not a deletion; another one deletes.
        desk.press(KeyCode.delete)
        #expect(desk.text == "wrold")
        #expect(desk.undone.count == 1)
    }

    @Test func learnedWordIsNotCorrectedAgain() {
        var desk = Desk(Settings(exceptions: ["wrold"], typoCorrection: true))
        desk.type("wrold ")
        #expect(desk.text == "wrold ")
        #expect(desk.corrections.isEmpty)
    }

    @Test func fastTypingKeepsOrder() {
        var desk = Desk(Self.on)
        desk.type("wrold hello", settling: false)
        #expect(!desk.held.isEmpty)
        desk.settle()
        #expect(desk.text == "world hello")
    }

    @Test func capitalAtSentenceStartIsCorrectedInsideItIsNot() {
        var desk = Desk(Self.on)
        desk.type("Wrold ")
        #expect(desk.text == "World ")
        desk.type("Wrold ")
        #expect(desk.text == "World Wrold ")
        desk.type("hello. Wrold ")
        #expect(desk.text == "World Wrold hello. World ")
    }

    @Test(arguments: ["world ", "wrd ", "thenm ", "wRold ", "WROLD ", "print(x) ", "wor-ld "])
    func keepCases(typed: String) {
        var desk = Desk(Self.on)
        desk.type(typed)
        #expect(desk.text == typed)
        #expect(desk.corrections.isEmpty)
    }

    @Test func wrongLayoutTypoIsFixedByOneRetype() throws {
        // "[jhjij" is "хорошо"; a doubled letter in it is fixed with the switch.
        var desk = Desk(Self.on)
        desk.type("[jhjjij ")
        #expect(desk.text == "хорошо ")
        #expect(desk.appLayout == ru)
        let correction = try #require(desk.corrections.first)
        #expect(correction.kind == .typo)
        #expect(correction.original == "[jhjjij")
        #expect(correction.replacement == "хорошо")
        #expect(desk.corrections.count == 1)
        // Undo puts the typed keys back in the typed layout.
        desk.press(KeyCode.delete)
        #expect(desk.text == "[jhjjij ")
        #expect(desk.appLayout == en)
        #expect(desk.learned == ["jhjjij"])
    }

    @Test func worksWithoutAutoswitch() {
        var desk = Desk(Settings(autoswitch: false, typoCorrection: true))
        desk.type("wrold ")
        #expect(desk.text == "world ")
        desk.type("[jhjij ")
        #expect(desk.text == "world [jhjij ", "no switch without autoswitch")
    }

    @Test func cancelledRetypeLeavesTheWord() {
        var desk = Desk(Self.on)
        desk.cancelRetypes = true
        desk.type("wrold ")
        #expect(desk.text == "wrold ")
        #expect(desk.corrections.isEmpty)
        #expect(desk.held.isEmpty)
    }
}

@Suite struct TypoCorrectionGateTests {
    static let on = Settings(typoCorrection: true)

    @Test(arguments: [AppMode.manualOnly, AppMode.off])
    func appModeKeepsItQuiet(mode: AppMode) {
        var desk = Desk(Self.on)
        desk.send(.appModeChanged(mode))
        desk.type("wrold ")
        #expect(desk.text == "wrold ")
        #expect(desk.corrections.isEmpty)
    }

    @Test func unknownFocusKeepsItQuiet() {
        var desk = Desk(Self.on, focus: .unknown(bundleID: "x"))
        desk.type("wrold ")
        #expect(desk.text == "wrold ")
    }

    @Test func passwordFieldKeepsItQuiet() {
        var desk = Desk(Self.on, focus: Focus(bundleID: "x", isSecureField: true))
        desk.type("wrold ")
        #expect(desk.text == "wrold ")
    }

    @Test func secureInputKeepsItQuiet() {
        var desk = Desk(Self.on)
        desk.send(.secureInputChanged(true))
        desk.type("wrold ")
        #expect(desk.corrections.isEmpty)
    }

    @Test func noModelNoCorrection() {
        var desk = Desk(Self.on, classifier: nil)
        desk.type("wrold ")
        #expect(desk.text == "wrold ")
    }

    @Test func settingToggle() {
        var desk = Desk(Settings(typoCorrection: false))
        desk.type("wrold ")
        #expect(desk.text == "wrold ")
        desk.send(.settingsChanged(Self.on))
        desk.type("wrold ")
        #expect(desk.text == "wrold world ")
    }

    @Test func settingReachesTheSnapshot() {
        var settings = AppSettings()
        #expect(settings.snapshot.typoCorrection)
        settings.typoCorrection = false
        #expect(!settings.snapshot.typoCorrection)
    }
}
