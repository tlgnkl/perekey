// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

/// A "/" between two words ends a part of the token: each part is judged as
/// a word of its own (`WordJudge.endsPart`).
@Suite struct SlashPartTests {
    @Test func aPartInTheWrongLayoutSwitchesAtTheSlash() throws {
        // No impossible start: "[jhjij" is judged at its end, here the "/".
        var desk = Desk()
        desk.type("[jhjij/")
        #expect(desk.text == "хорошо/")
        #expect(desk.appLayout == ru)
        desk.type("vbh ")
        #expect(desk.text == "хорошо/мир ")
        let correction = try #require(desk.corrections.first)
        #expect(correction.original == "[jhjij")
        #expect(correction.replacement == "хорошо")
    }

    @Test func thePartAfterTheSlashIsAWordOfItsOwn() {
        // The whole token reads as code and stays; its last part does not.
        var desk = Desk(current: ru)
        desk.type("привет/цщкдв ", on: Fixture.russian)
        #expect(desk.text == "привет/world ")
        #expect(desk.appLayout == en)
    }

    @Test(arguments: ["github.com/ghbdtn ", "b/ghbdtn ", "ghBdtn/vbh ", "~/ghbdtn ", "/ghbdtn "])
    func theTokenStaysWhole(typed: String) {
        // Code before the "/", one key, a capital inside, nothing before it.
        var desk = Desk()
        desk.type(typed)
        #expect(desk.text == typed)
        #expect(desk.corrections.isEmpty)
    }

    @Test(arguments: [[Fixture.abc, Fixture.russianPC], [Fixture.abc, Fixture.russian, Fixture.ukrainianPC]])
    func noCutWhereTheKeyOfTheSlashTypesSomethingElse(layouts: [LayoutMap]) {
        // Russian – PC types "." on the key of "/"; Ukrainian – PC too, and the
        // word may switch to it. The "/" would not come back as "/".
        var desk = Desk(layouts: layouts)
        desk.type("[jhjij/vbh ")
        #expect(desk.text == "[jhjij/vbh ")
    }

    @Test func backspaceRightAfterUndoesThePart() throws {
        var desk = Desk()
        desk.type("[jhjij/")
        #expect(desk.text == "хорошо/")
        desk.press(KeyCode.delete)
        #expect(desk.text == "[jhjij/")
        #expect(desk.appLayout == en)
        #expect(desk.learned == ["jhjij"], "the bracket is no part of a word")
        // The undone token is left alone to its end, as an undone word is.
        desk.type("vbh ")
        #expect(desk.text == "[jhjij/vbh ")
    }

    @Test func alwaysFixActsOnThePart() {
        var desk = Desk(Settings(alwaysFix: WordRules(always: ["аня"]).alwaysFixTable))
        desk.type("hello/Fyz ")
        #expect(desk.text == "hello/Аня ")
    }

    @Test func theRetypeShortcutTakesThePartThenTheToken() {
        var desk = Desk(Settings(typoCorrection: false), current: ru)
        desk.type("привет/мир", on: Fixture.russian)
        desk.tapOption()
        #expect(desk.text == "привет/vbh")
        desk.tapOption()
        #expect(desk.text == "привет/мир")
        desk.tapOption()
        #expect(desk.text == "ghbdtn/vbh")
    }

    @Test func offWithoutAutomaticSwitching() {
        var desk = Desk(Settings(autoswitch: false, typoCorrection: false))
        desk.type("[jhjij/vbh ")
        #expect(desk.text == "[jhjij/vbh ")
    }
}
