// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

@Suite struct AutoswitchTests {
    @Test func wordEndSwitches() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        #expect(desk.text == "хорошо ")
        #expect(desk.appLayout == ru)
        let correction = try #require(desk.corrections.first)
        #expect(correction.original == "[jhjij")
        #expect(correction.replacement == "хорошо")
        #expect(correction.source == en)
        #expect(correction.target == ru)
        #expect(correction.undoable)
        #expect(desk.corrections.count == 1)
    }

    @Test func russianPunctuationKeysStayInTheWord() {
        var desk = Desk()
        desk.type(",eltn ")
        #expect(desk.text == "будет ")
    }

    @Test func englishTypedInRussianSwitches() {
        var desk = Desk(current: ru)
        desk.type("руддщ ", on: Fixture.russian)
        #expect(desk.text == "hello ")
        #expect(desk.appLayout == en)
    }

    @Test func punctuationEndsTheWordAndLandsInTheNewLayout() {
        var desk = Desk()
        desk.type("[jhjij!")
        #expect(desk.text == "хорошо!")
        desk = Desk()
        desk.type("[jhjij?") // Shift+/ is "?" in both
        #expect(desk.text == "хорошо?")
    }

    @Test func returnEndsTheWordButCannotBeUndone() throws {
        var desk = Desk()
        desk.type("[jhjij")
        desk.press(KeyCode.return)
        #expect(desk.text == "хорошо\n")
        #expect(try #require(desk.corrections.first).undoable == false)
        desk.press(KeyCode.delete)
        #expect(desk.text == "хорошо")
        #expect(desk.undone.isEmpty)
    }

    @Test func impossiblePrefixSwitchesInsideTheWord() throws {
        var desk = Desk()
        desk.type("ghb")
        #expect(desk.text == "при")
        #expect(desk.appLayout == ru)
        #expect(desk.corrections.isEmpty, "reported when the word ends")
        desk.type("dtn ")
        #expect(desk.text == "привет ")
        let correction = try #require(desk.corrections.first)
        #expect(correction.original == "ghbdtn")
        #expect(correction.replacement == "привет")
        #expect(desk.corrections.count == 1)
    }

    @Test(arguments: ["ghbdtn vbh", "[jhjij vbh", "ghbdtn! vbh", "[jhjij! ,eltn"])
    func fastTypingKeepsOrderAndLayout(typed: String) {
        // The main thread lags behind the whole word: letters after the
        // switch must wait for the new layout, not go to the old one.
        var desk = Desk()
        desk.type(typed, settling: false)
        #expect(!desk.held.isEmpty, "the fence holds what follows the switch")
        desk.settle()
        let expected = Fixture.russian.type(Fixture.abc.strokes(typed))
        #expect(desk.text == expected)
    }

    @Test func fastTypingGivesPrivetMir() {
        var desk = Desk()
        desk.type("ghbdtn vbh", settling: false)
        desk.settle()
        #expect(desk.text == "привет мир")
    }

    @Test(arguments: ["hello ", "keyboard layout ", "https://example.com/path ", "print(x) ", "user@mail.ru ",
                      "ghBdtn!x ", "xkqzp ", "iPhone ", "a "])
    func keepCases(typed: String) {
        var desk = Desk()
        desk.type(typed)
        #expect(desk.text == typed)
        #expect(desk.corrections.isEmpty)
        #expect(desk.appLayout == en)
    }

    @Test func russianStaysRussian() {
        var desk = Desk(current: ru)
        desk.type("привет мир ", on: Fixture.russian)
        #expect(desk.text == "привет мир ")
        #expect(desk.corrections.isEmpty)
    }

    @Test(arguments: ["ghbdtn", "привет", "GHBDTN"])
    func exceptionsInEitherReadingAreKept(word: String) {
        let exception = WordExceptions.normalize(word)
        var desk = Desk(Settings(exceptions: [exception]))
        desk.type("ghbdtn ")
        #expect(desk.text == "ghbdtn ")
        #expect(desk.corrections.isEmpty)
        // Other words still switch.
        desk.type("[jhjij ")
        #expect(desk.text == "ghbdtn хорошо ")
    }

    @Test func previousWordIsContext() {
        // "f" alone after a Russian word is "а"; after an English one it stays.
        var desk = Desk(current: ru)
        desk.type("привет ", on: Fixture.russian)
        desk.tapShift() // the user switches to English by hand
        desk.type("f ")
        #expect(desk.text == "привет а ")

        desk = Desk()
        desk.type("hello f ")
        #expect(desk.text == "hello f ")
    }
}

@Suite struct AutoswitchGateTests {
    @Test(arguments: [AppMode.manualOnly, AppMode.off])
    func appModeKeepsItQuiet(mode: AppMode) {
        var desk = Desk()
        desk.send(.appModeChanged(mode))
        desk.type("ghbdtn [jhjij ")
        #expect(desk.text == "ghbdtn [jhjij ")
        #expect(desk.corrections.isEmpty)
        desk.send(.appModeChanged(.auto))
        desk.type("vbh ")
        #expect(desk.text == "ghbdtn [jhjij мир ")
    }

    @Test func manualRetypeWorksInManualOnly() {
        var desk = Desk()
        desk.send(.appModeChanged(.manualOnly))
        desk.type("ghbdtn")
        desk.tapOption()
        #expect(desk.text == "привет")
    }

    @Test func unknownFocusKeepsItQuiet() {
        var desk = Desk(focus: nil)
        desk.type("ghbdtn ")
        #expect(desk.text == "ghbdtn ")
        desk.send(.focusChanged(.unknown(bundleID: "com.apple.Safari")))
        desk.type("[jhjij ")
        #expect(desk.text == "ghbdtn [jhjij ")
        // A manual retype still works on an unknown focus.
        desk.tapOption()
        #expect(desk.text == "ghbdtn хорошо ")
    }

    @Test func passwordFieldKeepsItQuiet() {
        var desk = Desk(focus: Focus(bundleID: "com.apple.Safari", isSecureField: true))
        desk.type("ghbdtn ")
        #expect(desk.text == "ghbdtn ")
    }

    @Test func secureInputKeepsItQuiet() {
        var desk = Desk()
        desk.send(.secureInputChanged(true))
        desk.type("ghbdtn ")
        #expect(desk.text == "ghbdtn ")
        desk.send(.secureInputChanged(false))
        desk.type("[jhjij ")
        #expect(desk.text == "ghbdtn хорошо ")
    }

    @Test func settingToggle() {
        var desk = Desk(Settings(autoswitch: false))
        desk.type("ghbdtn ")
        #expect(desk.text == "ghbdtn ")
        desk.send(.settingsChanged(Settings(autoswitch: true)))
        desk.type("[jhjij ")
        #expect(desk.text == "ghbdtn хорошо ")
    }

    @Test func bothShiftsTurnItOff() {
        var desk = Desk()
        desk.time += 0.3
        for (keyCode, flags) in [(UInt16(56), Keyboard.leftShift), (60, Keyboard.leftShift | Keyboard.rightShift),
                                 (56, Keyboard.rightShift), (60, 0)]
        {
            desk.time += 0.01
            desk.send(.flagsChanged(keyCode: keyCode, flags: flags, origin: .user, time: desk.time))
        }
        #expect(desk.log == [.autoswitchChanged(false)])
        desk.type("ghbdtn ")
        #expect(desk.text == "ghbdtn ")
    }

    @Test func noClassifierNoSwitch() {
        var desk = Desk(classifier: nil)
        desk.type("ghbdtn ")
        #expect(desk.text == "ghbdtn ")
        desk.send(.classifierChanged(Desk.classifier))
        desk.type("[jhjij ")
        #expect(desk.text == "ghbdtn хорошо ")
    }

    @Test func cancelledSwitchLeavesTheWord() {
        var desk = Desk()
        desk.cancelRetypes = true
        desk.type("[jhjij vbh ")
        #expect(desk.text.hasPrefix("[jhjij "))
        #expect(desk.appLayout == en)
        #expect(desk.corrections.isEmpty)
    }
}

@Suite struct AutoswitchUndoTests {
    @Test func backspaceRightAfterUndoesAndLearns() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        let seq = try #require(desk.corrections.first).seq
        desk.press(KeyCode.delete)
        #expect(desk.text == "[jhjij ")
        #expect(desk.appLayout == en)
        #expect(desk.undone == [seq])
        #expect(desk.learned == ["jhjij"], "the bracket is no part of a word")
        // The next Backspace is an ordinary one.
        desk.press(KeyCode.delete)
        #expect(desk.text == "[jhjij")
        #expect(desk.undone.count == 1)
    }

    @Test func undoneWordIsNotSwitchedAgain() {
        var desk = Desk()
        desk.type("[jhjij!")
        desk.press(KeyCode.delete)
        #expect(desk.text == "[jhjij!")
        desk.type(" ")
        #expect(desk.text == "[jhjij! ")
        #expect(desk.corrections.count == 1)
        desk.type("vbh ")
        #expect(desk.text == "[jhjij! мир ")
    }

    @Test func undoAfterSwitchInsideTheWord() {
        var desk = Desk()
        desk.type("ghbdtn ")
        #expect(desk.text == "привет ")
        desk.press(KeyCode.delete)
        #expect(desk.text == "ghbdtn ")
        #expect(desk.learned == ["ghbdtn"])
        #expect(desk.undone.count == 1)
    }

    @Test func backspaceRightAfterEarlySwitchUndoesAndLearnsAtWordEnd() {
        var desk = Desk()
        desk.type("ghb")
        desk.press(KeyCode.delete)
        #expect(desk.text == "ghb")
        #expect(desk.learned.isEmpty, "only the start of the word is known")
        #expect(desk.undone.isEmpty, "never reported")
        desk.type("dtn ")
        #expect(desk.text == "ghbdtn ")
        #expect(desk.learned == ["ghbdtn"])
    }

    @Test func backspaceInsideTheWordFixesATypo() {
        var desk = Desk()
        desk.type("ghbdtnn")
        desk.press(KeyCode.delete)
        #expect(desk.text == "привет")
        desk.type(" ")
        #expect(desk.text == "привет ")
        #expect(desk.undone.isEmpty)
    }

    @Test func noLearningWhenOff() {
        var desk = Desk(Settings(learnFromUndos: false))
        desk.type("[jhjij ")
        desk.press(KeyCode.delete)
        #expect(desk.text == "[jhjij ")
        #expect(desk.learned.isEmpty)
        #expect(desk.undone.count == 1)
    }

    @Test func anotherKeyEndsTheChance() {
        var desk = Desk()
        desk.type("[jhjij v")
        desk.press(KeyCode.delete)
        #expect(desk.text == "хорошо ")
        #expect(desk.undone.isEmpty)
    }

    @Test func undoAction() {
        let f13: UInt16 = 105
        var settings = Settings()
        settings.hotkeys.append(HotkeyBinding(.key(keyCode: f13, modifiers: []), action: .undoLastCorrection))
        var desk = Desk(settings)
        desk.type("[jhjij ")
        desk.press(f13)
        #expect(desk.text == "[jhjij ")
        #expect(desk.learned == ["jhjij"], "the bracket is no part of a word")
        // Nothing left to undo.
        desk.press(f13)
        #expect(desk.text == "[jhjij ")
    }

    @Test func hintUndoAfterClickOnIt() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        let seq = try #require(desk.corrections.first).seq
        desk.send(.click(time: desk.time, onHint: true))
        desk.send(.undoLastCorrection(seq: seq, time: desk.time))
        desk.settle()
        #expect(desk.text == "[jhjij ")
        #expect(desk.undone.count == 1)
    }

    @Test(arguments: [false, true])
    func backspaceAfterClickIsOrdinary(onHint: Bool) {
        var desk = Desk()
        desk.type("[jhjij ")
        desk.send(.click(time: desk.time, onHint: onHint))
        desk.press(KeyCode.delete)
        #expect(desk.text == "хорошо")
        #expect(desk.undone.isEmpty)
    }

    @Test func undoEventWithoutCorrectionDoesNothing() {
        var desk = Desk()
        desk.type("hello ")
        desk.send(.undoLastCorrection(seq: 1, time: desk.time))
        desk.settle()
        #expect(desk.text == "hello ")
        #expect(desk.log.isEmpty)
    }

    @Test func focusChangeEndsTheChance() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        let seq = try #require(desk.corrections.first).seq
        desk.send(.focusChanged(Desk.textEdit))
        desk.send(.undoLastCorrection(seq: seq, time: desk.time))
        desk.settle()
        #expect(desk.text == "хорошо ")
    }
}

@Suite struct LearnableWordTests {
    @Test func readingThatTheListTakes() {
        #expect(CorrectionUndo.learnable("Ghbdtn", or: "Привет") == "ghbdtn")
        #expect(CorrectionUndo.learnable("[jhjij", or: "хорошо") == "jhjij")
        #expect(CorrectionUndo.learnable("ds,jh", or: "выбор") == "выбор")
        #expect(CorrectionUndo.learnable("a/b", or: "ф.и") == nil)
    }

    @Test func learnedWordStopsTheSwitch() {
        // What the app stores comes back in the next snapshot.
        var desk = Desk()
        desk.type("ds,jh ")
        #expect(desk.text == "выбор ")
        desk.press(KeyCode.delete)
        let word = desk.learned.first ?? ""
        desk.send(.settingsChanged(Settings(exceptions: [word])))
        desk.type("ds,jh ")
        #expect(desk.text == "ds,jh ds,jh ")
    }
}

@Suite struct AppSettingsSnapshotTests {
    @Test func exceptionsAndLearningGoToTheTap() {
        var settings = AppSettings()
        settings.words.add("Ghbdtn")
        settings.words.learn("vbh", at: 1)
        #expect(settings.snapshot.exceptions == ["ghbdtn", "vbh"])
        #expect(settings.snapshot.learnFromUndos)
        settings.words.learnFromUndos = false
        #expect(!settings.snapshot.learnFromUndos)
    }
}

/// Whatever may move the caret or change the text ends the chance to undo:
/// an undo then would erase someone else's text.
@Suite struct AutoswitchUndoSafetyTests {
    @Test func clickElsewhereEndsTheHintUndo() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        let seq = try #require(desk.corrections.first).seq
        desk.send(.click(time: desk.time)) // another paragraph, no AX there
        desk.send(.undoLastCorrection(seq: seq, time: desk.time))
        desk.settle()
        #expect(desk.text == "хорошо ")
        #expect(desk.undone.isEmpty)
        #expect(desk.learned.isEmpty)
    }

    @Test func clickWhileTheSwitchIsInFlightMakesItFinal() throws {
        var desk = Desk()
        desk.type("[jhjij ", settling: false)
        desk.send(.click(time: desk.time))
        desk.settle()
        #expect(try #require(desk.corrections.first).undoable == false, "no hint with Undo")
        desk.press(KeyCode.delete)
        #expect(desk.undone.isEmpty)
    }

    @Test func clickEndsAnOpenSwitchInsideTheWord() {
        var desk = Desk()
        desk.type("ghb")
        #expect(desk.text == "при")
        desk.send(.click(time: desk.time))
        desk.type("ljv ") // "дом", somewhere else
        #expect(desk.text == "придом ")
        #expect(desk.corrections.isEmpty, "the old word is not reported with the new letters")
        desk.press(KeyCode.delete)
        #expect(desk.text == "придом")
        #expect(desk.undone.isEmpty)
    }

    @Test func clickOnTheHintKeepsAnOpenSwitchFromGrowing() {
        var desk = Desk()
        desk.type("ghb")
        desk.send(.click(time: desk.time, onHint: true)) // an older hint
        desk.type("ljv ")
        #expect(desk.corrections.isEmpty)
    }

    @Test func navigationKeyEndsAnOpenSwitch() {
        var desk = Desk()
        desk.type("ghb")
        desk.press(KeyCode.leftArrow)
        desk.type("ljv ")
        #expect(desk.corrections.isEmpty)
        desk.press(KeyCode.delete)
        #expect(desk.undone.isEmpty)
    }

    @Test(arguments: [HotkeyAction.pastePlain, .switchLayout, .selectLanguage("ru"), .toggleAutoswitch])
    func shortcutEndsTheChance(action: HotkeyAction) {
        let f13: UInt16 = 105
        var settings = Settings()
        settings.hotkeys.append(HotkeyBinding(.key(keyCode: f13, modifiers: []), action: action))
        var desk = Desk(settings)
        desk.type("[jhjij ")
        desk.press(f13) // a plain paste would put text after the word
        desk.press(KeyCode.delete)
        #expect(desk.text == "хорошо")
        #expect(desk.undone.isEmpty)
    }

    @Test func olderHintDoesNotUndoANewerSwitch() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        desk.type("руддщ ", on: Fixture.russian)
        #expect(desk.text == "хорошо hello ")
        #expect(desk.corrections.count == 2)
        let older = desk.corrections[0].seq
        let newer = desk.corrections[1].seq
        desk.send(.undoLastCorrection(seq: older, time: desk.time))
        desk.settle()
        #expect(desk.text == "хорошо hello ")
        #expect(desk.undone.isEmpty)
        desk.send(.undoLastCorrection(seq: newer, time: desk.time))
        desk.settle()
        #expect(desk.text == "хорошо руддщ ")
        #expect(desk.undone == [newer])
    }

    @Test func hintOfAWordDoesNotUndoAnOpenSwitch() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        let seq = try #require(desk.corrections.first).seq
        desk.type("руддщ ", on: Fixture.russian)
        desk.type("ghb")
        desk.send(.undoLastCorrection(seq: seq, time: desk.time))
        desk.settle()
        #expect(desk.text == "хорошо hello при")
    }

    @Test func undoReportsOnlyOncePosted() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        let seq = try #require(desk.corrections.first).seq
        desk.press(KeyCode.delete, settling: false)
        #expect(desk.undone.isEmpty)
        #expect(desk.learned.isEmpty)
        desk.settle()
        #expect(desk.text == "[jhjij ")
        #expect(desk.undone == [seq])
        #expect(desk.learned == ["jhjij"])
    }

    @Test func cancelledUndoKeepsTheTextAndLetsTheBackspaceThrough() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        let seq = try #require(desk.corrections.first).seq
        desk.cancelRetypes = true // the caret check finds other text
        desk.press(KeyCode.delete, settling: false)
        desk.type("ljv", settling: false) // typed while the undo is in flight
        desk.settle()
        #expect(desk.text == "хорошодом", "an ordinary Backspace, then the letters")
        #expect(desk.appLayout == ru)
        #expect(desk.undone.isEmpty)
        #expect(desk.learned.isEmpty)
        #expect(desk.log.contains(.correctionUndoFailed(seq: seq)))
    }

    @Test func cancelledHintUndoChangesNothing() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        let seq = try #require(desk.corrections.first).seq
        desk.cancelRetypes = true
        desk.send(.click(time: desk.time, onHint: true))
        desk.send(.undoLastCorrection(seq: seq, time: desk.time))
        desk.settle()
        #expect(desk.text == "хорошо ")
        #expect(desk.learned.isEmpty)
        #expect(desk.log.contains(.correctionUndoFailed(seq: seq)))
    }

    @Test func switchInsideTheWordIsNotTakenBackAtItsEnd() {
        // "ghb" starts no English word, so it switches early; the whole
        // "ghbzzz" is English in this model. One retype, not two.
        let classifier = Classifier(model: ModelFixture.model(withRareEnglish: ["ghbzzz"]))
        var desk = Desk(classifier: classifier)
        desk.type("ghbzzz ")
        #expect(desk.text == Fixture.russian.type(Fixture.abc.strokes("ghbzzz ")))
        #expect(desk.appLayout == ru)
        #expect(desk.corrections.count == 1)
        #expect(desk.corrections.first?.source == en)
    }
}
