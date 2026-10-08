// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

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

        var desk = Desk(Settings(alwaysFix: ["аня"]))
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
        var desk = Desk(Settings(alwaysFix: ["аня"]))
        desk.type(typed + " ")
        let switched = typed == "Fyz!"
        #expect(desk.text == (switched ? "Аня! " : "fyz, "))
    }

    @Test func theListedFormStays() throws {
        // "руддщ" typed in Russian would switch to "hello"; listed, it is right as typed.
        var plain = Desk(current: ru)
        plain.type("руддщ ", on: Fixture.russian)
        try #require(plain.text == "hello ")

        var desk = Desk(Settings(alwaysFix: ["руддщ"]), current: ru)
        desk.type("руддщ ", on: Fixture.russian)
        #expect(desk.text == "руддщ ")
        #expect(desk.corrections.isEmpty)
    }

    @Test func noEarlySwitchAwayFromAListedWord() {
        var plain = Desk()
        plain.type("ghb")
        #expect(plain.text == "при")

        var desk = Desk(Settings(alwaysFix: ["ghbdtn"]))
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
        var desk = Desk(Settings(alwaysFix: ["привет"]))
        desk.type(typed)
        #expect(desk.text == typed)
        #expect(desk.corrections.isEmpty)
    }

    @Test(arguments: [AppMode.manualOnly, AppMode.off])
    func appModeBeatsTheList(mode: AppMode) {
        var desk = Desk(Settings(alwaysFix: ["аня"]))
        desk.send(.appModeChanged(mode))
        desk.type("Fyz ")
        #expect(desk.text == "Fyz ")
    }

    @Test func passwordFieldAndSecureInputBeatTheList() {
        var field = Desk(Settings(alwaysFix: ["аня"]),
                         focus: Focus(bundleID: "com.apple.Safari", isSecureField: true))
        field.type("Fyz ")
        #expect(field.text == "Fyz ")

        var secure = Desk(Settings(alwaysFix: ["аня"]))
        secure.send(.secureInputChanged(true))
        secure.type("Fyz ")
        #expect(secure.text == "Fyz ")
    }

    @Test func autoswitchOffBeatsTheList() {
        var desk = Desk(Settings(autoswitch: false, alwaysFix: ["аня"]))
        desk.type("Fyz ")
        #expect(desk.text == "Fyz ")
    }

    @Test(arguments: ["fyz", "аня"])
    func neverTouchBeatsTheListInEitherReading(exception: String) {
        // The snapshot keeps the lists apart; a stale one must still not switch.
        var desk = Desk(Settings(exceptions: [exception], alwaysFix: ["аня"]))
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

    @Test func undoOfAnAlwaysFixLearnsTheTypedReading() {
        var desk = Desk(Settings(alwaysFix: ["аня"]))
        desk.type("Fyz ")
        desk.press(KeyCode.delete)
        #expect(desk.text == "Fyz ")
        #expect(desk.learned == ["fyz"])
    }

    @Test func emptyListChangesNothing() {
        for typed in ["Fyz ", "ghbdtn ", "hello ", "ghBdtn! "] {
            var plain = Desk()
            plain.type(typed)
            var listed = Desk(Settings(alwaysFix: []))
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

    @Test(arguments: [Classifier.Reason.noise, .bothPlausible, .shortWord, .compared])
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
