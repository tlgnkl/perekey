// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

/// The retype shortcut right after an automatic fix takes it back, as
/// Backspace does, with every consequence of an undo.
@Suite struct UndoByRetypeTests {
    @Test func itStrikesTheFixFromTheRecentList() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        let seq = try #require(desk.corrections.first).seq
        desk.tapOption()
        #expect(desk.text == "[jhjij ")
        #expect(desk.undone == [seq])
    }

    @Test(arguments: [true, false])
    func itLearnsAsAnUndoDoes(learnFromUndos: Bool) {
        var desk = Desk(Settings(learnFromUndos: learnFromUndos))
        desk.type("[jhjij ")
        desk.tapOption()
        #expect(desk.learned == (learnFromUndos ? ["jhjij"] : []))
    }

    @Test func itWithdrawsAnAlwaysFixWord() {
        var desk = Desk(Settings(alwaysFix: WordRules(always: ["аня"]).alwaysFixTable))
        desk.type("Fyz ")
        #expect(desk.text == "Аня ")
        desk.tapOption()
        #expect(desk.text == "Fyz ")
        #expect(desk.withdrawn == ["аня"])
        #expect(desk.learned.isEmpty)
    }

    @Test func theContextLearnsTheOriginalLanguage() {
        var desk = Desk()
        desk.type("[jhjij ")
        #expect(desk.machine.judge.recent.latest == "ru")
        desk.tapOption()
        #expect(desk.machine.judge.recent.latest == "en")
    }

    @Test func laterTheShortcutRetypesAgain() {
        var desk = Desk()
        desk.type("[jhjij ")
        desk.type("ljv") // «дом», typed in Russian now
        #expect(desk.text == "хорошо дом")
        desk.tapOption()
        #expect(desk.text == "хорошо ljv")
        #expect(desk.undone.isEmpty, "a key after the fix closed its undo")
    }
}

/// What an undo or a manual retype tells the context waits for the retype
/// to be posted: a cancelled one tells nothing.
@Suite struct LanguageOnConfirmationTests {
    @Test func aCancelledUndoLeavesTheLanguageOfTheFix() {
        var desk = Desk()
        desk.type("[jhjij ")
        desk.cancelRetypes = true
        desk.press(KeyCode.delete)
        #expect(desk.text.hasPrefix("хорошо"), "the text stays corrected")
        #expect(desk.machine.judge.recent.latest == "ru")
    }

    @Test func aCancelledManualRetypeChoosesNothing() {
        var desk = Desk()
        desk.type("hello ")
        #expect(desk.machine.judge.recent.latest == "en")
        desk.cancelRetypes = true
        desk.tapOption()
        #expect(desk.machine.judge.recent.latest == "en")
        #expect(desk.machine.judge.recent.count == 1)
    }

    @Test func aPostedManualRetypeChooses() {
        var desk = Desk()
        desk.type("hello hello")
        desk.tapOption()
        #expect(desk.text == "hello руддщ")
        #expect(desk.machine.judge.recent == RecentLanguages(["ru"]))
    }

    @Test func anUndoMakesTheOriginalLayoutTheOneUsedLast() {
        var desk = Desk()
        desk.type("[jhjij ")          // Perekey goes to Russian: not the user's choice
        desk.type("руддщ ", on: Fixture.russian) // and back to English
        #expect(desk.machine.layouts.used.first == en)
        desk.tapOption()               // the user takes the second switch back
        #expect(desk.text.hasSuffix("руддщ "))
        #expect(desk.machine.layouts.used.first == ru)
    }

    @Test func aCancelledManualRetypeLeavesTheUsersLayoutFirst() {
        var desk = Desk()
        desk.type("hello")
        desk.cancelRetypes = true
        desk.tapOption()
        #expect(desk.appLayout == en)
        #expect(desk.machine.layouts.used.first == en, "not the target that never came")
    }
}
