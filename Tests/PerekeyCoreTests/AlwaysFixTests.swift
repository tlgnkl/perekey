// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

/// The snapshot's always-fix table of these words.
private func always(_ words: String...) -> [String: String] {
    WordRules(always: words).alwaysFixTable
}

/// "Всегда исправлять" in the word judge: the list beats the score, never a guard.
@Suite struct AlwaysFixTests {
    private func decision(_ typed: String) -> Classifier.Decision {
        Desk.classifier.classify(Fixture.abc.strokes(typed), typed: Fixture.abc, other: Fixture.russian)
    }

    @Test func switchesAWordTheClassifierKeeps() throws {
        // «Аня» is no word of the fixture model: alone, "Fyz" stays.
        try #require(decision("Fyz").verdict != .switch(to: ru))
        var plain = Desk()
        plain.type("Fyz ")
        #expect(plain.text == "Fyz ")

        var desk = Desk(Settings(alwaysFix: always("аня")))
        desk.type("Fyz ")
        #expect(desk.text == "Аня ")
        #expect(desk.appLayout == ru)
        let correction = try #require(desk.corrections.first)
        #expect(correction.original == "Fyz")
        #expect(correction.replacement == "Аня")
        #expect(correction.kind == .layout)
        #expect(correction.undoable)
        // Backspace still undoes it.
        desk.press(KeyCode.delete)
        #expect(desk.text == "Fyz ")
    }

    @Test(arguments: ["Fyz!", "fyz,"])
    func punctuationAroundTheWordStillMatches(typed: String) {
        // "," is "б" in Russian: "fyz," stays one token, and its core is no list word.
        var desk = Desk(Settings(alwaysFix: always("аня")))
        desk.type(typed + " ")
        let switched = typed == "Fyz!"
        #expect(desk.text == (switched ? "Аня! " : "fyz, "))
    }

    @Test func theListedFormStays() throws {
        // "руддщ" typed in Russian would switch to "hello"; listed, it is right as typed.
        var plain = Desk(current: ru)
        plain.type("руддщ ", on: Fixture.russian)
        try #require(plain.text == "hello ")

        var desk = Desk(Settings(alwaysFix: always("руддщ")), current: ru)
        desk.type("руддщ ", on: Fixture.russian)
        #expect(desk.text == "руддщ ")
        #expect(desk.corrections.isEmpty)
    }

    @Test func noEarlySwitchAwayFromAListedWord() {
        var plain = Desk()
        plain.type("ghb")
        #expect(plain.text == "при")

        var desk = Desk(Settings(alwaysFix: always("ghbdtn")))
        desk.type("ghbdtn ")
        #expect(desk.text == "ghbdtn ")
        #expect(desk.corrections.isEmpty)
    }

    @Test(arguments: ["ghBdtn! ", "gHbDtn "])
    func guardsBeatTheList(typed: String) throws {
        // Password-like ("прИвет!") and two capitals inside ("пРиВет"): the
        // other reading is "привет", on the list, and still nothing switches.
        let reason = decision(String(typed.dropLast())).reason
        try #require(reason.isGuard)
        var desk = Desk(Settings(alwaysFix: always("привет")))
        desk.type(typed)
        #expect(desk.text == typed)
        #expect(desk.corrections.isEmpty)
    }

    @Test(arguments: [AppMode.manualOnly, AppMode.off])
    func appModeBeatsTheList(mode: AppMode) {
        var desk = Desk(Settings(alwaysFix: always("аня")))
        desk.send(.appModeChanged(mode))
        desk.type("Fyz ")
        #expect(desk.text == "Fyz ")
    }

    @Test func passwordFieldAndSecureInputBeatTheList() {
        var field = Desk(Settings(alwaysFix: always("аня")),
                         focus: Focus(bundleID: "com.apple.Safari", isSecureField: true))
        field.type("Fyz ")
        #expect(field.text == "Fyz ")

        var secure = Desk(Settings(alwaysFix: always("аня")))
        secure.send(.secureInputChanged(true))
        secure.type("Fyz ")
        #expect(secure.text == "Fyz ")
    }

    @Test func autoswitchOffBeatsTheList() {
        var desk = Desk(Settings(autoswitch: false, alwaysFix: always("аня")))
        desk.type("Fyz ")
        #expect(desk.text == "Fyz ")
    }

    @Test(arguments: ["fyz", "аня"])
    func neverTouchBeatsTheListInEitherReading(exception: String) {
        // The snapshot keeps the lists apart; a stale one must still not switch.
        var desk = Desk(Settings(exceptions: [exception], alwaysFix: always("аня")))
        desk.type("Fyz ")
        #expect(desk.text == "Fyz ")
    }

    @Test func bothListsFromAnImportKeepTheWord() {
        var settings = AppSettings()
        settings.words = WordRules(mine: ["аня"], always: ["аня"])
        var desk = Desk(settings.snapshot)
        desk.type("Fyz ")
        #expect(desk.text == "Fyz ")
    }

    @Test(arguments: [true, false])
    func undoOfAnAlwaysFixWithdrawsTheWord(learnFromUndos: Bool) {
        var desk = Desk(Settings(alwaysFix: always("аня"), learnFromUndos: learnFromUndos))
        desk.type("Fyz ")
        #expect(desk.withdrawn.isEmpty, "only the undo withdraws")
        desk.press(KeyCode.delete)
        #expect(desk.text == "Fyz ")
        #expect(desk.withdrawn == ["аня"])
        #expect(desk.learned.isEmpty, "the latest signal wins: nothing learned")
        // The app takes the word off the list; the classifier decides alone.
        var settings = AppSettings(words: WordRules(always: ["аня"], learnFromUndos: learnFromUndos))
        settings.words.stopFixing(desk.withdrawn[0])
        desk.send(.settingsChanged(settings.snapshot))
        desk.type("Fyz ")
        #expect(desk.text == "Fyz Fyz ")
        #expect(desk.corrections.count == 1)
    }

    @Test func undoOfAnOrdinarySwitchStillLearns() {
        var desk = Desk(Settings(alwaysFix: always("аня")))
        desk.type("ghbdtn ")
        desk.press(KeyCode.delete)
        #expect(desk.learned == ["ghbdtn"])
        #expect(desk.withdrawn.isEmpty)
    }

    @Test func aFailedUndoWithdrawsNothing() throws {
        var desk = Desk(Settings(alwaysFix: always("аня")))
        desk.type("Fyz ")
        let seq = try #require(desk.corrections.first).seq
        desk.cancelRetypes = true
        desk.press(KeyCode.delete)
        #expect(desk.log.contains(.correctionUndoFailed(seq: seq)))
        #expect(desk.text == "Аня", "the Backspace goes through as an ordinary one")
        #expect(desk.withdrawn.isEmpty)
        #expect(desk.learned.isEmpty)
    }

    @Test(arguments: [("[jhjij ", "хорошо"), ("ghbdtn ", "привет")])
    func undoOfAClassifierSwitchToAListedWordWithdrawsIt(typed: String, word: String) {
        // The classifier switched it on its own, at the end or inside the
        // word ("ghb"); the word is listed all the same.
        var desk = Desk(Settings(alwaysFix: always(word)))
        desk.type(typed)
        #expect(desk.text == word + " ")
        desk.press(KeyCode.delete)
        #expect(desk.withdrawn == [word])
        #expect(desk.learned.isEmpty)
    }

    @Test func undoInsideTheWordOfAListedWordWithdrawsItAtTheEnd() {
        var desk = Desk(Settings(alwaysFix: always("привет")))
        desk.type("ghb")
        #expect(desk.text == "при")
        desk.press(KeyCode.delete)
        #expect(desk.text == "ghb")
        desk.type("dtn ")
        #expect(desk.text == "ghbdtn ")
        #expect(desk.withdrawn == ["привет"])
        #expect(desk.learned.isEmpty)
    }

    @Test(arguments: ["[jhJij ", "ds,Jh "])
    func aCapitalInsideBeatsTheList(typed: String) {
        // "ds,Jh" has a symbol in the typed reading: the classifier answers
        // `compared` before its mixed-case check. The judge checks it itself.
        var plain = Desk()
        plain.type(typed)
        var desk = Desk(Settings(alwaysFix: always("хорошо", "выбор")))
        desk.type(typed)
        #expect(desk.text == plain.text, "the list adds nothing to what the classifier decides")
    }

    @Test(arguments: [("fhntv ", "артём "), ("Fhntv ", "Артём "), ("FHNTV ", "АРТЁМ ")])
    func comesOutSpeltAsListed(typed: String, expected: String) throws {
        var desk = Desk(Settings(alwaysFix: always("артём")))
        desk.type(typed)
        #expect(desk.text == expected)
        // The undo puts back what was typed.
        desk.press(KeyCode.delete)
        #expect(desk.text == typed)
    }

    @Test func matchesWithYoAndApostropheFolded() {
        #expect(WordRules.matchKey(" Артём ") == "артем")
        #expect(WordRules.matchKey("rock\u{2019}n") == "rock'n")
        var desk = Desk(Settings(alwaysFix: always("артем")))
        desk.type("fhntv ")
        #expect(desk.text == "артем ", "stored without «ё», it comes out without")
    }

    @Test func emptyListChangesNothing() {
        for typed in ["Fyz ", "ghbdtn ", "hello ", "ghBdtn! "] {
            var plain = Desk()
            plain.type(typed)
            var listed = Desk(Settings(alwaysFix: [:]))
            listed.type(typed)
            #expect(listed.text == plain.text)
        }
    }
}

/// When the hint after a manual retype offers "Исправлять всегда".
@Suite struct OfferAlwaysFixTests {
    private let on = WordRules.OfferContext(autoswitch: true, appMode: .auto)

    private func decision(_ verdict: Classifier.Verdict, _ reason: Classifier.Reason,
                          score: Double = 4) -> Classifier.Decision
    {
        Classifier.Decision(verdict: verdict, score: score, reason: reason, language: nil)
    }

    @Test(arguments: [Classifier.Reason.noise, .bothPlausible, .compared])
    func offeredForDoubt(reason: Classifier.Reason) {
        #expect(WordRules.offerAlwaysFix(decision: decision(.keep, reason), context: on))
        #expect(WordRules.offerAlwaysFix(decision: decision(.unsure, reason), context: on))
    }

    @Test(arguments: [Classifier.Reason.empty, .unsupported, .tooLong, .digits, .kept, .passwordLike, .codeLike,
                      .mixedCase])
    func notOfferedForGuards(reason: Classifier.Reason) {
        #expect(reason.isGuard)
        #expect(!WordRules.offerAlwaysFix(decision: decision(.keep, reason, score: 0), context: on))
    }

    @Test func notOfferedForAShortWord() {
        // A doubt, but the list takes no word of 1–2 letters.
        #expect(!Classifier.Reason.shortWord.isGuard)
        #expect(!WordRules.offerAlwaysFix(decision: decision(.keep, .shortWord), context: on))
    }

    @Test func notOfferedWhenTheOtherReadingIsNoWord() {
        #expect(!WordRules.offerAlwaysFix(decision: decision(.keep, .compared, score: -.infinity), context: on))
    }

    @Test func notOfferedForASwitch() {
        // Automatic switching would have switched it: a guard outside the
        // classifier kept it (focus, a list), not a doubt.
        #expect(!WordRules.offerAlwaysFix(decision: decision(.switch(to: ru), .compared, score: 30), context: on))
    }

    @Test func needsAutoswitchAutoModeAndAnUnlistedWord() {
        let doubt = decision(.unsure, .compared)
        #expect(!WordRules.offerAlwaysFix(decision: doubt, context: .init(autoswitch: false, appMode: .auto)))
        #expect(!WordRules.offerAlwaysFix(decision: doubt, context: .init(autoswitch: true, appMode: .manualOnly)))
        #expect(!WordRules.offerAlwaysFix(decision: doubt, context: .init(autoswitch: true, appMode: .off)))
        #expect(!WordRules.offerAlwaysFix(decision: doubt,
                                          context: .init(autoswitch: true, appMode: .auto, listed: true)))
    }

    @Test func realDecisionsOfTheFixtureModel() {
        let classify = { (typed: String) in
            Desk.classifier.classify(Fixture.abc.strokes(typed), typed: Fixture.abc, other: Fixture.russian)
        }
        #expect(WordRules.offerAlwaysFix(decision: classify("Fyz"), context: on))
        #expect(!WordRules.offerAlwaysFix(decision: classify("ghbdtn"), context: on), "switched already")
        #expect(!WordRules.offerAlwaysFix(decision: classify("ghbdtn1"), context: on), "digits")
    }
}
